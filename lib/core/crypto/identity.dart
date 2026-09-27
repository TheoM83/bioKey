import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

/// Local stand-in for `package:meta`'s `@visibleForTesting`: marks a
/// declaration that is public only so a test in another file can exercise
/// it directly. Defined here (private to this file) rather than depending
/// on `package:meta` because `pubspec.yaml` is out of scope for this change
/// (`meta` is only a transitive dependency today), and kept private so it
/// can't collide with the real `@visibleForTesting` other files import from
/// `package:flutter/foundation.dart`.
class _VisibleForTesting {
  const _VisibleForTesting();
}

const _VisibleForTesting _visibleForTesting = _VisibleForTesting();

final class DesktopIdentity {
  DesktopIdentity._({required this.certPem, required this.keyPem, required this.fingerprintB64Url, required this.pcId});
  final String certPem;
  final String keyPem;
  final String fingerprintB64Url;
  final String pcId;

  // TLS 1.3 only: `dart:io`'s SecurityContext.minimumTlsProtocolVersion
  // (present since Dart 3.9, which this project targets) defaults to
  // TLS 1.2 — raise it so a downgrade to 1.2 is refused outright rather
  // than merely discouraged. Keep in step with pinned_socket.dart's client
  // context and SECURITY.md/spec §7.1/§7.3, which document this floor.
  SecurityContext securityContext() => SecurityContext()
    ..useCertificateChainBytes(utf8.encode(certPem))
    ..usePrivateKeyBytes(utf8.encode(keyPem))
    ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3;
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

// ---- OIDs used while building the self-signed X.509 v3 certificate ----
const String _oidEcPublicKey = '1.2.840.10045.2.1';
const String _oidPrime256v1 = '1.2.840.10045.3.1.7';
const String _oidEcdsaWithSha256 = '1.2.840.10045.4.3.2';
const String _oidCommonName = '2.5.4.3';
const String _oidOrganizationName = '2.5.4.10';
const String _oidBasicConstraints = '2.5.29.19';
const String _oidSubjectAltName = '2.5.29.17';

DesktopIdentity generateDesktopIdentity({required String pcName}) {
  final rng = _secureRandom();
  final keyGen = ECKeyGenerator()
    ..init(ParametersWithRandom(ECKeyGeneratorParameters(ECCurve_secp256r1()), rng));
  final pair = keyGen.generateKeyPair();
  final priv = pair.privateKey;
  final pub = pair.publicKey;

  final tbs = _buildTbsCertificate(pcName: pcName, pub: pub);
  final tbsDer = tbs.encode();

  final signer = Signer('SHA-256/ECDSA')
    ..init(true, ParametersWithRandom(PrivateKeyParameter<ECPrivateKey>(priv), rng));
  final sig = signer.generateSignature(Uint8List.fromList(tbsDer)) as ECSignature;
  final sigDer = ASN1Sequence(elements: [ASN1Integer(sig.r), ASN1Integer(sig.s)]).encode();

  final cert = ASN1Sequence(elements: [
    tbs,
    _algorithmIdSeq(_oidEcdsaWithSha256),
    ASN1BitString(stringValues: sigDer),
  ]);
  final certPem = _pem('CERTIFICATE', cert.encode());
  final keyPem = _pkcs8PrivateKeyPem(priv, pub);
  return parseDesktopIdentity(certPem: certPem, keyPem: keyPem);
}

SecureRandom _secureRandom() {
  final seed = Uint8List(32);
  final r = Random.secure();
  for (var i = 0; i < seed.length; i++) {
    seed[i] = r.nextInt(256);
  }
  return SecureRandom('Fortuna')..seed(KeyParameter(seed));
}

ASN1Sequence _algorithmIdSeq(String oid) =>
    ASN1Sequence(elements: [ASN1ObjectIdentifier.fromIdentifierString(oid)]);

ASN1Sequence _nameSeq({required String cn, required String o}) => ASN1Sequence(elements: [
      _rdn(_oidCommonName, cn),
      _rdn(_oidOrganizationName, o),
    ]);

ASN1Set _rdn(String oid, String value) => ASN1Set(elements: [
      ASN1Sequence(elements: [
        ASN1ObjectIdentifier.fromIdentifierString(oid),
        ASN1UTF8String(utf8StringValue: value),
      ]),
    ]);

/// Wraps [inner] in an `[tag] EXPLICIT` context-specific constructed value.
ASN1Object _explicit(int tag, ASN1Object inner) => ASN1Object(tag: tag)..valueBytes = inner.encode();

/// UTCTime for years in [1950, 2050) (2-digit year, per X.509), GeneralizedTime
/// otherwise. `ASN1GeneralizedTime.encode()` in pointycastle 4.0.0 does not
/// zero-pad month/day/hour/minute/second, so the GeneralizedTime branch is
/// built by hand rather than delegated to that class.
///
/// Exposed (not prefixed with `_`) and annotated `@_visibleForTesting`
/// purely so a test can exercise both branches directly, without needing a
/// certificate whose validity dates happen to straddle year 2050.
@_visibleForTesting
ASN1Object encodeAsn1Time(DateTime dt) {
  final utc = dt.toUtc();
  if (utc.year >= 1950 && utc.year < 2050) {
    return ASN1UtcTime(utc);
  }
  final s = '${utc.year.toString().padLeft(4, '0')}'
      '${utc.month.toString().padLeft(2, '0')}'
      '${utc.day.toString().padLeft(2, '0')}'
      '${utc.hour.toString().padLeft(2, '0')}'
      '${utc.minute.toString().padLeft(2, '0')}'
      '${utc.second.toString().padLeft(2, '0')}Z';
  return ASN1Object(tag: ASN1Tags.GENERALIZED_TIME)..valueBytes = Uint8List.fromList(ascii.encode(s));
}

ASN1Sequence _spkiSeq(ECPublicKey pub) => ASN1Sequence(elements: [
      ASN1Sequence(elements: [
        ASN1ObjectIdentifier.fromIdentifierString(_oidEcPublicKey),
        ASN1ObjectIdentifier.fromIdentifierString(_oidPrime256v1),
      ]),
      ASN1BitString(stringValues: pub.Q!.getEncoded(false)),
    ]);

ASN1Sequence _extension(String oid, Uint8List value, {bool critical = false}) {
  final elements = <ASN1Object>[ASN1ObjectIdentifier.fromIdentifierString(oid)];
  if (critical) elements.add(ASN1Boolean(true));
  elements.add(ASN1OctetString(octets: value));
  return ASN1Sequence(elements: elements);
}

ASN1Sequence _basicConstraintsExtension() =>
    _extension(_oidBasicConstraints, ASN1Sequence(elements: []).encode(), critical: true);

ASN1Sequence _subjectAltNameExtension() {
  final dns = ASN1Object(tag: 0x82)..valueBytes = Uint8List.fromList(ascii.encode('localhost'));
  final ip = ASN1Object(tag: 0x87)..valueBytes = Uint8List.fromList([127, 0, 0, 1]);
  final names = ASN1Sequence(elements: [dns, ip]);
  return _extension(_oidSubjectAltName, names.encode());
}

BigInt _bytesToPositiveBigInt(Uint8List bytes) {
  var result = BigInt.zero;
  for (final b in bytes) {
    result = (result << 8) | BigInt.from(b);
  }
  return result;
}

ASN1Sequence _buildTbsCertificate({required String pcName, required ECPublicKey pub}) {
  final now = DateTime.now().toUtc();
  final notBefore = now.subtract(const Duration(days: 1));
  final notAfter = DateTime.utc(now.year + 10, now.month, now.day, now.hour, now.minute, now.second);

  final serialBytes = Uint8List(16);
  final r = Random.secure();
  for (var i = 0; i < serialBytes.length; i++) {
    serialBytes[i] = r.nextInt(256);
  }
  final serial = ASN1Integer(_bytesToPositiveBigInt(serialBytes));

  final name = _nameSeq(cn: pcName, o: 'BioKey');

  return ASN1Sequence(elements: [
    _explicit(0xA0, ASN1Integer.fromtInt(2)),
    serial,
    _algorithmIdSeq(_oidEcdsaWithSha256),
    name,
    ASN1Sequence(elements: [encodeAsn1Time(notBefore), encodeAsn1Time(notAfter)]),
    name,
    _spkiSeq(pub),
    _explicit(0xA3, ASN1Sequence(elements: [_basicConstraintsExtension(), _subjectAltNameExtension()])),
  ]);
}

String _pem(String label, Uint8List der) {
  final b64 = base64Encode(der);
  final chunks = <String>[];
  for (var i = 0; i < b64.length; i += 64) {
    chunks.add(b64.substring(i, i + 64 > b64.length ? b64.length : i + 64));
  }
  return '-----BEGIN $label-----\n${chunks.join('\n')}\n-----END $label-----';
}

Uint8List _fixedLengthBytes(BigInt value, int length) {
  final out = Uint8List(length);
  var v = value;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v = v >> 8;
  }
  return out;
}

/// PKCS#8 `PrivateKeyInfo` envelope around a SEC1-shaped `ECPrivateKey`
/// (RFC 5915, `parameters` omitted since it duplicates the outer
/// `AlgorithmIdentifier`), which `dart:io`'s `SecurityContext.usePrivateKeyBytes`
/// accepts reliably across platforms.
String _pkcs8PrivateKeyPem(ECPrivateKey priv, ECPublicKey pub) {
  final ecPrivateKey = ASN1Sequence(elements: [
    ASN1Integer.fromtInt(1),
    ASN1OctetString(octets: _fixedLengthBytes(priv.d!, 32)),
    _explicit(0xA1, ASN1BitString(stringValues: pub.Q!.getEncoded(false))),
  ]);
  final algorithm = ASN1AlgorithmIdentifier(
    ASN1ObjectIdentifier.fromIdentifierString(_oidEcPublicKey),
    parameters: ASN1ObjectIdentifier.fromIdentifierString(_oidPrime256v1),
  );
  final pkInfo = ASN1PrivateKeyInfo(
    ASN1Integer.fromtInt(0),
    algorithm,
    ASN1OctetString(octets: ecPrivateKey.encode()),
  );
  return _pem('PRIVATE KEY', pkInfo.encode());
}
