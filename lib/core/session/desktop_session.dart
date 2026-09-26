import 'package:uuid/uuid.dart';
import '../crypto/random.dart' as rnd;
import '../crypto/verify.dart';
import '../protocol/codec.dart';
import '../protocol/messages.dart';
import '../storage/desktop_store.dart';
import 'clock.dart';

enum AuthOutcome { approved, denied, timeout, biometricFailed, noPhone, badSignature }

sealed class DesktopEffect {
  const DesktopEffect();
}

final class SendFrame extends DesktopEffect {
  const SendFrame(this.connId, this.frame);
  final String connId, frame;
}

final class CloseConn extends DesktopEffect {
  const CloseConn(this.connId);
  final String connId;
}

final class AuthResolved extends DesktopEffect {
  const AuthResolved(this.id, this.label, this.outcome);
  final String id, label;
  final AuthOutcome outcome;
}

final class PhonePaired extends DesktopEffect {
  const PhonePaired(this.phone);
  final PairedPhone phone;
}

final class PhoneOnline extends DesktopEffect {
  const PhoneOnline(this.online);
  final bool online;
}

final class _Pending {
  _Pending(this.frame, this.exp, this.label);
  final String frame, label;
  final int exp;
}

final class _Candidate {
  _Candidate(this.connId, this.name, this.pub, this.nonce);
  final String connId, name, pub, nonce;
}

final class DesktopSession {
  DesktopSession({
    required this.pcId,
    required this.pcName,
    required Verifier verifier,
    required Clock clock,
    this.phone,
    String Function(int bytes)? randomB64,
    String Function()? newId,
  })  : _v = verifier,
        _clock = clock,
        _rand = randomB64 ?? rnd.randomB64,
        _newId = newId ?? const Uuid().v4;

  final String pcId, pcName;
  final Verifier _v;
  final Clock _clock;
  final String Function(int) _rand;
  final String Function() _newId;

  static const pairingTtl = 120;
  static const authTtl = 30;

  PairedPhone? phone;
  String? pairingToken;
  int _pairingExp = 0;
  _Candidate? _cand;
  String? _phoneConn;
  final _pending = <String, _Pending>{};

  bool get phoneOnline => _phoneConn != null;

  List<DesktopEffect> startPairing() {
    pairingToken = rnd.randomB64Url(16);
    _pairingExp = _clock.nowSec() + pairingTtl;
    _cand = null;
    return const [];
  }

  (String, List<DesktopEffect>) requestAuth({required String label}) {
    final id = _newId();
    final conn = _phoneConn;
    if (conn == null) {
      return (id, [AuthResolved(id, label, AuthOutcome.noPhone)]);
    }
    final now = _clock.nowSec();
    final frame = Codec.encode(AuthMsg(
      id: id,
      pcId: pcId,
      action: 'open',
      label: label,
      nonce: _rand(32),
      iat: now,
      exp: now + authTtl,
    ));
    _pending[id] = _Pending(frame, now + authTtl, label);
    return (id, [SendFrame(conn, frame)]);
  }

  List<DesktopEffect> tick() {
    final now = _clock.nowSec();
    final fx = <DesktopEffect>[];
    _pending.removeWhere((id, p) {
      if (p.exp < now) {
        fx.add(AuthResolved(id, p.label, AuthOutcome.timeout));
        return true;
      }
      return false;
    });
    if (pairingToken != null && _pairingExp < now) pairingToken = null;
    return fx;
  }

  List<DesktopEffect> onDisconnect(String connId) {
    if (_cand?.connId == connId) _cand = null;
    if (_phoneConn == connId) {
      _phoneConn = null;
      return const [PhoneOnline(false)];
    }
    return const [];
  }

  List<DesktopEffect> onFrame(String connId, String frame) {
    final Message m;
    try {
      m = Codec.decode(frame);
    } on ProtocolException {
      return [CloseConn(connId)];
    }
    return switch (m) {
      PairMsg() => _onPair(connId, m),
      PairProofMsg() => _onPairProof(connId, m),
      HelloMsg() => _onHello(connId, m),
      AuthOkMsg() => _onAuthOk(connId, m),
      AuthDeniedMsg() => _onAuthDenied(connId, m),
      PingMsg() => [SendFrame(connId, Codec.encode(const PongMsg()))],
      PongMsg() => const [],
      // Desktop never legitimately receives pair_challenge/paired/welcome/unknown/auth.
      _ => [CloseConn(connId)],
    };
  }

  List<DesktopEffect> _onPair(String connId, PairMsg m) {
    final tok = pairingToken;
    if (tok == null || m.token != tok || _clock.nowSec() > _pairingExp) {
      return [CloseConn(connId)];
    }
    pairingToken = null;
    final nonce = _rand(32);
    _cand = _Candidate(connId, m.name, m.pub, nonce);
    return [SendFrame(connId, Codec.encode(PairChallengeMsg(nonce: nonce)))];
  }

  List<DesktopEffect> _onPairProof(String connId, PairProofMsg m) {
    final c = _cand;
    if (c == null || c.connId != connId) return [CloseConn(connId)];
    _cand = null;
    if (!_v.verify(pubSpkiB64: c.pub, payload: c.nonce, sigB64: m.sig)) {
      return [CloseConn(connId)];
    }
    final paired = PairedPhone(name: c.name, pub: c.pub);
    phone = paired;
    _phoneConn = connId;
    return [
      SendFrame(connId, Codec.encode(PairedMsg(pcId: pcId, name: pcName))),
      PhonePaired(paired),
      const PhoneOnline(true),
    ];
  }

  List<DesktopEffect> _onHello(String connId, HelloMsg m) {
    final p = phone;
    if (p == null || m.pub != p.pub || m.pcId != pcId) {
      return [SendFrame(connId, Codec.encode(const UnknownMsg())), CloseConn(connId)];
    }
    _phoneConn = connId;
    return [SendFrame(connId, Codec.encode(const WelcomeMsg())), const PhoneOnline(true)];
  }

  List<DesktopEffect> _onAuthOk(String connId, AuthOkMsg m) => _onAuthAnswer(connId, m.id, (p) {
        final ph = phone;
        if (ph == null) return AuthOutcome.badSignature;
        final ok = _v.verify(pubSpkiB64: ph.pub, payload: p.frame, sigB64: m.sig);
        return ok ? AuthOutcome.approved : AuthOutcome.badSignature;
      });

  List<DesktopEffect> _onAuthDenied(String connId, AuthDeniedMsg m) => _onAuthAnswer(connId, m.id, (_) => switch (m.reason) {
        DenyReason.user => AuthOutcome.denied,
        DenyReason.timeout => AuthOutcome.timeout,
        DenyReason.biometricFailed => AuthOutcome.biometricFailed,
      });

  List<DesktopEffect> _onAuthAnswer(String connId, String id, AuthOutcome Function(_Pending) judge) {
    if (connId != _phoneConn) return [CloseConn(connId)];
    final p = _pending.remove(id);
    if (p == null) return const [];
    return [AuthResolved(id, p.label, judge(p))];
  }
}
