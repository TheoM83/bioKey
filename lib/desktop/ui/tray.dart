import 'dart:async';

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../desktop_controller.dart';

/// System tray icon: status line, one entry per protected app, and the
/// window/quit actions. Rebuilds its menu whenever [DesktopController]
/// notifies (phone connects/disconnects, apps added/removed).
final class BioKeyTray with TrayListener {
  BioKeyTray(this.c);
  final DesktopController c;

  Future<void> init() async {
    await trayManager.setIcon('assets/tray/biokey.ico');
    await trayManager.setToolTip('BioKey');
    trayManager.addListener(this);
    c.addListener(rebuild);
    await rebuild();
  }

  Future<void> rebuild() async {
    final items = <MenuItem>[
      MenuItem(key: 'status', label: c.phoneOnline ? 'Téléphone connecté' : 'Téléphone hors ligne', disabled: true),
      MenuItem.separator(),
      for (final a in c.apps) MenuItem(key: 'open:${a.id}', label: a.label),
      if (c.apps.isNotEmpty) MenuItem.separator(),
      MenuItem(key: 'window', label: 'Ouvrir BioKey…'),
      MenuItem(key: 'quit', label: 'Quitter'),
    ];
    await trayManager.setContextMenu(Menu(items: items));
  }

  @override
  void onTrayIconMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final k = menuItem.key ?? '';
    if (k.startsWith('open:')) {
      unawaited(c.open(k.substring(5)));
    } else if (k == 'window') {
      unawaited(windowManager.show());
      unawaited(windowManager.focus());
    } else if (k == 'quit') {
      dispose();
      c.dispose();
      unawaited(windowManager.destroy());
    }
  }

  void dispose() {
    c.removeListener(rebuild);
    trayManager.removeListener(this);
  }
}
