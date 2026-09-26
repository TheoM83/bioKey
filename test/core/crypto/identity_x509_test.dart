import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/asn1.dart';
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
