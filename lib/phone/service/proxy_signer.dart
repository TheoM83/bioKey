import 'dart:async';

import '../../core/session/biometric_signer.dart';
import 'task_transport.dart';

/// The operations [ProxySigner] needs to surface an auth request when the
/// UI isn't in front: the `biokey_auth` high-priority / full-screen
/// notification. Abstracted so tests don't touch the real plugin.
abstract interface class AuthNotifierApi {
  Future<void> init();
  Future<void> show({required int id, required String body});
  Future<void> cancel(int id);
}

/// [BiometricSigner] used inside the foreground-service isolate, where the
/// biometric plugin (which needs an Activity) is unavailable: every call
/// is forwarded to the UI isolate, which owns the real signer.
///
/// `sign` → `{op:'sign', reqId, payload, prompt}`, answered by
/// `{op:'sig', reqId, sig}` or `{op:'err', reqId, kind:'cancel'|'fail'|'timeout', message}`.
///
/// Before proxying a signature, the UI must be attached *and* in front: a
/// `ping` must be answered within [pingTimeout] and [isAppOnForeground]
/// must be true. Otherwise the app is launched ([launchApp]) and the
/// `biokey_auth` full-screen notification shown (the only reliable way to
/// come to the front from the background / lock screen), then the UI is
/// awaited for up to [uiWait]; if it never answers, the request fails with
/// [BiometricTimeout] ('application en arrière-plan').
final class ProxySigner implements BiometricSigner {
  ProxySigner({
    required void Function(Map<String, Object?>) send,
    required Future<bool> Function() isAppOnForeground,
    required void Function() launchApp,
    required AuthNotifierApi notifier,
    Future<String?> Function()? cachedPublicKey,
    this.pingTimeout = const Duration(seconds: 1),
    this.uiWait = const Duration(seconds: 25),
    this.replyTimeout = const Duration(seconds: 90),
  })  : _send = send,
        _isAppOnForeground = isAppOnForeground,
        _launchApp = launchApp,
        _notifier = notifier,
        _cachedPublicKey = cachedPublicKey;

  final void Function(Map<String, Object?>) _send;
  final Future<bool> Function() _isAppOnForeground;
  final void Function() _launchApp;
  final AuthNotifierApi _notifier;
  final Future<String?> Function()? _cachedPublicKey;
  final Duration pingTimeout;
  final Duration uiWait;

  /// Upper bound on a proxied call once the UI has it (a biometric prompt
  /// left open, or a UI isolate that died mid-call).
  final Duration replyTimeout;

  int _nextId = 0;
  final _pending = <String, Completer<Map<String, Object?>>>{};

  /// Routes a reply from the UI isolate. Returns `true` if it was one.
  bool handleMessage(Map<String, Object?> m) {
    if (!TaskOps.replies.contains(m['op'])) return false;
    final c = _pending.remove(m['reqId']);
    if (c != null && !c.isCompleted) c.complete(m);
    return true;
  }

  Future<Map<String, Object?>> _request(String op, Map<String, Object?> args, Duration timeout) async {
    final reqId = 'r${++_nextId}';
    final c = Completer<Map<String, Object?>>();
    _pending[reqId] = c;
    try {
      _send({'op': op, 'reqId': reqId, ...args});
      return await c.future.timeout(timeout);
    } finally {
      _pending.remove(reqId);
    }
  }

  /// Whether a live UI isolate answers a ping in time.
  Future<bool> uiAttached() async {
    try {
      await _request(TaskOps.ping, const {}, pingTimeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  Future<bool> _foreground() async {
    try {
      return await _isAppOnForeground();
    } on Object {
      return false;
    }
  }

  /// Makes sure a UI isolate is attached and asked to come to the front.
  /// Shows the auth notification (id [notifyId], text [notifyBody]) when
  /// it had to launch the app; the caller cancels it.
  Future<void> _ensureUi({required int notifyId, required String notifyBody}) async {
    final attached = await uiAttached();
    if (attached && await _foreground()) return;
    try {
      _launchApp();
    } on Object {
      // Background activity starts may be refused: the notification below
      // is then the user's way in.
    }
    try {
      await _notifier.show(id: notifyId, body: notifyBody);
    } on Object {
      // Best effort: keep waiting for the UI regardless.
    }
    if (attached) return; // Alive but behind: its own gate waits for resume.
    final deadline = DateTime.now().add(uiWait);
    while (DateTime.now().isBefore(deadline)) {
      if (await uiAttached()) return;
    }
    throw BiometricTimeout('application en arrière-plan');
  }

  @override
  Future<String> sign({required String payload, required String prompt}) async {
    final notifyId = prompt.hashCode & 0x7fffffff;
    try {
      await _ensureUi(notifyId: notifyId, notifyBody: prompt);
      final Map<String, Object?> reply;
      try {
        reply = await _request(TaskOps.sign, {'payload': payload, 'prompt': prompt}, replyTimeout);
      } on TimeoutException {
        throw BiometricTimeout('pas de réponse de l’application');
      }
      final sig = reply['sig'];
      if (reply['op'] == TaskOps.sig && sig is String) return sig;
      throw _errorOf(reply);
    } finally {
      unawaited(_notifier.cancel(notifyId).catchError((Object _) {}));
    }
  }

  @override
  Future<String> ensurePublicKey() async {
    if (await uiAttached()) return _askPublicKey();
    // No UI (e.g. right after boot): the key's public half is cached in
    // secure storage by the UI's signer, which is all `hello` needs.
    final cached = await _cachedPublicKey?.call();
    if (cached != null) return cached;
    await _ensureUi(notifyId: 0x42696f4b, notifyBody: 'Ouvrez BioKey pour terminer la configuration');
    try {
      return await _askPublicKey();
    } finally {
      unawaited(_notifier.cancel(0x42696f4b).catchError((Object _) {}));
    }
  }

  Future<String> _askPublicKey() async {
    final Map<String, Object?> reply;
    try {
      reply = await _request(TaskOps.ensurePublicKey, const {}, replyTimeout);
    } on TimeoutException {
      throw BiometricTimeout('pas de réponse de l’application');
    }
    final pub = reply['pub'];
    if (reply['op'] == TaskOps.pub && pub is String) return pub;
    throw _errorOf(reply);
  }

  @override
  Future<void> deleteKey() async {
    final Map<String, Object?> reply;
    try {
      reply = await _request(TaskOps.deleteKey, const {}, replyTimeout);
    } on TimeoutException {
      throw BiometricFailed('pas de réponse de l’application');
    }
    if (reply['op'] != TaskOps.ok) throw _errorOf(reply);
  }

  Exception _errorOf(Map<String, Object?> reply) {
    final message = reply['message'] is String ? reply['message']! as String : 'erreur inconnue';
    return switch (reply['kind']) {
      'cancel' => BiometricCancelled(),
      'timeout' => BiometricTimeout(message),
      _ => BiometricFailed(message),
    };
  }

  /// Fails every in-flight request (the service is going away).
  void dispose() {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(TimeoutException('arrêt du service'));
    }
    _pending.clear();
  }
}
