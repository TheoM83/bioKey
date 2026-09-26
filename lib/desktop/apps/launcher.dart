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
    // ShellExecute via url_launcher: no cmd.exe in between, so characters
    // such as & ^ % in the path are never interpreted by a shell.
    if (!await launchUrl(Uri.file(t, windows: true))) throw LaunchFailed('Impossible d’ouvrir $t');
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
