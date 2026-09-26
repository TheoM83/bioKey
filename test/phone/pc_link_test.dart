import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/core/crypto/identity.dart';
import 'package:biokey/core/crypto/verify.dart';
import 'package:biokey/core/pairing/qr_payload.dart';
import 'package:biokey/core/session/clock.dart';
import 'package:biokey/core/session/desktop_session.dart';
import 'package:biokey/core/session/phone_session.dart';
import 'package:biokey/desktop/server/ws_server.dart';
import 'package:biokey/phone/net/pc_link.dart';
import 'package:biokey/phone/net/pinned_socket.dart';
import '../support/fake_signer.dart';

void main() {
  late DesktopIdentity id;
  late DesktopSession ds;
  late WsServer server;
  final desktopFx = <DesktopEffect>[];

  setUp(() async {
    id = generateDesktopIdentity(pcName: 'PC');
    ds = DesktopSession(pcId: id.pcId, pcName: 'PC', verifier: const EcdsaVerifier(), clock: const SystemClock());
    desktopFx.clear();
    server = WsServer(identity: id, session: ds, onEffect: desktopFx.add);
    await server.start(address: '127.0.0.1', port: 0);
  });
  tearDown(() => server.stop());

  test('pair, reconnect with hello, answer an auth, survive server restart', () async {
    final signer = FakeSigner();
    final ps = PhoneSession(signer: signer, clock: const SystemClock());
    ds.startPairing();
    final qr = QrPayload(pcId: id.pcId, name: 'PC', host: '127.0.0.1', port: server.port, fingerprint: id.fingerprintB64Url, token: ds.pairingToken!);
    final phoneFx = <PhoneEffect>[];
    final paired = await PcLink.pair(qr: qr, session: ps, onEffect: phoneFx.add).timeout(const Duration(seconds: 5));
    expect(paired.pcId, id.pcId);
    expect(ds.phone!.pub, signer.keys.pubSpkiB64);

    final link = PcLink(pc: paired, session: ps, onEffect: phoneFx.add);
    await link.start();
    await _until(() => ds.phoneOnline);

    final (authId, fx) = ds.requestAuth(label: 'Mon app');
    server.apply(fx);
    await _until(() => desktopFx.whereType<AuthResolved>().any((r) => r.id == authId));
    expect(desktopFx.whereType<AuthResolved>().single.outcome, AuthOutcome.approved);
    expect(signer.prompts.last, 'Ouvrir Mon app sur PC ?');

    // server restart on the same port → link must come back
    final port = server.port;
    await server.stop();
    await _until(() => !link.online);
    server = WsServer(identity: id, session: ds, onEffect: desktopFx.add);
    await server.start(address: '127.0.0.1', port: port);
    await _until(() => ds.phoneOnline, timeout: const Duration(seconds: 10));
    await link.stop();
  });

  test('pairing with wrong fingerprint fails', () async {
    ds.startPairing();
    final qr = QrPayload(pcId: id.pcId, name: 'PC', host: '127.0.0.1', port: server.port, fingerprint: 'wrong', token: ds.pairingToken!);
    expect(PcLink.pair(qr: qr, session: PhoneSession(signer: FakeSigner(), clock: const SystemClock()), onEffect: (_) {}).timeout(const Duration(seconds: 5)), throwsA(anything));
  });

  test('start(); stop(); start(); stop() with a slow connect leaves exactly one live loop and no leaked socket', () async {
    final signer = FakeSigner();
    final ps = PhoneSession(signer: signer, clock: const SystemClock());
    ds.startPairing();
    final qr = QrPayload(pcId: id.pcId, name: 'PC', host: '127.0.0.1', port: server.port, fingerprint: id.fingerprintB64Url, token: ds.pairingToken!);
    final paired = await PcLink.pair(qr: qr, session: ps, onEffect: (_) {}).timeout(const Duration(seconds: 5));

    var connectCalls = 0;
    Future<WebSocket> slowConnect(String h, int p, String fp) async {
      connectCalls++;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return connectPinned(host: h, port: p, fingerprint: fp);
    }

    final phoneFx = <PhoneEffect>[];
    final link = PcLink(pc: paired, session: ps, onEffect: phoneFx.add, connect: slowConnect);

    // Each stop() must fully await its generation's in-flight connect
    // (which arrives ~300ms later) before returning, so this whole
    // sequence is deterministic without any manual extra delay.
    await link.start().timeout(const Duration(seconds: 2));
    await link.stop().timeout(const Duration(seconds: 2));
    await link.start().timeout(const Duration(seconds: 2));
    await link.stop().timeout(const Duration(seconds: 2));

    expect(connectCalls, 2, reason: 'one connect attempt per start(), no duplicate loop retrying on its own');
    expect(link.online, isFalse);
    // A leaked/duplicate loop would eventually complete its handshake and
    // the desktop would see the phone online; give it a beat to prove it
    // never does.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(ds.phoneOnline, isFalse, reason: 'no socket from a stopped generation was ever used to say hello');
  });
}

Future<void> _until(bool Function() p, {Duration timeout = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (!p()) {
    if (DateTime.now().isAfter(end)) fail('timeout waiting for condition');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
