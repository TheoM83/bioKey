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

/// Alias kept so a service callback handle stored before this entry point
/// was renamed to [startCallback] (e.g. by the OS across an in-place
/// upgrade, before [startForegroundService] gets a chance to rebuild it —
/// see there) still resolves to a real handler instead of running headless.
@pragma('vm:entry-point')
void biokeyForegroundStartCallback() => startCallback();

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

/// The subset of [FlutterForegroundTask]'s static service-lifecycle calls
/// that [startForegroundService] needs, behind an interface so it (and its
/// handler-recovery logic) can be unit-tested without the real plugin.
abstract interface class ForegroundServiceApi {
  Future<bool> get isRunningService;

  Future<ServiceRequestResult> startService({
    required List<ForegroundServiceTypes> serviceTypes,
    required String notificationTitle,
    required String notificationText,
    required void Function() callback,
  });

  /// Rebuilds the running task with [callback] when its callback handle
  /// differs from the one it's currently running with; a no-op otherwise.
  Future<ServiceRequestResult> updateService({required void Function() callback});

  Future<ServiceRequestResult> restartService();
}

final class _PluginForegroundService implements ForegroundServiceApi {
  const _PluginForegroundService();

  @override
  Future<bool> get isRunningService => FlutterForegroundTask.isRunningService;

  @override
  Future<ServiceRequestResult> startService({
    required List<ForegroundServiceTypes> serviceTypes,
    required String notificationTitle,
    required String notificationText,
    required void Function() callback,
  }) =>
      FlutterForegroundTask.startService(
        serviceTypes: serviceTypes,
        notificationTitle: notificationTitle,
        notificationText: notificationText,
        callback: callback,
      );

  @override
  Future<ServiceRequestResult> updateService({required void Function() callback}) =>
      FlutterForegroundTask.updateService(callback: callback);

  @override
  Future<ServiceRequestResult> restartService() => FlutterForegroundTask.restartService();
}

/// Starts the persistent `connectedDevice` foreground service that owns the
/// links to paired PCs — or, if it already runs (e.g. started at boot, or
/// resumed by the OS right after an in-place upgrade via
/// `autoRunOnMyPackageReplaced`), makes sure it is running with the
/// *current* [startCallback] handle: a service resumed after an upgrade
/// restarts with whatever handle was stored before it, which can resolve to
/// nothing once the entry point has moved — leaving the service running
/// with no [BiokeyTaskHandler] and no link to any paired PC, and nothing
/// else would ever restart it.
///
/// After starting/updating, a `getState` probe is sent over [transport]
/// (when given — the real caller always has the UI's task transport) and,
/// if no `state` reply arrives within [handlerCheckTimeout], the service is
/// force-restarted once: proof the handler is actually alive, not just the
/// service process.
Future<ServiceRequestResult> startForegroundService({
  TaskTransport? transport,
  ForegroundServiceApi api = const _PluginForegroundService(),
  Duration handlerCheckTimeout = const Duration(seconds: 5),
}) async {
  _initForegroundTask();
  final result = await api.isRunningService
      ? await api.updateService(callback: startCallback)
      : await api.startService(
          serviceTypes: const [ForegroundServiceTypes.connectedDevice],
          notificationTitle: 'BioKey',
          notificationText: 'BioKey veille sur vos PC',
          callback: startCallback,
        );
  if (result is ServiceRequestSuccess) {
    await _ensureHandlerRunning(api: api, transport: transport, timeout: handlerCheckTimeout);
  }
  return result;
}

/// Sends `{op: 'getState'}` and waits for a `state` reply; if none arrives
/// within [timeout], the running service process has no working task
/// handler (a callback handle that resolved to nothing), so it's
/// force-restarted once.
Future<void> _ensureHandlerRunning({
  required ForegroundServiceApi api,
  required TaskTransport? transport,
  required Duration timeout,
}) async {
  if (transport == null) return; // caller opted out of the liveness check.
  if (await _stateReplyArrives(transport, timeout)) return;
  try {
    await api.restartService();
  } on Object {
    // Best-effort: the UI's own getState retry loop (PhoneController) will
    // keep probing regardless, so a failed restart here just delays
    // recovery rather than losing it.
  }
}

Future<bool> _stateReplyArrives(TaskTransport transport, Duration timeout) async {
  final completer = Completer<bool>();
  final sub = transport.messages.listen((m) {
    if (m['op'] == TaskOps.state && !completer.isCompleted) completer.complete(true);
  });
  try {
    transport.send({'op': TaskOps.getState});
    return await completer.future.timeout(timeout, onTimeout: () => false);
  } finally {
    await sub.cancel();
  }
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
