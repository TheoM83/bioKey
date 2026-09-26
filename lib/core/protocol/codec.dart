import 'dart:convert';
import 'messages.dart';

abstract final class Codec {
  static String encode(Message m) => jsonEncode(m.toJson());

  static Message decode(String frame) {
    final Object? raw;
    try {
      raw = jsonDecode(frame);
    } on FormatException catch (e) {
      throw ProtocolException('JSON invalide: ${e.message}');
    }
    if (raw is! Map<String, Object?>) throw ProtocolException('trame non-objet');
    final Map<String, Object?> obj = raw;
    final type = obj['type'];
    if (type is! String) throw ProtocolException('type manquant');
    if (type == 'pair' || type == 'hello') {
      if (obj['v'] != protocolVersion) throw ProtocolException('version non prise en charge: ${obj['v']}');
    }
    String s(String k) {
      final v = obj[k];
      if (v is! String) throw ProtocolException('champ $k manquant ou non-string');
      return v;
    }

    int i(String k) {
      final v = obj[k];
      if (v is! int) throw ProtocolException('champ $k manquant ou non-entier');
      return v;
    }

    return switch (type) {
      'pair' => PairMsg(token: s('token'), name: s('name'), pub: s('pub')),
      'pair_challenge' => PairChallengeMsg(nonce: s('nonce')),
      'pair_proof' => PairProofMsg(sig: s('sig')),
      'paired' => PairedMsg(pcId: s('pcId'), name: s('name'), session: s('session')),
      'hello' => HelloMsg(pcId: s('pcId'), pub: s('pub'), session: s('session')),
      'welcome' => const WelcomeMsg(),
      'unknown' => const UnknownMsg(),
      'auth' => AuthMsg(
          id: s('id'),
          pcId: s('pcId'),
          action: s('action'),
          label: s('label'),
          nonce: s('nonce'),
          iat: i('iat'),
          exp: i('exp'),
        ),
      'auth_ok' => AuthOkMsg(id: s('id'), sig: s('sig')),
      'auth_denied' => AuthDeniedMsg(id: s('id'), reason: DenyReason.fromWire(s('reason'))),
      'ping' => const PingMsg(),
      'pong' => const PongMsg(),
      _ => throw ProtocolException('type inconnu: $type'),
    };
  }
}
