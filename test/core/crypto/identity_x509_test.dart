import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';
import 'package:biokey/core/crypto/identity.dart';

Uint8List _certDer(String certPem) => base64Decode(
    certPem.replaceAll(RegExp(r'-----[A-Z ]+-----'), '').replaceAll(RegExp(r'\s'), ''));

DateTime _timeOf(ASN1Object o) =>
    o is ASN1UtcTime ? o.time! : (o as ASN1GeneralizedTime).dateTimeValue!;

String? _cnOf(ASN1Sequence name) {
  for (final rdn in name.elements!) {
    final atv = (rdn as ASN1Set).elements!.first as ASN1Sequence;
    final oid = atv.elements![0] as ASN1ObjectIdentifier;
    if (oid.objectIdentifierAsString == '2.5.4.3') {
      final value = atv.elements![1] as ASN1UTF8String;
      return value.utf8StringValue;
    }
  }
  return null;
}

/// Extension OIDs present in the `[3] EXPLICIT Extensions` field of [tbs].
Set<String?> _extensionOids(ASN1Sequence tbs) {
  final wrapper = tbs.elements![7];
  final extSeq = ASN1Parser(wrapper.valueBytes).nextObject() as ASN1Sequence;
  return {
    for (final e in extSeq.elements!) ((e as ASN1Sequence).elements![0] as ASN1ObjectIdentifier).objectIdentifierAsString,
  };
}

/// Verifies an ECDSA-SHA256 signature directly with pointycastle, over the
/// raw [message] bytes (not routed through [EcdsaVerifier], whose `payload`
/// parameter is a `String` and would corrupt arbitrary binary DER — the
/// signed `tbsCertificate` is not valid UTF-8 in general, since it embeds
/// raw EC point/serial bytes).
bool _verifyRawEcdsaSha256({required Uint8List spkiDer, required Uint8List sigDer, required Uint8List message}) {
  final spkiSeq = ASN1Parser(spkiDer).nextObject() as ASN1Sequence;
  final bitString = spkiSeq.elements![1] as ASN1BitString;
  final curve = ECCurve_secp256r1();
  final point = curve.curve.decodePoint(bitString.stringValues!);
  final pub = ECPublicKey(point, curve);

  final sigSeq = ASN1Parser(sigDer).nextObject() as ASN1Sequence;
  final r = (sigSeq.elements![0] as ASN1Integer).integer!;
  final s = (sigSeq.elements![1] as ASN1Integer).integer!;
  final sig = ECSignature(r, s);

  final signer = Signer('SHA-256/ECDSA')..init(false, PublicKeyParameter<ECPublicKey>(pub));
  return signer.verifySignature(message, sig);
}

void main() {
  test('generated certificate DER has the expected X.509 v3 structure', () {
    final id = generateDesktopIdentity(pcName: 'PC-X509');
    final der = _certDer(id.certPem);

    final cert = ASN1Parser(der).nextObject() as ASN1Sequence;
    final tbs = cert.elements![0] as ASN1Sequence;

    // [0] EXPLICIT version INTEGER 2 (v3)
    final versionWrapper = tbs.elements![0];
    final version = ASN1Parser(versionWrapper.valueBytes).nextObject() as ASN1Integer;
    expect(version.integer, BigInt.two);

    // signature AlgorithmIdentifier: ecdsa-with-SHA256
    final sigAlgInTbs = tbs.elements![2] as ASN1Sequence;
    final sigOid = sigAlgInTbs.elements![0] as ASN1ObjectIdentifier;
    expect(sigOid.objectIdentifierAsString, '1.2.840.10045.4.3.2');

    // outer signatureAlgorithm matches
    final outerSigAlg = cert.elements![1] as ASN1Sequence;
    final outerSigOid = outerSigAlg.elements![0] as ASN1ObjectIdentifier;
    expect(outerSigOid.objectIdentifierAsString, '1.2.840.10045.4.3.2');

    // signature BIT STRING has 0 unused bits
    final sigBitString = cert.elements![2] as ASN1BitString;
    expect(sigBitString.unusedbits, 0);

    // issuer / subject CN
    final issuer = tbs.elements![3] as ASN1Sequence;
    final subject = tbs.elements![5] as ASN1Sequence;
    expect(_cnOf(issuer), 'PC-X509');
    expect(_cnOf(subject), 'PC-X509');

    // validity ordering
    final validity = tbs.elements![4] as ASN1Sequence;
    final notBefore = _timeOf(validity.elements![0]);
    final notAfter = _timeOf(validity.elements![1]);
    expect(notBefore.isBefore(notAfter), isTrue);
    expect(notAfter.difference(notBefore).inDays, greaterThan(3650 - 2));
  });

  test('the certificate genuinely verifies its own self-signature, and carries a valid '
      'serial plus the required extensions', () {
    final id = generateDesktopIdentity(pcName: 'PC-X509-SIG');
    final der = _certDer(id.certPem);

    final cert = ASN1Parser(der).nextObject() as ASN1Sequence;
    final tbs = cert.elements![0] as ASN1Sequence;
    final sigBitString = cert.elements![2] as ASN1BitString;

    // The TLS handshake test elsewhere only proves dart:io/BoringSSL accepts
    // the certificate via a bypassed badCertificateCallback, not that the
    // embedded signature actually verifies against the embedded SPKI over
    // the embedded tbsCertificate bytes. Prove that directly here.
    final tbsDer = tbs.encode(); // tbs was parsed from `der`, so this returns those exact bytes.
    final spkiDer = (tbs.elements![6] as ASN1Sequence).encode();
    final sigDer = Uint8List.fromList(sigBitString.stringValues!);
    expect(
      _verifyRawEcdsaSha256(spkiDer: spkiDer, sigDer: sigDer, message: tbsDer),
      isTrue,
      reason: 'the certificate signature must verify over the exact embedded tbsCertificate bytes',
    );

    // A signature over a tampered copy of the tbs bytes must not verify.
    final tampered = Uint8List.fromList(tbsDer)..[tbsDer.length - 1] ^= 0x01;
    expect(_verifyRawEcdsaSha256(spkiDer: spkiDer, sigDer: sigDer, message: tampered), isFalse);

    // Serial number: positive, and within RFC 5280's 20-octet limit.
    final serial = tbs.elements![1] as ASN1Integer;
    expect(serial.integer! > BigInt.zero, isTrue);
    expect(serial.valueBytes!.length, lessThanOrEqualTo(20));

    // basicConstraints (2.5.29.19) and subjectAltName (2.5.29.17) are present.
    final oids = _extensionOids(tbs);
    expect(oids, containsAll(<String>['2.5.29.19', '2.5.29.17']));
  });

  test('real TLS handshake: X509Certificate reports subject with CN=<pcName>', () async {
    final id = generateDesktopIdentity(pcName: 'PC-X509-TLS');
    final server = await HttpServer.bindSecure('127.0.0.1', 0, id.securityContext());
    server.listen((req) => req.response.close());

    X509Certificate? seenCert;
    final client = HttpClient()
      ..badCertificateCallback = (cert, host, port) {
        seenCert = cert;
        return true;
      };
    final req = await client.getUrl(Uri.parse('https://127.0.0.1:${server.port}/'));
    await (await req.close()).drain<void>();

    expect(seenCert, isNotNull);
    expect(seenCert!.subject, contains('CN=PC-X509-TLS'));

    client.close(force: true);
    await server.close(force: true);
  });
}
