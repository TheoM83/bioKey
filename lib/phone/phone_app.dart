import 'dart:async';

import 'package:flutter/material.dart';

import '../core/pairing/qr_payload.dart';
import '../core/session/clock.dart';
import '../core/storage/phone_store.dart';
import '../core/storage/secure_kv.dart';
import '../platform/flutter_secure_kv.dart';
import 'net/mdns_finder.dart';
import 'net/pc_link.dart';
import 'phone_controller.dart';
import 'service/foreground.dart';
import 'service/foreground_gate.dart';
import 'signer/biometric_signature_signer.dart';
import 'ui/battery_guide.dart';
import 'ui/computers_screen.dart';
import 'ui/scan_screen.dart';

/// Entry point for the phone role: wires secure storage, the biometric
/// signer, the reconnecting-link controller and the Android foreground
/// service together, then runs the UI.
///
/// The foreground service's permission requests and startup are
/// best-effort: a plugin failure there (missing permission, OS quirk, …)
/// must never prevent the UI itself from showing, so it's caught and
/// surfaced as a banner instead of propagating.
Future<void> runPhone() async {
  final kv = FlutterSecureKv();
  final store = PhoneStore(kv);
  final gate = ForegroundGate()..attach();
  final signer = BiometricSignatureSigner(store, waitForeground: gate.whenResumed);
  final controller = PhoneController(
    store: store,
    signer: signer,
    clock: const SystemClock(),
    gate: gate,
    linkFactory: (pc, session, onEffect) =>
        PcLink(pc: pc, session: session, onEffect: onEffect, resolveHost: MdnsFinder().resolveHost),
  );

  String? serviceError;
  try {
    await requestForegroundPermissions();
    await startForegroundService();
  } on Object catch (e) {
    serviceError = '$e';
  }

  await controller.init();
  runApp(PhoneApp(controller: controller, kv: kv, serviceError: serviceError));
}

final class PhoneApp extends StatefulWidget {
  const PhoneApp({super.key, required this.controller, required this.kv, this.serviceError});

  final PhoneController controller;
  final SecureKv kv;
  final String? serviceError;

  @override
  State<PhoneApp> createState() => _PhoneAppState();
}

/// Observes app lifecycle at the root so [PhoneController.shutdown] runs
/// when the app is torn down — the plan requires every link stopped and
/// every pending auth notification cancelled before disposal, which
/// [PhoneController.dispose] alone can't guarantee since
/// `ChangeNotifier.dispose()` is synchronous (see its own doc comment).
class _PhoneAppState extends State<PhoneApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.detached) return;
    // `didChangeAppLifecycleState` is synchronous, so shutdown() can't be
    // awaited here — it's fired and left to run best-effort. This hook is
    // itself best-effort on Android: the OS usually kills the process
    // outright (without ever delivering `detached`, let alone giving this
    // callback time to run) rather than giving the app a chance to react,
    // so this mainly helps on lifecycles that do deliver it cleanly
    // (iOS, desktop-hosted runs, an app-initiated exit).
    unawaited(widget.controller.shutdown());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Best-effort backstop for a disposal that didn't go through a
    // `detached` lifecycle event: dispose() itself fires shutdown()
    // un-awaited (see its doc comment).
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BioKey',
      theme: ThemeData(colorSchemeSeed: const Color(0xFFD71921), useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: const Color(0xFFD71921), brightness: Brightness.dark, useMaterial3: true),
      home: _PhoneHome(controller: widget.controller, kv: widget.kv, serviceError: widget.serviceError),
    );
  }
}

class _PhoneHome extends StatefulWidget {
  const _PhoneHome({required this.controller, required this.kv, this.serviceError});

  final PhoneController controller;
  final SecureKv kv;
  final String? serviceError;

  @override
  State<_PhoneHome> createState() => _PhoneHomeState();
}

class _PhoneHomeState extends State<_PhoneHome> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_onFirstFrame()));
  }

  Future<void> _onFirstFrame() async {
    if (!mounted) return;
    if (widget.serviceError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Service d'arrière-plan indisponible")),
      );
    }
    await maybeShowBatteryGuide(context, widget.kv);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) => ComputersScreen(
        pcs: widget.controller.pcs,
        isOnline: widget.controller.isOnline,
        needsRepair: widget.controller.needsRepair,
        onScan: () => unawaited(_scan(context)),
        onRevoke: (pcId) => unawaited(widget.controller.revoke(pcId)),
      ),
    );
  }

  Future<void> _scan(BuildContext context) async {
    final payload = await Navigator.push<QrPayload>(
      context,
      MaterialPageRoute<QrPayload>(builder: (_) => const ScanScreen()),
    );
    if (payload == null) return;
    try {
      await widget.controller.pair(payload);
    } on Object catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Appairage échoué : $e')),
      );
    }
  }
}
