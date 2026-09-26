import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/core/protocol/framing.dart';

void main() {
  Future<List<String>> decode(List<List<int>> chunks) =>
      Stream<List<int>>.fromIterable(chunks).transform(FrameDecoder()).toList();

  test('round-trip one frame', () async {
    final f = encodeFrame('{"type":"ping"}');
    expect(f.length, 4 + 15);
    expect(await decode([f]), ['{"type":"ping"}']);
  });

  test('two frames in one chunk and one frame split across chunks', () async {
    final a = encodeFrame('A'), b = encodeFrame('BB');
    final joined = Uint8List.fromList([...a, ...b]);
    expect(await decode([joined]), ['A', 'BB']);
    expect(await decode([joined.sublist(0, 3), joined.sublist(3, 6), joined.sublist(6)]), ['A', 'BB']);
  });

  test('unicode payload survives', () async {
    const s = '{"label":"Ouvrir l’app — é"}';
    expect(await decode([encodeFrame(s)]), [s]);
  });

  test('oversized length field is rejected before reading the body', () async {
    final hdr = ByteData(4)..setUint32(0, 5 * 1024 * 1024);
    expect(decode([hdr.buffer.asUint8List()]), throwsA(isA<FramingException>()));
  });

  test('encodeFrame refuses oversized payloads', () {
    expect(() => encodeFrame('x' * (maxFrameBytes + 1)), throwsArgumentError);
  });

  test('invalid utf-8 is rejected', () async {
    final hdr = ByteData(4)..setUint32(0, 2);
    expect(decode([[...hdr.buffer.asUint8List(), 0xC3, 0x28]]), throwsA(isA<FramingException>()));
  });
}
