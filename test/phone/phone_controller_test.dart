import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/core/session/clock.dart';
import 'package:biokey/core/storage/phone_store.dart';
import 'package:biokey/core/storage/secure_kv.dart';
import 'package:biokey/core/session/phone_session.dart';
import 'package:biokey/phone/net/pc_link.dart';
import 'package:biokey/phone/phone_controller.dart';
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
  @override
  bool online = false;

  void emit(PhoneEffect e) => _onEffect(e);

  @override
  Future<void> start() async => started = true;

  @override
  Future<void> stop() async => started = false;
}

void main() {
  late PhoneStore store;
  late FakeSigner signer;
  final links = <String, FakePcLink>{};

  PairedPc makePc(String pcId) => PairedPc(pcId: pcId, name: 'PC $pcId', host: '127.0.0.1', port: 1, fingerprint: 'fp', session: 'sess');

  PhoneController build() {
    links.clear();
    return PhoneController(
      store: store,
      signer: signer,
      clock: const SystemClock(),
      linkFactory: (pc, session, onEffect) {
        final link = FakePcLink(pc, onEffect);
        links[pc.pcId] = link;
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

  test('revoke of the last PC deletes the key', () async {
    await store.upsertPc(makePc('a'));
    final ctrl = build();
    await ctrl.init();

    await ctrl.revoke('a');

    expect(ctrl.pcs, isEmpty);
    expect(links['a']!.started, isFalse);
    expect(await store.pubKey(), isNull);
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
  });

  test('PhoneUnknownByPc marks needsRepair', () async {
    await store.upsertPc(makePc('a'));
    final ctrl = build();
    await ctrl.init();

    links['a']!.emit(const PhoneUnknownByPc('a'));

    expect(ctrl.needsRepair, contains('a'));
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
}
