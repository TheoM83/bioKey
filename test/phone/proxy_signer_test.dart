import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/core/crypto/verify.dart';
import 'package:biokey/core/session/biometric_signer.dart';
import 'package:biokey/core/storage/phone_store.dart';
import 'package:biokey/core/storage/secure_kv.dart';
import 'package:biokey/phone/phone_controller.dart';
import 'package:biokey/phone/service/proxy_signer.dart';
import 'package:biokey/phone/service/task_transport.dart';
import '../support/fake_auth_notifier.dart';
import '../support/fake_foreground_gate.dart';
import '../support/fake_signer.dart';
import '../support/in_memory_task_transport.dart';

void main() {
  late InMemoryTaskLink link;
  late FakeSigner signer;
  late FakeAuthNotifier notifier;
  late bool foreground;
  late int launches;
  late ProxySigner proxy;
  PhoneController? ui;

  ProxySigner buildProxy({
    Duration pingTimeout = const Duration(milliseconds: 100),
    Duration uiWait = const Duration(seconds: 2),
    Future<String?> Function()? cachedPublicKey,
  }) {
    final p = ProxySigner(
      send: link.task.send,
      isAppOnForeground: () async => foreground,
      launchApp: () => launches++,
      notifier: notifier,
      cachedPublicKey: cachedPublicKey,
      pingTimeout: pingTimeout,
      uiWait: uiWait,
      replyTimeout: const Duration(seconds: 2),
    );
    link.task.messages.listen((m) => p.handleMessage(m));
    return p;
  }

  Future<PhoneController> attachUi() async {
    final c = PhoneController(
      transport: link.ui,
      signer: signer,
      store: PhoneStore(InMemorySecureKv()),
      gate: FakeForegroundGate()..resume(),
      stateRetry: const Duration(hours: 1),
    );
    await c.init();
    ui = c;
    return c;
  }

  setUp(() {
    link = InMemoryTaskLink();
    signer = FakeSigner();
    notifier = FakeAuthNotifier();
    foreground = true;
    launches = 0;
    proxy = buildProxy();
  });

  tearDown(() async {
    await ui?.shutdown();
    ui = null;
  });

  test('sign round-trips {op:sign} → {op:sig} with the same reqId, and the signature verifies', () async {
    await attachUi();
    final sig = await proxy.sign(payload: 'FRAME', prompt: 'Ouvrir X sur PC ?');

    expect(const EcdsaVerifier().verify(pubSpkiB64: signer.keys.pubSpkiB64, payload: 'FRAME', sigB64: sig), isTrue);
    expect(signer.prompts, ['Ouvrir X sur PC ?']);
    final req = link.task.sent.singleWhere((m) => m['op'] == TaskOps.sign);
    expect(req['payload'], 'FRAME');
    expect(req['prompt'], 'Ouvrir X sur PC ?');
    final reply = link.ui.sent.singleWhere((m) => m['op'] == TaskOps.sig);
    expect(reply['reqId'], req['reqId']);
    expect(launches, 0, reason: 'UI attached and in front: nothing to launch');
    expect(notifier.shown, isEmpty);
  });

  test('UI-side errors come back as the matching exceptions', () async {
    await attachUi();
    signer.cancelNext = true;
    await expectLater(proxy.sign(payload: 'p', prompt: 'x'), throwsA(isA<BiometricCancelled>()));
    signer.timeoutNext = true;
    await expectLater(proxy.sign(payload: 'p', prompt: 'x'), throwsA(isA<BiometricTimeout>()));
    signer.failNext = true;
    await expectLater(
      proxy.sign(payload: 'p', prompt: 'x'),
      throwsA(isA<BiometricFailed>().having((e) => e.message, 'message', 'lockout')),
    );
    signer.throwNext = true;
    await expectLater(proxy.sign(payload: 'p', prompt: 'x'), throwsA(isA<BiometricFailed>()));
    final kinds = link.ui.sent.where((m) => m['op'] == TaskOps.err).map((m) => m['kind']).toList();
    expect(kinds, ['cancel', 'timeout', 'fail', 'fail']);
  });

  test('ensurePublicKey and deleteKey are proxied to the UI signer', () async {
    await attachUi();
    expect(await proxy.ensurePublicKey(), signer.keys.pubSpkiB64);
    await proxy.deleteKey();
    expect(signer.deleteCalls, 1);
  });

  test('ensurePublicKey with no UI uses the cached key without launching the app', () async {
    proxy = buildProxy(cachedPublicKey: () async => 'CACHED');
    expect(await proxy.ensurePublicKey(), 'CACHED');
    expect(launches, 0);
  });

  test('no UI attached: launches the app, shows the auth notification, waits for the UI, then signs', () async {
    final signing = proxy.sign(payload: 'FRAME', prompt: 'Ouvrir X sur PC ?');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(launches, 1);
    expect(notifier.shown.single.body, 'Ouvrir X sur PC ?');

    await attachUi(); // the launched Activity comes up
    final sig = await signing;
    expect(const EcdsaVerifier().verify(pubSpkiB64: signer.keys.pubSpkiB64, payload: 'FRAME', sigB64: sig), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(notifier.cancelled, [notifier.shown.single.id]);
  });

  test('UI attached but in the background: launch + notification, then proxied', () async {
    await attachUi();
    foreground = false;
    await proxy.sign(payload: 'p', prompt: 'x');
    expect(launches, 1);
    expect(notifier.shown, hasLength(1));
  });

  test('no UI ever: BiometricTimeout (application en arrière-plan) after the wait', () async {
    proxy = buildProxy(uiWait: const Duration(milliseconds: 400));
    await expectLater(
      proxy.sign(payload: 'p', prompt: 'x'),
      throwsA(isA<BiometricTimeout>().having((e) => e.message, 'message', 'application en arrière-plan')),
    );
    expect(signer.prompts, isEmpty);
  });

  test('replies for unknown request ids are consumed and ignored', () {
    expect(proxy.handleMessage({'op': TaskOps.sig, 'reqId': 'nope', 'sig': 'x'}), isTrue);
    expect(proxy.handleMessage({'op': TaskOps.state}), isFalse);
  });
}
