import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/asn1.dart';
import 'package:biokey/core/crypto/verify.dart';
import 'package:biokey/core/crypto/random.dart';
import '../../support/test_keys.dart';

/// Raw 65-byte uncompressed EC point (0x04 || X || Y) embedded in [spkiB64].
Uint8List _pointOf(String spkiB64) {
  final seq = ASN1Parser(base64Decode(spkiB64)).nextObject() as ASN1Sequence;
  final bitString = seq.elements![1] as ASN1BitString;
  return Uint8List.fromList(bitString.stringValues!);
}

/// Compresses an uncompressed X9.62 point (0x04 || X || Y) to 0x02/0x03 || X.
Uint8List _compress(Uint8List uncompressedPoint) {
  final x = uncompressedPoint.sublist(1, 33);
  final yLast = uncompressedPoint[64];
  return Uint8List.fromList([(yLast & 1) == 0 ? 0x02 : 0x03, ...x]);
}

Uint8List _spkiDer({required String algOid, required String curveOid, required List<int> point}) =>
    ASN1Sequence(elements: [
      ASN1Sequence(elements: [
        ASN1ObjectIdentifier.fromIdentifierString(algOid),
        ASN1ObjectIdentifier.fromIdentifierString(curveOid),
      ]),
      ASN1BitString(stringValues: point),
    ]).encode();

void main() {
  final keys = TestKeys();
  const v = EcdsaVerifier();
  const payload = '{"type":"auth","id":"u1"}';
  const oidEcPublicKey = '1.2.840.10045.2.1';
  const oidPrime256v1 = '1.2.840.10045.3.1.7';

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

  test('wrong algorithm OID (rsaEncryption) fails even with a valid point', () {
    final point = _pointOf(keys.pubSpkiB64);
    final spki = _spkiDer(algOid: '1.2.840.113549.1.1.1', curveOid: oidPrime256v1, point: point);
    expect(
      v.verify(pubSpkiB64: base64Encode(spki), payload: payload, sigB64: keys.sign(payload)),
      isFalse,
    );
  });

  test('wrong curve OID (secp384r1) fails even with a valid point', () {
    final point = _pointOf(keys.pubSpkiB64);
    final spki = _spkiDer(algOid: oidEcPublicKey, curveOid: '1.3.132.0.34', point: point);
    expect(
      v.verify(pubSpkiB64: base64Encode(spki), payload: payload, sigB64: keys.sign(payload)),
      isFalse,
    );
  });

  test('a compressed point is rejected', () {
    final compressed = _compress(_pointOf(keys.pubSpkiB64));
    final spki = _spkiDer(algOid: oidEcPublicKey, curveOid: oidPrime256v1, point: compressed);
    expect(
      v.verify(pubSpkiB64: base64Encode(spki), payload: payload, sigB64: keys.sign(payload)),
      isFalse,
    );
  });

  test('trailing bytes after the SPKI DER are rejected', () {
    final point = _pointOf(keys.pubSpkiB64);
    final spki = _spkiDer(algOid: oidEcPublicKey, curveOid: oidPrime256v1, point: point);
    final withTrailer = Uint8List.fromList([...spki, 0x00]);
    expect(
      v.verify(pubSpkiB64: base64Encode(withTrailer), payload: payload, sigB64: keys.sign(payload)),
      isFalse,
    );
  });

  test('trailing bytes after the signature DER are rejected', () {
    final sig = base64Decode(keys.sign(payload));
    final withTrailer = Uint8List.fromList([...sig, 0x00]);
    expect(
      v.verify(pubSpkiB64: keys.pubSpkiB64, payload: payload, sigB64: base64Encode(withTrailer)),
      isFalse,
    );
  });

  test('a signature SEQUENCE without exactly two INTEGER elements is rejected', () {
    final oneElement = ASN1Sequence(elements: [ASN1Integer.fromtInt(1)]).encode();
    expect(
      v.verify(pubSpkiB64: keys.pubSpkiB64, payload: payload, sigB64: base64Encode(oneElement)),
      isFalse,
    );
    final threeElements =
        ASN1Sequence(elements: [ASN1Integer.fromtInt(1), ASN1Integer.fromtInt(2), ASN1Integer.fromtInt(3)])
            .encode();
    expect(
      v.verify(pubSpkiB64: keys.pubSpkiB64, payload: payload, sigB64: base64Encode(threeElements)),
      isFalse,
    );
  });

  test('a negative r or s in the DER signature is rejected', () {
    final negR = ASN1Sequence(elements: [ASN1Integer(BigInt.from(-1)), ASN1Integer(BigInt.one)]).encode();
    expect(v.verify(pubSpkiB64: keys.pubSpkiB64, payload: payload, sigB64: base64Encode(negR)), isFalse);
    final negS = ASN1Sequence(elements: [ASN1Integer(BigInt.one), ASN1Integer(BigInt.from(-1))]).encode();
    expect(v.verify(pubSpkiB64: keys.pubSpkiB64, payload: payload, sigB64: base64Encode(negS)), isFalse);
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
