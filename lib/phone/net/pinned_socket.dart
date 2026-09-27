import 'dart:io';
import 'package:flutter/foundation.dart' show visibleForTesting;
import '../../core/crypto/identity.dart';

/// Connects to the desktop's pinned-TLS raw socket endpoint: the server's
/// leaf certificate is accepted only when its SHA-256 fingerprint matches
/// [fingerprint] (the one embedded in the pairing QR / stored [PairedPc]),
/// never via the platform CA trust store — the desktop's certificate is
/// self-signed.
///
/// `SecurityContext(withTrustedRoots: false)` is load-bearing: without it,
/// any certificate chaining to an installed CA (not just the pinned one)
/// would be accepted *without* even reaching [onBadCertificate]. Starting
/// from an empty trust store forces every certificate — including a
/// legitimately CA-signed one — through the pin check below.
///
/// Defence in depth: `onBadCertificate` can be invoked once per certificate
/// in the chain the peer presents, not only the leaf — a peer presenting
/// `[attacker leaf, genuine cert]` could get `onBadCertificate` called with
/// the *genuine* one, which matches [fingerprint] and would otherwise wave
/// the whole (attacker-controlled) connection through. So after the
/// handshake completes we independently re-check [fingerprint] against
/// `socket.peerCertificate` — which the platform TLS stack guarantees is
/// always the leaf actually presented — and refuse the socket if it
/// disagrees, regardless of what `onBadCertificate` decided.
Future<SecureSocket> connectPinned({
  required String host,
  required int port,
  required String fingerprint,
  // Test-only hook: lets a test simulate onBadCertificate waving through a
  // mismatched cert (as in the attack above) without having to build a
  // real forged certificate chain, so the post-connect re-check below can
  // be exercised as the thing that actually rejects it.
  @visibleForTesting bool Function(X509Certificate cert)? onBadCertificateOverride,
}) async {
  // TLS 1.3 only, matching the server identity's context (see
  // identity.dart) and SECURITY.md/spec §7.1/§7.3 — refuses a downgrade
  // to 1.2 outright rather than merely discouraging it.
  final context = SecurityContext(withTrustedRoots: false)..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3;
  final socket = await SecureSocket.connect(
    host,
    port,
    context: context,
    onBadCertificate: onBadCertificateOverride ?? (cert) => certFingerprintB64Url(cert.der) == fingerprint,
    timeout: const Duration(seconds: 4),
  );
  final peer = socket.peerCertificate;
  if (peer == null || certFingerprintB64Url(peer.der) != fingerprint) {
    socket.destroy();
    throw HandshakeException('pinned certificate fingerprint mismatch (post-connect check)');
  }
  try {
    socket.setOption(SocketOption.tcpNoDelay, true);
  } on Object {
    socket.destroy();
    rethrow;
  }
  return socket;
}
