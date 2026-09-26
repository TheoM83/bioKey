import 'dart:io';

import 'package:flutter/material.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:window_manager/window_manager.dart';

import '../core/crypto/verify.dart';
import '../core/session/clock.dart';
import '../core/storage/desktop_store.dart';
import '../platform/flutter_secure_kv.dart';
import 'apps/app_store.dart';
import 'apps/cli.dart';
import 'apps/launcher.dart';
import 'apps/single_instance.dart';
import 'desktop_controller.dart';
import 'notify.dart';
import 'server/mdns_advertiser.dart';
import 'ui/main_window.dart';
import 'ui/tray.dart';

/// Entry point for the desktop role: single-instance guard, identity +
/// server + tray + window wiring, autostart registration, then handles the
/// CLI command this launch was invoked with (a protected-shortcut "open ID"
/// or a plain window show).
Future<void> runDesktop(List<String> args) async {
  final cmd = parseCli(args);
  if (await SingleInstance.forward(args)) {
    exit(0); // a running instance took it
  }

  final kv = FlutterSecureKv();
  final notifier = LocalNotifier();
  await notifier.setup();

  final controller = DesktopController(
    store: DesktopStore(kv),
    apps: AppStore(kv),
    launcher: WindowsLauncher(),
    verifier: const EcdsaVerifier(),
    clock: const SystemClock(),
    notifier: notifier,
    mdns: MdnsAdvertiser(),
  );

  await windowManager.ensureInitialized();
  await SingleInstance.acquire(onArgs: (a) => controller.handleCli(a));
  await controller.init();

  final tray = BioKeyTray(controller);
  await tray.init();

  launchAtStartup.setup(appName: 'BioKey', appPath: Platform.resolvedExecutable);
  await launchAtStartup.enable();

  await windowManager.setPreventClose(true);

  runApp(DesktopApp(controller: controller));

  if (cmd is OpenApp) {
    await controller.open(cmd.id);
    await windowManager.hide();
  } else {
    await windowManager.show();
  }
}

final class DesktopApp extends StatelessWidget {
  const DesktopApp({super.key, required this.controller});
  final DesktopController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BioKey',
      theme: ThemeData(colorSchemeSeed: const Color(0xFFD71921), useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: const Color(0xFFD71921), brightness: Brightness.dark, useMaterial3: true),
      home: MainWindow(controller: controller),
    );
  }
}
