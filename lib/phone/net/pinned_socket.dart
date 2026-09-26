import 'dart:io';
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
Future<SecureSocket> connectPinned({required String host, required int port, required String fingerprint}) async {
  final socket = await SecureSocket.connect(
    host,
    port,
    context: SecurityContext(withTrustedRoots: false),
    onBadCertificate: (cert) => certFingerprintB64Url(cert.der) == fingerprint,
    timeout: const Duration(seconds: 4),
  );
  socket.setOption(SocketOption.tcpNoDelay, true);
  return socket;
}
