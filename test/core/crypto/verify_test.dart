import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/core/crypto/verify.dart';
import 'package:biokey/core/crypto/random.dart';
import '../../support/test_keys.dart';

void main() {
  final keys = TestKeys();
  const v = EcdsaVerifier();
  const payload = '{"type":"auth","id":"u1"}';

  test('valid signature verifies', () {
    expect(v.verify(pubSpkiB64: keys.pubSpkiB64, payload: payload, sigB64: keys.sign(payload)), isTrue);
  });

  test('tampered payload fails', () {
    expect(v.verify(pubSpkiB64: keys.pubSpkiB64, payload: '$payload ', sigB64: keys.sign(payload)), isFalse);
  });

  test('wrong key fails', () {
    final other = TestKeys();
    expect(v.verify(pubSpkiB64: other.pubSpkiB64, payload: payload, sigB64: keys.sign(payload)), isFalse);
  });

  test('garbage inputs return false, never throw', () {
    expect(v.verify(pubSpkiB64: 'not base64!!', payload: payload, sigB64: keys.sign(payload)), isFalse);
    expect(v.verify(pubSpkiB64: keys.pubSpkiB64, payload: payload, sigB64: 'AAAA'), isFalse);
    expect(v.verify(pubSpkiB64: keys.pubSpkiB64, payload: payload, sigB64: ''), isFalse);
  });

  test('randomB64 yields requested byte length and differs each call', () {
    final a = randomB64(32);
    final b = randomB64(32);
    expect(base64Decode(a).length, 32);
    expect(a, isNot(b));
    final u = randomB64Url(16);
    expect(u, isNot(contains('=')));
    expect(base64Url.decode(base64Url.normalize(u)).length, 16);
  });
}
