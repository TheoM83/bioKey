import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../desktop_controller.dart';
import 'apps_tab.dart';
import 'phone_tab.dart';

/// The main BioKey window: closing it hides it to the tray instead of
/// quitting the app, which keeps the TLS link server and mDNS
/// advertisement running in the background.
final class MainWindow extends StatefulWidget {
  const MainWindow({super.key, required this.controller});
  final DesktopController controller;

  @override
  State<MainWindow> createState() => _MainWindowState();
}

class _MainWindowState extends State<MainWindow> with WindowListener {
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() {
    unawaited(windowManager.hide());
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('BioKey'),
          bottom: const TabBar(tabs: [Tab(text: 'Téléphone'), Tab(text: 'Apps')]),
        ),
        body: TabBarView(
          children: [
            PhoneTab(controller: widget.controller),
            AppsTab(controller: widget.controller),
          ],
        ),
      ),
    );
  }
}
