import 'dart:async';
import 'package:biokey/phone/service/foreground_gate.dart';

/// A [ForegroundGateApi] whose foreground state is toggled directly by the
/// test instead of tracking a real `WidgetsBindingObserver` — which would
/// otherwise require a fully initialized widget binding.
class FakeForegroundGate implements ForegroundGateApi {
  @override
  bool isResumed = false;

  final _changes = StreamController<bool>.broadcast();

  void resume() {
    isResumed = true;
    _changes.add(true);
  }

  void pause() {
    isResumed = false;
    _changes.add(false);
  }

  @override
  Future<void> whenResumed({Duration timeout = const Duration(seconds: 25)}) {
    if (isResumed) return Future<void>.value();
    return _changes.stream.firstWhere((r) => r).timeout(timeout).then((_) {});
  }
}
