import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/pairing/qr_payload.dart';
import '../core/session/biometric_signer.dart';
import '../core/session/clock.dart';
import '../core/session/phone_session.dart';
import '../core/storage/phone_store.dart';
import 'net/pc_link.dart';
import 'service/foreground.dart';

typedef LinkFactory = PcLinkApi Function(PairedPc pc, PhoneSession session, void Function(PhoneEffect) onEffect);

/// Wires the pure [PhoneSession] state machine to one reconnecting [PcLink]
/// per paired PC, persists pairing/host changes to [PhoneStore], and
/// exposes the phone role's state (paired PCs, online status, PCs needing
/// re-pairing) to the UI as a [ChangeNotifier].
final class PhoneController extends ChangeNotifier {
  PhoneController({
    required PhoneStore store,
    required BiometricSigner signer,
    required Clock clock,
    LinkFactory? linkFactory,
    AuthNotifier? authNotifier,
    bool Function()? isAppForeground,
  })  : _store = store,
        _signer = signer,
        _session = PhoneSession(signer: signer, clock: clock),
        _linkFactory = linkFactory ?? ((pc, session, onEffect) => PcLink(pc: pc, session: session, onEffect: onEffect)),
        _authNotifier = authNotifier,
        _isAppForeground = isAppForeground ?? _defaultIsAppForeground;

  final PhoneStore _store;
  final BiometricSigner _signer;
  final PhoneSession _session;
  final LinkFactory _linkFactory;
  AuthNotifier? _authNotifier;
  bool _authNotifierReady = false;
  final bool Function() _isAppForeground;

  final _links = <String, PcLinkApi>{};
  final _onlinePcIds = <String>{};

  /// PCs whose link reported us as `unknown` — the stored pairing is stale
  /// (e.g. the desktop was reinstalled/re-paired with a different phone)
  /// and this PC needs to be re-paired from scratch.
  final needsRepair = <String>{};

  var _pcs = <PairedPc>[];
  var _disposed = false;

  List<PairedPc> get pcs => List.unmodifiable(_pcs);
  bool isOnline(String pcId) => _onlinePcIds.contains(pcId);

  Future<void> init() async {
    _pcs = await _store.pcs();
    for (final pc in _pcs) {
      _startLink(pc);
    }
    _notify();
  }

  /// Runs the pairing handshake against [qr]'s desktop, persists the
  /// resulting [PairedPc], and starts its reconnecting link.
  Future<PairedPc> pair(QrPayload qr) async {
    final pc = await PcLink.pair(qr: qr, session: _session, onEffect: _onEffect);
    await _store.upsertPc(pc);
    _pcs = await _store.pcs();
    needsRepair.remove(pc.pcId);
    _startLink(pc);
    _notify();
    return pc;
  }

  /// Stops the link to [pcId], forgets it, and — once no PC remains paired
  /// — deletes the biometric key (there is nothing left for it to prove
  /// possession of).
  Future<void> revoke(String pcId) async {
    final link = _links.remove(pcId);
    await link?.stop();
    _onlinePcIds.remove(pcId);
    needsRepair.remove(pcId);
    await _store.removePc(pcId);
    _pcs = await _store.pcs();
    if (_pcs.isEmpty) {
      await _signer.deleteKey();
    }
    _notify();
  }

  void _startLink(PairedPc pc) {
    final link = _linkFactory(pc, _session, _onEffect);
    _links[pc.pcId] = link;
    unawaited(link.start());
  }

  void _onEffect(PhoneEffect e) {
    switch (e) {
      case PhonePairedWith():
        unawaited(_onHostUpdated(e.pc));
      case PhoneUnknownByPc():
        needsRepair.add(e.pcId);
        _notify();
      case PhoneOnlineChanged():
        if (e.online) {
          _onlinePcIds.add(e.pcId);
        } else {
          _onlinePcIds.remove(e.pcId);
        }
        _notify();
      case PhoneAuthShown():
        unawaited(_onAuthShown(e));
      case PhoneSend():
      case PhoneClose():
        break;
    }
  }

  Future<void> _onHostUpdated(PairedPc pc) async {
    await _store.upsertPc(pc);
    _pcs = await _store.pcs();
    _notify();
  }

  /// Surfaces a high-priority notification for an incoming auth request
  /// when the app isn't in the foreground — the biometric prompt itself is
  /// already showing by the time this effect arrives (`sign()` runs as
  /// soon as the `auth` frame does), so this only needs to get the user's
  /// attention, not gate anything.
  Future<void> _onAuthShown(PhoneAuthShown e) async {
    if (_isAppForeground()) return;
    final notifier = _authNotifier ??= AuthNotifier();
    if (!_authNotifierReady) {
      await notifier.init();
      _authNotifierReady = true;
    }
    await notifier.showAuthPrompt(label: e.label, pcName: e.pcName);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final link in _links.values) {
      unawaited(link.stop());
    }
    super.dispose();
  }
}

bool _defaultIsAppForeground() => WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
