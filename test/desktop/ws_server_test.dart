import 'dart:io';
import 'package:async/async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/core/crypto/identity.dart';
import 'package:biokey/core/crypto/verify.dart';
import 'package:biokey/core/protocol/codec.dart';
import 'package:biokey/core/protocol/messages.dart';
import 'package:biokey/core/session/clock.dart';
import 'package:biokey/core/session/desktop_session.dart';
import 'package:biokey/desktop/server/ws_server.dart';
import '../support/test_keys.dart';

Future<WebSocket> connectPinned(String host, int port, String fp) {
  final c = HttpClient()..badCertificateCallback = (cert, _, _) => certFingerprintB64Url(cert.der) == fp;
  return WebSocket.connect('wss://$host:$port/', customClient: c);
}

void main() {
  late DesktopIdentity id;
  late DesktopSession session;
  late WsServer server;
  final effects = <DesktopEffect>[];
  final keys = TestKeys();

  setUp(() async {
    id = generateDesktopIdentity(pcName: 'PC-TEST');
    session = DesktopSession(pcId: id.pcId, pcName: 'PC-TEST', verifier: const EcdsaVerifier(), clock: const SystemClock());
    effects.clear();
    server = WsServer(identity: id, session: session, onEffect: effects.add);
    await server.start(address: '127.0.0.1', port: 0);
  });
  tearDown(() => server.stop());

  test('handshake fails when fingerprint does not match', () async {
    expect(connectPinned('127.0.0.1', server.port, 'wrong').timeout(const Duration(seconds: 5)), throwsA(anything));
  });

  test('pair then auth over real TLS websocket', () async {
    session.startPairing();
    final ws = await connectPinned('127.0.0.1', server.port, id.fingerprintB64Url);
    final inbox = StreamQueue<String>(ws.map((e) => e as String));
    ws.add(Codec.encode(PairMsg(token: session.pairingToken!, name: 'Fake', pub: keys.pubSpkiB64)));
    final ch = Codec.decode(await inbox.next) as PairChallengeMsg;
    ws.add(Codec.encode(PairProofMsg(sig: keys.sign(ch.nonce))));
    expect(Codec.decode(await inbox.next), isA<PairedMsg>());
    expect(session.phoneOnline, isTrue);

    final (authId, fx) = session.requestAuth(label: 'Mon app');
    server.apply(fx);
    final frame = await inbox.next;
    expect((Codec.decode(frame) as AuthMsg).id, authId);
    ws.add(Codec.encode(AuthOkMsg(id: authId, sig: keys.sign(frame))));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final resolved = effects.whereType<AuthResolved>().single;
    expect(resolved.outcome, AuthOutcome.approved);

    await ws.close();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(session.phoneOnline, isFalse);
  });

  test('malformed frame gets the socket closed', () async {
    final ws = await connectPinned('127.0.0.1', server.port, id.fingerprintB64Url);
    // dart:io's WebSocket only pumps its internal (close-handshake-driving)
    // subscription once the public stream has a listener, so `ws.done`
    // never completes on an otherwise-undrained socket; a no-op listener
    // is enough to observe the server-initiated close.
    ws.listen((_) {});
    ws.add('nope');
    await ws.done.timeout(const Duration(seconds: 2));
  });
}
