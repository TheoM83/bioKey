import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/core/pairing/qr_payload.dart';
import 'package:biokey/core/storage/phone_store.dart';
import 'package:biokey/core/storage/secure_kv.dart';
import 'package:biokey/phone/phone_controller.dart';
import 'package:biokey/phone/service/task_transport.dart';
import '../support/fake_foreground_gate.dart';
import '../support/fake_signer.dart';
import '../support/in_memory_task_transport.dart';

PairedPc makePc(String pcId) => PairedPc(pcId: pcId, name: 'PC $pcId', host: 'h', port: 1, fingerprint: 'fp', session: 'sess');

void main() {
  late InMemoryTaskLink link;
  late FakeSigner signer;
  late PhoneStore store;
  late FakeForegroundGate gate;
  late PhoneController c;
  final toTask = <Map<String, Object?>>[];

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  void publish({List<PairedPc> pcs = const [], List<String> online = const [], List<String> needsRepair = const []}) {
    link.task.send({
      'op': TaskOps.state,
      'pcs': [for (final p in pcs) p.toJson()],
      'online': online,
      'needsRepair': needsRepair,
    });
  }

  setUp(() async {
    link = InMemoryTaskLink();
    toTask.clear();
    link.task.messages.listen(toTask.add);
    signer = FakeSigner();
    store = PhoneStore(InMemorySecureKv());
    gate = FakeForegroundGate()..resume();
    c = PhoneController(transport: link.ui, signer: signer, store: store, gate: gate, stateRetry: const Duration(milliseconds: 20));
    await c.init();
  });

  tearDown(() => c.shutdown());

  test('init asks the service for its state, retrying until it answers', () async {
    await Future<void>.delayed(const Duration(milliseconds: 70));
    final asks = toTask.where((m) => m['op'] == TaskOps.getState).length;
    expect(asks, greaterThanOrEqualTo(2));
    publish();
    await Future<void>.delayed(const Duration(milliseconds: 70));
    expect(toTask.where((m) => m['op'] == TaskOps.getState).length, lessThanOrEqualTo(asks + 1));
  });

  test('mirrors the published state and notifies listeners', () async {
    var notified = 0;
    c.addListener(() => notified++);
    publish(pcs: [makePc('a'), makePc('b')], online: ['a'], needsRepair: ['b']);
    await settle();
    expect(c.pcs.map((p) => p.pcId), ['a', 'b']);
    expect(c.isOnline('a'), isTrue);
    expect(c.isOnline('b'), isFalse);
    expect(c.needsRepair, {'b'});
    expect(notified, 1);
  });

  test('pair sends the QR and resolves with the paired PC', () async {
    const qr = QrPayload(pcId: 'n', name: 'PC n', host: 'h', port: 1, fingerprint: 'fp', token: 't');
    final pairing = c.pair(qr);
    await settle();
    final cmd = toTask.singleWhere((m) => m['op'] == TaskOps.pair);
    expect(QrPayload.parse(cmd['qr']! as String), qr);
    link.task.send({'op': TaskOps.pairResult, 'reqId': cmd['reqId'], 'ok': true, 'pc': makePc('n').toJson()});
    expect((await pairing).pcId, 'n');
  });

  test('pair throws the service-side reason on failure', () async {
    const qr = QrPayload(pcId: 'n', name: 'PC n', host: 'h', port: 1, fingerprint: 'fp', token: 't');
    final pairing = c.pair(qr);
    await settle();
    final cmd = toTask.singleWhere((m) => m['op'] == TaskOps.pair);
    link.task.send({'op': TaskOps.pairResult, 'reqId': cmd['reqId'], 'ok': false, 'error': 'appairage refusé'});
    await expectLater(pairing, throwsA(isA<StateError>().having((e) => e.message, 'message', 'appairage refusé')));
  });

  test('revoke completes once the service acknowledges it', () async {
    var done = false;
    final revoking = c.revoke('a').then((_) => done = true);
    await settle();
    final cmd = toTask.singleWhere((m) => m['op'] == TaskOps.revoke);
    expect(cmd['pcId'], 'a');
    expect(done, isFalse);
    link.task.send({'op': TaskOps.revoked, 'reqId': cmd['reqId']});
    await revoking;
    expect(done, isTrue);
  });

  test('setHost sends the command and resolves once the service acknowledges it', () async {
    var done = false;
    final setting = c.setHost('a', 'pc-maison.tailnet.ts.net').then((_) => done = true);
    await settle();
    final cmd = toTask.singleWhere((m) => m['op'] == TaskOps.setHost);
    expect(cmd['pcId'], 'a');
    expect(cmd['host'], 'pc-maison.tailnet.ts.net');
    expect(done, isFalse);
    link.task.send({'op': TaskOps.setHostResult, 'reqId': cmd['reqId'], 'ok': true});
    await setting;
    expect(done, isTrue);
  });

  test('setHost throws the service-side reason on failure', () async {
    final setting = c.setHost('a', 'not a host');
    await settle();
    final cmd = toTask.singleWhere((m) => m['op'] == TaskOps.setHost);
    link.task.send({'op': TaskOps.setHostResult, 'reqId': cmd['reqId'], 'ok': false, 'error': 'Adresse invalide'});
    await expectLater(setting, throwsA(isA<StateError>().having((e) => e.message, 'message', 'Adresse invalide')));
  });

  test('answers ping with pong, and signer requests with the real signer', () async {
    link.task.send({'op': TaskOps.ping, 'reqId': 'p1'});
    link.task.send({'op': TaskOps.ensurePublicKey, 'reqId': 'k1'});
    link.task.send({'op': TaskOps.sign, 'reqId': 's1', 'payload': 'X', 'prompt': 'Ouvrir A sur PC ?'});
    link.task.send({'op': TaskOps.deleteKey, 'reqId': 'd1'});
    await settle();
    Map<String, Object?> reply(String reqId) => toTask.singleWhere((m) => m['reqId'] == reqId);
    expect(reply('p1')['op'], TaskOps.pong);
    expect(reply('k1')['pub'], signer.keys.pubSpkiB64);
    expect(reply('s1')['op'], TaskOps.sig);
    expect(signer.prompts, ['Ouvrir A sur PC ?']);
    expect(reply('d1')['op'], TaskOps.ok);
    expect(signer.deleteCalls, 1);
  });

  test('once paired PCs are known, a changed public key makes the service reconnect', () async {
    await store.savePubKey('OLD-KEY');
    publish(pcs: [makePc('a')]);
    await settle();
    expect(toTask.where((m) => m['op'] == TaskOps.refresh), hasLength(1));
  });

  test('an unchanged public key does not trigger a refresh', () async {
    await store.savePubKey(signer.keys.pubSpkiB64);
    publish(pcs: [makePc('a')]);
    await settle();
    expect(toTask.where((m) => m['op'] == TaskOps.refresh), isEmpty);
  });

  test('shutdown detaches the gate and fails pending commands', () async {
    final revoking = expectLater(c.revoke('a'), throwsA(isA<StateError>()));
    await settle();
    await c.shutdown();
    await revoking;
    expect(gate.detached, isTrue);
  });
}
