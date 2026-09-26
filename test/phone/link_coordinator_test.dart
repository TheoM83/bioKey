import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/core/pairing/qr_payload.dart';
import 'package:biokey/core/session/clock.dart';
import 'package:biokey/core/session/phone_session.dart';
import 'package:biokey/core/storage/phone_store.dart';
import 'package:biokey/core/storage/secure_kv.dart';
import 'package:biokey/phone/net/pc_link.dart';
import 'package:biokey/phone/service/link_coordinator.dart';
import 'package:biokey/phone/service/task_transport.dart';
import '../support/fake_signer.dart';
import '../support/in_memory_task_transport.dart';

/// A controllable [PcLinkApi]: `start`/`stop` flip [started]; tests fire
/// effects with [emit] ([pc_link_test.dart] covers the real networking).
final class FakePcLink implements PcLinkApi {
  FakePcLink(this.pc, this._onEffect);
  @override
  PairedPc pc;
  final void Function(PhoneEffect) _onEffect;
  bool started = false;
  int stopCalls = 0;
  @override
  bool online = false;

  void emit(PhoneEffect e) => _onEffect(e);

  @override
  Future<void> start() async => started = true;

  @override
  Future<void> stop() async {
    stopCalls++;
    started = false;
  }
}

PairedPc makePc(String pcId, {String host = '127.0.0.1'}) =>
    PairedPc(pcId: pcId, name: 'PC $pcId', host: host, port: 1, fingerprint: 'fp', session: 'sess');

