import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/core/crypto/verify.dart';
import 'package:biokey/core/pairing/qr_payload.dart';
import 'package:biokey/core/protocol/codec.dart';
import 'package:biokey/core/protocol/messages.dart';
import 'package:biokey/core/session/clock.dart';
import 'package:biokey/core/session/phone_session.dart';
import 'package:biokey/core/storage/phone_store.dart';
import '../../support/fake_signer.dart';

void main() {
  const qr = QrPayload(pcId: 'pc1', name: 'PC', host: 'h', port: 1, fingerprint: 'fp', token: 'tok');
  const pc = PairedPc(pcId: 'pc1', name: 'PC', host: 'h', port: 1, fingerprint: 'fp', session: 'sess1');
  late FakeSigner signer;
  late FakeClock clock;
  late PhoneSession s;
  const v = EcdsaVerifier();

  setUp(() {
    signer = FakeSigner();
    clock = FakeClock(1000);
    s = PhoneSession(signer: signer, clock: clock);
  });

  Message sentOf(List<PhoneEffect> fx) => Codec.decode(fx.whereType<PhoneSend>().single.frame);

  test('beginPairing sends pair with pub and token', () async {
    final m = sentOf(await s.beginPairing(qr)) as PairMsg;
    expect(m.token, 'tok');
    expect(m.pub, signer.keys.pubSpkiB64);
  });

  test('pair_challenge → signed proof with pairing prompt; paired → PhonePairedWith carrying the session', () async {
    await s.beginPairing(qr);
    final fx = await s.onFrame(pc, Codec.encode(const PairChallengeMsg(nonce: 'NONCE')));
    final proof = sentOf(fx) as PairProofMsg;
    expect(v.verify(pubSpkiB64: signer.keys.pubSpkiB64, payload: 'biokey-pair:NONCE', sigB64: proof.sig), isTrue);
    expect(v.verify(pubSpkiB64: signer.keys.pubSpkiB64, payload: 'NONCE', sigB64: proof.sig), isFalse,
        reason: 'the proof is domain-separated, never over the bare nonce');
    expect(signer.prompts.single, 'Appairer avec PC ?');
    final done = await s.onFrame(pc, Codec.encode(const PairedMsg(pcId: 'pc1', name: 'PC-MAISON', session: 'newsess')));
    final paired = done.whereType<PhonePairedWith>().single.pc;
    expect(paired.name, 'PC-MAISON');
    expect(paired.session, 'newsess');
  });

  test('pair_challenge without a pairing in flight closes without prompting', () async {
    final fx = await s.onFrame(pc, Codec.encode(const PairChallengeMsg(nonce: 'N')));
    expect(fx.single, isA<PhoneClose>());
    expect(signer.prompts, isEmpty);
  });

  test('paired with a pcId different from the pairing QR closes without pairing', () async {
    await s.beginPairing(qr);
    final fx = await s.onFrame(pc, Codec.encode(const PairedMsg(pcId: 'someone-else', name: 'x', session: 's')));
    expect(fx.single, isA<PhoneClose>());
    expect(fx.whereType<PhonePairedWith>(), isEmpty);
  });

  test('paired with no pairing in flight closes without pairing', () async {
    final fx = await s.onFrame(pc, Codec.encode(const PairedMsg(pcId: 'pc1', name: 'x', session: 's')));
    expect(fx.single, isA<PhoneClose>());
    expect(fx.whereType<PhonePairedWith>(), isEmpty);
  });

  test('cancelled pairing closes', () async {
    await s.beginPairing(qr);
    signer.cancelNext = true;
    expect((await s.onFrame(pc, Codec.encode(const PairChallengeMsg(nonce: 'N')))).single, isA<PhoneClose>());
  });

  test('an unexpected signer error during pairing closes', () async {
    await s.beginPairing(qr);
    signer.throwNext = true;
    expect((await s.onFrame(pc, Codec.encode(const PairChallengeMsg(nonce: 'N')))).single, isA<PhoneClose>());
  });

  test('auth → shown + auth_ok signed over exact frame with French prompt', () async {
    final frame = Codec.encode(const AuthMsg(id: 'u1', pcId: 'pc1', action: 'open', label: 'Mon app', nonce: 'N', iat: 1000, exp: 1030));
    final fx = await s.onFrame(pc, frame);
    expect(fx.whereType<PhoneAuthShown>().single.label, 'Mon app');
    final ok = sentOf(fx) as AuthOkMsg;
    expect(v.verify(pubSpkiB64: signer.keys.pubSpkiB64, payload: frame, sigB64: ok.sig), isTrue);
    expect(signer.prompts.single, 'Ouvrir Mon app sur PC ?');
  });

  test('onAuthShown callback fires before signer.sign is called', () async {
    final order = <String>[];
    final orderedSigner = _OrderTrackingSigner(order);
    final withCallback = PhoneSession(
      signer: orderedSigner,
      clock: clock,
      onAuthShown: (_) => order.add('shown'),
    );
    final frame = Codec.encode(const AuthMsg(id: 'u1', pcId: 'pc1', action: 'open', label: 'x', nonce: 'N', iat: 1000, exp: 1030));
    final fx = await withCallback.onFrame(pc, frame);
    expect(order, ['shown', 'sign']);
    expect(fx.whereType<PhoneAuthShown>(), isNotEmpty);
  });

  test('auth cancelled → denied user; failed → denied biometric_failed', () async {
    final frame = Codec.encode(const AuthMsg(id: 'u1', pcId: 'pc1', action: 'open', label: 'x', nonce: 'N', iat: 1000, exp: 1030));
    signer.cancelNext = true;
    expect((sentOf(await s.onFrame(pc, frame)) as AuthDeniedMsg).reason, DenyReason.user);
    signer.failNext = true;
    expect((sentOf(await s.onFrame(pc, frame)) as AuthDeniedMsg).reason, DenyReason.biometricFailed);
  });

  test('prompt never shown in time (BiometricTimeout) → denied timeout', () async {
    final frame = Codec.encode(const AuthMsg(id: 'u1', pcId: 'pc1', action: 'open', label: 'x', nonce: 'N', iat: 1000, exp: 1030));
    signer.timeoutNext = true;
    expect((sentOf(await s.onFrame(pc, frame)) as AuthDeniedMsg).reason, DenyReason.timeout);
  });

  test('clock skew is symmetric: a request up to 60 s past exp by our clock is still accepted', () async {
    final behind = Codec.encode(const AuthMsg(id: 'u', pcId: 'pc1', action: 'open', label: 'x', nonce: 'N', iat: 950, exp: 980));
    expect(sentOf(await s.onFrame(pc, behind)), isA<AuthOkMsg>());
    final tooOld = Codec.encode(const AuthMsg(id: 'u', pcId: 'pc1', action: 'open', label: 'x', nonce: 'N', iat: 900, exp: 930));
    expect((sentOf(await s.onFrame(pc, tooOld)) as AuthDeniedMsg).reason, DenyReason.timeout);
  });

  test('a close during pairing ends it: a later paired is refused', () async {
    await s.beginPairing(qr);
    expect((await s.onFrame(pc, 'garbage')).single, isA<PhoneClose>());
    final fx = await s.onFrame(pc, Codec.encode(const PairedMsg(pcId: 'pc1', name: 'x', session: 's')));
    expect(fx.whereType<PhonePairedWith>(), isEmpty);
  });

  test('cancelPairing ends the pairing: a later pair_challenge closes without prompting', () async {
    await s.beginPairing(qr);
    s.cancelPairing();
    final fx = await s.onFrame(pc, Codec.encode(const PairChallengeMsg(nonce: 'N')));
    expect(fx.single, isA<PhoneClose>());
    expect(signer.prompts, isEmpty);
  });

  test('an unexpected signer error during auth denies as biometric_failed', () async {
    final frame = Codec.encode(const AuthMsg(id: 'u1', pcId: 'pc1', action: 'open', label: 'x', nonce: 'N', iat: 1000, exp: 1030));
    signer.throwNext = true;
    final fx = await s.onFrame(pc, frame);
    expect(fx.whereType<PhoneAuthShown>(), isNotEmpty);
    expect((sentOf(fx) as AuthDeniedMsg).reason, DenyReason.biometricFailed);
  });

  test('expired, oversized window or foreign pcId → denied timeout without prompting', () async {
    final expired = Codec.encode(const AuthMsg(id: 'u', pcId: 'pc1', action: 'open', label: 'x', nonce: 'N', iat: 900, exp: 930));
    final wide = Codec.encode(const AuthMsg(id: 'u', pcId: 'pc1', action: 'open', label: 'x', nonce: 'N', iat: 1000, exp: 1100));
    final foreign = Codec.encode(const AuthMsg(id: 'u', pcId: 'other', action: 'open', label: 'x', nonce: 'N', iat: 1000, exp: 1030));
    for (final f in [expired, wide, foreign]) {
      expect((sentOf(await s.onFrame(pc, f)) as AuthDeniedMsg).reason, DenyReason.timeout);
    }
    expect(signer.prompts, isEmpty);
  });

  test('iat too far in the future, exp before iat, or non-open action → denied timeout without prompting', () async {
    final futureIat = Codec.encode(const AuthMsg(id: 'u', pcId: 'pc1', action: 'open', label: 'x', nonce: 'N', iat: 1061, exp: 1090));
    final backwards = Codec.encode(const AuthMsg(id: 'u', pcId: 'pc1', action: 'open', label: 'x', nonce: 'N', iat: 1030, exp: 1000));
    final wrongAction = Codec.encode(const AuthMsg(id: 'u', pcId: 'pc1', action: 'close', label: 'x', nonce: 'N', iat: 1000, exp: 1030));
    for (final f in [futureIat, backwards, wrongAction]) {
      expect((sentOf(await s.onFrame(pc, f)) as AuthDeniedMsg).reason, DenyReason.timeout);
    }
    expect(signer.prompts, isEmpty);
  });

  test('unknown → PhoneUnknownByPc; ping → pong; garbage → close', () async {
    expect((await s.onFrame(pc, Codec.encode(const UnknownMsg()))).single, isA<PhoneUnknownByPc>());
    expect(sentOf(await s.onFrame(pc, Codec.encode(const PingMsg()))), isA<PongMsg>());
    expect((await s.onFrame(pc, 'x')).single, isA<PhoneClose>());
  });

  test('hello carries pub, pcId and the stored session', () async {
    final m = sentOf(await s.hello(pc)) as HelloMsg;
    expect(m.pcId, 'pc1');
    expect(m.pub, signer.keys.pubSpkiB64);
    expect(m.session, pc.session);
  });
}

/// A [FakeSigner] that appends 'sign' to a shared order list the instant
/// `sign()` is called, so a test can prove `PhoneSession`'s `onAuthShown`
/// callback — which appends its own marker — really fires first.
class _OrderTrackingSigner extends FakeSigner {
  _OrderTrackingSigner(this._order);
  final List<String> _order;

  @override
  Future<String> sign({required String payload, required String prompt}) {
    _order.add('sign');
    return super.sign(payload: payload, prompt: prompt);
  }
}
