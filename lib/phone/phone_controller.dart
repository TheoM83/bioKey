import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/pairing/qr_payload.dart';
import '../core/session/biometric_signer.dart';
import '../core/storage/phone_store.dart';
import 'service/foreground_gate.dart';
import 'service/task_transport.dart';

/// The phone role's UI-isolate side.
///
/// The links to paired PCs live in the foreground-service isolate (see
/// `LinkCoordinator`), so they survive the Activity being destroyed and
/// come back on boot. This controller only:
/// - sends commands to it (`pair`, `revoke`, `refresh`, `getState`),
/// - mirrors the `state` it publishes (paired PCs, online, needs re-pair)
///   for the UI, as a [ChangeNotifier],
/// - answers its signer requests (`ping`, `sign`, `ensurePublicKey`,
///   `deleteKey`) with the real biometric [BiometricSigner], which needs
///   an Activity and therefore can only run here.
final class PhoneController extends ChangeNotifier {
  PhoneController({
    required TaskTransport transport,
    required BiometricSigner signer,
    required PhoneStore store,
    ForegroundGateApi? gate,
    this.commandTimeout = const Duration(seconds: 90),
    this.stateRetry = const Duration(seconds: 1),
  })  : _transport = transport,
        _signer = signer,
        _store = store,
        _gate = gate;

  final TaskTransport _transport;
  final BiometricSigner _signer;
  final PhoneStore _store;
  final ForegroundGateApi? _gate;

  /// Bound on a `pair`/`revoke` round trip (pairing itself is bounded at
  /// 60 s by the service; this only guards against a dead service).
  final Duration commandTimeout;

  /// How often `getState` is re-sent until the service first answers (it
  /// may still be starting when the UI comes up).
  final Duration stateRetry;

  StreamSubscription<Map<String, Object?>>? _sub;
  Timer? _stateTimer;
  var _gotState = false;
  var _keyChecked = false;
  var _disposed = false;
  int _nextId = 0;
  final _pending = <String, Completer<Map<String, Object?>>>{};

  var _pcs = <PairedPc>[];
  final _online = <String>{};

  /// PCs that answered `unknown`: the stored pairing is stale and must be
  /// redone from scratch.
  final needsRepair = <String>{};

  List<PairedPc> get pcs => List.unmodifiable(_pcs);
  bool isOnline(String pcId) => _online.contains(pcId);

  Future<void> init() async {
    _sub ??= _transport.messages.listen(_onMessage);
    _transport.send({'op': TaskOps.getState});
    _stateTimer ??= Timer.periodic(stateRetry, (t) {
      if (_gotState || _disposed || t.tick > 15) {
        t.cancel();
        return;
      }
      _transport.send({'op': TaskOps.getState});
    });
  }

  /// Runs the pairing handshake (in the service) and resolves with the
  /// new [PairedPc]; throws a [StateError] with the reason on failure.
  Future<PairedPc> pair(QrPayload qr) async {
    final reply = await _command(TaskOps.pair, {'qr': qr.toUri().toString()});
    if (reply['ok'] == true && reply['pc'] is Map) {
      return PairedPc.fromJson(Map<String, Object?>.from(reply['pc']! as Map));
    }
    throw StateError('${reply['error'] ?? 'échec'}');
  }

  Future<void> revoke(String pcId) async {
    await _command(TaskOps.revoke, {'pcId': pcId});
  }

  /// Sets a manual host for [pcId] (for reaching it over the user's own
  /// WireGuard/Tailscale tunnel — BioKey itself never has a server). The
  /// service validates and persists it, then restarts that PC's link with
  /// the new host; throws a [StateError] with the reason (e.g. "Adresse
  /// invalide") on failure.
  Future<void> setHost(String pcId, String host) async {
    final reply = await _command(TaskOps.setHost, {'pcId': pcId, 'host': host});
    if (reply['ok'] != true) {
      throw StateError('${reply['error'] ?? 'échec'}');
    }
  }

  Future<Map<String, Object?>> _command(String op, Map<String, Object?> args) async {
    final reqId = 'u${++_nextId}';
    final c = Completer<Map<String, Object?>>();
    _pending[reqId] = c;
    try {
      _transport.send({'op': op, 'reqId': reqId, ...args});
      return await c.future.timeout(
        commandTimeout,
        onTimeout: () => throw StateError("service d'arrière-plan injoignable"),
      );
    } finally {
      _pending.remove(reqId);
    }
  }

