import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/crypto/identity.dart';
import '../core/crypto/verify.dart';
import '../core/pairing/qr_payload.dart';
import '../core/session/clock.dart';
import '../core/session/desktop_session.dart';
import '../core/storage/desktop_store.dart';
import 'apps/app_store.dart';
import 'apps/cli.dart';
import 'apps/launcher.dart';
import 'apps/protected_app.dart';
import 'notify.dart';
import 'server/discovery_responder.dart';
import 'server/lan.dart';
import 'server/tls_server.dart';

/// Wires the pure [DesktopSession] state machine to the [LinkServerApi],
/// [AppStore], [AppLauncher] and [Notifier], and exposes the desktop role's
/// state (paired phone, protected apps, pairing QR) to the tray/window UI
/// as a [ChangeNotifier].
final class DesktopController extends ChangeNotifier {
  DesktopController({
    required DesktopStore store,
    required AppStore apps,
    required AppLauncher launcher,
    required Verifier verifier,
    required Clock clock,
    required Notifier notifier,
    LinkServerApi Function(DesktopIdentity identity, DesktopSession session, void Function(DesktopEffect) onEffect)? serverFactory,
    DiscoveryApi? discovery,
    void Function()? onShowWindow,
    void Function()? onDispose,
    Duration phoneWait = const Duration(seconds: 5),
    Future<String?> Function() lanAddress = primaryLanIPv4,
  })  : _store = store,
        _phoneWait = phoneWait,
        _apps = apps,
        _launcher = launcher,
        _verifier = verifier,
        _clock = clock,
        _notifier = notifier,
        _serverFactory = serverFactory,
        _discovery = discovery,
        _onShowWindow = onShowWindow,
        _onDispose = onDispose,
        _lanAddress = lanAddress,
        _unlock = UnlockCache(clock);

  final DesktopStore _store;
  final AppStore _apps;
  final AppLauncher _launcher;
  final Verifier _verifier;
  final Clock _clock;
  final Notifier _notifier;
  final LinkServerApi Function(DesktopIdentity, DesktopSession, void Function(DesktopEffect))? _serverFactory;
  final DiscoveryApi? _discovery;
  final void Function()? _onShowWindow;
  final void Function()? _onDispose;

  /// The LAN IPv4 address put in the pairing QR; overridable in tests so
  /// `startPairing` doesn't depend on the test machine actually having a
  /// LAN interface (see [primaryLanIPv4]).
  final Future<String?> Function() _lanAddress;
  final UnlockCache _unlock;

  /// How long [open] waits for a paired-but-offline phone to (re)connect
  /// before giving up with `noPhone` — covers the PC having just started
  /// while the phone's link is still in its reconnect backoff.
  final Duration _phoneWait;

  late DesktopIdentity _identity;
  late DesktopSession _session;
  late LinkServerApi _server;

  List<ProtectedApp> _appsCache = <ProtectedApp>[];
  PairedPhone? _phone;
  bool _online = false;
  QrPayload? _pairingQr;
  bool _disposed = false;
  bool _initialized = false;
  bool _serverCreated = false;
  bool _needsRepair = false;
  final _authToApp = <String, String>{};

  /// CLI commands forwarded by a second launch (single-instance guard)
  /// before [init] finished: replayed, in order, once it has.
  final _queuedCli = <List<String>>[];

  /// Completed (with `true`) as soon as the phone comes online; see [open].
  final _onlineWaiters = <Completer<bool>>[];

  String get pcId => _identity.pcId;
  QrPayload? get pairingQr => _pairingQr;
  bool get phoneOnline => _online;
  PairedPhone? get phone => _phone;

  /// The paired phone presented a key/session that no longer matches the
  /// stored pairing (see `PairingInvalid`): the Téléphone tab asks the user
  /// to re-pair.
  bool get phoneNeedsRepair => _needsRepair;
  List<ProtectedApp> get apps => List.unmodifiable(_appsCache);

