import '../pairing/qr_payload.dart';
import '../protocol/codec.dart';
import '../protocol/messages.dart';
import '../storage/phone_store.dart';
import 'biometric_signer.dart';
import 'clock.dart';

sealed class PhoneEffect {
  const PhoneEffect();
}

final class PhoneSend extends PhoneEffect {
  const PhoneSend(this.frame);
  final String frame;
}

final class PhoneClose extends PhoneEffect {
  const PhoneClose();
}

final class PhonePairedWith extends PhoneEffect {
  const PhonePairedWith(this.pc);
  final PairedPc pc;
}

final class PhoneUnknownByPc extends PhoneEffect {
  const PhoneUnknownByPc(this.pcId);
  final String pcId;
}

final class PhoneAuthShown extends PhoneEffect {
  const PhoneAuthShown(this.label, this.pcName);
  final String label, pcName;
}

final class PhoneSession {
  PhoneSession({required BiometricSigner signer, required Clock clock})
      : _signer = signer,
        _clock = clock;

  final BiometricSigner _signer;
  final Clock _clock;
  QrPayload? _pairingQr;

  static const authTtl = 30;

  Future<List<PhoneEffect>> beginPairing(QrPayload qr) async {
    _pairingQr = qr;
    final pub = await _signer.ensurePublicKey();
    return [PhoneSend(Codec.encode(PairMsg(token: qr.token, name: 'Téléphone', pub: pub)))];
  }

  Future<List<PhoneEffect>> hello(PairedPc pc) async {
    final pub = await _signer.ensurePublicKey();
    return [PhoneSend(Codec.encode(HelloMsg(pcId: pc.pcId, pub: pub)))];
  }

  Future<List<PhoneEffect>> onFrame(PairedPc pc, String frame) async {
    final Message m;
    try {
      m = Codec.decode(frame);
    } on ProtocolException {
      return const [PhoneClose()];
    }
    switch (m) {
      case PairChallengeMsg():
        return _onPairChallenge(pc, m);
      case PairedMsg():
        return _onPaired(pc, m);
      case UnknownMsg():
        return [PhoneUnknownByPc(pc.pcId)];
      case AuthMsg():
        return _onAuth(pc, m, frame);
      case PingMsg():
        return [PhoneSend(Codec.encode(const PongMsg()))];
      case WelcomeMsg() || PongMsg():
        return const [];
      case PairMsg() || PairProofMsg() || HelloMsg() || AuthOkMsg() || AuthDeniedMsg():
        return const [PhoneClose()];
    }
  }

  Future<List<PhoneEffect>> _onPairChallenge(PairedPc pc, PairChallengeMsg m) async {
    try {
      final sig = await _signer.sign(payload: m.nonce, prompt: 'Appairer avec ${pc.name} ?');
      return [PhoneSend(Codec.encode(PairProofMsg(sig: sig)))];
    } on BiometricCancelled {
      return const [PhoneClose()];
    } on BiometricFailed {
      return const [PhoneClose()];
    }
  }

  Future<List<PhoneEffect>> _onPaired(PairedPc pc, PairedMsg m) async {
    final qr = _pairingQr;
    _pairingQr = null;
    return [
      PhonePairedWith(PairedPc(
        pcId: m.pcId,
        name: m.name,
        host: qr?.host ?? pc.host,
        port: qr?.port ?? pc.port,
        fingerprint: qr?.fingerprint ?? pc.fingerprint,
      )),
    ];
  }

  Future<List<PhoneEffect>> _onAuth(PairedPc pc, AuthMsg m, String frame) async {
    final now = _clock.nowSec();
    if (m.pcId != pc.pcId || now > m.exp || m.exp - m.iat > authTtl) {
      return [PhoneSend(Codec.encode(AuthDeniedMsg(id: m.id, reason: DenyReason.timeout)))];
    }
    final shown = PhoneAuthShown(m.label, pc.name);
    try {
      final sig = await _signer.sign(payload: frame, prompt: 'Ouvrir ${m.label} sur ${pc.name} ?');
      return [shown, PhoneSend(Codec.encode(AuthOkMsg(id: m.id, sig: sig)))];
    } on BiometricCancelled {
      return [shown, PhoneSend(Codec.encode(AuthDeniedMsg(id: m.id, reason: DenyReason.user)))];
    } on BiometricFailed {
      return [shown, PhoneSend(Codec.encode(AuthDeniedMsg(id: m.id, reason: DenyReason.biometricFailed)))];
    }
  }
}
