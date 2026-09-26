import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/core/crypto/identity.dart';
import 'package:biokey/core/crypto/verify.dart';
import 'package:biokey/core/pairing/qr_payload.dart';
import 'package:biokey/core/session/clock.dart';
import 'package:biokey/core/session/desktop_session.dart';
import 'package:biokey/core/session/phone_session.dart';
import 'package:biokey/desktop/server/tls_server.dart';
import 'package:biokey/phone/net/pc_link.dart';
import 'package:biokey/phone/net/pinned_socket.dart';
import '../support/fake_signer.dart';

void main() {
  late DesktopIdentity id;
  late DesktopSession ds;
  late TlsServer server;
  final desktopFx = <DesktopEffect>[];

  setUp(() async {
    id = generateDesktopIdentity(pcName: 'PC');
    ds = DesktopSession(pcId: id.pcId, pcName: 'PC', verifier: const EcdsaVerifier(), clock: const SystemClock());
    desktopFx.clear();
    server = TlsServer(identity: id, session: ds, onEffect: desktopFx.add);
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
    server = TlsServer(identity: id, session: ds, onEffect: desktopFx.add);
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
    Future<SecureSocket> slowConnect(String h, int p, String fp) async {
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

  test('a bogus resolved host does not permanently strand the link off the stored (working) host', () async {
    final signer = FakeSigner();
    final ps = PhoneSession(signer: signer, clock: const SystemClock());
    ds.startPairing();
    final qr = QrPayload(pcId: id.pcId, name: 'PC', host: '127.0.0.1', port: server.port, fingerprint: id.fingerprintB64Url, token: ds.pairingToken!);
    final paired = await PcLink.pair(qr: qr, session: ps, onEffect: (_) {}).timeout(const Duration(seconds: 5));

    // A fake "bogus" host that fails instantly (a real TCP connect to an
    // unreachable address can take seconds to time out, which would make
    // this test slow/flaky) — everything else still goes through the real
    // connectPinned, so the stored (real) host genuinely round-trips.
    const bogusHost = 'bogus.invalid';
    Future<SecureSocket> fastFailingConnect(String h, int p, String fp) {
      if (h == bogusHost) return Future<SecureSocket>.error(const SocketException('refused'));
      return connectPinned(host: h, port: p, fingerprint: fp);
    }

    final resolvedHosts = <String?>[];
    Future<String?> flakyResolve(String pcId) async {
      final result = resolvedHosts.isEmpty ? bogusHost : null;
      resolvedHosts.add(result);
      return result;
    }

    final phoneFx = <PhoneEffect>[];
    final link = PcLink(
      pc: paired,
      session: ps,
      onEffect: phoneFx.add,
      connect: fastFailingConnect,
      resolveHost: flakyResolve,
      backoff: (_) => const Duration(milliseconds: 50),
    );
    await link.start();
    await _until(() => ds.phoneOnline);

    // Take the real server down so the link is forced to reconnect and
    // consult resolveHost along the way.
    final port = server.port;
    await server.stop();
    await _until(() => !link.online);

    // Let it burn through: the stored host failing, the bogus resolved
    // host failing, and resolveHost reporting "unknown" — all before the
    // stored host is reachable again.
    await _until(() => resolvedHosts.length >= 2, timeout: const Duration(seconds: 5));

    server = TlsServer(identity: id, session: ds, onEffect: desktopFx.add);
    await server.start(address: '127.0.0.1', port: port);
    await _until(() => ds.phoneOnline, timeout: const Duration(seconds: 10));

    expect(resolvedHosts.first, bogusHost, reason: 'sanity: the bogus host really was offered');
    expect(link.pc.host, '127.0.0.1', reason: 'never got stuck persisting/re-trying only the bogus host');
    await link.stop();
  });

  test('pairing retries once on the discovery-resolved host when the QR host is unreachable', () async {
    ds.startPairing();
    final qr = QrPayload(pcId: id.pcId, name: 'PC', host: 'unreachable.invalid', port: server.port, fingerprint: id.fingerprintB64Url, token: ds.pairingToken!);
    final tried = <String>[];
    Future<SecureSocket> connect(String h, int p, String fp) {
      tried.add(h);
      if (h == 'unreachable.invalid') return Future<SecureSocket>.error(const SocketException('unreachable'));
      return connectPinned(host: h, port: p, fingerprint: fp);
    }

    final resolvedFor = <String>[];
    final paired = await PcLink.pair(
      qr: qr,
      session: PhoneSession(signer: FakeSigner(), clock: const SystemClock()),
      onEffect: (_) {},
      connect: connect,
      resolveHost: (pcId) async {
        resolvedFor.add(pcId);
        return '127.0.0.1';
      },
    ).timeout(const Duration(seconds: 5));

    expect(resolvedFor, [id.pcId]);
    expect(tried, ['unreachable.invalid', '127.0.0.1']);
    expect(paired.host, '127.0.0.1', reason: 'the host that actually worked is the one remembered');
    expect(paired.fingerprint, id.fingerprintB64Url);
  });

  test('pairing fails when the QR host is unreachable and discovery finds nothing', () async {
    ds.startPairing();
    final qr = QrPayload(pcId: id.pcId, name: 'PC', host: 'unreachable.invalid', port: server.port, fingerprint: id.fingerprintB64Url, token: ds.pairingToken!);
    Future<SecureSocket> connect(String h, int p, String fp) => Future<SecureSocket>.error(const SocketException('unreachable'));
    await expectLater(
      PcLink.pair(qr: qr, session: PhoneSession(signer: FakeSigner(), clock: const SystemClock()), onEffect: (_) {}, connect: connect, resolveHost: (_) async => null),
      throwsA(isA<SocketException>()),
    );
  });

  test('the link survives a slow fingerprint prompt (well under the liveness timeout)', () async {
    final signer = _SlowSigner(const Duration(milliseconds: 1500));
    final ps = PhoneSession(signer: signer, clock: const SystemClock());
    ds.startPairing();
    final qr = QrPayload(pcId: id.pcId, name: 'PC', host: '127.0.0.1', port: server.port, fingerprint: id.fingerprintB64Url, token: ds.pairingToken!);
    final paired = await PcLink.pair(qr: qr, session: ps, onEffect: (_) {}).timeout(const Duration(seconds: 10));

    final link = PcLink(pc: paired, session: ps, onEffect: (_) {});
    await link.start();
    await _until(() => ds.phoneOnline);

    final (authId, fx) = ds.requestAuth(label: 'Mon app');
    server.apply(fx);
    await _until(() => desktopFx.whereType<AuthResolved>().any((r) => r.id == authId), timeout: const Duration(seconds: 10));
    expect(desktopFx.whereType<AuthResolved>().single.outcome, AuthOutcome.approved);
    await link.stop();
  });

  test('stop() called during a long backoff returns quickly instead of blocking for it', () async {
    final signer = FakeSigner();
    final ps = PhoneSession(signer: signer, clock: const SystemClock());
    ds.startPairing();
    final qr = QrPayload(pcId: id.pcId, name: 'PC', host: '127.0.0.1', port: server.port, fingerprint: id.fingerprintB64Url, token: ds.pairingToken!);
    final paired = await PcLink.pair(qr: qr, session: ps, onEffect: (_) {}).timeout(const Duration(seconds: 5));

    // Fails instantly every time, so the loop reliably reaches its backoff
    // sleep — with every backoff forced to 30s — almost immediately,
    // without depending on real (slow/OS-specific) TCP-refusal timing.
    Future<SecureSocket> alwaysFailConnect(String h, int p, String fp) => Future<SecureSocket>.error(const SocketException('refused'));
    final link = PcLink(pc: paired, session: ps, onEffect: (_) {}, connect: alwaysFailConnect, backoff: (_) => const Duration(seconds: 30));
    await link.start();
    // Let the failing connect attempt run its course so the loop is
    // actually sitting in the 30s backoff sleep by the time we stop it.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final sw = Stopwatch()..start();
    await link.stop().timeout(const Duration(milliseconds: 1500));
    sw.stop();

    expect(sw.elapsedMilliseconds, lessThan(500), reason: 'stop() must wake the backoff sleep, not sit through it');
  });
}

Future<void> _until(bool Function() p, {Duration timeout = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (!p()) {
    if (DateTime.now().isAfter(end)) fail('timeout waiting for condition');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// A [FakeSigner] whose `sign` takes [delay], like a user taking their time
/// on the fingerprint prompt.
class _SlowSigner extends FakeSigner {
  _SlowSigner(this.delay);
  final Duration delay;

  @override
  Future<String> sign({required String payload, required String prompt}) async {
    await Future<void>.delayed(delay);
    return super.sign(payload: payload, prompt: prompt);
  }
}
