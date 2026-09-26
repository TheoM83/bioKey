import 'dart:async';
import 'dart:io' show Platform;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../apps/protected_app.dart';
import '../apps/shortcuts.dart';
import '../desktop_controller.dart';

/// Protected-apps list: drag-and-drop or file-picker to add an app, per-app
/// unlock duration, shortcut creation, and removal.
final class AppsTab extends StatelessWidget {
  const AppsTab({super.key, required this.controller});
  final DesktopController controller;

  static const _unlockChoices = [0, 5, 15, 60];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          return DropTarget(
            onDragDone: (details) async {
              for (final f in details.files) {
                await controller.addApp(f.path);
              }
            },
            child: controller.apps.isEmpty
                ? const Center(child: Text('Glissez une application ici, ou ajoutez-en une.'))
                : ListView.builder(
                    itemCount: controller.apps.length,
                    itemBuilder: (context, i) => _AppRow(controller: controller, app: controller.apps[i]),
                  ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['exe', 'lnk']);
          final files = result?.files ?? const <PlatformFile>[];
          final path = files.length == 1 ? files.first.path : null;
          if (path != null) await controller.addApp(path);
        },
        label: const Text('Ajouter une app'),
        icon: const Icon(Icons.add),
      ),
    );
  }
}

class _AppRow extends StatelessWidget {
  const _AppRow({required this.controller, required this.app});
  final DesktopController controller;
  final ProtectedApp app;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(app.label),
      subtitle: Text(app.target),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButton<int>(
            value: AppsTab._unlockChoices.contains(app.unlockMinutes) ? app.unlockMinutes : 0,
            items: [
              for (final m in AppsTab._unlockChoices) DropdownMenuItem(value: m, child: Text(m == 0 ? 'Toujours demander' : '$m min')),
            ],
            onChanged: (m) {
              if (m != null) unawaited(controller.setUnlockMinutes(app.id, m));
            },
          ),
          TextButton(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              try {
                await createProtectedShortcut(app: app, exePath: Platform.resolvedExecutable);
                messenger.showSnackBar(const SnackBar(content: Text('Raccourci créé sur le Bureau')));
              } on Object catch (e) {
                messenger.showSnackBar(SnackBar(content: Text(_shortcutErrorMessage(e))));
              }
            },
            child: const Text('Créer le raccourci'),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => controller.removeApp(app.id),
          ),
        ],
      ),
    );
  }
}

/// [createProtectedShortcut] already throws an `Exception` whose message
/// reads "Création du raccourci impossible : details"; strip the
/// `Exception: ` wrapper `Object.toString()` adds instead of re-wrapping
/// the prefix a second time.
String _shortcutErrorMessage(Object e) {
  final s = e.toString();
  const prefix = 'Exception: ';
  return s.startsWith(prefix) ? s.substring(prefix.length) : s;
}
