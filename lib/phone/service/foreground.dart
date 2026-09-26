import 'dart:async';
import 'dart:io';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// No-op task handler: BioKey doesn't run periodic work in the foreground
/// task, it only needs the persistent Android notification (and the process
/// priority that comes with it) to keep the WebSocket links to paired PCs
/// alive while the app is backgrounded.
@pragma('vm:entry-point')
void biokeyForegroundStartCallback() {
  FlutterForegroundTask.setTaskHandler(_BiokeyTaskHandler());
}

final class _BiokeyTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

/// Requests the permissions the foreground service needs: notification
/// permission (Android 13+) to show its persistent notification, and an
/// exemption from battery optimizations so the OS doesn't kill the service
/// (and with it, the link to paired PCs) in the background.
Future<void> requestForegroundPermissions() async {
  final permission = await FlutterForegroundTask.checkNotificationPermission();
  if (permission != NotificationPermission.granted) {
    await FlutterForegroundTask.requestNotificationPermission();
  }
  if (Platform.isAndroid && !await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
    await FlutterForegroundTask.requestIgnoreBatteryOptimization();
  }
}

/// Initializes and starts the persistent foreground service that keeps
/// BioKey's paired-PC links alive while the app is backgrounded.
Future<ServiceRequestResult> startForegroundService() async {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'biokey_foreground',
      channelName: 'BioKey',
      channelDescription: 'BioKey veille sur vos PC',
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(showNotification: false, playSound: false),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      autoRunOnBoot: true,
      autoRunOnMyPackageReplaced: true,
      allowWakeLock: true,
    ),
  );
  if (await FlutterForegroundTask.isRunningService) {
    return FlutterForegroundTask.restartService();
  }
  return FlutterForegroundTask.startService(
    notificationTitle: 'BioKey',
    notificationText: 'BioKey veille sur vos PC',
    callback: biokeyForegroundStartCallback,
  );
}

/// The operations [PhoneController] needs from the `biokey_auth` notifier,
/// extracted so tests can inject a fake instead of touching the real
/// `flutter_local_notifications` platform channel.
abstract interface class AuthNotifierApi {
  Future<void> init();
  Future<void> showAuthPrompt({required int id, required String label, required String pcName});
  Future<void> cancel(int id);
}

/// The Android notification channel used to alert the user of an incoming
/// biometric authentication request (`PhoneAuthShown`) while BioKey is
/// backgrounded — high-priority/full-screen so it surfaces immediately,
/// since the biometric prompt itself is already showing by the time this
/// fires (the phone session invokes its `onAuthShown` callback *before*
/// calling into the biometric signer, not after).
final class AuthNotifier implements AuthNotifierApi {
  static const _channelId = 'biokey_auth';

  final _plugin = FlutterLocalNotificationsPlugin();

  /// The in-flight (or completed) initialization, memoised so concurrent
  /// callers share the same attempt instead of racing two
  /// `initialize`/`createNotificationChannel` calls. Cleared on failure so
  /// the *next* call retries from scratch rather than being stuck forever
  /// returning an already-failed future.
  Future<void>? _initFuture;

  /// Idempotent and safe to call concurrently: safe to call before every
  /// [showAuthPrompt] without re-registering the notification channel each
  /// time, and a caller that starts init() while another init() is still
  /// running gets that same in-flight attempt rather than starting a
  /// second one.
  @override
  Future<void> init() {
    final existing = _initFuture;
    if (existing != null) return existing;
    final future = _doInit();
    _initFuture = future;
    unawaited(future.catchError((Object _) {
      // Let the next init() call try again instead of every future call
      // replaying this same failure forever.
      _initFuture = null;
    }));
    return future;
  }

  Future<void> _doInit() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(settings: const InitializationSettings(android: android));
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _channelId,
            'Demandes d’authentification',
            description: 'Alerte quand un PC appairé demande une authentification biométrique',
            importance: Importance.max,
          ),
        );
  }

  @override
  Future<void> showAuthPrompt({required int id, required String label, required String pcName}) async {
    await init();
    await _plugin.show(
      id: id,
      title: 'BioKey',
      body: 'Ouvrir $label sur $pcName ?',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Demandes d’authentification',
          channelDescription: 'Alerte quand un PC appairé demande une authentification biométrique',
          importance: Importance.max,
          priority: Priority.high,
          fullScreenIntent: true,
          category: AndroidNotificationCategory.call,
        ),
      ),
    );
  }

  @override
  Future<void> cancel(int id) => _plugin.cancel(id: id);
}
