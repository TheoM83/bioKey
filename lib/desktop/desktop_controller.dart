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
import 'server/lan.dart';
import 'server/mdns_advertiser.dart';
import 'server/ws_server.dart';

/// Wires the pure [DesktopSession] state machine to the [WsServerApi],
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
    WsServerApi Function(DesktopIdentity identity, DesktopSession session, void Function(DesktopEffect) onEffect)? serverFactory,
    MdnsAdvertiser? mdns,
  })  : _store = store,
        _apps = apps,
        _launcher = launcher,
        _verifier = verifier,
        _clock = clock,
        _notifier = notifier,
        _serverFactory = serverFactory,
        _mdns = mdns,
        _unlock = UnlockCache(clock);

  final DesktopStore _store;
  final AppStore _apps;
  final AppLauncher _launcher;
  final Verifier _verifier;
  final Clock _clock;
  final Notifier _notifier;
  final WsServerApi Function(DesktopIdentity, DesktopSession, void Function(DesktopEffect))? _serverFactory;
  final MdnsAdvertiser? _mdns;
  final UnlockCache _unlock;

  late DesktopIdentity _identity;
  late DesktopSession _session;
  late WsServerApi _server;

  List<ProtectedApp> _appsCache = <ProtectedApp>[];
  PairedPhone? _phone;
  bool _online = false;
  QrPayload? _pairingQr;
  final _authToApp = <String, String>{};

  String get pcId => _identity.pcId;
  QrPayload? get pairingQr => _pairingQr;
  bool get phoneOnline => _online;
  PairedPhone? get phone => _phone;
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

    final factory = _serverFactory ?? (DesktopIdentity id, DesktopSession s, void Function(DesktopEffect) onEffect) => WsServer(identity: id, session: s, onEffect: onEffect);
    _server = factory(_identity, _session, _onEffect);
    await _server.start(port: await _store.port());
    await _mdns?.start(pcId: _identity.pcId, name: pcName, port: _server.port);

    _appsCache = await _apps.all();
    notifyListeners();
  }

  Future<void> startPairing() async {
    _session.startPairing();
    final host = await primaryLanIPv4();
    _pairingQr = QrPayload(
      pcId: _identity.pcId,
      name: await _store.pcName(),
      host: host ?? '',
      port: _server.port,
      fingerprint: _identity.fingerprintB64Url,
      token: _session.pairingToken!,
    );
    notifyListeners();
  }

  Future<void> revokePhone() async {
    await _store.clearPairedPhone();
    _session.phone = null;
    _phone = null;
    notifyListeners();
  }

  Future<void> addApp(String target, {String? label}) async {
    final app = ProtectedApp.create(label: label ?? _labelFromTarget(target), target: target);
    await _apps.upsert(app);
    _appsCache = await _apps.all();
    notifyListeners();
  }

  Future<void> removeApp(String id) async {
    await _apps.remove(id);
    _appsCache = await _apps.all();
    notifyListeners();
  }

  Future<void> setUnlockMinutes(String id, int m) async {
    final app = await _apps.byId(id);
    if (app == null) return;
    await _apps.upsert(app.copyWith(unlockMinutes: m));
    _appsCache = await _apps.all();
    notifyListeners();
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
    final (id, fx) = _session.requestAuth(label: app.label);
    _authToApp[id] = app.id;
    _server.apply(fx);
  }

  Future<void> handleCli(List<String> args) async {
    final cmd = parseCli(args);
    switch (cmd) {
      case OpenApp():
        await open(cmd.id);
      case ShowWindow():
        break;
    }
  }

  void _onEffect(DesktopEffect e) {
    switch (e) {
      case AuthResolved():
        final appId = _authToApp.remove(e.id);
        if (appId != null) onAuthResolved(e.id, appId, e.outcome);
      case PhonePaired():
        unawaited(_store.savePairedPhone(e.phone));
        _phone = e.phone;
        _pairingQr = null;
        unawaited(_notifier.show('BioKey', 'Téléphone appairé : ${e.phone.name}'));
        notifyListeners();
      case PhoneOnline():
        _online = e.online;
        notifyListeners();
      case SendFrame():
      case CloseConn():
        break;
    }
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
        unawaited(_launch(found).then((_) => _unlock.markUnlocked(found)));
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

  Future<void> _launch(ProtectedApp app) async {
    try {
      await _launcher.launch(app);
    } on LaunchFailed catch (e) {
      await _notifier.show('BioKey', 'Impossible d’ouvrir ${app.label} : ${e.message}');
    }
  }

  String _labelFromTarget(String target) {
    final name = target.replaceAll('\\', '/').split('/').last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  @override
  void dispose() {
    unawaited(_server.stop());
    unawaited(_mdns?.stop());
    super.dispose();
  }
}
