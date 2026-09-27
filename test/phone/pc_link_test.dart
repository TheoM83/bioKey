import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/core/crypto/identity.dart';
import 'package:biokey/core/crypto/verify.dart';
import 'package:biokey/core/pairing/qr_payload.dart';
import 'package:biokey/core/protocol/codec.dart';
import 'package:biokey/core/protocol/framing.dart';
import 'package:biokey/core/protocol/messages.dart';
import 'package:biokey/core/session/clock.dart';
import 'package:biokey/core/session/desktop_session.dart';
import 'package:biokey/core/session/phone_session.dart';
import 'package:biokey/core/storage/phone_store.dart';
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
    // pair()'s own teardown already drained the peer's close echo, so the
    // desktop has run its onDisconnect by the time we get here — no race
    // with a fresh PcLink opening a new connection right after.
    expect(ds.phoneOnline, isFalse);

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

  test('connects using a hostname (localhost) instead of an IP literal — a manual host can be a MagicDNS/tunnel name', () async {
    final signer = FakeSigner();
    final ps = PhoneSession(signer: signer, clock: const SystemClock());
    ds.startPairing();
    final qr = QrPayload(pcId: id.pcId, name: 'PC', host: 'localhost', port: server.port, fingerprint: id.fingerprintB64Url, token: ds.pairingToken!);
    final paired = await PcLink.pair(qr: qr, session: ps, onEffect: (_) {}).timeout(const Duration(seconds: 5));
    expect(paired.host, 'localhost');

    final link = PcLink(pc: paired, session: ps, onEffect: (_) {});
    await link.start();
    await _until(() => ds.phoneOnline);
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

  test('a manual host that fails alternates with the LAN host, and a fresh discovery result is preferred over retrying it', () async {
    final signer = FakeSigner();
    final ps = PhoneSession(signer: signer, clock: const SystemClock());
    ds.startPairing();
    final qr = QrPayload(pcId: id.pcId, name: 'PC', host: '127.0.0.1', port: server.port, fingerprint: id.fingerprintB64Url, token: ds.pairingToken!);
    final paired = await PcLink.pair(qr: qr, session: ps, onEffect: (_) {}).timeout(const Duration(seconds: 5));
    // pair()'s own teardown drains the peer's close echo before returning,
    // so the desktop's onDisconnect is normally already done by here — but
    // make it an explicit wait rather than an implicit race, so a slow
    // machine can't make ds.phoneOnline read true from the *pairing*
    // connection's stale state instead of the new link's first real
    // attempt below.
    await _until(() => !ds.phoneOnline);

    // Both the manual (tunnel) host and the stored-but-stale LAN host fail
    // instantly; only the real address — which discovery will resolve to
    // — actually connects.
    const manual = 'bogus.manual.invalid';
    const staleLan = 'stale.lan.invalid';
    final tried = <String>[];
    Future<SecureSocket> connect(String h, int p, String fp) {
      tried.add(h);
      if (h == manual || h == staleLan) return Future<SecureSocket>.error(const SocketException('refused'));
      return connectPinned(host: h, port: p, fingerprint: fp);
    }

    var resolveCalls = 0;
    Future<String?> resolve(String pcId) async {
      resolveCalls++;
      return '127.0.0.1';
    }

    final pcWithManual = paired.copyWith(host: staleLan, manualHost: manual);
    final phoneFx = <PhoneEffect>[];
    final link = PcLink(
      pc: pcWithManual,
      session: ps,
      onEffect: phoneFx.add,
      connect: connect,
      resolveHost: resolve,
      backoff: (_) => const Duration(milliseconds: 20),
    );
    await link.start();
    await _until(() => ds.phoneOnline, timeout: const Duration(seconds: 5));

    expect(tried, containsAllInOrder([manual, staleLan, '127.0.0.1']), reason: 'manual is tried first, then the stale LAN host, then the discovery-resolved real one');
    expect(resolveCalls, greaterThanOrEqualTo(1));
    expect(link.pc.host, '127.0.0.1', reason: 'the LAN host is updated to the address that actually worked');
    expect(link.pc.manualHost, manual, reason: 'the manual host must never be overwritten by a discovery result');

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

  test('short liveness intervals: pings are sent at the idle interval, and the link closes after the no-receive timeout', () async {
    // A bare TLS stub that never replies to anything (not even the desktop's
    // usual pong) — isolates PcLink's own liveness behaviour (driven by a
    // monotonic Stopwatch, not DateTime.now()) from the real server's.
    final stub = await SecureServerSocket.bind('127.0.0.1', 0, id.securityContext());
    final pings = <String>[];
    final closed = Completer<void>();
    final sub = stub.listen((socket) {
      FrameDecoder().bind(socket).listen(
        (frame) {
          if (Codec.decode(frame) is PingMsg) pings.add(frame);
        },
        onDone: () {
          if (!closed.isCompleted) closed.complete();
        },
        onError: (Object _) {
          if (!closed.isCompleted) closed.complete();
        },
      );
    });

    final pc = PairedPc(pcId: 'stub', name: 'Stub', host: '127.0.0.1', port: stub.port, fingerprint: id.fingerprintB64Url, session: 'sess');
    final ps = PhoneSession(signer: FakeSigner(), clock: const SystemClock());
    // The liveness/ping check itself only runs once a second (see
    // PcLink._loop), so "short" here means short relative to the real
    // defaults (30s/60s), not sub-second.
    final link = PcLink(
      pc: pc,
      session: ps,
      onEffect: (_) {},
      pingInterval: const Duration(seconds: 1),
      livenessTimeout: const Duration(seconds: 3),
    );
    await link.start();

    await _until(() => pings.length >= 2, timeout: const Duration(seconds: 10));
    expect(pings.length, greaterThanOrEqualTo(2), reason: 'a ping is sent every pingInterval while the link is otherwise idle');

    await closed.future.timeout(const Duration(seconds: 10), onTimeout: () => fail('the link never closed after the no-receive liveness timeout'));

    await link.stop();
    await sub.cancel();
    await stub.close();
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
