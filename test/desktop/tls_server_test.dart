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

  test('a pong from an unauthenticated connection is allowed (defence in depth) and does not close it', () async {
    final socket = await connectPinned('127.0.0.1', server.port, id.fingerprintB64Url);
    var closed = false;
    socket.listen((_) {}, onDone: () => closed = true, onError: (Object _) => closed = true);
    socket.add(encodeFrame(Codec.encode(const PongMsg())));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(closed, isFalse, reason: 'a pong answering a ping sent before the connection authenticated must not be rejected as a disallowed pre-auth frame');
    await socket.close();
  });

  test('sendPings only writes to authenticated connections', () async {
    final unauth = await connectPinned('127.0.0.1', server.port, id.fingerprintB64Url);
    final inbox = StreamQueue<String>(FrameDecoder().bind(unauth));

    session.startPairing();
    final authed = await connectPinned('127.0.0.1', server.port, id.fingerprintB64Url);
    final authedInbox = StreamQueue<String>(FrameDecoder().bind(authed));
    authed.add(encodeFrame(Codec.encode(PairMsg(token: session.pairingToken!, name: 'Fake', pub: keys.pubSpkiB64))));
    final ch = Codec.decode(await authedInbox.next) as PairChallengeMsg;
    authed.add(encodeFrame(Codec.encode(PairProofMsg(sig: keys.sign('$pairProofDomain${ch.nonce}')))));
    expect(Codec.decode(await authedInbox.next), isA<PairedMsg>());

    server.sendPings();

    // The authenticated connection gets a real ping...
    expect(Codec.decode(await authedInbox.next.timeout(const Duration(seconds: 2))), isA<PingMsg>());
    // ...but the unauthenticated one, still sitting mid-nothing, gets
    // nothing at all — give it a beat to prove no frame ever arrives.
    var unauthGotSomething = false;
    unawaited(inbox.next.then(
      (_) {
        unauthGotSomething = true;
      },
      // Expected once the socket below is closed with nothing ever having
      // arrived: the queue's pending `next()` completes with an error
      // rather than a value.
      onError: (Object _) {},
    ));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(unauthGotSomething, isFalse, reason: 'sendPings must never write to a connection that has not authenticated');

    await unauth.close();
    await authed.close();
  });

  test('a frame decoded from the same chunk right after a disallowed frame closed the connection is never processed', () async {
    session.startPairing();
    final socket = await connectPinned('127.0.0.1', server.port, id.fingerprintB64Url);
    final closed = Completer<void>();
    socket.listen((_) {}, onDone: closed.complete, onError: (Object _) => closed.complete());

    // A bare `ping` from an unauthenticated connection is disallowed (see
    // _isAllowedUnauthFrame) and closes it — a `pair` frame right behind
    // it, in the exact same write (so both decode out of one chunk), must
    // never reach session.onFrame for that now-dead connection id.
    final ping = encodeFrame(Codec.encode(const PingMsg()));
    final pair = encodeFrame(Codec.encode(PairMsg(token: session.pairingToken!, name: 'Fake', pub: keys.pubSpkiB64)));
    socket.add(ping + pair);
    await closed.future.timeout(const Duration(seconds: 2));

    // If the `pair` frame had reached the session despite the connection
    // being dropped, it would have consumed the one-shot pairing token —
    // a fresh connection presenting the same token would then be
    // rejected. Assert it's still usable instead.
    final retry = await connectPinned('127.0.0.1', server.port, id.fingerprintB64Url);
    final inbox = StreamQueue<String>(FrameDecoder().bind(retry));
    retry.add(encodeFrame(Codec.encode(PairMsg(token: session.pairingToken!, name: 'Fake2', pub: keys.pubSpkiB64))));
    expect(Codec.decode(await inbox.next.timeout(const Duration(seconds: 2))), isA<PairChallengeMsg>(), reason: 'the token was never consumed by the frame that arrived after the connection was already dropped');
    await retry.close();
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

  test('the liveness close of an authenticated connection runs onDisconnect: phone goes offline and requestAuth reports noPhone', () async {
    await server.stop();
    server = TlsServer(identity: id, session: session, onEffect: effects.add, livenessTimeout: const Duration(milliseconds: 300));
    await server.start(address: '127.0.0.1', port: 0);

    session.startPairing();
    final socket = await connectPinned('127.0.0.1', server.port, id.fingerprintB64Url);
    final inbox = StreamQueue<String>(FrameDecoder().bind(socket));
    socket.add(encodeFrame(Codec.encode(PairMsg(token: session.pairingToken!, name: 'Fake', pub: keys.pubSpkiB64))));
    final ch = Codec.decode(await inbox.next) as PairChallengeMsg;
    socket.add(encodeFrame(Codec.encode(PairProofMsg(sig: keys.sign('biokey-pair:${ch.nonce}')))));
    expect(Codec.decode(await inbox.next), isA<PairedMsg>());
    expect(session.phoneOnline, isTrue);

    // The phone stays silent (no frame, not even a ping): the liveness
    // timer should close the socket and — this is the regression under
    // test — that close must run session.onDisconnect exactly once, not
    // silently forget the connection.
    var socketClosed = false;
    unawaited(inbox.rest.drain<void>().catchError((_) {}).whenComplete(() => socketClosed = true));
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(socketClosed, isTrue, reason: 'the liveness timeout must close the dead connection');
    expect(session.phoneOnline, isFalse, reason: 'onDisconnect must have run for the tray/session to notice the phone went offline');
    expect(effects.whereType<PhoneOnline>().where((e) => !e.online).length, 1, reason: 'onDisconnect must run exactly once');

    final (_, fx) = session.requestAuth(label: 'Mon app');
    expect(fx.single, isA<AuthResolved>().having((e) => e.outcome, 'outcome', AuthOutcome.noPhone));
  });

  test('the idle close of an unauthenticated (mid-pairing) connection runs onDisconnect exactly once', () async {
    await server.stop();
    server = TlsServer(identity: id, session: session, onEffect: effects.add, pairingIdle: const Duration(milliseconds: 300));
    await server.start(address: '127.0.0.1', port: 0);

    session.startPairing();
    final socket = await connectPinned('127.0.0.1', server.port, id.fingerprintB64Url);
    final inbox = StreamQueue<String>(FrameDecoder().bind(socket));
    socket.add(encodeFrame(Codec.encode(PairMsg(token: session.pairingToken!, name: 'Fake', pub: keys.pubSpkiB64))));
    await inbox.next; // pair_challenge: now mid-pairing, still unauthenticated.

    var socketClosed = false;
    unawaited(inbox.rest.drain<void>().catchError((_) {}).whenComplete(() => socketClosed = true));
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(socketClosed, isTrue);
    // onDisconnect running exactly once is observable here as exactly one
    // PairingExpired effect (it clears the dangling pairing candidate);
    // before the fix, CloseConn from the idle timer never reached
    // onDisconnect at all, so this would be empty.
    expect(effects.whereType<PairingExpired>().length, 1);
  });

  test('an unauthenticated client pinging every 200ms with a 500ms idle deadline is still closed', () async {
    await server.stop();
    server = TlsServer(identity: id, session: session, onEffect: effects.add, unauthIdle: const Duration(milliseconds: 500));
    await server.start(address: '127.0.0.1', port: 0);

    final socket = await connectPinned('127.0.0.1', server.port, id.fingerprintB64Url);
    final closed = Completer<void>();
    socket.listen((_) {}, onDone: closed.complete, onError: (Object _) => closed.complete());
    // A `ping` from a connection that never authenticated must not extend
    // (or even survive on) its idle deadline: TlsServer drops any frame
    // from an unauthenticated connection that isn't pair/pair_proof/hello,
    // and — even if it somehow got through — frames no longer re-arm the
    // unauthenticated idle timer at all, so pinging can't hold the slot
    // open past the 500ms absolute deadline either.
    final pinger = Timer.periodic(const Duration(milliseconds: 200), (_) {
      try {
        socket.add(encodeFrame(Codec.encode(const PingMsg())));
      } on Object {
        // Already closed: nothing to do.
      }
    });
    await closed.future.timeout(const Duration(seconds: 2), onTimeout: () => fail('pinging kept the unauthenticated connection alive past its deadline'));
    pinger.cancel();
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
