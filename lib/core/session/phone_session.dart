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

/// Emitted by [PcLink] (never by [PhoneSession] itself) when the link to a
/// paired PC transitions between online and offline, so [PhoneController]
/// can track connectivity without polling.
final class PhoneOnlineChanged extends PhoneEffect {
  const PhoneOnlineChanged(this.pcId, this.online);
  final String pcId;
  final bool online;
}

final class PhoneSession {
  PhoneSession({required BiometricSigner signer, required Clock clock, void Function(PhoneAuthShown)? onAuthShown})
      : _signer = signer,
        _clock = clock,
        _onAuthShown = onAuthShown;

  final BiometricSigner _signer;
  final Clock _clock;
  final void Function(PhoneAuthShown)? _onAuthShown;
  QrPayload? _pairingQr;

  static const authTtl = 30;
  static const clockSkewAllowance = 60;

  Future<List<PhoneEffect>> beginPairing(QrPayload qr) async {
    _pairingQr = qr;
    final pub = await _signer.ensurePublicKey();
    return [PhoneSend(Codec.encode(PairMsg(token: qr.token, name: 'Téléphone', pub: pub)))];
  }

  Future<List<PhoneEffect>> hello(PairedPc pc) async {
    final pub = await _signer.ensurePublicKey();
    return [PhoneSend(Codec.encode(HelloMsg(pcId: pc.pcId, pub: pub, session: pc.session)))];
  }

  /// Abandons an in-flight pairing (the caller timed out or its socket
  /// failed): a later `pair_challenge`/`paired` must no longer be honoured.
  void cancelPairing() => _pairingQr = null;

  Future<List<PhoneEffect>> onFrame(PairedPc pc, String frame) async {
    final fx = await _onFrame(pc, frame);
    // Any close ends whatever pairing this connection was carrying.
    if (fx.any((e) => e is PhoneClose)) _pairingQr = null;
    return fx;
  }

  Future<List<PhoneEffect>> _onFrame(PairedPc pc, String frame) async {
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
        return _onPaired(m);
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
    // No pairing session in flight: this connection has no business asking
    // us to sign anything. Refuse without prompting the user.
    if (_pairingQr == null) return const [PhoneClose()];
    try {
      final sig = await _signer.sign(payload: '$pairProofDomain${m.nonce}', prompt: 'Appairer avec ${pc.name} ?');
      return [PhoneSend(Codec.encode(PairProofMsg(sig: sig)))];
    } on BiometricCancelled {
      _pairingQr = null;
      return const [PhoneClose()];
    } on BiometricFailed {
      _pairingQr = null;
      return const [PhoneClose()];
    } on Object {
      _pairingQr = null;
      return const [PhoneClose()];
    }
  }

  Future<List<PhoneEffect>> _onPaired(PairedMsg m) async {
    final qr = _pairingQr;
    if (qr == null || m.pcId != qr.pcId) {
      _pairingQr = null;
      return const [PhoneClose()];
    }
    _pairingQr = null;
    return [
      PhonePairedWith(PairedPc(
        pcId: m.pcId,
        name: m.name,
        host: qr.host,
        port: qr.port,
        fingerprint: qr.fingerprint,
        session: m.session,
      )),
    ];
  }

  Future<List<PhoneEffect>> _onAuth(PairedPc pc, AuthMsg m, String frame) async {
    final now = _clock.nowSec();
    final fresh = m.pcId == pc.pcId &&
        m.action == 'open' &&
        m.exp >= m.iat &&
        m.exp - m.iat <= authTtl &&
        // Symmetric skew allowance: the PC's clock may run ahead of or
        // behind ours by up to a minute.
        m.iat <= now + clockSkewAllowance &&
        now <= m.exp + clockSkewAllowance;
    if (!fresh) {
      return [PhoneSend(Codec.encode(AuthDeniedMsg(id: m.id, reason: DenyReason.timeout)))];
    }
    final shown = PhoneAuthShown(m.label, pc.name);
    // Invoked synchronously, before `sign()` even starts: on Android the
    // biometric prompt cannot be shown from a backgrounded activity, so
    // the controller needs this notice *before* the (blocking) sign call
    // begins, not after — by the time the returned effect list reaches the
    // controller, sign() has already run to completion (or failure).
    _onAuthShown?.call(shown);
    try {
      final sig = await _signer.sign(payload: frame, prompt: 'Ouvrir ${m.label} sur ${pc.name} ?');
      return [shown, PhoneSend(Codec.encode(AuthOkMsg(id: m.id, sig: sig)))];
    } on BiometricCancelled {
      return [shown, PhoneSend(Codec.encode(AuthDeniedMsg(id: m.id, reason: DenyReason.user)))];
    } on BiometricTimeout {
      return [shown, PhoneSend(Codec.encode(AuthDeniedMsg(id: m.id, reason: DenyReason.timeout)))];
    } on BiometricFailed {
      return [shown, PhoneSend(Codec.encode(AuthDeniedMsg(id: m.id, reason: DenyReason.biometricFailed)))];
    } on Object {
      return [shown, PhoneSend(Codec.encode(AuthDeniedMsg(id: m.id, reason: DenyReason.biometricFailed)))];
    }
  }
}
