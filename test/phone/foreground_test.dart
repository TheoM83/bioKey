import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/phone/service/foreground.dart';
import 'package:biokey/phone/service/task_transport.dart';

/// Fakes the plugin calls [startForegroundService] needs, so a stuck /
/// handlerless service can be simulated without touching the real
/// `flutter_foreground_task` plugin.
final class FakeForegroundServiceApi implements ForegroundServiceApi {
  bool running = false;
  ServiceRequestResult startResult = const ServiceRequestSuccess();
  ServiceRequestResult updateResult = const ServiceRequestSuccess();
  ServiceRequestResult restartResult = const ServiceRequestSuccess();

  int startCalls = 0;
  int updateCalls = 0;
  int restartCalls = 0;
  void Function()? lastCallback;

  @override
  Future<bool> get isRunningService async => running;

  @override
  Future<ServiceRequestResult> startService({
    required List<ForegroundServiceTypes> serviceTypes,
    required String notificationTitle,
    required String notificationText,
    required void Function() callback,
  }) async {
    startCalls++;
    lastCallback = callback;
    running = true;
    return startResult;
  }

  @override
  Future<ServiceRequestResult> updateService({required void Function() callback}) async {
    updateCalls++;
    lastCallback = callback;
    return updateResult;
  }

  @override
  Future<ServiceRequestResult> restartService() async {
    restartCalls++;
    return restartResult;
  }
}

/// A [TaskTransport] whose [send] can be made to answer a `getState` with a
/// `state` reply (or stay silent, simulating a running service with no
/// working task handler).
final class FakeUiTransport implements TaskTransport {
  bool respondToGetState = false;
  final sent = <Map<String, Object?>>[];
  final _c = StreamController<Map<String, Object?>>.broadcast();

  @override
  void send(Map<String, Object?> message) {
    sent.add(message);
    if (respondToGetState && message['op'] == TaskOps.getState) {
      scheduleMicrotask(() => _c.add({'op': TaskOps.state, 'pcs': <Object?>[], 'online': <Object?>[], 'needsRepair': <Object?>[]}));
    }
  }

  @override
  Stream<Map<String, Object?>> get messages => _c.stream;
}

void main() {
  late FakeForegroundServiceApi api;
  late FakeUiTransport transport;

  setUp(() {
    api = FakeForegroundServiceApi();
    transport = FakeUiTransport();
  });

  test('service not running: starts it with startCallback', () async {
    transport.respondToGetState = true;
    final result = await startForegroundService(
      transport: transport,
      api: api,
      handlerCheckTimeout: const Duration(milliseconds: 50),
    );
    expect(result, isA<ServiceRequestSuccess>());
    expect(api.startCalls, 1);
    expect(api.updateCalls, 0);
    expect(api.lastCallback, startCallback);
    expect(api.restartCalls, 0, reason: 'the fresh handler answered the probe');
  });

  test('already-running service (e.g. resumed after an upgrade) is rebuilt with the current callback', () async {
    api.running = true;
    transport.respondToGetState = true;
    final result = await startForegroundService(
      transport: transport,
      api: api,
      handlerCheckTimeout: const Duration(milliseconds: 50),
    );
    expect(result, isA<ServiceRequestSuccess>());
    expect(api.updateCalls, 1);
    expect(api.startCalls, 0);
    expect(api.lastCallback, startCallback);
  });

  test('a running service that never answers getState (handlerless after an upgrade) is restarted once', () async {
    api.running = true;
    transport.respondToGetState = false; // simulates the stale-handle bug: nobody answers.
    final result = await startForegroundService(
      transport: transport,
      api: api,
      handlerCheckTimeout: const Duration(milliseconds: 20),
    );
    expect(result, isA<ServiceRequestSuccess>(), reason: 'updateService itself still reports success');
    expect(api.updateCalls, 1, reason: 'the handle is rebuilt first');
    expect(api.restartCalls, 1, reason: 'no state reply within the timeout forces a restart');
    expect(transport.sent.where((m) => m['op'] == TaskOps.getState), isNotEmpty);
  });

  test('no transport given: skips the liveness check entirely (never restarts)', () async {
    api.running = true;
    final result = await startForegroundService(api: api, handlerCheckTimeout: const Duration(milliseconds: 20));
    expect(result, isA<ServiceRequestSuccess>());
    expect(api.restartCalls, 0);
  });

  test('a failed start/update never triggers the liveness check or a restart', () async {
    api.updateResult = const ServiceRequestFailure(error: 'boom');
    api.running = true;
    transport.respondToGetState = false;
    final result = await startForegroundService(
      transport: transport,
      api: api,
      handlerCheckTimeout: const Duration(milliseconds: 20),
    );
    expect(result, isA<ServiceRequestFailure>());
    expect(api.restartCalls, 0);
    expect(transport.sent, isEmpty);
  });
}
