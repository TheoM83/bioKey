import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/core/crypto/verify.dart';
import 'package:biokey/core/protocol/codec.dart';
import 'package:biokey/core/protocol/messages.dart';
import 'package:biokey/core/session/clock.dart';
import 'package:biokey/core/session/desktop_session.dart';
import '../../support/test_keys.dart';

void main() {
  final keys = TestKeys();
  late FakeClock clock;
  late DesktopSession s;

  setUp(() {
    clock = FakeClock(1000);
    s = DesktopSession(pcId: 'pc1', pcName: 'PC', verifier: const EcdsaVerifier(), clock: clock);
  });

  T single<T extends DesktopEffect>(List<DesktopEffect> fx) => fx.whereType<T>().single;
  Message sent(List<DesktopEffect> fx) => Codec.decode(single<SendFrame>(fx).frame);

  List<DesktopEffect> pairFully(String conn) {
    s.startPairing();
    final fx1 = s.onFrame(conn, Codec.encode(PairMsg(token: s.pairingToken!, name: 'Nothing', pub: keys.pubSpkiB64)));
    final ch = sent(fx1) as PairChallengeMsg;
    return s.onFrame(conn, Codec.encode(PairProofMsg(sig: keys.sign(ch.nonce))));
  }

  test('full pairing succeeds and phone becomes online', () {
    final fx = pairFully('c1');
    expect(sent(fx), isA<PairedMsg>());
    expect(single<PhonePaired>(fx).phone.pub, keys.pubSpkiB64);
    expect(single<PhoneOnline>(fx).online, isTrue);
    expect(s.pairingToken, isNull);
  });

  test('wrong token, expired token, reused token all close', () {
    s.startPairing();
    expect(s.onFrame('c1', Codec.encode(PairMsg(token: 'bad', name: 'n', pub: 'p'))).single, isA<CloseConn>());
    s.startPairing();
    final tok = s.pairingToken!;
    clock.now += 121;
    expect(s.onFrame('c1', Codec.encode(PairMsg(token: tok, name: 'n', pub: 'p'))).single, isA<CloseConn>());
    clock.now = 1000;
    pairFully('c2');
    expect(s.onFrame('c3', Codec.encode(PairMsg(token: tok, name: 'n', pub: 'p'))).single, isA<CloseConn>());
  });

  test('bad pair_proof signature closes', () {
    s.startPairing();
    s.onFrame('c1', Codec.encode(PairMsg(token: s.pairingToken!, name: 'n', pub: keys.pubSpkiB64)));
    expect(s.onFrame('c1', Codec.encode(const PairProofMsg(sig: 'AAAA'))).single, isA<CloseConn>());
  });

  test('hello with known pub → welcome; unknown pub → unknown + close', () {
    pairFully('c1');
    s.onDisconnect('c1');
    final fx = s.onFrame('c2', Codec.encode(HelloMsg(pcId: 'pc1', pub: keys.pubSpkiB64)));
    expect(sent(fx), isA<WelcomeMsg>());
    final bad = s.onFrame('c3', Codec.encode(const HelloMsg(pcId: 'pc1', pub: 'other')));
    expect(sent(bad), isA<UnknownMsg>());
    expect(bad.whereType<CloseConn>(), isNotEmpty);
  });

  test('auth approved with valid signature over the exact frame', () {
    pairFully('c1');
    final (id, fx) = s.requestAuth(label: 'Mon app');
    final frame = single<SendFrame>(fx).frame;
    final auth = Codec.decode(frame) as AuthMsg;
    expect(auth.exp - auth.iat, 30);
    final res = s.onFrame('c1', Codec.encode(AuthOkMsg(id: id, sig: keys.sign(frame))));
    expect(single<AuthResolved>(res).outcome, AuthOutcome.approved);
  });

  test('replayed auth_ok is rejected (one-shot)', () {
    pairFully('c1');
    final (id, fx) = s.requestAuth(label: 'x');
    final ok = Codec.encode(AuthOkMsg(id: id, sig: keys.sign(single<SendFrame>(fx).frame)));
    s.onFrame('c1', ok);
    expect(s.onFrame('c1', ok), isEmpty);
    // and after a reconnect on a new socket
    s.onDisconnect('c1');
    s.onFrame('c2', Codec.encode(HelloMsg(pcId: 'pc1', pub: keys.pubSpkiB64)));
    expect(s.onFrame('c2', ok), isEmpty);
  });

  test('auth_ok from a non-phone connection is closed and ignored', () {
    pairFully('c1');
    final (id, fx) = s.requestAuth(label: 'x');
    final ok = Codec.encode(AuthOkMsg(id: id, sig: keys.sign(single<SendFrame>(fx).frame)));
    final res = s.onFrame('intruder', ok);
    expect(res.single, isA<CloseConn>());
    // still pending: the real phone can answer
    expect(single<AuthResolved>(s.onFrame('c1', ok)).outcome, AuthOutcome.approved);
  });

  test('bad signature → badSignature and id consumed', () {
    pairFully('c1');
    final (id, _) = s.requestAuth(label: 'x');
    final res = s.onFrame('c1', Codec.encode(AuthOkMsg(id: id, sig: keys.sign('other'))));
    expect(single<AuthResolved>(res).outcome, AuthOutcome.badSignature);
  });

  test('denied maps reasons', () {
    pairFully('c1');
    final (id, _) = s.requestAuth(label: 'x');
    final res = s.onFrame('c1', Codec.encode(AuthDeniedMsg(id: id, reason: DenyReason.biometricFailed)));
    expect(single<AuthResolved>(res).outcome, AuthOutcome.biometricFailed);
  });

  test('tick expires pending auths', () {
    pairFully('c1');
    final (id, _) = s.requestAuth(label: 'x');
    clock.now += 31;
    final fx = s.tick();
    expect(single<AuthResolved>(fx).id, id);
    expect(single<AuthResolved>(fx).outcome, AuthOutcome.timeout);
    expect(s.tick(), isEmpty);
  });

  test('requestAuth without phone → noPhone', () {
    final (_, fx) = s.requestAuth(label: 'x');
    expect(single<AuthResolved>(fx).outcome, AuthOutcome.noPhone);
  });

  test('malformed frame closes; ping answers pong', () {
    pairFully('c1');
    expect(s.onFrame('c1', '{garbage').single, isA<CloseConn>());
    expect(sent(s.onFrame('c1', Codec.encode(const PingMsg()))), isA<PongMsg>());
  });

  test('disconnect of phone conn → offline', () {
    pairFully('c1');
    expect(single<PhoneOnline>(s.onDisconnect('c1')).online, isFalse);
    expect(s.phoneOnline, isFalse);
  });
}
