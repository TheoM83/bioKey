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

  List<DesktopEffect> pairFully(String conn, {TestKeys? withKeys, String name = 'Nothing'}) {
    final k = withKeys ?? keys;
    s.startPairing();
    final fx1 = s.onFrame(conn, Codec.encode(PairMsg(token: s.pairingToken!, name: name, pub: k.pubSpkiB64)));
    final ch = sent(fx1) as PairChallengeMsg;
    return s.onFrame(conn, Codec.encode(PairProofMsg(sig: k.sign('biokey-pair:${ch.nonce}'))));
  }

  test('full pairing succeeds and phone becomes online', () {
    final fx = pairFully('c1');
    final paired = sent(fx) as PairedMsg;
    expect(paired.pcId, 'pc1');
    final phonePaired = single<PhonePaired>(fx).phone;
    expect(phonePaired.pub, keys.pubSpkiB64);
    expect(phonePaired.session, isNotEmpty);
    expect(paired.session, phonePaired.session);
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

  test('token is single-use: reusing a token consumed by a successful pairing closes', () {
    s.startPairing();
    final tok = s.pairingToken!;
    final fx1 = s.onFrame('c1', Codec.encode(PairMsg(token: tok, name: 'n', pub: keys.pubSpkiB64)));
    final ch = sent(fx1) as PairChallengeMsg;
    s.onFrame('c1', Codec.encode(PairProofMsg(sig: keys.sign('biokey-pair:${ch.nonce}'))));
    expect(s.onFrame('c2', Codec.encode(PairMsg(token: tok, name: 'n', pub: 'p'))).single, isA<CloseConn>());
  });

  test('bad pair_proof signature closes', () {
    s.startPairing();
    s.onFrame('c1', Codec.encode(PairMsg(token: s.pairingToken!, name: 'n', pub: keys.pubSpkiB64)));
    final fx = s.onFrame('c1', Codec.encode(const PairProofMsg(sig: 'AAAA')));
    expect(fx.whereType<CloseConn>(), hasLength(1));
    expect(fx.whereType<PairingExpired>(), hasLength(1));
  });

  test('pair_proof from a connection other than the candidate closes', () {
    s.startPairing();
    s.onFrame('c1', Codec.encode(PairMsg(token: s.pairingToken!, name: 'n', pub: keys.pubSpkiB64)));
    expect(s.onFrame('intruder', Codec.encode(PairProofMsg(sig: keys.sign('whatever')))).single, isA<CloseConn>());
  });

  test('second startPairing invalidates the pending pairing candidate', () {
    s.startPairing();
    final fx1 = s.onFrame('c1', Codec.encode(PairMsg(token: s.pairingToken!, name: 'n', pub: keys.pubSpkiB64)));
    final ch = sent(fx1) as PairChallengeMsg;
    s.startPairing();
    expect(s.onFrame('c1', Codec.encode(PairProofMsg(sig: keys.sign('biokey-pair:${ch.nonce}')))).single, isA<CloseConn>());
  });

  test('candidate disconnecting then sending pair_proof closes', () {
    s.startPairing();
    final fx1 = s.onFrame('c1', Codec.encode(PairMsg(token: s.pairingToken!, name: 'n', pub: keys.pubSpkiB64)));
    final ch = sent(fx1) as PairChallengeMsg;
    expect(s.onDisconnect('c1').whereType<PairingExpired>(), hasLength(1), reason: 'the consumed QR is dead');
    expect(s.onFrame('c1', Codec.encode(PairProofMsg(sig: keys.sign('biokey-pair:${ch.nonce}')))).single, isA<CloseConn>());
  });

  test('pair_proof after the pairing candidate expires closes', () {
    s.startPairing();
    final fx1 = s.onFrame('c1', Codec.encode(PairMsg(token: s.pairingToken!, name: 'n', pub: keys.pubSpkiB64)));
    final ch = sent(fx1) as PairChallengeMsg;
    clock.now += 121;
    expect(s.onFrame('c1', Codec.encode(PairProofMsg(sig: keys.sign('biokey-pair:${ch.nonce}')))).first, isA<CloseConn>());
  });

  test('hello with known pub and session → welcome; unknown pub → unknown + close', () {
    final fx0 = pairFully('c1');
    final session = single<PhonePaired>(fx0).phone.session;
    s.onDisconnect('c1');
    final fx = s.onFrame('c2', Codec.encode(HelloMsg(pcId: 'pc1', pub: keys.pubSpkiB64, session: session)));
    expect(sent(fx), isA<WelcomeMsg>());
    final bad = s.onFrame('c3', Codec.encode(const HelloMsg(pcId: 'pc1', pub: 'other', session: 'x')));
    expect(sent(bad), isA<UnknownMsg>());
    expect(bad.whereType<CloseConn>(), isNotEmpty);
  });

  test('hello with correct pub but wrong session → unknown + close', () {
    pairFully('c1');
    s.onDisconnect('c1');
    final bad = s.onFrame('c2', Codec.encode(HelloMsg(pcId: 'pc1', pub: keys.pubSpkiB64, session: 'WRONG')));
    expect(sent(bad), isA<UnknownMsg>());
    expect(bad.whereType<CloseConn>(), isNotEmpty);
  });

  test('hello with wrong pcId → unknown + close', () {
    final fx0 = pairFully('c1');
    final session = single<PhonePaired>(fx0).phone.session;
    s.onDisconnect('c1');
    final bad = s.onFrame('c2', Codec.encode(HelloMsg(pcId: 'other', pub: keys.pubSpkiB64, session: session)));
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
    final session = s.phone!.session;
    s.onFrame('c2', Codec.encode(HelloMsg(pcId: 'pc1', pub: keys.pubSpkiB64, session: session)));
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

  test('bad signature → badSignature and id consumed; a second answer is then ignored', () {
    pairFully('c1');
    final (id, _) = s.requestAuth(label: 'x');
    final res = s.onFrame('c1', Codec.encode(AuthOkMsg(id: id, sig: keys.sign('other'))));
    expect(single<AuthResolved>(res).outcome, AuthOutcome.badSignature);
    expect(s.onFrame('c1', Codec.encode(AuthOkMsg(id: id, sig: keys.sign('other')))), isEmpty);
  });

  test('denied maps reasons', () {
    pairFully('c1');
    final (id, _) = s.requestAuth(label: 'x');
    final res = s.onFrame('c1', Codec.encode(AuthDeniedMsg(id: id, reason: DenyReason.biometricFailed)));
    expect(single<AuthResolved>(res).outcome, AuthOutcome.biometricFailed);
  });

  test('auth_denied from a non-phone connection closes and leaves the id pending', () {
    pairFully('c1');
    final (id, _) = s.requestAuth(label: 'x');
    final res = s.onFrame('intruder', Codec.encode(AuthDeniedMsg(id: id, reason: DenyReason.user)));
    expect(res.single, isA<CloseConn>());
    final ok = s.onFrame('c1', Codec.encode(AuthDeniedMsg(id: id, reason: DenyReason.biometricFailed)));
    expect(single<AuthResolved>(ok).outcome, AuthOutcome.biometricFailed);
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

  test('tick clears an expired pairing token and emits PairingExpired once', () {
    s.startPairing();
    clock.now += 121;
    expect(s.tick().whereType<PairingExpired>(), hasLength(1));
    expect(s.pairingToken, isNull);
    expect(s.tick(), isEmpty);
  });

  test('tick emits PairingExpired when a candidate that consumed the token expires', () {
    s.startPairing();
    s.onFrame('c1', Codec.encode(PairMsg(token: s.pairingToken!, name: 'n', pub: keys.pubSpkiB64)));
    expect(s.pairingToken, isNull);
    clock.now += 121;
    expect(s.tick().whereType<PairingExpired>(), hasLength(1));
    expect(s.tick(), isEmpty);
  });

  test('a proof over the bare nonce (no domain prefix) is rejected', () {
    s.startPairing();
    final fx1 = s.onFrame('c1', Codec.encode(PairMsg(token: s.pairingToken!, name: 'n', pub: keys.pubSpkiB64)));
    final ch = sent(fx1) as PairChallengeMsg;
    final fx = s.onFrame('c1', Codec.encode(PairProofMsg(sig: keys.sign(ch.nonce))));
    expect(fx.whereType<PhonePaired>(), isEmpty);
    expect(fx.whereType<CloseConn>(), hasLength(1));
  });

  test('revoke closes the phone connection, times out pending auths and forgets the phone', () {
    pairFully('c1');
    final (id, _) = s.requestAuth(label: 'x');
    final fx = s.revoke();
    expect(single<CloseConn>(fx).connId, 'c1');
    expect(single<AuthResolved>(fx).id, id);
    expect(single<AuthResolved>(fx).outcome, AuthOutcome.timeout);
    expect(single<PhoneOnline>(fx).online, isFalse);
    expect(s.phone, isNull);
    expect(s.phoneOnline, isFalse);
    final (_, after) = s.requestAuth(label: 'y');
    expect(single<AuthResolved>(after).outcome, AuthOutcome.noPhone);
  });

  test('hello with our pcId but a changed pub or session → unknown + close + PairingInvalid', () {
    final fx0 = pairFully('c1');
    final session = single<PhonePaired>(fx0).phone.session;
    s.onDisconnect('c1');
    final newKey = s.onFrame('c2', Codec.encode(HelloMsg(pcId: 'pc1', pub: TestKeys().pubSpkiB64, session: session)));
    expect(sent(newKey), isA<UnknownMsg>());
    expect(newKey.whereType<PairingInvalid>(), hasLength(1));
    final newSession = s.onFrame('c3', Codec.encode(HelloMsg(pcId: 'pc1', pub: keys.pubSpkiB64, session: 'WRONG')));
    expect(newSession.whereType<PairingInvalid>(), hasLength(1));
    final otherPc = s.onFrame('c4', Codec.encode(HelloMsg(pcId: 'other', pub: keys.pubSpkiB64, session: session)));
    expect(otherPc.whereType<PairingInvalid>(), isEmpty, reason: 'not our pairing to invalidate');
  });

  test('an auth answer arriving after expiry resolves as timeout, not judged', () {
    pairFully('c1');
    final (id, fx) = s.requestAuth(label: 'x');
    final frame = single<SendFrame>(fx).frame;
    clock.now += 31;
    final res = s.onFrame('c1', Codec.encode(AuthOkMsg(id: id, sig: keys.sign(frame))));
    expect(single<AuthResolved>(res).outcome, AuthOutcome.timeout);
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

  test('re-pairing on a new connection closes the old phone conn and times out pending auths', () {
    pairFully('c1');
    final (id, _) = s.requestAuth(label: 'x');
    final other = TestKeys();
    final fx = pairFully('c2', withKeys: other, name: 'Other');
    expect(fx.whereType<CloseConn>().map((c) => c.connId), contains('c1'));
    final resolved = fx.whereType<AuthResolved>().where((a) => a.id == id).single;
    expect(resolved.outcome, AuthOutcome.timeout);
    expect(s.phoneOnline, isTrue);
  });
}
