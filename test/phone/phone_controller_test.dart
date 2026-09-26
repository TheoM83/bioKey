import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/core/protocol/codec.dart';
import 'package:biokey/core/protocol/messages.dart';
import 'package:biokey/core/session/clock.dart';
import 'package:biokey/core/storage/phone_store.dart';
import 'package:biokey/core/storage/secure_kv.dart';
import 'package:biokey/core/session/phone_session.dart';
import 'package:biokey/phone/net/pc_link.dart';
import 'package:biokey/phone/phone_controller.dart';
import '../support/fake_auth_notifier.dart';
import '../support/fake_foreground_gate.dart';
import '../support/fake_signer.dart';

/// A controllable fake of [PcLinkApi]: `start`/`stop` just flip [started],
/// and tests fire effects directly via [FakePcLink.emit] instead of driving
/// a real socket — [pc_link_test.dart] already covers the real networking.
final class FakePcLink implements PcLinkApi {
  FakePcLink(this.pc, this._onEffect);
  @override
  PairedPc pc;
  final void Function(PhoneEffect) _onEffect;
  bool started = false;
  int startCalls = 0;
  int stopCalls = 0;
  @override
  bool online = false;

  void emit(PhoneEffect e) => _onEffect(e);

  @override
  Future<void> start() async {
    startCalls++;
    started = true;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    started = false;
  }
}

