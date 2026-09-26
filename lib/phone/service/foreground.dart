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

/// The Android notification channel used to alert the user of an incoming
/// biometric authentication request (`PhoneAuthShown`) while BioKey is
/// backgrounded — high-priority/full-screen so it surfaces immediately,
/// since the biometric prompt itself is already showing by the time this
/// fires (`sign()` runs as soon as the `auth` frame arrives).
final class AuthNotifier {
  static const _channelId = 'biokey_auth';

  final _plugin = FlutterLocalNotificationsPlugin();

  Future<void> init() async {
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

  Future<void> showAuthPrompt({required String label, required String pcName}) async {
    await _plugin.show(
      id: 0,
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
}
