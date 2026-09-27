# BioKey J1.1 — Lean transport (dart:io only) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove every third-party network and crypto-wrapper library from BioKey's security path: raw pinned TLS sockets with length-prefixed JSON frames, UDP-broadcast discovery, and `pointycastle`-only crypto — same protocol v1, same state machines, same tests.

**Architecture:** `WsServer`/`PcLink.connectPinned` become `TlsServer`/`SecureSocket` over a shared `Framing` codec (4-byte big-endian length + UTF-8 JSON, 64 KiB max). Discovery is a tiny UDP request/response (`_biokey` mDNS removed). `basic_utils` is replaced by direct `pointycastle` calls (ECDSA verify, X.509 self-signed cert). Off-LAN use is the user's own WireGuard/Tailscale: the phone gets an editable host per PC.

**Tech Stack:** Flutter 3.35 / Dart 3.9, `dart:io` (`SecureServerSocket`, `SecureSocket`, `RawDatagramSocket`), `pointycastle`. Removed: `bonsoir`, `basic_utils`.

**Spec:** `CAHIER_DES_CHARGES.md` v0.2 — §7 unchanged except the transport line in §7.3 ("JSON sur WebSocket" → "JSON en trames longueur-préfixées sur TLS") and the stack table in §8.2 (Task 8 updates them).

## Global Constraints

- The only network I/O: desktop listens on TCP `<port>` (TLS) and UDP `47623`; phone connects out to the TCP port and sends UDP discovery broadcasts. Nothing else.
- Frame = `uint32 BE length` + UTF-8 JSON payload; `length ≤ 65536`, else close. Frames are exactly what gets signed (`auth`) — the payload string must be forwarded byte-for-byte to `DesktopSession`/`PhoneSession` as today.
- TLS: server cert = existing `DesktopIdentity`; client pins the SHA-256 of the DER cert with `onBadCertificate` on a `SecurityContext(withTrustedRoots: false)`; no other acceptance path.
- Protocol v1 messages, `DesktopSession`, `PhoneSession`, stores, controllers' public APIs unchanged. All existing tests must keep passing (transport-specific tests are ported, not deleted).
- No new pub dependencies. `bonsoir` and `basic_utils` are removed from `pubspec.yaml` at the end (Task 7), `pointycastle` stays.
- `flutter analyze` no issues, `flutter test` green before every commit; commit trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- French UI strings.

## Review Focus

1. **A frame split across TCP segments or two frames in one segment** must decode into exactly the same payload strings (Task 1 tests both).
2. **A client that sends a 5 MB length prefix** must be closed before any allocation of that size (Task 1: reject on the length field; Task 3: close).
3. **Certificate mismatch on connect** (wrong pin) must fail the handshake with no bytes of protocol sent (Task 4 test).
4. **Discovery reply spoofing**: a rogue LAN host answering the UDP probe must not change a stored host — a candidate host is only persisted after a pinned `welcome` (already the rule in `PcLink`; Task 5 keeps it and tests that a bogus reply is ignored).
5. **Manual host edit** with a hostname (Tailscale MagicDNS) instead of an IP must work (Task 6: `SecureSocket.connect` accepts hostnames; test with `localhost`).

---

### Task 1: Framing codec (pure Dart)

**Files:**
- Create: `lib/core/protocol/framing.dart`
- Test: `test/core/protocol/framing_test.dart`

**Interfaces:**
- Produces:
  - `const int maxFrameBytes = 65536;`
  - `Uint8List encodeFrame(String payload)` — length prefix + UTF-8 bytes; throws `ArgumentError` if the encoded payload exceeds `maxFrameBytes`.
  - `final class FrameDecoder extends StreamTransformerBase<List<int>, String>` — turns a byte stream into a stream of payload strings; emits a `FramingException` (extends `ProtocolException`) and closes when a length field exceeds `maxFrameBytes` or the payload is not valid UTF-8.

- [ ] **Step 1: Failing tests**

