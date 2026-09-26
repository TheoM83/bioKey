import 'dart:io';
import '../../core/crypto/identity.dart';

/// Connects to the desktop's pinned-TLS WebSocket endpoint: the server's
/// leaf certificate is accepted only when its SHA-256 fingerprint matches
/// [fingerprint] (the one embedded in the pairing QR / stored [PairedPc]),
/// never via the platform CA trust store — the desktop's certificate is
/// self-signed.
///
/// `SecurityContext(withTrustedRoots: false)` is load-bearing: a plain
/// `HttpClient()` falls back to the platform's system trust store, so any
/// certificate chaining to an installed CA (not just the pinned one) would
/// be accepted *without* even reaching [badCertificateCallback]. Starting
/// from an empty trust store forces every certificate — including a
/// legitimately CA-signed one — through the pin check below.
Future<WebSocket> connectPinned({required String host, required int port, required String fingerprint}) async {
  final c = HttpClient(context: SecurityContext(withTrustedRoots: false))
    ..connectionTimeout = const Duration(seconds: 4)
    ..badCertificateCallback = (cert, _, _) => certFingerprintB64Url(cert.der) == fingerprint;
  // IPv6 literals must be bracketed in a URI authority (`[::1]`, not `::1`).
  final authority = host.contains(':') ? '[$host]' : host;
  final ws = await WebSocket.connect('wss://$authority:$port/', customClient: c);
  // A silent Wi-Fi drop leaves a TCP socket that never sees a FIN/RST; the
  // periodic ping/pong forces the connection to fail (and the `await for`
  // in PcLink to end) within a bounded time instead of hanging forever.
  ws.pingInterval = const Duration(seconds: 30);
  return ws;
}
