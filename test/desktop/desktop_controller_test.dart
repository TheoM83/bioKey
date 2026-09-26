import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/core/crypto/verify.dart';
import 'package:biokey/core/session/clock.dart';
import 'package:biokey/core/session/desktop_session.dart';
import 'package:biokey/core/storage/secure_kv.dart';
import 'package:biokey/core/storage/desktop_store.dart';
import 'package:biokey/desktop/apps/app_store.dart';
import 'package:biokey/desktop/apps/launcher.dart';
import 'package:biokey/desktop/desktop_controller.dart';
import 'package:biokey/desktop/notify.dart';
import 'package:biokey/desktop/server/ws_server.dart';

void main() {
  late DesktopController c;
  late FakeLauncher launcher;
  late FakeNotifier notifier;
  late DesktopSession session;
  late FakeWsServer fakeServer;

  setUp(() async {
    final kv = InMemorySecureKv();
    launcher = FakeLauncher();
    notifier = FakeNotifier();
    c = DesktopController(
      store: DesktopStore(kv), apps: AppStore(kv), launcher: launcher, verifier: const EcdsaVerifier(),
      clock: FakeClock(1000), notifier: notifier,
      serverFactory: (id, s, onEffect) { session = s; return fakeServer = FakeWsServer(onEffect); },
      mdns: null,
    );
    await c.init();
  });

  test('init generates identity once and persists it', () async {
    expect(c.pcId, hasLength(16));
  });

  test('startPairing exposes a QR with token', () async {
    await c.startPairing();
    expect(c.pairingQr!.token, session.pairingToken);
    expect(c.pairingQr!.pcId, c.pcId);
  });

  test('open with no phone → notification, nothing launched', () async {
    await c.addApp(r'C:\x.exe', label: 'X');
    await c.open(c.apps.single.id);
    expect(launcher.launched, isEmpty);
    expect(notifier.shown.single.$2, contains('Téléphone introuvable'));
  });

  test('approved auth launches; LaunchFailed becomes a notification', () async {
    await c.addApp(r'C:\x.exe', label: 'X');
    final app = c.apps.single;
    // simulate an approved outcome arriving from the server
    fakeServer.onEffect(AuthResolved('id1', 'X', AuthOutcome.approved));
    c.onAuthResolved('id1', app.id, AuthOutcome.approved); // see implementation note
    expect(launcher.launched.map((a) => a.id), [app.id]);
    launcher.failNext = true;
    c.onAuthResolved('id2', app.id, AuthOutcome.approved);
    await Future<void>.delayed(Duration.zero);
    expect(notifier.shown.last.$2, contains('Impossible d’ouvrir'));
  });

  test('handleCli open with unknown id notifies', () async {
    await c.handleCli(['open', 'nope']);
    expect(notifier.shown.single.$2, contains('inconnue'));
  });

  test('revokePhone resets phoneOnline after a PhoneOnline(true) effect', () async {
    fakeServer.onEffect(const PhoneOnline(true));
    expect(c.phoneOnline, isTrue);
    await c.revokePhone();
    expect(c.phoneOnline, isFalse);
  });

  test('handleCli([]) invokes onShowWindow', () async {
    var shown = false;
    final kv = InMemorySecureKv();
    final withCallback = DesktopController(
      store: DesktopStore(kv), apps: AppStore(kv), launcher: FakeLauncher(), verifier: const EcdsaVerifier(),
      clock: FakeClock(1000), notifier: FakeNotifier(),
      serverFactory: (id, s, onEffect) => FakeWsServer(onEffect),
      mdns: null,
      onShowWindow: () => shown = true,
    );
    await withCallback.init();
    await withCallback.handleCli(<String>[]);
    expect(shown, isTrue);
  });

  test('after dispose(), pushing a PhoneOnline(false) effect does not throw', () async {
    c.dispose();
    expect(() => fakeServer.onEffect(const PhoneOnline(false)), returnsNormally);
  });
}

class FakeWsServer implements WsServerApi {
  FakeWsServer(this.onEffect);
  final void Function(DesktopEffect) onEffect;
  final applied = <DesktopEffect>[];
  @override
  Future<void> start({String address = '0.0.0.0', required int port}) async {}
  @override
  int get port => 1;
  @override
  Future<void> stop() async {}
  @override
  void apply(List<DesktopEffect> fx) { applied.addAll(fx); fx.forEach(onEffect); }
}
