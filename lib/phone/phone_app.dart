import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart' show ServiceRequestFailure;

import '../core/pairing/qr_payload.dart';
import '../core/storage/phone_store.dart';
import '../core/storage/secure_kv.dart';
import '../platform/flutter_secure_kv.dart';
import 'phone_controller.dart';
import 'service/foreground.dart';
import 'service/foreground_gate.dart';
import 'signer/biometric_signature_signer.dart';
import 'ui/battery_guide.dart';
import 'ui/computers_screen.dart';
import 'ui/full_screen_guide.dart';
import 'ui/scan_screen.dart';

/// Entry point for the phone role (UI isolate).
///
/// The links to paired PCs run in the foreground service's isolate
/// (`startCallback` → `LinkCoordinator`), so they survive this Activity
/// being destroyed and restart on boot. This isolate owns the biometric
/// signer and answers the service's signing requests (see
/// [PhoneController]).
///
/// The foreground service's permission requests and startup are
/// best-effort: a plugin failure there must never prevent the UI itself
/// from showing, so it's caught and surfaced as a banner instead.
Future<void> runPhone() async {
  final kv = FlutterSecureKv();
  final store = PhoneStore(kv);
  // Touch secure storage from this isolate before the service's isolate
  // does, so the two engines never race to create its master key.
  await store.pubKey();
  final gate = ForegroundGate()..attach();
  final signer = BiometricSignatureSigner(store, waitForeground: gate.whenResumed);
  final transport = uiTaskTransport();
  final controller = PhoneController(transport: transport, signer: signer, store: store, gate: gate);
  // Listen before the service starts so its first state isn't missed.
  await controller.init();

  String? serviceError;
  try {
    await requestForegroundPermissions();
    final result = await startForegroundService(transport: transport);
    if (result is ServiceRequestFailure) serviceError = '${result.error}';
  } on Object catch (e) {
    serviceError = '$e';
  }

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
/// when the UI is torn down: it detaches from the service (whose links keep
/// running) and from the foreground gate.
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
    if (!mounted) return;
    await maybeShowFullScreenGuide(context, widget.kv);
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
        onRevoke: (pcId) => unawaited(_revoke(context, pcId)),
        onSetHost: (pcId, host) => unawaited(_setHost(context, pcId, host)),
      ),
    );
  }

  Future<void> _revoke(BuildContext context, String pcId) async {
    try {
      await widget.controller.revoke(pcId);
    } on Object catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Révocation échouée : ${e is StateError ? e.message : e}')),
      );
    }
  }

  Future<void> _setHost(BuildContext context, String pcId, String host) async {
    try {
      await widget.controller.setHost(pcId, host);
    } on Object catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Modification de l'adresse échouée : ${e is StateError ? e.message : e}")),
      );
    }
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
        SnackBar(content: Text('Appairage échoué : ${e is StateError ? e.message : e}')),
      );
    }
  }
}