```dart
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/core/protocol/framing.dart';

void main() {
  Future<List<String>> decode(List<List<int>> chunks) =>
      Stream<List<int>>.fromIterable(chunks).transform(FrameDecoder()).toList();

  test('round-trip one frame', () async {
    final f = encodeFrame('{"type":"ping"}');
    expect(f.length, 4 + 15);
    expect(await decode([f]), ['{"type":"ping"}']);
  });

  test('two frames in one chunk and one frame split across chunks', () async {
    final a = encodeFrame('A'), b = encodeFrame('BB');
    final joined = Uint8List.fromList([...a, ...b]);
    expect(await decode([joined]), ['A', 'BB']);
    expect(await decode([joined.sublist(0, 3), joined.sublist(3, 6), joined.sublist(6)]), ['A', 'BB']);
  });

  test('unicode payload survives', () async {
    const s = '{"label":"Ouvrir l’app — é"}';
    expect(await decode([encodeFrame(s)]), [s]);
  });

  test('oversized length field is rejected before reading the body', () async {
    final hdr = ByteData(4)..setUint32(0, 5 * 1024 * 1024);
    expect(decode([hdr.buffer.asUint8List()]), throwsA(isA<FramingException>()));
  });

  test('encodeFrame refuses oversized payloads', () {
    expect(() => encodeFrame('x' * (maxFrameBytes + 1)), throwsArgumentError);
  });

  test('invalid utf-8 is rejected', () async {
    final hdr = ByteData(4)..setUint32(0, 2);
    expect(decode([[...hdr.buffer.asUint8List(), 0xC3, 0x28]]), throwsA(isA<FramingException>()));
  });
}
```

- [ ] **Step 2: Run, expect failure** — `flutter test test/core/protocol/framing_test.dart`

- [ ] **Step 3: Implement**

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'messages.dart' show ProtocolException;

const int maxFrameBytes = 65536;

class FramingException extends ProtocolException {
  FramingException(super.message);
}

Uint8List encodeFrame(String payload) {
  final body = utf8.encode(payload);
  if (body.length > maxFrameBytes) throw ArgumentError('trame trop grande: ${body.length} octets');
  final out = Uint8List(4 + body.length);
  ByteData.view(out.buffer).setUint32(0, body.length);
  out.setRange(4, out.length, body);
  return out;
}

