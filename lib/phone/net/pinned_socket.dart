import 'dart:io';
import '../../core/crypto/identity.dart';

/// Connects to the desktop's pinned-TLS WebSocket endpoint: the server's
/// leaf certificate is accepted only when its SHA-256 fingerprint matches
/// [fingerprint] (the one embedded in the pairing QR / stored [PairedPc]),
/// never via the platform CA trust store — the desktop's certificate is
/// self-signed.
Future<WebSocket> connectPinned({required String host, required int port, required String fingerprint}) {
  final c = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4)
    ..badCertificateCallback = (cert, _, _) => certFingerprintB64Url(cert.der) == fingerprint;
  return WebSocket.connect('wss://$host:$port/', customClient: c);
}
