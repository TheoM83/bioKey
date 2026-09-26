import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../desktop_controller.dart';

/// Pairing / paired-phone status tab: shows a QR code to pair a new phone,
/// or the paired phone's status with a revoke button.
final class PhoneTab extends StatelessWidget {
  const PhoneTab({super.key, required this.controller});
  final DesktopController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final phone = controller.phone;
        if (phone == null) {
          final qr = controller.pairingQr;
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (qr == null)
                    FilledButton(
                      onPressed: controller.startPairing,
                      child: const Text("Afficher le QR d'appairage"),
                    )
                  else ...[
                    QrImageView(data: qr.toUri().toString(), size: 280),
                    const SizedBox(height: 16),
                    const Text(
                      'Scannez avec BioKey sur votre téléphone (valide 2 min)',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ),
          );
        }
        return Center(
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${phone.name} · ${controller.phoneOnline ? 'connecté' : 'hors ligne'}'),
                  const SizedBox(height: 16),
                  FilledButton.tonal(
                    onPressed: controller.revokePhone,
                    child: const Text('Révoquer'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
