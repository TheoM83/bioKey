import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/pairing/qr_payload.dart';

/// Scans a BioKey pairing QR code and pops with the parsed [QrPayload] once
/// one is found — or shows a SnackBar and keeps scanning if the code isn't a
/// BioKey QR.
final class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  var _handled = false;

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;
    final raw = barcodes.first.rawValue;
    if (raw == null) return;
    try {
      final payload = QrPayload.parse(raw);
      _handled = true;
      Navigator.pop(context, payload);
    } on FormatException {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Ce QR n'est pas un QR BioKey")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scanner un QR')),
      body: MobileScanner(onDetect: _onDetect),
    );
  }
}
