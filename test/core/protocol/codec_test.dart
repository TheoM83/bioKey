import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/core/protocol/codec.dart';
import 'package:biokey/core/protocol/messages.dart';

void main() {
  group('Codec', () {
    test('round-trips every message type', () {
      final msgs = <Message>[
        const PairMsg(token: 't', name: 'Nothing Phone', pub: 'PUB'),
        const PairChallengeMsg(nonce: 'N'),
        const PairProofMsg(sig: 'S'),
        const PairedMsg(pcId: 'abcd', name: 'PC-MAISON'),
        const HelloMsg(pcId: 'abcd', pub: 'PUB'),
        const WelcomeMsg(),
        const UnknownMsg(),
        const AuthMsg(id: 'u1', pcId: 'abcd', action: 'open', label: 'Mon app', nonce: 'N', iat: 100, exp: 130),
        const AuthOkMsg(id: 'u1', sig: 'S'),
        const AuthDeniedMsg(id: 'u1', reason: DenyReason.biometricFailed),
        const PingMsg(),
        const PongMsg(),
      ];
      for (final m in msgs) {
        expect(Codec.decode(Codec.encode(m)), equals(m), reason: m.type);
      }
    });

    test('auth encodes with stable field order', () {
      const m = AuthMsg(id: 'u1', pcId: 'abcd', action: 'open', label: 'Mon app', nonce: 'N', iat: 100, exp: 130);
      expect(Codec.encode(m),
          '{"type":"auth","id":"u1","pcId":"abcd","action":"open","label":"Mon app","nonce":"N","iat":100,"exp":130}');
    });

    test('pair and hello carry v=1', () {
      expect(Codec.encode(const PairMsg(token: 't', name: 'n', pub: 'p')), contains('"v":1'));
      expect(Codec.encode(const HelloMsg(pcId: 'x', pub: 'p')), contains('"v":1'));
    });

    test('rejects wrong version', () {
      expect(() => Codec.decode('{"type":"hello","v":2,"pcId":"x","pub":"p"}'), throwsA(isA<ProtocolException>()));
    });

    test('rejects unknown type, non-object, malformed json, missing field', () {
      expect(() => Codec.decode('{"type":"nope"}'), throwsA(isA<ProtocolException>()));
      expect(() => Codec.decode('[1,2]'), throwsA(isA<ProtocolException>()));
      expect(() => Codec.decode('{not json'), throwsA(isA<ProtocolException>()));
      expect(() => Codec.decode('{"type":"auth_ok","id":"u1"}'), throwsA(isA<ProtocolException>()));
      expect(() => Codec.decode('{"type":"auth_denied","id":"u1","reason":"lol"}'), throwsA(isA<ProtocolException>()));
    });

    test('deny reasons use wire names', () {
      expect(Codec.encode(const AuthDeniedMsg(id: 'u', reason: DenyReason.biometricFailed)), contains('"biometric_failed"'));
    });
  });
}
