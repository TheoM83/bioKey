import 'dart:async';

/// Message channel between the UI isolate and the foreground-service
/// (TaskHandler) isolate. Messages are plain JSON-compatible maps with an
/// `op` field; see [TaskOps].
///
/// Abstracted so the coordinator, the proxy signer and the UI controller
/// can be unit-tested over an in-memory transport instead of the
/// `flutter_foreground_task` plumbing.
abstract interface class TaskTransport {
  void send(Map<String, Object?> message);
  Stream<Map<String, Object?>> get messages;
}

/// Operation names used on a [TaskTransport].
///
/// UI → task commands: [getState], [pair], [revoke], [refresh], [setHost].
/// Task → UI state: [state], [pairResult], [revoked], [setHostResult].
/// Task → UI signer requests: [ping], [sign], [ensurePublicKey], [deleteKey];
/// UI → task replies (same `reqId`): [pong], [sig], [err], [pub], [ok].
abstract final class TaskOps {
  static const getState = 'getState';
  static const pair = 'pair';
  static const revoke = 'revoke';
  static const refresh = 'refresh';
  static const setHost = 'setHost';

  static const state = 'state';
  static const pairResult = 'pairResult';
  static const revoked = 'revoked';
  static const setHostResult = 'setHostResult';

  static const ping = 'ping';
  static const sign = 'sign';
  static const ensurePublicKey = 'ensurePublicKey';
  static const deleteKey = 'deleteKey';

  static const pong = 'pong';
  static const sig = 'sig';
  static const err = 'err';
  static const pub = 'pub';
  static const ok = 'ok';

  /// Replies the task side waits for (routed to the proxy signer).
  static const replies = {pong, sig, err, pub, ok};
}

/// Normalises whatever a platform channel / SendPort delivered into a
/// message map, or `null` if it isn't one.
Map<String, Object?>? asTaskMessage(Object? data) {
  if (data is! Map) return null;
  final out = <String, Object?>{};
  for (final e in data.entries) {
    final k = e.key;
    if (k is! String) return null;
    out[k] = e.value;
  }
  return out['op'] is String ? out : null;
}

/// A [TaskTransport] whose incoming side is fed by [deliver] — used by the
/// TaskHandler (fed from `onReceiveData`) and by the UI isolate (fed from
/// the task data callback).
final class CallbackTaskTransport implements TaskTransport {
  CallbackTaskTransport(this._send);
  final void Function(Object message) _send;
  final _incoming = StreamController<Map<String, Object?>>.broadcast();

  @override
  void send(Map<String, Object?> message) => _send(message);

  @override
  Stream<Map<String, Object?>> get messages => _incoming.stream;

  void deliver(Object? data) {
    final m = asTaskMessage(data);
    if (m != null && !_incoming.isClosed) _incoming.add(m);
  }

  Future<void> close() => _incoming.close();
}