  Future<void> init() async {
    final pcName = await _store.pcName();
    final saved = await _store.identity();
    if (saved == null) {
      _identity = generateDesktopIdentity(pcName: pcName);
      await _store.saveIdentity(_identity.certPem, _identity.keyPem);
    } else {
      _identity = parseDesktopIdentity(certPem: saved.certPem, keyPem: saved.keyPem);
    }

    _phone = await _store.pairedPhone();
    _online = false;
    _session = DesktopSession(pcId: _identity.pcId, pcName: pcName, verifier: _verifier, clock: _clock, phone: _phone);

    final factory = _serverFactory ?? (DesktopIdentity id, DesktopSession s, void Function(DesktopEffect) onEffect) => TlsServer(identity: id, session: s, onEffect: onEffect);
    _server = factory(_identity, _session, _onEffect);
    _serverCreated = true;
    await _server.start(port: await _store.port());
    try {
      await _discovery?.start(pcId: _identity.pcId, name: pcName, tcpPort: _server.port);
    } on Object {
      // Discovery is a convenience (auto-find on the LAN), not a
      // requirement: pairing by QR code (which carries the host directly)
      // and typing a manual address both still work without it. A bind
      // failure here (e.g. port 47623 already held by another process)
      // must not abort the rest of startup.
      unawaited(_notifier.show('BioKey', 'Découverte réseau indisponible (port 47623 occupé) — l\'appairage par QR et l\'adresse manuelle fonctionnent'));
    }

    _appsCache = await _apps.all();
    _initialized = true;
    _notify();

    final queued = List<List<String>>.of(_queuedCli);
    _queuedCli.clear();
    for (final args in queued) {
      await handleCli(args);
    }
  }

  Future<void> startPairing() async {
    _session.startPairing();
    final host = await _lanAddress();
    if (host == null) {
      await _notifier.show('BioKey', 'Aucun réseau local détecté — connectez le PC au Wi-Fi ou au câble');
      return;
    }
    _pairingQr = QrPayload(
      pcId: _identity.pcId,
      name: await _store.pcName(),
      host: host,
      port: _server.port,
      fingerprint: _identity.fingerprintB64Url,
      token: _session.pairingToken!,
    );
    _notify();
  }

  /// Forgets the paired phone *and* drops its live connection (and any
  /// pending auth request): a revoked phone must not keep answering on a
  /// socket it authenticated before the revocation.
  Future<void> revokePhone() async {
    await _store.clearPairedPhone();
    _server.apply(_session.revoke());
    _phone = null;
    _online = false;
    _needsRepair = false;
    _notify();
  }

  /// "Nouveau QR" for a phone whose pairing became invalid: forget it and
  /// show a fresh pairing QR straight away.
  Future<void> repairPhone() async {
    await revokePhone();
    await startPairing();
  }

  Future<void> addApp(String target, {String? label}) async {
    final app = ProtectedApp.create(label: label ?? _labelFromTarget(target), target: target);
    await _apps.upsert(app);
    _appsCache = await _apps.all();
    _notify();
  }

  Future<void> removeApp(String id) async {
    await _apps.remove(id);
    _appsCache = await _apps.all();
    _notify();
  }

  Future<void> setUnlockMinutes(String id, int m) async {
    final app = await _apps.byId(id);
    if (app == null) return;
    await _apps.upsert(app.copyWith(unlockMinutes: m));
    _appsCache = await _apps.all();
    _notify();
  }

  /// The protected launch: looks the app up in the store, launches it
  /// directly if [UnlockCache] says it is still unlocked, otherwise asks
  /// the paired phone for a fresh biometric approval.
  Future<void> open(String appId) async {
    final app = await _apps.byId(appId);
    if (app == null) {
      await _notifier.show('BioKey', 'Application inconnue');
      return;
    }
    if (_unlock.isUnlocked(app)) {
      await _launch(app);
      return;
    }
    if (!_session.phoneOnline && _phone != null) {
      await _waitForPhone();
    }
    final (id, fx) = _session.requestAuth(label: app.label);
    _authToApp[id] = app.id;
    _server.apply(fx);
  }

