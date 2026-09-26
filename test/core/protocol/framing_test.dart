import 'dart:async';
import 'dart:convert';
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

  test('zero-length frame decodes to the empty string', () async {
    expect(await decode([encodeFrame('')]), ['']);
  });

  test('a length field of exactly maxFrameBytes is accepted', () async {
    final body = utf8.encode('x' * maxFrameBytes);
    final hdr = ByteData(4)..setUint32(0, body.length);
    expect(await decode([[...hdr.buffer.asUint8List(), ...body]]), ['x' * maxFrameBytes]);
  });

  test('a length field of maxFrameBytes + 1 is rejected', () async {
    final hdr = ByteData(4)..setUint32(0, maxFrameBytes + 1);
    expect(decode([hdr.buffer.asUint8List()]), throwsA(isA<FramingException>()));
  });

  test('header split across four one-byte chunks is still parsed', () async {
    final f = encodeFrame('Z');
    final chunks = [for (var i = 0; i < f.length; i++) f.sublist(i, i + 1)];
    expect(await decode(chunks), ['Z']);
  });

  test('a max-size frame fed one byte at a time decodes well under the CI-safe time bound', () async {
    final frame = encodeFrame('x' * maxFrameBytes);
    final chunks = [for (var i = 0; i < frame.length; i++) frame.sublist(i, i + 1)];
    final sw = Stopwatch()..start();
    final result = await decode(chunks);
    sw.stop();
    expect(result, ['x' * maxFrameBytes]);
    expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('an upstream error closes the output stream after forwarding it', () async {
    final source = StreamController<List<int>>();
    final doneCompleter = Completer<void>();
    Object? seenError;
    source.stream.transform(FrameDecoder()).listen(
      (_) {},
      onError: (Object e) => seenError = e,
      onDone: doneCompleter.complete,
    );
    source.addError(Exception('boom'));
    await doneCompleter.future.timeout(const Duration(seconds: 2));
    expect(seenError, isA<Exception>());
  });

  test('cancelling the output subscription cancels the upstream subscription', () async {
    var upstreamCancelled = false;
    final source = StreamController<List<int>>(onCancel: () => upstreamCancelled = true);
    final sub = source.stream.transform(FrameDecoder()).listen((_) {});
    await sub.cancel();
    expect(upstreamCancelled, isTrue);
  });

  test('pausing/resuming the output subscription forwards to the upstream subscription', () async {
    var paused = false;
    var resumed = false;
    final source = StreamController<List<int>>(
      onPause: () => paused = true,
      onResume: () => resumed = true,
    );
    final sub = source.stream.transform(FrameDecoder()).listen((_) {});
    sub.pause();
    expect(paused, isTrue);
    sub.resume();
    expect(resumed, isTrue);
    await sub.cancel();
  });
}
