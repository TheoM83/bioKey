import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/core/crypto/identity.dart';
import 'package:biokey/core/crypto/verify.dart';
import 'package:biokey/core/session/clock.dart';
import 'package:biokey/core/session/desktop_session.dart';
import 'package:biokey/desktop/server/tls_server.dart';
import 'package:biokey/phone/net/pinned_socket.dart';

/// `connectPinned` is what actually decides whether a certificate is
/// trusted: this exercises it directly (not just through the higher-level
/// pairing/link flows already covered in pc_link_test.dart) with two real,
/// independently-generated desktop identities, so a bug that accidentally
/// falls back to the system trust store (accepting *any* well-formed
/// certificate) would show up here even though every cert involved is
/// otherwise perfectly valid.
///
/// Note: `connectPinned` connects with `SecurityContext(withTrustedRoots:
/// false)` (see pinned_socket.dart) — without that, a default
/// `SecureSocket.connect` consults the platform's system trust store
/// *before* `onBadCertificate` ever runs, so a CA-chained certificate would
/// be accepted regardless of fingerprint. Both identities here are
/// self-signed (like the real desktop's), so this test wouldn't catch that
/// specific regression by itself; it is covered by reading the code (see
/// the report) rather than by a runnable assertion, since simulating a
/// CA-trusted chain in a unit test isn't practical.
void main() {
  test('a real desktop cert pinned to a different identity\'s fingerprint is rejected', () async {
    final servedIdentity = generateDesktopIdentity(pcName: 'served');
    final otherIdentity = generateDesktopIdentity(pcName: 'other');
    final session = DesktopSession(pcId: servedIdentity.pcId, pcName: 'served', verifier: const EcdsaVerifier(), clock: const SystemClock());
    final server = TlsServer(identity: servedIdentity, session: session, onEffect: (_) {});
    await server.start(address: '127.0.0.1', port: 0);
    addTearDown(server.stop);

    expect(
      connectPinned(host: '127.0.0.1', port: server.port, fingerprint: otherIdentity.fingerprintB64Url).timeout(const Duration(seconds: 5)),
      throwsA(anything),
    );
  });

  test('the matching fingerprint connects', () async {
    final identity = generateDesktopIdentity(pcName: 'PC');
    final session = DesktopSession(pcId: identity.pcId, pcName: 'PC', verifier: const EcdsaVerifier(), clock: const SystemClock());
    final server = TlsServer(identity: identity, session: session, onEffect: (_) {});
    await server.start(address: '127.0.0.1', port: 0);
    addTearDown(server.stop);

    final socket = await connectPinned(host: '127.0.0.1', port: server.port, fingerprint: identity.fingerprintB64Url).timeout(const Duration(seconds: 5));
    await socket.close();
  });
}
