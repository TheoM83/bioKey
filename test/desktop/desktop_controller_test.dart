import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/core/crypto/verify.dart';
import 'package:biokey/core/discovery/udp_discovery.dart';
import 'package:biokey/core/protocol/codec.dart';
import 'package:biokey/core/protocol/messages.dart';
import 'package:biokey/core/session/clock.dart';
import 'package:biokey/core/session/desktop_session.dart';
import 'package:biokey/core/storage/secure_kv.dart';
import 'package:biokey/core/storage/desktop_store.dart';
import 'package:biokey/desktop/apps/app_store.dart';
import 'package:biokey/desktop/apps/launcher.dart';
import 'package:biokey/desktop/desktop_controller.dart';
import 'package:biokey/desktop/notify.dart';
import 'package:biokey/desktop/server/discovery_responder.dart';
import 'package:biokey/desktop/server/tls_server.dart';
import '../support/test_keys.dart';

void main() {
  late DesktopController c;
  late FakeLauncher launcher;
  late FakeNotifier notifier;
  late DesktopSession session;
  late FakeLinkServer fakeServer;
  late FakeClock clock;
  final keys = TestKeys();

  DesktopController build(SecureKv kv, {Duration phoneWait = const Duration(seconds: 5), void Function()? onShowWindow, DiscoveryApi? discovery}) => DesktopController(
        store: DesktopStore(kv), apps: AppStore(kv), launcher: launcher, verifier: const EcdsaVerifier(),
        clock: clock, notifier: notifier,
        serverFactory: (id, s, onEffect) { session = s; return fakeServer = FakeLinkServer(onEffect); },
        discovery: discovery,
        phoneWait: phoneWait,
        onShowWindow: onShowWindow,
        // Fixed instead of the real primaryLanIPv4(): startPairing() must not
        // depend on the test machine actually having a LAN interface.
        lanAddress: () async => '192.168.1.42',
      );

  setUp(() async {
    clock = FakeClock(1000);
    launcher = FakeLauncher();
    notifier = FakeNotifier();
    c = build(InMemorySecureKv());
    await c.init();
  });

  /// Pairs [keys] as the phone on connection [conn] through the real
  /// [DesktopSession], the way a real phone would over the socket.
  void pairPhone(String conn) {
    session.startPairing();
    fakeServer.apply(session.onFrame(conn, Codec.encode(PairMsg(token: session.pairingToken!, name: 'Nothing', pub: keys.pubSpkiB64))));
    final ch = Codec.decode(fakeServer.applied.whereType<SendFrame>().last.frame) as PairChallengeMsg;
    fakeServer.apply(session.onFrame(conn, Codec.encode(PairProofMsg(sig: keys.sign('$pairProofDomain${ch.nonce}')))));
  }

  /// Answers the last auth request sent to the phone with a valid signature.
  void approveLastAuth(String conn) {
    final frame = fakeServer.applied.whereType<SendFrame>().last.frame;
    final auth = Codec.decode(frame) as AuthMsg;
    fakeServer.apply(session.onFrame(conn, Codec.encode(AuthOkMsg(id: auth.id, sig: keys.sign(frame)))));
  }

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
    c.onAuthResolved('id1', app.id, AuthOutcome.approved);
    await Future<void>.delayed(Duration.zero);
    expect(launcher.launched.map((a) => a.id), [app.id]);
    launcher.failNext = true;
    c.onAuthResolved('id2', app.id, AuthOutcome.approved);
    await Future<void>.delayed(Duration.zero);
    expect(notifier.shown.last.$2, contains('Impossible d’ouvrir'));
  });

  test('open() → auth frame → signed auth_ok through a real DesktopSession → launched', () async {
    pairPhone('c1');
    expect(c.phone, isNotNull);
    expect(c.phoneOnline, isTrue);
    await c.addApp(r'C:\x.exe', label: 'X');

    await c.open(c.apps.single.id);
    final auth = Codec.decode(fakeServer.applied.whereType<SendFrame>().last.frame);
    expect(auth, isA<AuthMsg>());
    expect((auth as AuthMsg).label, 'X');
    expect(launcher.launched, isEmpty);

    approveLastAuth('c1');
    await Future<void>.delayed(Duration.zero);
    expect(launcher.launched.map((a) => a.label), ['X']);
  });

  test('a failed launch does not open the unlock window', () async {
    pairPhone('c1');
    await c.addApp(r'C:\x.exe', label: 'X');
    final id = c.apps.single.id;
    await c.setUnlockMinutes(id, 5);

    launcher.failNext = true;
    await c.open(id);
    approveLastAuth('c1');
    await Future<void>.delayed(Duration.zero);
    expect(launcher.launched, isEmpty);

    final sentBefore = fakeServer.applied.whereType<SendFrame>().length;
    await c.open(id);
    expect(fakeServer.applied.whereType<SendFrame>().length, sentBefore + 1, reason: 'still locked: a fresh auth is requested');
    expect(launcher.launched, isEmpty);

    approveLastAuth('c1');
    await Future<void>.delayed(Duration.zero);
    expect(launcher.launched, hasLength(1));
    await c.open(id);
    expect(launcher.launched, hasLength(2), reason: 'a successful launch unlocks for 5 min');
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

  test('revokePhone closes the phone connection and times out pending auths', () async {
    pairPhone('c1');
    await c.addApp(r'C:\x.exe', label: 'X');
    await c.open(c.apps.single.id);

    await c.revokePhone();

    expect(fakeServer.applied.whereType<CloseConn>().map((e) => e.connId), contains('c1'));
    expect(fakeServer.applied.whereType<AuthResolved>().single.outcome, AuthOutcome.timeout);
    expect(c.phone, isNull);
    expect(session.phone, isNull);
    expect(session.phoneOnline, isFalse);
  });

  test('PairingExpired clears the pairing QR', () async {
    await c.startPairing();
    expect(c.pairingQr, isNotNull);
    clock.now += 121;
    fakeServer.apply(session.tick());
    expect(c.pairingQr, isNull);
  });

  test('PairingInvalid notifies and marks the phone as needing re-pair', () async {
    pairPhone('c1');
    session.onDisconnect('c1');
    var notified = 0;
    c.addListener(() => notified++);
    fakeServer.apply(session.onFrame('c2', Codec.encode(HelloMsg(pcId: c.pcId, pub: TestKeys().pubSpkiB64, session: c.phone!.session))));
    expect(c.phoneNeedsRepair, isTrue);
    expect(notifier.shown.last.$2, 'Appairage invalide — scannez à nouveau le QR');
    expect(notified, greaterThan(0));

    await c.revokePhone();
    expect(c.phoneNeedsRepair, isFalse);
  });

  test('a later PhoneOnline(true) also clears phoneNeedsRepair (a fresh hello proves the pairing is fine)', () async {
    fakeServer.onEffect(const PairingInvalid());
    expect(c.phoneNeedsRepair, isTrue);

    fakeServer.onEffect(const PhoneOnline(true));
    expect(c.phoneNeedsRepair, isFalse);
  });

  test('CLI commands arriving before init() are queued and replayed after it', () async {
    var shown = 0;
    final early = build(InMemorySecureKv(), onShowWindow: () => shown++);
    await early.handleCli(<String>[]);
    await early.handleCli(['open', 'nope']);
    expect(shown, 0);
    expect(notifier.shown, isEmpty);

    await early.init();
    expect(shown, 1);
    expect(notifier.shown.single.$2, contains('inconnue'));
  });

  test('open() with a paired but offline phone waits for it to come online', () async {
    pairPhone('c1');
    fakeServer.apply(session.onDisconnect('c1'));
    expect(c.phoneOnline, isFalse);
    await c.addApp(r'C:\x.exe', label: 'X');

    final opening = c.open(c.apps.single.id);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    fakeServer.apply(session.onFrame('c2', Codec.encode(HelloMsg(pcId: c.pcId, pub: keys.pubSpkiB64, session: c.phone!.session))));
    await opening;

    expect(Codec.decode(fakeServer.applied.whereType<SendFrame>().last.frame), isA<AuthMsg>());
    expect(notifier.shown.where((n) => n.$2.contains('introuvable')), isEmpty);
  });

  test('open() gives up with noPhone once the wait expires', () async {
    final kv = InMemorySecureKv();
    final short = build(kv, phoneWait: const Duration(milliseconds: 50));
    await short.init();
    pairPhone('c1');
    fakeServer.apply(session.onDisconnect('c1'));
    await short.addApp(r'C:\x.exe', label: 'X');

    await short.open(short.apps.single.id);
    expect(notifier.shown.last.$2, contains('Téléphone introuvable'));
  });

  test('handleCli([]) invokes onShowWindow', () async {
    var shown = false;
    final withCallback = build(InMemorySecureKv(), onShowWindow: () => shown = true);
    await withCallback.init();
    await withCallback.handleCli(<String>[]);
    expect(shown, isTrue);
  });

  test('after dispose(), pushing a PhoneOnline(false) effect does not throw', () async {
    c.dispose();
    expect(() => fakeServer.onEffect(const PhoneOnline(false)), returnsNormally);
  });

  test('a discovery bind failure notifies but does not abort init(); the rest of the desktop still starts', () async {
    final broken = FakeDiscovery(startError: Exception('address in use'));
    final withDiscovery = build(InMemorySecureKv(), discovery: broken);
    await expectLater(withDiscovery.init(), completes);
    expect(broken.startCalled, isTrue);
    expect(notifier.shown.single.$2, contains('Découverte réseau indisponible'));
    // init() finished past the discovery failure: the rest of startup ran.
    expect(withDiscovery.pcId, hasLength(16));
    await withDiscovery.addApp(r'C:\x.exe', label: 'X');
    expect(withDiscovery.apps, hasLength(1));
  });
}

class FakeDiscovery implements DiscoveryApi {
  FakeDiscovery({this.startError});
  final Object? startError;
  bool startCalled = false;
  @override
  Future<void> start({required String pcId, required String name, required int tcpPort, InternetAddress? bind, int port = discoveryPort}) async {
    startCalled = true;
    final err = startError;
    if (err != null) throw err;
  }

  @override
  Future<void> stop() async {}
}

class FakeLinkServer implements LinkServerApi {
  FakeLinkServer(this.onEffect);
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
