import 'dart:convert';
import 'dart:typed_data';
import 'package:basic_utils/basic_utils.dart';

abstract interface class Verifier {
  bool verify({required String pubSpkiB64, required String payload, required String sigB64});
}

final class EcdsaVerifier implements Verifier {
  const EcdsaVerifier();

  @override
  bool verify({required String pubSpkiB64, required String payload, required String sigB64}) {
    try {
      final pem = '-----BEGIN PUBLIC KEY-----\n$pubSpkiB64\n-----END PUBLIC KEY-----';
      final pub = CryptoUtils.ecPublicKeyFromPem(pem);
      final sig = base64Decode(sigB64);
      if (sig.isEmpty) return false;
      final ecSig = CryptoUtils.ecSignatureFromDerBytes(sig);
      return CryptoUtils.ecVerify(pub, Uint8List.fromList(utf8.encode(payload)), ecSig, algorithm: 'SHA-256/ECDSA');
    } catch (_) {
      return false;
    }
  }
}