final class FrameDecoder extends StreamTransformerBase<List<int>, String> {
  @override
  Stream<String> bind(Stream<List<int>> stream) {
    final controller = StreamController<String>();
    final buf = BytesBuilder(copy: false);
    int? need;
    late StreamSubscription<List<int>> sub;

    void fail(String msg) {
      controller.addError(FramingException(msg));
      sub.cancel();
      controller.close();
    }

    sub = stream.listen((chunk) {
      buf.add(chunk);
      while (true) {
        final bytes = buf.toBytes();
        if (need == null) {
          if (bytes.length < 4) break;
          final len = ByteData.view(bytes.buffer, bytes.offsetInBytes, 4).getUint32(0);
          if (len > maxFrameBytes) { fail('longueur de trame $len > $maxFrameBytes'); return; }
          need = len;
          buf.clear(); buf.add(bytes.sublist(4));
          continue;
        }
        if (bytes.length < need!) break;
        final body = bytes.sublist(0, need!);
        buf.clear(); buf.add(bytes.sublist(need!));
        need = null;
        try {
          controller.add(utf8.decode(body, allowMalformed: false));
        } on FormatException {
          fail('trame non UTF-8'); return;
        }
      }
    }, onError: controller.addError, onDone: controller.close, cancelOnError: true);
    controller.onCancel = sub.cancel;
    return controller.stream;
  }
}
```

- [ ] **Step 4: Run + analyze; commit** — `feat(core): length-prefixed frame codec`

---

### Task 2: Crypto on pointycastle only

**Files:**
- Modify: `lib/core/crypto/verify.dart`, `lib/core/crypto/identity.dart`
- Test: existing `test/core/crypto/*` must pass unchanged; add `test/core/crypto/identity_x509_test.dart`
- Modify: `test/support/test_keys.dart` (no `basic_utils`)

**Interfaces:** unchanged public API (`Verifier`, `EcdsaVerifier`, `DesktopIdentity`, `generateDesktopIdentity`, `parseDesktopIdentity`, `certFingerprintB64Url`, `pcIdFromFingerprint`). Internals:
- `verify`: parse SPKI DER with `ASN1Parser` (`package:pointycastle/asn1.dart`): SEQUENCE { SEQUENCE { OID ecPublicKey, OID prime256v1 }, BIT STRING point } → `ECPublicKey(curve.decodePoint(bits), ECCurve_secp256r1())`; parse DER signature SEQUENCE { INTEGER r, INTEGER s } → `ECSignature`; `Signer('SHA-256/ECDSA')..init(false, PublicKeyParameter(pub))`.`verifySignature(bytes, sig)`. Any exception ⇒ `false`.
- `TestKeys.sign`: `Signer('SHA-256/ECDSA')` with `ParametersWithRandom(PrivateKeyParameter(priv), SecureRandom('Fortuna')..seed(...))`, DER-encode `ECSignature` with `ASN1Sequence`/`ASN1Integer`. `pubSpkiB64`: build the SPKI SEQUENCE with `ASN1ObjectIdentifier.fromIdentifierString('1.2.840.10045.2.1')`, `'1.2.840.10045.3.1.7'`, `ASN1BitString(stringValues: pub.Q!.getEncoded(false))`.
- `generateDesktopIdentity`: build an X.509 v3 self-signed certificate with pointycastle ASN.1: `tbsCertificate` = SEQUENCE { [0] EXPLICIT INTEGER 2, INTEGER serial (random 16 bytes, positive), SEQUENCE { OID 1.2.840.10045.4.3.2 (ecdsa-with-SHA256) }, Name(CN=pcName, O=BioKey), Validity(UTCTime now-1 day, GeneralizedTime now+10 y), same Name, SPKI, [3] EXPLICIT Extensions { basicConstraints CA:FALSE critical; subjectAltName DNS:localhost (harmless) } }; signature = ECDSA-SHA256 over the DER of tbsCertificate, DER-encoded; certificate = SEQUENCE { tbs, sigAlg, BIT STRING sig }. PEM-wrap. Private key PEM = PKCS#8 (`ASN1PrivateKeyInfo` stays, it is pointycastle).
- Tests: the existing `identity_test.dart` real-TLS handshake is the oracle (dart:io/BoringSSL must accept the cert). Add `identity_x509_test.dart`: parse the generated DER back with `ASN1Parser`, assert version 2, sigAlg OID, CN, validity order, and that `X509Certificate` from a real `HttpClient` handshake reports `subject` containing `CN=<pcName>`.

- [ ] **Step 1: Write the failing X.509 test** (as described; the TLS handshake test already exists).
- [ ] **Step 2: Implement `verify.dart`, `identity.dart`, `test_keys.dart` without `basic_utils`** (delete every `basic_utils` import in `lib/` and `test/`; `grep -r basic_utils lib test` must be empty).
- [ ] **Step 3: `flutter analyze && flutter test`** — all crypto, session, server and link tests green (they all use `TestKeys`).
- [ ] **Step 4: Commit** — `refactor(core): pointycastle-only ECDSA verify and X.509 identity`

---

### Task 3: Desktop TLS server (replaces WsServer)

**Files:**
- Create: `lib/desktop/server/tls_server.dart`
- Delete: `lib/desktop/server/ws_server.dart` (after Task 4 ports the client; keep until then)
- Test: `test/desktop/tls_server_test.dart` (port of `ws_server_test.dart`)

**Interfaces:**
- Produces: `abstract interface class LinkServerApi { Future<void> start({String address = '0.0.0.0', required int port}); int get port; Future<void> stop(); void apply(List<DesktopEffect> fx); }` (rename of `WsServerApi`; keep a `typedef WsServerApi = LinkServerApi` until Task 7 cleans callers).
- `final class TlsServer implements LinkServerApi { TlsServer({required DesktopIdentity identity, required DesktopSession session, required void Function(DesktopEffect) onEffect}); }`
  - `SecureServerSocket.bind(address, port, identity.securityContext())`; per connection id `c<n>`; `socket.transform(FrameDecoder())` → `session.onFrame(id, payload)`; any `FramingException`/error ⇒ close; `SendFrame` ⇒ `socket.add(encodeFrame(frame))`; `CloseConn` ⇒ `destroy()`; done/error ⇒ `session.onDisconnect(id)` once.
  - Keep: 1 s `tick`, 45 s protocol `ping` to the phone connection, unauthenticated idle close 10 s (120 s after `pair_challenge`), cap 8 connections, TCP keep-alive on (`socket.setOption(SocketOption.tcpNoDelay, true)`), and an application-level liveness rule: if no frame (any) from the phone connection for 60 s, close it (replaces WebSocket ping/pong at transport level).
- Test helper (also used by Task 4): `Future<SecureSocket> connectPinned({required String host, required int port, required String fingerprint})` — for the test, inline the pinned connect: `SecureSocket.connect(host, port, context: SecurityContext(withTrustedRoots: false), onBadCertificate: (c) => certFingerprintB64Url(c.der) == fingerprint, timeout: 4 s)`.

- [ ] **Step 1: Port the test**: same scenarios as `ws_server_test.dart` (wrong fingerprint fails handshake with no protocol bytes; pair then auth over real TLS; malformed frame gets the socket closed; oversized length prefix gets the socket closed; connection cap) using `FrameDecoder` on the client side and `encodeFrame` for sends.
- [ ] **Step 2: Implement `tls_server.dart`.**
- [ ] **Step 3: Run + analyze; commit** — `feat(desktop): raw TLS frame server`

---

### Task 4: Phone pinned TLS client (replaces WebSocket in PcLink)

**Files:**
- Modify: `lib/phone/net/pinned_socket.dart` (returns `SecureSocket`), `lib/phone/net/pc_link.dart`
- Test: `test/phone/pinned_socket_test.dart`, `test/phone/pc_link_test.dart` (ported to `TlsServer`)

**Interfaces:**
- `Future<SecureSocket> connectPinned({required String host, required int port, required String fingerprint})` — `SecurityContext(withTrustedRoots: false)`, `onBadCertificate` pin, 4 s timeout, IPv6 hosts passed as-is (no URL now), `tcpNoDelay`.
- `PcLink`: `Connect` typedef now yields a `SecureSocket`; reads `socket.transform(FrameDecoder())`, writes `socket.add(encodeFrame(frame))`; keeps the generation/backoff/wake/pending-host/non-blocking-read logic unchanged; the transport liveness: send a protocol `ping` every 30 s when idle and close if no frame for 60 s (mirror of the server rule).
- `PcLink.pair`: same flow over `SecureSocket`; deterministic close = `await socket.close()` then wait for `done` (bounded 5 s).

- [ ] **Step 1: Port `pc_link_test.dart` and `pinned_socket_test.dart` to `TlsServer`** (scenarios unchanged, including server restart, bogus resolved host, stop-during-backoff, start/stop/start/stop).
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Delete `ws_server.dart`/`ws_server_test.dart`; point `DesktopController` at `TlsServer` (`serverFactory` default). `flutter analyze && flutter test`.**
- [ ] **Step 4: Commit** — `feat(phone): pinned raw TLS link`

---

### Task 5: UDP discovery in dart:io (replaces bonsoir)

**Files:**
- Create: `lib/core/discovery/udp_discovery.dart`
- Modify: `lib/desktop/server/mdns_advertiser.dart` → rename to `lib/desktop/server/discovery_responder.dart`; `lib/phone/net/mdns_finder.dart` → `lib/phone/net/discovery_finder.dart`
- Test: `test/core/discovery/udp_discovery_test.dart` (loopback)

**Interfaces:**
- `const int discoveryPort = 47623;` Request datagram: `BIOKEY1?` (ASCII). Response: `BIOKEY1 <pcId> <tcpPort> <name-b64url>`.
- `final class DiscoveryResponder { Future<void> start({required String pcId, required String name, required int tcpPort, InternetAddress? bind}); Future<void> stop(); }` — `RawDatagramSocket.bind(anyIPv4, discoveryPort, reuseAddress: true)`; answers only exact `BIOKEY1?` requests (ignores everything else, no echo of attacker data); rate-limit 20 replies/s.
- `final class DiscoveryFinder { Future<String?> resolveHost(String pcId, {Duration timeout = const Duration(seconds: 3), List<InternetAddress>? targets}); }` — sends `BIOKEY1?` to `255.255.255.255:47623` and to each interface's subnet-directed broadcast (compute from `NetworkInterface.list` addresses; assume /24 when the prefix is unknown), `broadcastEnabled = true`; collects replies until timeout; returns the sender address of the first reply whose `pcId` matches (and whose `tcpPort` equals the stored port — otherwise ignore). Returns `null` on timeout.
- Same signature as the old `MdnsFinder.resolveHost` so `PcLink`'s `resolveHost` injection is untouched.

- [ ] **Step 1: Failing loopback test**: responder bound to `127.0.0.1` on a random port (make the port injectable for tests), finder with `targets: [127.0.0.1:port]` resolves the pcId; a responder with another pcId is ignored; a reply with a wrong tcpPort is ignored; garbage datagrams do not crash the responder.
- [ ] **Step 2: Implement.** Android note: sending broadcast needs no multicast lock; keep the manifest as is.
- [ ] **Step 3: Wire**: `DesktopController` uses `DiscoveryResponder`; the phone coordinator uses `DiscoveryFinder`. `flutter analyze && flutter test`.
- [ ] **Step 4: Commit** — `feat(discovery): UDP broadcast discovery in dart:io`

---

### Task 6: Manual host per PC (off-LAN via the user's tunnel)

**Files:**
- Modify: `lib/phone/ui/computers_screen.dart` (tile menu « Modifier l'adresse… »), `lib/phone/phone_controller.dart` (`setHost(pcId, host)` command → coordinator → `PhoneStore.upsertPc` + link restart), `lib/phone/service/link_coordinator.dart`
- Modify: `README.md` (section « Hors de chez soi » / "Away from home": install WireGuard or Tailscale on both devices, put the PC's tunnel IP or MagicDNS name in « Modifier l'adresse »; the pinned certificate and the fingerprint stay the same; no BioKey server involved)
- Test: `test/phone/link_coordinator_test.dart` (setHost restarts the link with the new host, session preserved), widget test for the dialog

- [ ] Steps: failing tests → implement → analyze/test → commit `feat(phone): manual host per PC for tunnel use`

---

### Task 7: Remove libraries and dead code

**Files:**
- Modify: `pubspec.yaml` (remove `bonsoir`, `basic_utils`), `pubspec.lock` via `flutter pub get`
- Delete: any remaining `ws_server*`, `mdns_*` files; rename `WsServerApi` typedef away
- Modify: `android/app/src/main/AndroidManifest.xml` — no change needed (keep `CHANGE_WIFI_MULTICAST_STATE` as the `connectedDevice` prerequisite); remove nothing.

- [ ] `grep -rn "bonsoir\|basic_utils\|WebSocket\|ws_server\|mdns" lib test` must be empty (except comments explaining the change, if any).
- [ ] `flutter pub get && flutter analyze && flutter test && flutter build apk --release` (via `tool/build_release.ps1 -SkipWindows`).
- [ ] Commit — `chore: drop bonsoir and basic_utils`

---

### Task 8: Docs

**Files:**
- Modify: `CAHIER_DES_CHARGES.md` §7.3 heading/transport line, §8 diagram label, §8.2 rows (Transport: `dart:io` TLS + trames; Découverte: UDP broadcast `dart:io`; Certificat/vérification: `pointycastle`), §11 risk row for Linux tray unchanged
- Modify: `CHANGELOG.md` — `## [1.1.0] - <date>`: raw TLS frames, UDP discovery, pointycastle-only, manual host; removed bonsoir/basic_utils
- Modify: `docs/superpowers/plans/2026-09-26-biokey-j1-mvp.md` Task 14 checklist: add "discovery works after the PC changes IP", "manual host through Tailscale/WireGuard"

- [ ] Commit — `docs: J1.1 lean transport`
