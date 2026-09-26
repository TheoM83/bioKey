import 'dart:io';
import 'package:url_launcher/url_launcher.dart';
import '../../core/session/clock.dart';
import 'protected_app.dart';

class LaunchFailed implements Exception {
  LaunchFailed(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract interface class AppLauncher {
  Future<void> launch(ProtectedApp app);
}

final class WindowsLauncher implements AppLauncher {
  @override
  Future<void> launch(ProtectedApp app) async {
    final t = app.target;
    if (t.contains('://')) {
      if (!await launchUrl(Uri.parse(t))) throw LaunchFailed('Impossible d’ouvrir $t');
      return;
    }
    if (!File(t).existsSync() && !Directory(t).existsSync()) throw LaunchFailed('Introuvable : $t');
    await Process.start('cmd', ['/c', 'start', '', t], runInShell: false, mode: ProcessStartMode.detached);
  }
}

final class FakeLauncher implements AppLauncher {
  final launched = <ProtectedApp>[];
  bool failNext = false;
  @override
  Future<void> launch(ProtectedApp app) async {
    if (failNext) {
      failNext = false;
      throw LaunchFailed('fake');
    }
    launched.add(app);
  }
}

enum UnlockState { locked, unlocked }

final class UnlockCache {
  UnlockCache(this._clock);
  final Clock _clock;
  final _until = <String, int>{};
  bool isUnlocked(ProtectedApp a) => a.unlockMinutes > 0 && (_until[a.id] ?? 0) > _clock.nowSec();
  void markUnlocked(ProtectedApp a) {
    if (a.unlockMinutes > 0) _until[a.id] = _clock.nowSec() + a.unlockMinutes * 60;
  }
}
