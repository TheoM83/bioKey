import 'dart:convert';
import 'dart:typed_data';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

abstract interface class Verifier {
  bool verify({required String pubSpkiB64, required String payload, required String sigB64});
}

final class EcdsaVerifier implements Verifier {
  const EcdsaVerifier();

  @override
  bool verify({required String pubSpkiB64, required String payload, required String sigB64}) {
    try {
      final spkiDer = base64Decode(pubSpkiB64);
      final spkiSeq = ASN1Parser(spkiDer).nextObject() as ASN1Sequence;
      final bitString = spkiSeq.elements![1] as ASN1BitString;
      final curve = ECCurve_secp256r1();
      final point = curve.curve.decodePoint(bitString.stringValues!);
      final pub = ECPublicKey(point, curve);

      final sigBytes = base64Decode(sigB64);
      if (sigBytes.isEmpty) return false;
      final sigSeq = ASN1Parser(sigBytes).nextObject() as ASN1Sequence;
      final r = (sigSeq.elements![0] as ASN1Integer).integer!;
      final s = (sigSeq.elements![1] as ASN1Integer).integer!;
      final sig = ECSignature(r, s);

      final signer = Signer('SHA-256/ECDSA')..init(false, PublicKeyParameter<ECPublicKey>(pub));
      return signer.verifySignature(Uint8List.fromList(utf8.encode(payload)), sig);
    } catch (_) {
      return false;
    }
  }
}
