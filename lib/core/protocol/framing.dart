import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'messages.dart' show ProtocolException;

const int maxFrameBytes = 65536;

class FramingException extends ProtocolException {
  FramingException(super.message);
}

Uint8List encodeFrame(String payload) {
  final body = utf8.encode(payload);
  if (body.length > maxFrameBytes) throw ArgumentError('trame trop grande: ${body.length} octets');
  final out = Uint8List(4 + body.length);
  ByteData.view(out.buffer).setUint32(0, body.length);
  out.setRange(4, out.length, body);
  return out;
}

final class FrameDecoder extends StreamTransformerBase<List<int>, String> {
  @override
  Stream<String> bind(Stream<List<int>> stream) {
    final controller = StreamController<String>();
    final buf = BytesBuilder(copy: false);
    int? need;
    late StreamSubscription<List<int>> sub;

    void fail(String msg) {
      controller.addError(FramingException(msg));
      sub.cancel();
      controller.close();
    }

    sub = stream.listen((chunk) {
      buf.add(chunk);
      while (true) {
        final bytes = buf.toBytes();
        if (need == null) {
          if (bytes.length < 4) break;
          final len = ByteData.view(bytes.buffer, bytes.offsetInBytes, 4).getUint32(0);
          if (len > maxFrameBytes) {
            fail('longueur de trame $len > $maxFrameBytes');
            return;
          }
          need = len;
          buf.clear();
          buf.add(bytes.sublist(4));
          continue;
        }
        if (bytes.length < need!) break;
        final body = bytes.sublist(0, need!);
        buf.clear();
        buf.add(bytes.sublist(need!));
        need = null;
        try {
          controller.add(utf8.decode(body, allowMalformed: false));
        } on FormatException {
          fail('trame non UTF-8');
          return;
        }
      }
    }, onError: controller.addError, onDone: controller.close, cancelOnError: true);
    controller.onCancel = sub.cancel;
    return controller.stream;
  }
}