  void _onMessage(Map<String, Object?> m) {
    switch (m['op']) {
      case TaskOps.state:
        _applyState(m);
      case TaskOps.pairResult || TaskOps.revoked || TaskOps.setHostResult:
        final c = _pending.remove(m['reqId']);
        if (c != null && !c.isCompleted) c.complete(m);
      case TaskOps.ping:
        _transport.send({'op': TaskOps.pong, 'reqId': m['reqId']});
      case TaskOps.sign:
        unawaited(_answerSign(m));
      case TaskOps.ensurePublicKey:
        unawaited(_answerEnsure(m));
      case TaskOps.deleteKey:
        unawaited(_answerDelete(m));
    }
  }

  void _applyState(Map<String, Object?> m) {
    final pcs = <PairedPc>[];
    final raw = m['pcs'];
    if (raw is List) {
      for (final j in raw) {
        if (j is! Map) continue;
        try {
          pcs.add(PairedPc.fromJson(Map<String, Object?>.from(j)));
        } on Object {
          // Skip a malformed entry rather than dropping the whole state.
        }
      }
    }
    _pcs = pcs;
    _online
      ..clear()
      ..addAll(_strings(m['online']));
    needsRepair
      ..clear()
      ..addAll(_strings(m['needsRepair']));
    _gotState = true;
    _notify();
    if (!_keyChecked && _pcs.isNotEmpty) {
      _keyChecked = true;
      unawaited(_checkKey());
    }
  }

  Iterable<String> _strings(Object? v) => v is List ? v.whereType<String>() : const <String>[];

  /// With no UI (e.g. after boot) the service says `hello` with the cached
  /// public key; once the UI is up, confirm the key still exists — if
  /// enrolment changed it was recreated, and the service must reconnect so
  /// the PCs see the new key (and ask for re-pairing).
  Future<void> _checkKey() async {
    try {
      final before = await _store.pubKey();
      final after = await _signer.ensurePublicKey();
      if (before != after) _transport.send({'op': TaskOps.refresh});
    } on Object {
      // A later sign/ensure request will surface the problem.
    }
  }

  Future<void> _answerSign(Map<String, Object?> m) async {
    final reqId = m['reqId'];
    final payload = m['payload'];
    final prompt = m['prompt'];
    if (payload is! String || prompt is! String) {
      _transport.send({'op': TaskOps.err, 'reqId': reqId, 'kind': 'fail', 'message': 'requête invalide'});
      return;
    }
    try {
      final sig = await _signer.sign(payload: payload, prompt: prompt);
      _transport.send({'op': TaskOps.sig, 'reqId': reqId, 'sig': sig});
    } on Object catch (e) {
      _transport.send(_err(reqId, e));
    }
  }

  Future<void> _answerEnsure(Map<String, Object?> m) async {
    try {
      final pub = await _signer.ensurePublicKey();
      _transport.send({'op': TaskOps.pub, 'reqId': m['reqId'], 'pub': pub});
    } on Object catch (e) {
      _transport.send(_err(m['reqId'], e));
    }
  }

  Future<void> _answerDelete(Map<String, Object?> m) async {
    try {
      await _signer.deleteKey();
      _transport.send({'op': TaskOps.ok, 'reqId': m['reqId']});
    } on Object catch (e) {
      _transport.send(_err(m['reqId'], e));
    }
  }

  Map<String, Object?> _err(Object? reqId, Object e) => switch (e) {
        BiometricCancelled() => {'op': TaskOps.err, 'reqId': reqId, 'kind': 'cancel', 'message': 'annulé'},
        BiometricTimeout(:final message) => {'op': TaskOps.err, 'reqId': reqId, 'kind': 'timeout', 'message': message},
        BiometricFailed(:final message) => {'op': TaskOps.err, 'reqId': reqId, 'kind': 'fail', 'message': message},
        _ => {'op': TaskOps.err, 'reqId': reqId, 'kind': 'fail', 'message': 'erreur interne'},
      };

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Detaches from the service (which keeps running) and the foreground
  /// gate. The links are *not* stopped: they belong to the service.
  Future<void> shutdown() async {
    _stateTimer?.cancel();
    _stateTimer = null;
    _gate?.detach();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('application fermée'));
    }
    _pending.clear();
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(shutdown());
    super.dispose();
  }
}
