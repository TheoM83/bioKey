import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

Uint8List randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
}

String randomB64(int n) => base64Encode(randomBytes(n));
String randomB64Url(int n) => base64UrlEncode(randomBytes(n)).replaceAll('=', '');