  /// Waits up to [_phoneWait] for the paired phone to come online.
  Future<void> _waitForPhone() async {
    final waiter = Completer<bool>();
    _onlineWaiters.add(waiter);
    await waiter.future.timeout(_phoneWait, onTimeout: () => false);
    _onlineWaiters.remove(waiter);
  }

  Future<void> handleCli(List<String> args) async {
    if (!_initialized) {
      // A shortcut launched while we're still starting (e.g. at login):
      // the session/server don't exist yet, so replay it after init().
      _queuedCli.add(List<String>.of(args));
      return;
    }
    final cmd = parseCli(args);
    switch (cmd) {
      case OpenApp():
        await open(cmd.id);
      case ShowWindow():
        _onShowWindow?.call();
    }
  }

  void _onEffect(DesktopEffect e) {
    if (_disposed) return;
    switch (e) {
      case AuthResolved():
        final appId = _authToApp.remove(e.id);
        if (appId != null) onAuthResolved(e.id, appId, e.outcome);
      case PhonePaired():
        unawaited(_store.savePairedPhone(e.phone));
        _phone = e.phone;
        _pairingQr = null;
        _needsRepair = false;
        unawaited(_notifier.show('BioKey', 'Téléphone appairé : ${e.phone.name}'));
        _notify();
      case PhoneOnline():
        _online = e.online;
        if (e.online) {
          // A successful `hello` proves the stored pairing is fine again.
          _needsRepair = false;
          for (final w in _onlineWaiters.toList()) {
            if (!w.isCompleted) w.complete(true);
          }
        }
        _notify();
      case PairingExpired():
        if (_pairingQr != null) {
          _pairingQr = null;
          _notify();
        }
      case PairingInvalid():
        _needsRepair = true;
        unawaited(_notifier.show('BioKey', 'Appairage invalide — scannez à nouveau le QR'));
        _notify();
      case SendFrame():
      case CloseConn():
        break;
    }
  }

  /// Notifies listeners unless this controller has already been disposed
  /// (an in-flight async callback, e.g. from the server, can still land
  /// after the window/tray tears the controller down on quit).
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Public so tests can simulate an [AuthResolved] effect arriving for a
  /// synthetic id without wiring a real (fake) server round-trip.
  void onAuthResolved(String authId, String appId, AuthOutcome outcome) {
    ProtectedApp? app;
    for (final a in _appsCache) {
      if (a.id == appId) {
        app = a;
        break;
      }
    }
    if (app == null) return;
    final found = app;
    switch (outcome) {
      case AuthOutcome.approved:
        unawaited(_launch(found).then((ok) {
          // Only a launch that actually happened opens the unlock window.
          if (ok) _unlock.markUnlocked(found);
        }));
      case AuthOutcome.noPhone:
        unawaited(_notifier.show('BioKey', 'Téléphone introuvable — même Wi-Fi ?'));
      case AuthOutcome.timeout:
        unawaited(_notifier.show('BioKey', 'Demande expirée'));
      case AuthOutcome.denied:
        unawaited(_notifier.show('BioKey', 'Demande refusée'));
      case AuthOutcome.biometricFailed:
        unawaited(_notifier.show('BioKey', 'Échec biométrique'));
      case AuthOutcome.badSignature:
        unawaited(_notifier.show('BioKey', 'Signature invalide — réappairez le téléphone'));
    }
  }

  Future<bool> _launch(ProtectedApp app) async {
    try {
      await _launcher.launch(app);
      return true;
    } on LaunchFailed catch (e) {
      await _notifier.show('BioKey', 'Impossible d’ouvrir ${app.label} : ${e.message}');
      return false;
    }
  }

  String _labelFromTarget(String target) {
    final name = target.replaceAll('\\', '/').split('/').last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final w in _onlineWaiters) {
      if (!w.isCompleted) w.complete(false);
    }
    if (_serverCreated) unawaited(_server.stop());
    unawaited(_discovery?.stop());
    _onDispose?.call();
    super.dispose();
  }
}
