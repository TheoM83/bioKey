import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/core/crypto/identity.dart';

void main() {
  test('generate → parse gives same fingerprint and pcId', () {
    final id = generateDesktopIdentity(pcName: 'PC-TEST');
    expect(id.certPem, contains('BEGIN CERTIFICATE'));
    expect(id.fingerprintB64Url, isNot(contains('=')));
    expect(id.pcId, hasLength(16));
    final again = parseDesktopIdentity(certPem: id.certPem, keyPem: id.keyPem);
    expect(again.fingerprintB64Url, id.fingerprintB64Url);
    expect(again.pcId, id.pcId);
  });

  test('two identities differ', () {
    expect(generateDesktopIdentity(pcName: 'A').pcId, isNot(generateDesktopIdentity(pcName: 'B').pcId));
  });

  test('certificate is accepted by dart:io TLS server and fingerprint matches on the wire', () async {
    final id = generateDesktopIdentity(pcName: 'PC-TEST');
    final server = await HttpServer.bindSecure('127.0.0.1', 0, id.securityContext());
    server.listen((req) => req.response.close());
    String? seen;
    final client = HttpClient()
      ..badCertificateCallback = (cert, host, port) {
        seen = certFingerprintB64Url(cert.der);
        return true;
      };
    final req = await client.getUrl(Uri.parse('https://127.0.0.1:${server.port}/'));
    await (await req.close()).drain<void>();
    expect(seen, id.fingerprintB64Url);
    client.close(force: true);
    await server.close(force: true);
  });
}
