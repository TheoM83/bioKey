import 'dart:async';
import 'dart:convert';

import 'package:biokey/phone/service/task_transport.dart';

/// Two connected in-memory [TaskTransport] ends (UI side / task side).
///
/// Like the real plugin plumbing, delivery is asynchronous and every
/// message is JSON round-tripped, so a non-serialisable payload fails here
/// too. Detaching an end ([detached]) silently drops what is sent to it,
/// like a UI isolate that is gone.
final class InMemoryTaskLink {
  InMemoryTaskLink() {
    ui = InMemoryTaskEnd(this, toTask: true);
    task = InMemoryTaskEnd(this, toTask: false);
  }

  late final InMemoryTaskEnd ui;
  late final InMemoryTaskEnd task;

  /// Every message sent, in order, as seen on the wire.
  final log = <Map<String, Object?>>[];

  void _route(Map<String, Object?> m, {required bool toTask}) {
    final wire = jsonDecode(jsonEncode(m)) as Map<String, Object?>;
    log.add(wire);
    final target = toTask ? task : ui;
    scheduleMicrotask(() {
      if (!target.detached && !target._c.isClosed) target._c.add(wire);
    });
  }
}

final class InMemoryTaskEnd implements TaskTransport {
  InMemoryTaskEnd(this._link, {required bool toTask}) : _toTask = toTask;
  final InMemoryTaskLink _link;
  final bool _toTask;
  final _c = StreamController<Map<String, Object?>>.broadcast();
  bool detached = false;

  /// Everything this end sent.
  final sent = <Map<String, Object?>>[];

  @override
  void send(Map<String, Object?> message) {
    sent.add(message);
    _link._route(message, toTask: _toTask);
  }

  @override
  Stream<Map<String, Object?>> get messages => _c.stream;
}