void main() {
  late PhoneStore store;
  late FakeSigner signer;
  final links = <String, FakePcLink>{};
  final sessions = <String, PhoneSession>{};

  PairedPc makePc(String pcId) => PairedPc(pcId: pcId, name: 'PC $pcId', host: '127.0.0.1', port: 1, fingerprint: 'fp', session: 'sess');

  PhoneController build({FakeForegroundGate? gate, FakeAuthNotifier? authNotifier}) {
    links.clear();
    sessions.clear();
    return PhoneController(
      store: store,
      signer: signer,
      clock: const SystemClock(),
      gate: gate ?? FakeForegroundGate(),
      authNotifier: authNotifier ?? FakeAuthNotifier(),
      linkFactory: (pc, session, onEffect) {
        final link = FakePcLink(pc, onEffect);
        links[pc.pcId] = link;
        sessions[pc.pcId] = session;
        return link;
      },
    );
  }

  setUp(() {
    store = PhoneStore(InMemorySecureKv());
    signer = FakeSigner();
  });

  test('init starts one link per stored PC', () async {
    await store.upsertPc(makePc('a'));
    await store.upsertPc(makePc('b'));

    final ctrl = build();
    await ctrl.init();

    expect(ctrl.pcs.map((p) => p.pcId).toSet(), {'a', 'b'});
    expect(links.keys.toSet(), {'a', 'b'});
    expect(links['a']!.started, isTrue);
    expect(links['b']!.started, isTrue);
  });

  test('starting a link for a PC that already has one stops the old one first', () async {
    await store.upsertPc(makePc('a'));
    final ctrl = build();
    await ctrl.init();
    final firstLink = links['a']!;
    expect(firstLink.started, isTrue);

    // init() again simulates re-establishing a link for an already-linked
    // PC (the same path pair() takes when re-pairing an existing PC).
    await ctrl.init();
    final secondLink = links['a']!;

    expect(firstLink.stopCalls, 1, reason: 'the orphaned old link must be stopped, not left running');
    expect(firstLink.started, isFalse);
    expect(identical(firstLink, secondLink), isFalse, reason: 'a fresh link replaces the old one');
    expect(secondLink.started, isTrue);
  });

  test('revoke of the last PC deletes the key', () async {
    await store.upsertPc(makePc('a'));
    final ctrl = build();
    await ctrl.init();

    await ctrl.revoke('a');

    expect(ctrl.pcs, isEmpty);
    expect(links['a']!.started, isFalse);
    expect(links['a']!.stopCalls, 1);
    expect(await store.pubKey(), isNull);
    expect(signer.deleteCalls, 1);
  });

  test('revoke keeps the key while another PC is still paired', () async {
    await store.upsertPc(makePc('a'));
    await store.upsertPc(makePc('b'));
    await store.savePubKey('cached-pub');
    final ctrl = build();
    await ctrl.init();

    await ctrl.revoke('a');

    expect(ctrl.pcs.map((p) => p.pcId), ['b']);
    expect(await store.pubKey(), 'cached-pub');
    expect(signer.deleteCalls, 0);
  });

  test('PhoneUnknownByPc marks needsRepair and stops the link', () async {
    await store.upsertPc(makePc('a'));
    final ctrl = build();
    await ctrl.init();

    links['a']!.emit(const PhoneUnknownByPc('a'));
    await Future<void>.delayed(Duration.zero);

    expect(ctrl.needsRepair, contains('a'));
    expect(links['a']!.started, isFalse, reason: 'a stale session will never succeed; retrying it is pointless');
  });

  test('PhonePairedWith for a revoked PC is ignored', () async {
    await store.upsertPc(makePc('a'));
    final ctrl = build();
    await ctrl.init();
    final staleLink = links['a']!;

    await ctrl.revoke('a');
    expect(ctrl.pcs, isEmpty);

    // A late-arriving effect from the now-stopped link (e.g. it resolved a
    // host right as it was being torn down) must not resurrect the PC.
    staleLink.emit(PhonePairedWith(makePc('a')));
    await Future<void>.delayed(Duration.zero);

    expect(ctrl.pcs, isEmpty);
    expect(await store.pcs(), isEmpty);
  });

  test('PhoneOnlineChanged drives isOnline', () async {
    await store.upsertPc(makePc('a'));
    final ctrl = build();
    await ctrl.init();

    expect(ctrl.isOnline('a'), isFalse);

    links['a']!.emit(const PhoneOnlineChanged('a', true));
    expect(ctrl.isOnline('a'), isTrue);

    links['a']!.emit(const PhoneOnlineChanged('a', false));
    expect(ctrl.isOnline('a'), isFalse);
  });

  test('notifies listeners on relevant effects', () async {
    await store.upsertPc(makePc('a'));
    final ctrl = build();
    await ctrl.init();

    var notified = 0;
    ctrl.addListener(() => notified++);

    links['a']!.emit(const PhoneOnlineChanged('a', true));
    expect(notified, 1);
  });

  test('an incoming auth while backgrounded shows a notification and cancels it on resume', () async {
    await store.upsertPc(makePc('a'));
    final gate = FakeForegroundGate();
    final authNotifier = FakeAuthNotifier();
    final ctrl = build(gate: gate, authNotifier: authNotifier);
    await ctrl.init();

    final pc = ctrl.pcs.single;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final frame = Codec.encode(AuthMsg(id: 'u1', pcId: 'a', action: 'open', label: 'Mon app', nonce: 'N', iat: now, exp: now + 20));
    await sessions['a']!.onFrame(pc, frame);
    // The notification is shown by an un-awaited continuation started
    // synchronously from onFrame's onAuthShown callback; let it settle.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(authNotifier.initCalls, greaterThanOrEqualTo(1));
    expect(authNotifier.shown, hasLength(1));
    expect(authNotifier.shown.single.label, 'Mon app');
    expect(authNotifier.shown.single.pcName, pc.name);
    expect(authNotifier.cancelled, isEmpty);

    gate.resume();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(authNotifier.cancelled, [authNotifier.shown.single.id]);
  });

  test('an incoming auth while foregrounded does not notify', () async {
    await store.upsertPc(makePc('a'));
    final gate = FakeForegroundGate()..resume();
    final authNotifier = FakeAuthNotifier();
    final ctrl = build(gate: gate, authNotifier: authNotifier);
    await ctrl.init();

    final pc = ctrl.pcs.single;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final frame = Codec.encode(AuthMsg(id: 'u1', pcId: 'a', action: 'open', label: 'Mon app', nonce: 'N', iat: now, exp: now + 20));
    await sessions['a']!.onFrame(pc, frame);
    await Future<void>.delayed(Duration.zero);

    expect(authNotifier.shown, isEmpty);
  });
}
