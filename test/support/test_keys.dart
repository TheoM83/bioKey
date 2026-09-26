import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

/// Real P-256 keypair for tests. `sign` mimics Android `SHA256withECDSA`
/// (DER-encoded r,s). `pubSpkiB64` is the base64 SubjectPublicKeyInfo DER,
/// the same format `biometric_signature` returns.
class TestKeys {
  TestKeys() {
    final rng = _secureRandom();
    final keyGen = ECKeyGenerator()
      ..init(ParametersWithRandom(ECKeyGeneratorParameters(ECCurve_secp256r1()), rng));
    final pair = keyGen.generateKeyPair();
    _priv = pair.privateKey;
    final pub = pair.publicKey;
    final spki = ASN1Sequence(elements: [
      ASN1Sequence(elements: [
        ASN1ObjectIdentifier.fromIdentifierString('1.2.840.10045.2.1'),
        ASN1ObjectIdentifier.fromIdentifierString('1.2.840.10045.3.1.7'),
      ]),
      ASN1BitString(stringValues: pub.Q!.getEncoded(false)),
    ]);
    pubSpkiB64 = base64Encode(spki.encode());
  }
  late final ECPrivateKey _priv;
  late final String pubSpkiB64;

  String sign(String payload) {
    final signer = Signer('SHA-256/ECDSA')
      ..init(true, ParametersWithRandom(PrivateKeyParameter<ECPrivateKey>(_priv), _secureRandom()));
    final sig = signer.generateSignature(Uint8List.fromList(utf8.encode(payload))) as ECSignature;
    final der = ASN1Sequence(elements: [ASN1Integer(sig.r), ASN1Integer(sig.s)]).encode();
    return base64Encode(der);
  }
}

SecureRandom _secureRandom() {
  final seed = Uint8List(32);
  final r = Random.secure();
  for (var i = 0; i < seed.length; i++) {
    seed[i] = r.nextInt(256);
  }
  return SecureRandom('Fortuna')..seed(KeyParameter(seed));
}
