import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/core/pairing/qr_payload.dart';

void main() {
  const p = QrPayload(pcId: '0011223344556677', name: 'PC MAISON', host: '192.168.1.10', port: 47621, fingerprint: 'abc_-', token: 'tok');

  test('round-trip', () {
    final s = p.toUri().toString();
    expect(s, startsWith('biokey://pair?v=1&'));
    expect(QrPayload.parse(s), equals(p));
  });

  test('rejects wrong scheme, version, missing fields, bad port', () {
    expect(() => QrPayload.parse('https://x'), throwsFormatException);
    expect(() => QrPayload.parse('biokey://pair?v=2&id=a&n=b&h=c&p=1&fp=d&t=e'), throwsFormatException);
    expect(() => QrPayload.parse('biokey://pair?v=1&id=a&n=b&h=c&p=1&fp=d'), throwsFormatException);
    expect(() => QrPayload.parse('biokey://pair?v=1&id=a&n=b&h=c&p=99999&fp=d&t=e'), throwsFormatException);
  });
}
