import 'dart:async';
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
///
/// The native runner never shows the window by itself
/// (`windows/runner/flutter_window.cpp`): it is shown here, once ready,
/// only for a plain interactive launch — not for the `--hidden` autostart
/// launch at login, nor for a shortcut's `open ID`.
Future<void> runDesktop(List<String> args) async {
  final cmd = parseCli(args);
  final hidden = args.contains(hiddenFlag);
  // A login-time autostart while BioKey already runs has nothing to hand
  // over (forwarding it would pop the window up): just leave.
  if (!hidden && await SingleInstance.forward(args)) {
    exit(0); // a running instance took it
  }

  final kv = FlutterSecureKv();
  final notifier = LocalNotifier();
  await notifier.setup();

  SingleInstance? guard;

  final controller = DesktopController(
    store: DesktopStore(kv),
    apps: AppStore(kv),
    launcher: WindowsLauncher(),
    verifier: const EcdsaVerifier(),
    clock: const SystemClock(),
    notifier: notifier,
    mdns: MdnsAdvertiser(),
    onShowWindow: () {
      unawaited(windowManager.show());
      unawaited(windowManager.focus());
    },
    onDispose: () => unawaited(guard?.dispose()),
  );

  await windowManager.ensureInitialized();

  try {
    guard = await SingleInstance.acquire(onArgs: (a) => unawaited(controller.handleCli(a)));
  } on Object catch (e) {
    await _failStartup(notifier, null, e);
  }
  if (guard == null) {
    if (hidden) exit(0);
    // Lost the bind race: another instance grabbed the port between our
    // own `forward` above (which found nobody listening) and now. Give it
    // one more chance to take this launch before giving up.
    if (await SingleInstance.forward(args)) {
      exit(0);
    }
    await notifier.show('BioKey', 'BioKey est déjà lancé');
    exit(1);
  }

  try {
    await controller.init();
  } on Object catch (e) {
    // Never leave a windowless, trayless process holding the
    // single-instance port: every later launch would forward into it.
    await _failStartup(notifier, guard, e);
  }

  final tray = BioKeyTray(controller);
  await tray.init();

  try {
    // Quoted: the install path may contain spaces. Writes
    // HKCU\...\Run\BioKey = "<exe>" --hidden (same value as the installer).
    launchAtStartup.setup(appName: 'BioKey', appPath: '"${Platform.resolvedExecutable}"', args: const [hiddenFlag]);
    await launchAtStartup.enable();
  } on Object catch (_) {
    // Autostart is non-essential: never block startup on it.
  }

  await windowManager.setPreventClose(true);

  runApp(DesktopApp(controller: controller));

  await windowManager.waitUntilReadyToShow(null, () {
    if (hidden || cmd is OpenApp) return;
    unawaited(windowManager.show());
    unawaited(windowManager.focus());
  });

  if (cmd is OpenApp) {
    await controller.open(cmd.id);
  }
}

Future<Never> _failStartup(LocalNotifier notifier, SingleInstance? guard, Object error) async {
  try {
    await notifier.show('BioKey', "BioKey n'a pas pu démarrer : $error");
  } on Object {
    // Nothing more we can tell the user.
  }
  await guard?.dispose();
  exit(1);
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