void main() {
  late PhoneStore store;
  late FakeSigner signer;
  late InMemoryTaskLink link;
  late List<FakePcLink> created;
  late Future<PairedPc> Function(QrPayload qr) pairer;
  late LinkCoordinator coord;
  late TaskBackend backend;
  final ui = <Map<String, Object?>>[];

  FakePcLink latest(String pcId) => created.lastWhere((l) => l.pc.pcId == pcId);
  Map<String, Object?> lastState() => ui.lastWhere((m) => m['op'] == TaskOps.state);
  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> startBackend() async {
    coord = LinkCoordinator(
      store: store,
      signer: signer,
      clock: const SystemClock(),
      send: link.task.send,
      linkFactory: (pc, session, onEffect) {
        final l = FakePcLink(pc, onEffect);
        created.add(l);
        return l;
      },
      pairer: (qr, session, onEffect) => pairer(qr),
    );
    backend = TaskBackend(transport: link.task, coordinator: coord, replies: (_) => false);
    await backend.start();
    await settle();
  }

  setUp(() {
    store = PhoneStore(InMemorySecureKv());
    signer = FakeSigner();
    link = InMemoryTaskLink();
    created = [];
    ui.clear();
    link.ui.messages.listen(ui.add);
    pairer = (qr) async => makePc(qr.pcId);
  });

  test('start runs one link per stored PC and publishes the state', () async {
    await store.upsertPc(makePc('a'));
    await store.upsertPc(makePc('b'));
    await startBackend();

    expect(created.map((l) => l.pc.pcId), ['a', 'b']);
    expect(created.every((l) => l.started), isTrue);
    final pcs = (lastState()['pcs']! as List<Object?>).cast<Map<String, Object?>>();
    expect(pcs.map((p) => p['pcId']), ['a', 'b']);
  });

  test('pair command: pairs, persists, starts a link and answers pairResult', () async {
    await startBackend();
    const qr = QrPayload(pcId: 'n', name: 'PC n', host: '10.0.0.2', port: 1, fingerprint: 'fp', token: 't');
    link.ui.send({'op': TaskOps.pair, 'reqId': 'u1', 'qr': qr.toUri().toString()});
    await settle();

    final res = ui.singleWhere((m) => m['op'] == TaskOps.pairResult);
    expect(res['reqId'], 'u1');
    expect(res['ok'], isTrue);
    expect((res['pc']! as Map<String, Object?>)['pcId'], 'n');
    expect((await store.pcs()).map((p) => p.pcId), ['n']);
    expect(latest('n').started, isTrue);
  });

  test('re-pairing a PC replaces its link instead of running two', () async {
    await store.upsertPc(makePc('a'));
    await startBackend();
    final old = latest('a');
    const qr = QrPayload(pcId: 'a', name: 'PC a', host: 'h', port: 1, fingerprint: 'fp', token: 't');
    link.ui.send({'op': TaskOps.pair, 'reqId': 'u1', 'qr': qr.toUri().toString()});
    await settle();
    expect(old.stopCalls, 1);
    expect(latest('a').started, isTrue);
    expect(created.where((l) => l.started), hasLength(1));
  });

  test('two overlapping commands for the same PC are serialised, not raced', () async {
    await store.upsertPc(makePc('a'));
    await startBackend();

    // The first pair blocks mid-flight (inside _pair, before _startLink
    // runs): if handleCommand calls weren't serialised, the second command
    // — sent while the first is still stuck here — would run its own
    // _startLink/_stopLink concurrently with the first's.
    final firstGate = Completer<void>();
    var pairCalls = 0;
    pairer = (qr) async {
      pairCalls++;
      if (pairCalls == 1) await firstGate.future;
      return makePc('a', host: 'h$pairCalls');
    };
    const qr = QrPayload(pcId: 'a', name: 'PC a', host: 'h', port: 1, fingerprint: 'fp', token: 't');

    link.ui.send({'op': TaskOps.pair, 'reqId': 'u1', 'qr': qr.toUri().toString()});
    await settle();
    expect(pairCalls, 1, reason: 'sanity: the first pair is in flight, gated');

    link.ui.send({'op': TaskOps.pair, 'reqId': 'u2', 'qr': qr.toUri().toString()});
    await settle();
    expect(pairCalls, 1, reason: 'the second command must queue behind the first rather than run concurrently');
    expect(ui.where((m) => m['op'] == TaskOps.pairResult), isEmpty);

    firstGate.complete();
    await settle();

    expect(pairCalls, 2);
    final results = ui.where((m) => m['op'] == TaskOps.pairResult).toList();
    expect(results.map((m) => m['reqId']), ['u1', 'u2'], reason: 'both commands complete, in the order they arrived');
    expect(latest('a').pc.host, 'h2', reason: 'the second pair ran (and replaced the first link) only after the first finished');
    expect(created.where((l) => l.pc.pcId == 'a' && l.started), hasLength(1), reason: 'never two live links for the same PC');
  });

  test('a failed pairing answers ok:false with the reason', () async {
    pairer = (_) async => throw StateError('appairage refusé');
    await startBackend();
    const qr = QrPayload(pcId: 'n', name: 'PC n', host: 'h', port: 1, fingerprint: 'fp', token: 't');
    link.ui.send({'op': TaskOps.pair, 'reqId': 'u1', 'qr': qr.toUri().toString()});
    await settle();
    final res = ui.singleWhere((m) => m['op'] == TaskOps.pairResult);
    expect(res['ok'], isFalse);
    expect(res['error'], 'appairage refusé');
    expect(await store.pcs(), isEmpty);
  });

  test('revoke of the last PC stops its link, forgets it and deletes the key', () async {
    await store.upsertPc(makePc('a'));
    await startBackend();
    link.ui.send({'op': TaskOps.revoke, 'reqId': 'u2', 'pcId': 'a'});
    await settle();

    expect(ui.where((m) => m['op'] == TaskOps.revoked).single['reqId'], 'u2');
    expect(latest('a').started, isFalse);
    expect(await store.pcs(), isEmpty);
    expect(signer.deleteCalls, 1);
    expect(lastState()['pcs'], isEmpty);
  });

  test('revoke keeps the key while another PC is still paired', () async {
    await store.upsertPc(makePc('a'));
    await store.upsertPc(makePc('b'));
    await startBackend();
    link.ui.send({'op': TaskOps.revoke, 'reqId': 'u2', 'pcId': 'a'});
    await settle();
    expect((await store.pcs()).map((p) => p.pcId), ['b']);
    expect(signer.deleteCalls, 0);
  });

  test('link effects: online, unknown (needs re-pair, link stopped), host update', () async {
    await store.upsertPc(makePc('a'));
    await startBackend();

    latest('a').emit(const PhoneOnlineChanged('a', true));
    await settle();
    expect(lastState()['online'], ['a']);

    latest('a').emit(PhonePairedWith(makePc('a', host: '10.0.0.9')));
    await settle();
    expect((await store.pcs()).single.host, '10.0.0.9');

    latest('a').emit(const PhoneUnknownByPc('a'));
    await settle();
    expect(lastState()['needsRepair'], ['a']);
    expect(latest('a').started, isFalse);
  });

  test('a late host update from a revoked PC does not resurrect it', () async {
    await store.upsertPc(makePc('a'));
    await startBackend();
    final stale = latest('a');
    link.ui.send({'op': TaskOps.revoke, 'reqId': 'u', 'pcId': 'a'});
    await settle();
    stale.emit(PhonePairedWith(makePc('a')));
    await settle();
    expect(await store.pcs(), isEmpty);
  });

  test('refresh restarts every link and clears needsRepair', () async {
    await store.upsertPc(makePc('a'));
    await startBackend();
    latest('a').emit(const PhoneUnknownByPc('a'));
    await settle();
    link.ui.send({'op': TaskOps.refresh});
    await settle();
    expect(created.where((l) => l.pc.pcId == 'a'), hasLength(2));
    expect(latest('a').started, isTrue);
    expect(lastState()['needsRepair'], isEmpty);
  });

  test('getState answers with a fresh snapshot; signer replies never reach the coordinator', () async {
    await startBackend();
    final routed = <String>[];
    await backend.stop();
    backend = TaskBackend(
      transport: link.task,
      coordinator: coord = LinkCoordinator(
        store: store,
        signer: signer,
        clock: const SystemClock(),
        send: link.task.send,
        linkFactory: (pc, session, onEffect) => FakePcLink(pc, onEffect),
        pairer: (qr, session, onEffect) => pairer(qr),
      ),
      replies: (m) {
        final isReply = TaskOps.replies.contains(m['op']);
        if (isReply) routed.add(m['op']! as String);
        return isReply;
      },
    );
    await backend.start();
    await settle();
    ui.clear();
    link.ui.send({'op': TaskOps.pong, 'reqId': 'r1'});
    link.ui.send({'op': TaskOps.getState});
    await settle();
    expect(routed, [TaskOps.pong]);
    expect(ui.single['op'], TaskOps.state);
  });

  test('commands arriving while the links are still starting are handled once started', () async {
    final gate = Completer<void>();
    final kv = _SlowKv(gate.future);
    await kv.write('pcs', '[${'{'}"pcId":"a","name":"PC a","host":"h","port":1,"fingerprint":"fp","session":"s"${'}'}]');
    final slowStore = PhoneStore(kv);
    coord = LinkCoordinator(
      store: slowStore,
      signer: signer,
      clock: const SystemClock(),
      send: link.task.send,
      linkFactory: (pc, session, onEffect) {
        final l = FakePcLink(pc, onEffect);
        created.add(l);
        return l;
      },
      pairer: (qr, session, onEffect) => pairer(qr),
    );
    backend = TaskBackend(transport: link.task, coordinator: coord, replies: (_) => false);
    final starting = backend.start();
    link.ui.send({'op': TaskOps.revoke, 'reqId': 'early', 'pcId': 'a'});
    await settle();
    expect(ui.where((m) => m['op'] == TaskOps.revoked), isEmpty);
    gate.complete();
    await starting;
    await settle();
    expect(ui.where((m) => m['op'] == TaskOps.revoked).single['reqId'], 'early');
    expect(await slowStore.pcs(), isEmpty);
  });
}

/// A [SecureKv] whose first `pcs` read waits on [gate] (a slow secure
/// storage read at service start).
final class _SlowKv implements SecureKv {
  _SlowKv(this.gate);
  final Future<void> gate;
  final _inner = InMemorySecureKv();
  var _first = true;

  @override
  Future<String?> read(String key) async {
    if (key == 'pcs' && _first) {
      _first = false;
      await gate;
    }
    return _inner.read(key);
  }

  @override
  Future<void> write(String key, String value) => _inner.write(key, value);

  @override
  Future<void> delete(String key) => _inner.delete(key);
}
