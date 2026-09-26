import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../core/storage/secure_kv.dart';

const _fullScreenGuideShownKey = 'fullScreenGuideShown';
const _system = MethodChannel('biokey/system');

/// Whether auth notifications may launch BioKey full screen (always true
/// before Android 14; afterwards the user or the store may revoke it).
Future<bool> canUseFullScreenIntent() async {
  if (!Platform.isAndroid) return true;
  try {
    return await _system.invokeMethod<bool>('canUseFullScreenIntent') ?? true;
  } on Object {
    return true;
  }
}

/// On Android 14+, if full-screen notifications are not allowed, shows a
/// one-time guide « Autoriser les alertes plein écran » whose button opens
/// the system setting: without it an auth request can't bring BioKey up
/// over the lock screen.
Future<void> maybeShowFullScreenGuide(BuildContext context, SecureKv kv, {Future<bool> Function()? check}) async {
  if (await kv.read(_fullScreenGuideShownKey) != null) return;
  if (await (check ?? canUseFullScreenIntent)()) return;
  await kv.write(_fullScreenGuideShownKey, '1');
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Autoriser les alertes plein écran'),
      content: const Text(
        'Pour que BioKey puisse vous demander votre empreinte même écran verrouillé, '
        'autorisez-le à afficher des alertes en plein écran.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Plus tard'),
        ),
        FilledButton(
          onPressed: () async {
            Navigator.pop(dialogContext);
            await FlutterLocalNotificationsPlugin()
                .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
                ?.requestFullScreenIntentPermission();
          },
          child: const Text('Autoriser'),
        ),
      ],
    ),
  );
}
