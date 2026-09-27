import 'dart:async';
import 'dart:collection';
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

/// A FIFO byte buffer that never re-scans or re-copies bytes it has already
/// buffered: incoming chunks are queued as-is, [length] is tracked
/// incrementally (O(1)), and [take] only copies the exact bytes it removes
/// (each byte is copied at most once, on its way out). This keeps
/// [FrameDecoder] linear in the number of bytes received, even when fed one
/// byte at a time.
final class _ByteQueue {
  final Queue<Uint8List> _chunks = Queue<Uint8List>();
  int _length = 0;

  int get length => _length;

  void add(List<int> chunk) {
    if (chunk.isEmpty) return;
    _chunks.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
    _length += chunk.length;
  }

  /// Removes and returns exactly [n] bytes from the front of the queue.
  /// Callers must first check `length >= n`.
  Uint8List take(int n) {
    if (n == 0) return Uint8List(0);
    final first = _chunks.first;
    if (first.length == n) {
      _chunks.removeFirst();
      _length -= n;
      return first;
    }
    if (first.length > n) {
      final result = Uint8List.sublistView(first, 0, n);
      _chunks.removeFirst();
      _chunks.addFirst(Uint8List.sublistView(first, n));
      _length -= n;
      return result;
    }
    final out = Uint8List(n);
    var offset = 0;
    while (offset < n) {
      final chunk = _chunks.first;
      final remaining = n - offset;
      if (chunk.length <= remaining) {
        out.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
        _chunks.removeFirst();
      } else {
        out.setRange(offset, n, chunk);
        _chunks.removeFirst();
        _chunks.addFirst(Uint8List.sublistView(chunk, remaining));
        offset = n;
      }
    }
    _length -= n;
    return out;
  }
}

final class FrameDecoder extends StreamTransformerBase<List<int>, String> {
  @override
  Stream<String> bind(Stream<List<int>> stream) {
    final controller = StreamController<String>();
    final buf = _ByteQueue();
    int? need;
    late StreamSubscription<List<int>> sub;

    void fail(String msg) {
      controller.addError(FramingException(msg));
      controller.close();
      sub.cancel();
    }

    sub = stream.listen((chunk) {
      buf.add(chunk);
      while (true) {
        if (need == null) {
          if (buf.length < 4) break;
          final header = buf.take(4);
          final len = ByteData.view(header.buffer, header.offsetInBytes, 4).getUint32(0);
          if (len > maxFrameBytes) {
            fail('longueur de trame $len > $maxFrameBytes');
            return;
          }
          need = len;
          continue;
        }
        if (buf.length < need!) break;
        final body = buf.take(need!);
        need = null;
        try {
          controller.add(utf8.decode(body, allowMalformed: false));
        } on FormatException {
          fail('trame non UTF-8');
          return;
        }
      }
    }, onError: (Object e, StackTrace st) {
      // An upstream error otherwise leaves cancelOnError's automatic
      // subscription cancellation as the only thing that happens: onDone
      // never fires (the subscription was cancelled, not completed) and
      // nothing closes `controller`, so the output stream would hang open
      // forever. Forward the error, then close explicitly.
      controller.addError(e, st);
      controller.close();
    }, onDone: controller.close, cancelOnError: true);
    controller.onCancel = sub.cancel;
    controller.onPause = sub.pause;
    controller.onResume = sub.resume;
    return controller.stream;
  }
}
