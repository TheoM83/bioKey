import 'dart:async';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../core/session/clock.dart';
import '../../core/storage/phone_store.dart';
import '../../platform/flutter_secure_kv.dart';
import '../net/mdns_finder.dart';
import '../net/pc_link.dart';
import 'link_coordinator.dart';
import 'proxy_signer.dart';
import 'task_transport.dart';

/// Entry point of the foreground-service isolate (also used by the plugin's
/// boot receiver: `autoRunOnBoot`), which owns every link to paired PCs.
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(BiokeyTaskHandler());
}

/// Runs the phone's network side ([LinkCoordinator]) in the service
/// isolate. Its signer is a [ProxySigner] to the UI isolate, which owns the
/// biometric key; with no UI attached it launches the app / shows the
/// full-screen auth notification first.
final class BiokeyTaskHandler extends TaskHandler {
  final _transport = CallbackTaskTransport((m) => FlutterForegroundTask.sendDataToMain(m));
  ProxySigner? _signer;
  TaskBackend? _backend;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // flutter_secure_storage only needs the application context, which the
    // service's engine has: the service reads/writes the PC list itself.
    final store = PhoneStore(FlutterSecureKv());
    final signer = ProxySigner(
      send: _transport.send,
      isAppOnForeground: () => FlutterForegroundTask.isAppOnForeground,
      launchApp: FlutterForegroundTask.launchApp,
      notifier: AuthNotifier(),
      cachedPublicKey: store.pubKey,
    );
    final mdns = MdnsFinder();
    final coordinator = LinkCoordinator(
      store: store,
      signer: signer,
      clock: const SystemClock(),
      send: _transport.send,
      linkFactory: (pc, session, onEffect) =>
          PcLink(pc: pc, session: session, onEffect: onEffect, resolveHost: mdns.resolveHost),
      pairer: (qr, session, onEffect) =>
          PcLink.pair(qr: qr, session: session, onEffect: onEffect, resolveHost: mdns.resolveHost),
    );
    final backend = TaskBackend(transport: _transport, coordinator: coordinator, replies: signer.handleMessage);
    _signer = signer;
    _backend = backend;
    await backend.start();
  }

  @override
  void onReceiveData(Object data) => _transport.deliver(data);

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp();

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _signer?.dispose();
    await _backend?.stop();
    await _transport.close();
  }
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

void _initForegroundTask() {
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
      allowWifiLock: true,
    ),
  );
}

/// Starts the persistent `connectedDevice` foreground service that owns the
/// links to paired PCs — or, if it already runs (e.g. started at boot),
/// leaves it alone: restarting it would drop every live link.
Future<ServiceRequestResult> startForegroundService() async {
  _initForegroundTask();
  if (await FlutterForegroundTask.isRunningService) {
    return const ServiceRequestSuccess();
  }
  return FlutterForegroundTask.startService(
    serviceTypes: const [ForegroundServiceTypes.connectedDevice],
    notificationTitle: 'BioKey',
    notificationText: 'BioKey veille sur vos PC',
    callback: startCallback,
  );
}

/// The UI isolate's end of the channel to the service.
CallbackTaskTransport uiTaskTransport() {
  FlutterForegroundTask.initCommunicationPort();
  final t = CallbackTaskTransport((m) => FlutterForegroundTask.sendDataToTask(m));
  FlutterForegroundTask.addTaskDataCallback(t.deliver);
  return t;
}

/// The Android notification channel used to alert the user of an incoming
/// biometric authentication request while BioKey isn't in front —
/// high-priority / full-screen so it surfaces immediately, including over
/// the lock screen (the activity is `showWhenLocked`/`turnScreenOn`).
final class AuthNotifier implements AuthNotifierApi {
  static const _channelId = 'biokey_auth';
  static const _channelName = 'Demandes d’authentification';
  static const _channelDescription = 'Alerte quand un PC appairé demande une authentification biométrique';

  final _plugin = FlutterLocalNotificationsPlugin();

  /// Memoised in-flight/complete initialisation; cleared on failure so the
  /// next call retries.
  Future<void>? _initFuture;

  @override
  Future<void> init() {
    final existing = _initFuture;
    if (existing != null) return existing;
    final future = _doInit();
    _initFuture = future;
    unawaited(future.catchError((Object _) {
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
          const AndroidNotificationChannel(_channelId, _channelName, description: _channelDescription, importance: Importance.max),
        );
  }

  @override
  Future<void> show({required int id, required String body}) async {
    await init();
    await _plugin.show(
      id: id,
      title: 'BioKey',
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
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
