import 'dart:async';
import 'package:flutter/widgets.dart';

/// The operations [PhoneController] (and [BiometricSignatureSigner], via
/// its `waitForeground` callback) need from foreground tracking, extracted
/// so tests can inject a fake `isResumed` toggle instead of a real
/// `WidgetsBindingObserver` — which would otherwise need a fully
/// initialized widget binding.
abstract interface class ForegroundGateApi {
  bool get isResumed;
  Future<void> whenResumed({Duration timeout});
}

/// Tracks whether BioKey is in the foreground (`AppLifecycleState.resumed`)
/// via `WidgetsBindingObserver`, so callers can check it without polling
/// and wait for a resume instead of guessing.
///
/// Used two ways:
/// - [BiometricSignatureSigner] awaits [whenResumed] before invoking the
///   plugin, since Android cannot show a `BiometricPrompt` from a
///   backgrounded activity.
/// - [PhoneController] checks [isResumed] to decide whether to surface the
///   `biokey_auth` notification, and awaits [whenResumed] to know when to
///   cancel it.
class ForegroundGate with WidgetsBindingObserver implements ForegroundGateApi {
  bool _resumed = false;
  final _changes = StreamController<bool>.broadcast();

  @override
  bool get isResumed => _resumed;

  void attach() {
    WidgetsBinding.instance.addObserver(this);
    _resumed = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  }

  void detach() {
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (resumed == _resumed) return;
    _resumed = resumed;
    _changes.add(resumed);
  }

  /// Completes as soon as the app is resumed — immediately if it already
  /// is. Throws [TimeoutException] if it isn't resumed within [timeout].
  @override
  Future<void> whenResumed({Duration timeout = const Duration(seconds: 25)}) {
    if (_resumed) return Future<void>.value();
    return _changes.stream.firstWhere((resumed) => resumed).timeout(timeout).then((_) {});
  }

  void dispose() {
    unawaited(_changes.close());
  }
}
