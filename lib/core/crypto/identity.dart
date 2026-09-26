import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:basic_utils/basic_utils.dart';
import 'package:pointycastle/asn1.dart' show ASN1PrivateKeyInfo;
import 'package:pointycastle/export.dart' show ECPrivateKey, ECPublicKey, SHA256Digest;

final class DesktopIdentity {
  DesktopIdentity._({required this.certPem, required this.keyPem, required this.fingerprintB64Url, required this.pcId});
  final String certPem;
  final String keyPem;
  final String fingerprintB64Url;
  final String pcId;

  SecurityContext securityContext() => SecurityContext()
    ..useCertificateChainBytes(utf8.encode(certPem))
    ..usePrivateKeyBytes(utf8.encode(keyPem));
}

Uint8List _sha256(Uint8List data) => SHA256Digest().process(data);

String certFingerprintB64Url(Uint8List der) => base64UrlEncode(_sha256(der)).replaceAll('=', '');

String pcIdFromFingerprint(Uint8List sha256) =>
    sha256.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _derFromPem(String pem) =>
    base64Decode(pem.replaceAll(RegExp(r'-----[A-Z ]+-----'), '').replaceAll(RegExp(r'\s'), ''));

DesktopIdentity parseDesktopIdentity({required String certPem, required String keyPem}) {
  final der = _derFromPem(certPem);
  final h = _sha256(der);
  return DesktopIdentity._(
    certPem: certPem,
    keyPem: keyPem,
    fingerprintB64Url: base64UrlEncode(h).replaceAll('=', ''),
    pcId: pcIdFromFingerprint(h),
  );
}

DesktopIdentity generateDesktopIdentity({required String pcName}) {
  final pair = CryptoUtils.generateEcKeyPair(curve: 'prime256v1');
  final priv = pair.privateKey as ECPrivateKey;
  final pub = pair.publicKey as ECPublicKey;
  final csr = X509Utils.generateEccCsrPem({'CN': pcName, 'O': 'BioKey'}, priv, pub);
  final certPem = X509Utils.generateSelfSignedCertificate(priv, csr, 3650);
  final keyPem = _pkcs8PrivateKeyPem(priv);
  return parseDesktopIdentity(certPem: certPem, keyPem: keyPem);
}

/// Wraps the SEC1 "EC PRIVATE KEY" PEM (as produced by
/// [CryptoUtils.encodeEcPrivateKeyToPem]) in a PKCS#8 `PrivateKeyInfo`
/// envelope, which `dart:io`'s `SecurityContext.usePrivateKeyBytes` accepts
/// reliably across platforms.
String _pkcs8PrivateKeyPem(ECPrivateKey priv) {
  final sec1Pem = CryptoUtils.encodeEcPrivateKeyToPem(priv);
  final der = ASN1PrivateKeyInfo.fromEccPem(sec1Pem).encode();

  final b64 = base64Encode(der);
  final chunks = <String>[];
  for (var i = 0; i < b64.length; i += 64) {
    chunks.add(b64.substring(i, i + 64 > b64.length ? b64.length : i + 64));
  }
  return '-----BEGIN PRIVATE KEY-----\n${chunks.join('\n')}\n-----END PRIVATE KEY-----';
}
