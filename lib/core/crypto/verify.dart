import 'dart:convert';
import 'dart:typed_data';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

const String _oidEcPublicKey = '1.2.840.10045.2.1';
const String _oidPrime256v1 = '1.2.840.10045.3.1.7';

abstract interface class Verifier {
  bool verify({required String pubSpkiB64, required String payload, required String sigB64});
}

final class EcdsaVerifier implements Verifier {
  const EcdsaVerifier();

  @override
  bool verify({required String pubSpkiB64, required String payload, required String sigB64}) {
    try {
      final pub = _decodeSpki(base64Decode(pubSpkiB64));
      if (pub == null) return false;

      final sig = _decodeDerSignature(base64Decode(sigB64));
      if (sig == null) return false;

      final signer = Signer('SHA-256/ECDSA')..init(false, PublicKeyParameter<ECPublicKey>(pub));
      return signer.verifySignature(Uint8List.fromList(utf8.encode(payload)), sig);
    } catch (_) {
      return false;
    }
  }

  /// Strictly parses a P-256 SubjectPublicKeyInfo: `SEQUENCE { SEQUENCE { OID
  /// ecPublicKey, OID prime256v1 }, BIT STRING <65-byte uncompressed point> }`
  /// with no trailing DER bytes. Anything else — a different algorithm or
  /// curve OID, a compressed or otherwise mis-sized point, extra bytes after
  /// the structure — is rejected rather than silently accepted with the
  /// hardcoded P-256 curve.
  ECPublicKey? _decodeSpki(Uint8List der) {
    final parser = ASN1Parser(der);
    final spkiSeq = parser.nextObject();
    if (parser.hasNext()) return null;
    if (spkiSeq is! ASN1Sequence || spkiSeq.elements!.length != 2) return null;

    final algSeq = spkiSeq.elements![0];
    if (algSeq is! ASN1Sequence || algSeq.elements!.length != 2) return null;
    final algOid = algSeq.elements![0];
    final curveOid = algSeq.elements![1];
    if (algOid is! ASN1ObjectIdentifier || algOid.objectIdentifierAsString != _oidEcPublicKey) {
      return null;
    }
    if (curveOid is! ASN1ObjectIdentifier || curveOid.objectIdentifierAsString != _oidPrime256v1) {
      return null;
    }

    final bitString = spkiSeq.elements![1];
    if (bitString is! ASN1BitString) return null;
    final point = bitString.stringValues;
    if (point == null || point.length != 65 || point[0] != 0x04) return null;

    final curve = ECCurve_secp256r1();
    final decoded = curve.curve.decodePoint(point);
    if (decoded == null) return null;
    return ECPublicKey(decoded, curve);
  }

  /// Strictly parses a DER ECDSA signature: `SEQUENCE { INTEGER r, INTEGER s
  /// }` with no trailing bytes and exactly two INTEGER elements.
  ECSignature? _decodeDerSignature(Uint8List der) {
    if (der.isEmpty) return null;
    final parser = ASN1Parser(der);
    final sigSeq = parser.nextObject();
    if (parser.hasNext()) return null;
    if (sigSeq is! ASN1Sequence || sigSeq.elements!.length != 2) return null;
    final rObj = sigSeq.elements![0];
    final sObj = sigSeq.elements![1];
    if (rObj is! ASN1Integer || sObj is! ASN1Integer) return null;
    return ECSignature(rObj.integer!, sObj.integer!);
  }
}
