import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../../core/storage/secure_kv.dart';

const _batteryGuideShownKey = 'batteryGuideShown';

/// Shows a one-time dialog (on the phone role's first launch) explaining
/// why BioKey needs an exemption from battery optimization to keep
/// receiving auth requests while backgrounded, with a button that opens the
/// system setting for it. Never shown again once [kv] records it was seen.
Future<void> maybeShowBatteryGuide(BuildContext context, SecureKv kv) async {
  final alreadyShown = await kv.read(_batteryGuideShownKey);
  if (alreadyShown != null) return;
  await kv.write(_batteryGuideShownKey, '1');
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('BioKey'),
      content: const Text(
        "Pour recevoir les demandes même en veille, autorisez BioKey à ignorer l'optimisation de batterie.",
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Plus tard'),
        ),
        FilledButton(
          onPressed: () async {
            Navigator.pop(dialogContext);
            await FlutterForegroundTask.requestIgnoreBatteryOptimization();
          },
          child: const Text('Autoriser'),
        ),
      ],
    ),
  );
}
