import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/asn1.dart';
import 'package:biokey/core/crypto/identity.dart';

void main() {
  test('a year < 2050 encodes as a 13-character zero-padded UTCTime', () {
    final dt = DateTime.utc(2049, 3, 5, 1, 2, 3);
    final obj = encodeAsn1Time(dt);
    final der = obj.encode();

    expect(obj.tag, ASN1Tags.UTC_TIME);
    expect(obj.valueBytes!.length, 13);
    expect(ascii.decode(obj.valueBytes!), '490305010203Z');

    final parsed = ASN1Parser(der).nextObject() as ASN1UtcTime;
    expect(parsed.time, dt);
  });

  test(
      'a year >= 2050 with single-digit month/day/h/m/s encodes as a '
      '15-character zero-padded GeneralizedTime', () {
    final dt = DateTime.utc(2051, 3, 5, 1, 2, 3);
    final obj = encodeAsn1Time(dt);
    final der = obj.encode();

    expect(obj.tag, ASN1Tags.GENERALIZED_TIME);
    expect(obj.valueBytes!.length, 15);
    expect(ascii.decode(obj.valueBytes!), '20510305010203Z');

    final parsed = ASN1Parser(der).nextObject() as ASN1GeneralizedTime;
    expect(parsed.dateTimeValue, dt);
  });
}
