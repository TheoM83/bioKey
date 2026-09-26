import 'dart:convert';
import 'dart:typed_data';
import 'package:basic_utils/basic_utils.dart';

/// Real P-256 keypair for tests. `sign` mimics Android `SHA256withECDSA`
/// (DER-encoded r,s). `pubSpkiB64` is the base64 SubjectPublicKeyInfo DER,
/// the same format `biometric_signature` returns.
class TestKeys {
  TestKeys() {
    final pair = CryptoUtils.generateEcKeyPair(curve: 'prime256v1');
    _priv = pair.privateKey as ECPrivateKey;
    final pub = pair.publicKey as ECPublicKey;
    final pem = CryptoUtils.encodeEcPublicKeyToPem(pub);
    pubSpkiB64 = pem.replaceAll(RegExp(r'-----[A-Z ]+-----'), '').replaceAll(RegExp(r'\s'), '');
  }
  late final ECPrivateKey _priv;
  late final String pubSpkiB64;

  String sign(String payload) {
    final sig = CryptoUtils.ecSign(_priv, Uint8List.fromList(utf8.encode(payload)), algorithmName: 'SHA-256/ECDSA');
    return CryptoUtils.ecSignatureToBase64(sig);
  }
}
