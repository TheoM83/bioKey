const int protocolVersion = 1;

enum DenyReason {
  user('user'),
  timeout('timeout'),
  biometricFailed('biometric_failed');

  const DenyReason(this.wire);
  final String wire;

  static DenyReason fromWire(String s) =>
      values.firstWhere((r) => r.wire == s, orElse: () => throw ProtocolException('reason inconnue: $s'));
}

class ProtocolException implements Exception {
  ProtocolException(this.message);
  final String message;
  @override
  String toString() => 'ProtocolException: $message';
}

sealed class Message {
  const Message();
  String get type;
  Map<String, Object?> toJson();
}

final class PairMsg extends Message {
  const PairMsg({required this.token, required this.name, required this.pub});
  final String token, name, pub;
  @override
  String get type => 'pair';
  @override
  Map<String, Object?> toJson() => {'type': type, 'v': protocolVersion, 'token': token, 'name': name, 'pub': pub};
  @override
  bool operator ==(Object other) => other is PairMsg && other.token == token && other.name == name && other.pub == pub;
  @override
  int get hashCode => Object.hash(token, name, pub);
}

final class PairChallengeMsg extends Message {
  const PairChallengeMsg({required this.nonce});
  final String nonce;
  @override
  String get type => 'pair_challenge';
  @override
  Map<String, Object?> toJson() => {'type': type, 'nonce': nonce};
  @override
  bool operator ==(Object other) => other is PairChallengeMsg && other.nonce == nonce;
  @override
  int get hashCode => nonce.hashCode;
}

final class PairProofMsg extends Message {
  const PairProofMsg({required this.sig});
  final String sig;
  @override
  String get type => 'pair_proof';
  @override
  Map<String, Object?> toJson() => {'type': type, 'sig': sig};
  @override
  bool operator ==(Object other) => other is PairProofMsg && other.sig == sig;
  @override
  int get hashCode => sig.hashCode;
}

final class PairedMsg extends Message {
  const PairedMsg({required this.pcId, required this.name, required this.session});
  final String pcId, name, session;
  @override
  String get type => 'paired';
  @override
  Map<String, Object?> toJson() => {'type': type, 'pcId': pcId, 'name': name, 'session': session};
  @override
  bool operator ==(Object other) => other is PairedMsg && other.pcId == pcId && other.name == name && other.session == session;
  @override
  int get hashCode => Object.hash(pcId, name, session);
}

final class HelloMsg extends Message {
  const HelloMsg({required this.pcId, required this.pub, required this.session});
  final String pcId, pub, session;
  @override
  String get type => 'hello';
  @override
  Map<String, Object?> toJson() => {'type': type, 'v': protocolVersion, 'pcId': pcId, 'pub': pub, 'session': session};
  @override
  bool operator ==(Object other) => other is HelloMsg && other.pcId == pcId && other.pub == pub && other.session == session;
  @override
  int get hashCode => Object.hash(pcId, pub, session);
}

final class WelcomeMsg extends Message {
  const WelcomeMsg();
  @override
  String get type => 'welcome';
  @override
  Map<String, Object?> toJson() => {'type': type};
  @override
  bool operator ==(Object other) => other is WelcomeMsg;
  @override
  int get hashCode => runtimeType.hashCode;
}

final class UnknownMsg extends Message {
  const UnknownMsg();
  @override
  String get type => 'unknown';
  @override
  Map<String, Object?> toJson() => {'type': type};
  @override
  bool operator ==(Object other) => other is UnknownMsg;
  @override
  int get hashCode => runtimeType.hashCode;
}

final class AuthMsg extends Message {
  const AuthMsg({
    required this.id,
    required this.pcId,
    required this.action,
    required this.label,
    required this.nonce,
    required this.iat,
    required this.exp,
  });
  final String id, pcId, action, label, nonce;
  final int iat, exp;
  @override
  String get type => 'auth';
  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'id': id,
        'pcId': pcId,
        'action': action,
        'label': label,
        'nonce': nonce,
        'iat': iat,
        'exp': exp,
      };
  @override
  bool operator ==(Object other) =>
      other is AuthMsg &&
      other.id == id &&
      other.pcId == pcId &&
      other.action == action &&
      other.label == label &&
      other.nonce == nonce &&
      other.iat == iat &&
      other.exp == exp;
  @override
  int get hashCode => Object.hash(id, pcId, action, label, nonce, iat, exp);
}

final class AuthOkMsg extends Message {
  const AuthOkMsg({required this.id, required this.sig});
  final String id, sig;
  @override
  String get type => 'auth_ok';
  @override
  Map<String, Object?> toJson() => {'type': type, 'id': id, 'sig': sig};
  @override
  bool operator ==(Object other) => other is AuthOkMsg && other.id == id && other.sig == sig;
  @override
  int get hashCode => Object.hash(id, sig);
}

final class AuthDeniedMsg extends Message {
  const AuthDeniedMsg({required this.id, required this.reason});
  final String id;
  final DenyReason reason;
  @override
  String get type => 'auth_denied';
  @override
  Map<String, Object?> toJson() => {'type': type, 'id': id, 'reason': reason.wire};
  @override
  bool operator ==(Object other) => other is AuthDeniedMsg && other.id == id && other.reason == reason;
  @override
  int get hashCode => Object.hash(id, reason);
}

final class PingMsg extends Message {
  const PingMsg();
  @override
  String get type => 'ping';
  @override
  Map<String, Object?> toJson() => {'type': type};
  @override
  bool operator ==(Object other) => other is PingMsg;
  @override
  int get hashCode => runtimeType.hashCode;
}

final class PongMsg extends Message {
  const PongMsg();
  @override
  String get type => 'pong';
  @override
  Map<String, Object?> toJson() => {'type': type};
  @override
  bool operator ==(Object other) => other is PongMsg;
  @override
  int get hashCode => runtimeType.hashCode;
}
