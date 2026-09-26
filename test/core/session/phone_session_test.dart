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
  const pc = PairedPc(pcId: 'pc1', name: 'PC', host: 'h', port: 1, fingerprint: 'fp');
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

  test('pair_challenge → signed proof with pairing prompt; paired → PhonePairedWith', () async {
    await s.beginPairing(qr);
    final fx = await s.onFrame(pc, Codec.encode(const PairChallengeMsg(nonce: 'NONCE')));
    final proof = sentOf(fx) as PairProofMsg;
    expect(v.verify(pubSpkiB64: signer.keys.pubSpkiB64, payload: 'NONCE', sigB64: proof.sig), isTrue);
    expect(signer.prompts.single, 'Appairer avec PC ?');
    final done = await s.onFrame(pc, Codec.encode(const PairedMsg(pcId: 'pc1', name: 'PC-MAISON')));
    expect(done.whereType<PhonePairedWith>().single.pc.name, 'PC-MAISON');
  });

  test('cancelled pairing closes', () async {
    signer.cancelNext = true;
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

  test('auth cancelled → denied user; failed → denied biometric_failed', () async {
    final frame = Codec.encode(const AuthMsg(id: 'u1', pcId: 'pc1', action: 'open', label: 'x', nonce: 'N', iat: 1000, exp: 1030));
    signer.cancelNext = true;
    expect((sentOf(await s.onFrame(pc, frame)) as AuthDeniedMsg).reason, DenyReason.user);
    signer.failNext = true;
    expect((sentOf(await s.onFrame(pc, frame)) as AuthDeniedMsg).reason, DenyReason.biometricFailed);
  });

  test('expired, oversized window or foreign pcId → denied timeout without prompting', () async {
    final expired = Codec.encode(const AuthMsg(id: 'u', pcId: 'pc1', action: 'open', label: 'x', nonce: 'N', iat: 900, exp: 990));
    final wide = Codec.encode(const AuthMsg(id: 'u', pcId: 'pc1', action: 'open', label: 'x', nonce: 'N', iat: 1000, exp: 1100));
    final foreign = Codec.encode(const AuthMsg(id: 'u', pcId: 'other', action: 'open', label: 'x', nonce: 'N', iat: 1000, exp: 1030));
    for (final f in [expired, wide, foreign]) {
      expect((sentOf(await s.onFrame(pc, f)) as AuthDeniedMsg).reason, DenyReason.timeout);
    }
    expect(signer.prompts, isEmpty);
  });

  test('unknown → PhoneUnknownByPc; ping → pong; garbage → close', () async {
    expect((await s.onFrame(pc, Codec.encode(const UnknownMsg()))).single, isA<PhoneUnknownByPc>());
    expect(sentOf(await s.onFrame(pc, Codec.encode(const PingMsg()))), isA<PongMsg>());
    expect((await s.onFrame(pc, 'x')).single, isA<PhoneClose>());
  });

  test('hello carries pub and pcId', () async {
    final m = sentOf(await s.hello(pc)) as HelloMsg;
    expect(m.pcId, 'pc1');
    expect(m.pub, signer.keys.pubSpkiB64);
  });
}
