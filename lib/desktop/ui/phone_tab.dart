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
                    const SizedBox(height: 12),
                    // Always offered: a QR that expired, or whose token was
                    // consumed by a pairing attempt that failed, is dead.
                    OutlinedButton(
                      onPressed: controller.startPairing,
                      child: const Text('Nouveau QR'),
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
                  if (controller.phoneNeedsRepair) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Appairage invalide — scannez à nouveau le QR',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: controller.repairPhone,
                      child: const Text('Nouveau QR'),
                    ),
                  ],
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
