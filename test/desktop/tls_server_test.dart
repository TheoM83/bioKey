import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:async/async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/core/crypto/identity.dart';
import 'package:biokey/core/crypto/verify.dart';
import 'package:biokey/core/protocol/codec.dart';
import 'package:biokey/core/protocol/framing.dart';
import 'package:biokey/core/protocol/messages.dart';
import 'package:biokey/core/session/clock.dart';
import 'package:biokey/core/session/desktop_session.dart';
import 'package:biokey/desktop/server/tls_server.dart';
import '../support/test_keys.dart';

Future<SecureSocket> connectPinned(String host, int port, String fp) => SecureSocket.connect(
      host,
      port,
      context: SecurityContext(withTrustedRoots: false),
      onBadCertificate: (cert) => certFingerprintB64Url(cert.der) == fp,
      timeout: const Duration(seconds: 4),
    );

void main() {
  late DesktopIdentity id;
  late DesktopSession session;
  late TlsServer server;
  final effects = <DesktopEffect>[];
  final keys = TestKeys();

  setUp(() async {
    id = generateDesktopIdentity(pcName: 'PC-TEST');
    session = DesktopSession(pcId: id.pcId, pcName: 'PC-TEST', verifier: const EcdsaVerifier(), clock: const SystemClock());
    effects.clear();
    server = TlsServer(identity: id, session: session, onEffect: effects.add);
    await server.start(address: '127.0.0.1', port: 0);
  });
  tearDown(() => server.stop());

  test('handshake fails when fingerprint does not match, and no connection is left registered', () async {
    await expectLater(
      connectPinned('127.0.0.1', server.port, 'wrong').timeout(const Duration(seconds: 5)),
      throwsA(isA<HandshakeException>()),
    );
    // Give the server a beat to notice the aborted handshake.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(server.connections, isEmpty);
  });

  test('pair then auth over real pinned TLS', () async {
    session.startPairing();
    final socket = await connectPinned('127.0.0.1', server.port, id.fingerprintB64Url);
    final inbox = StreamQueue<String>(FrameDecoder().bind(socket));
    socket.add(encodeFrame(Codec.encode(PairMsg(token: session.pairingToken!, name: 'Fake', pub: keys.pubSpkiB64))));
    final ch = Codec.decode(await inbox.next) as PairChallengeMsg;
    socket.add(encodeFrame(Codec.encode(PairProofMsg(sig: keys.sign('biokey-pair:${ch.nonce}')))));
    expect(Codec.decode(await inbox.next), isA<PairedMsg>());
    expect(session.phoneOnline, isTrue);

    final (authId, fx) = session.requestAuth(label: 'Mon app');
    server.apply(fx);
    final frame = await inbox.next;
    expect((Codec.decode(frame) as AuthMsg).id, authId);
    socket.add(encodeFrame(Codec.encode(AuthOkMsg(id: authId, sig: keys.sign(frame)))));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final resolved = effects.whereType<AuthResolved>().single;
    expect(resolved.outcome, AuthOutcome.approved);

    await socket.close();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(session.phoneOnline, isFalse);
  });

  test('malformed frame content gets the socket closed', () async {
    final socket = await connectPinned('127.0.0.1', server.port, id.fingerprintB64Url);
    final done = Completer<void>();
    socket.listen((_) {}, onDone: done.complete, onError: (Object _) => done.complete());
    socket.add(encodeFrame('nope'));
    await done.future.timeout(const Duration(seconds: 2));
  });

  test('a length prefix of exactly the max frame size is accepted; one byte over is rejected', () async {
    // At the limit: the header alone must not get the socket closed — the
    // decoder should be waiting for a body, not rejecting outright.
    final atLimit = await connectPinned('127.0.0.1', server.port, id.fingerprintB64Url);
    var atLimitClosed = false;
    atLimit.listen((_) {}, onDone: () => atLimitClosed = true, onError: (Object _) => atLimitClosed = true);
    final okHeader = ByteData(4)..setUint32(0, maxFrameBytes);
    atLimit.add(okHeader.buffer.asUint8List());
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(atLimitClosed, isFalse, reason: '65536 is exactly maxFrameBytes and must be accepted, not rejected');
    await atLimit.close();

    // One byte over: rejected as soon as the header is read.
    final overLimit = await connectPinned('127.0.0.1', server.port, id.fingerprintB64Url);
    final done = Completer<void>();
    overLimit.listen((_) {}, onDone: done.complete, onError: (Object _) => done.complete());
    final badHeader = ByteData(4)..setUint32(0, maxFrameBytes + 1);
    overLimit.add(badHeader.buffer.asUint8List());
    await done.future.timeout(const Duration(seconds: 2));
  });

  test('an oversized length prefix gets the socket closed', () async {
    final socket = await connectPinned('127.0.0.1', server.port, id.fingerprintB64Url);
    final done = Completer<void>();
    socket.listen((_) {}, onDone: done.complete, onError: (Object _) => done.complete());
    final hdr = ByteData(4)..setUint32(0, 5 * 1024 * 1024);
    socket.add(hdr.buffer.asUint8List());
    await done.future.timeout(const Duration(seconds: 2));
  });

  test('more than 8 concurrent connections are refused', () async {
    final open = <SecureSocket>[];
    for (var i = 0; i < TlsServer.maxConnections; i++) {
      open.add(await connectPinned('127.0.0.1', server.port, id.fingerprintB64Url));
    }
    // The 9th connection completes its TLS handshake (a raw TCP+TLS accept
    // can't be gated before that) but is destroyed immediately, before any
    // frame is ever read.
    final extra = await connectPinned('127.0.0.1', server.port, id.fingerprintB64Url);
    final done = Completer<void>();
    extra.listen((_) {}, onDone: done.complete, onError: (Object _) => done.complete());
    await done.future.timeout(const Duration(seconds: 2));
    for (final socket in open) {
      await socket.close();
    }
  });

  test('an unauthenticated socket is closed after the idle delay; an authenticated one is not', () async {
    await server.stop();
    server = TlsServer(identity: id, session: session, onEffect: effects.add, unauthIdle: const Duration(milliseconds: 200));
    await server.start(address: '127.0.0.1', port: 0);

    final idle = await connectPinned('127.0.0.1', server.port, id.fingerprintB64Url);
    final closed = Completer<void>();
    idle.listen((_) {}, onDone: closed.complete, onError: (Object _) => closed.complete());
    await closed.future.timeout(const Duration(seconds: 2));

    session.startPairing();
    final socket = await connectPinned('127.0.0.1', server.port, id.fingerprintB64Url);
    final inbox = StreamQueue<String>(FrameDecoder().bind(socket));
    socket.add(encodeFrame(Codec.encode(PairMsg(token: session.pairingToken!, name: 'Fake', pub: keys.pubSpkiB64))));
    final ch = Codec.decode(await inbox.next) as PairChallengeMsg;
    socket.add(encodeFrame(Codec.encode(PairProofMsg(sig: keys.sign('biokey-pair:${ch.nonce}')))));
    expect(Codec.decode(await inbox.next), isA<PairedMsg>());
    var socketClosed = false;
    unawaited(inbox.rest.drain<void>().catchError((_) {}).whenComplete(() => socketClosed = true));
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(socketClosed, isFalse, reason: 'authenticated sockets are exempt from the (short) unauth idle rule');
    expect(session.phoneOnline, isTrue);
    await socket.close();
  });
}
