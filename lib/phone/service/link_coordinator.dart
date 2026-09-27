import 'dart:async';
import 'dart:io' show InternetAddress;

import '../../core/pairing/qr_payload.dart';
import '../../core/session/biometric_signer.dart';
import '../../core/session/clock.dart';
import '../../core/session/phone_session.dart';
import '../../core/storage/phone_store.dart';
import '../net/pc_link.dart';
import 'task_transport.dart';

typedef LinkFactory = PcLinkApi Function(PairedPc pc, PhoneSession session, void Function(PhoneEffect) onEffect);
typedef Pairer = Future<PairedPc> Function(QrPayload qr, PhoneSession session, void Function(PhoneEffect) onEffect);

/// A conservative check for what [PcLink]'s pinned `SecureSocket.connect`
/// can actually resolve: an IPv4/IPv6 literal (for a bare tunnel IP), or a
/// DNS-style hostname — including a MagicDNS name such as
/// `pc-maison.tailnet.ts.net`. [host] must already be trimmed.
///
/// The QR fingerprint stays the pin either way: accepting a hostname here
/// widens *reachability*, never the security boundary.
///
/// `host:port` is rejected on purpose: the port is never user-supplied
/// here — it stays whatever was already stored for the paired PC (see
/// [LinkCoordinator._setHost]) — so a manual host is a bare address/name.
bool isValidHost(String host) {
  if (host.isEmpty || host.length > 253 || host.contains(' ')) return false;
  if (InternetAddress.tryParse(host) != null) return true;
  return RegExp(r'^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$')
      .hasMatch(host);
}

/// The network side of the phone role, run inside the foreground-service
/// isolate so the links to paired PCs survive the Activity being destroyed
/// (swiped from recents) and come back on boot with no UI at all.
///
/// Owns the [PhoneStore] (paired PCs) and one reconnecting [PcLinkApi] per
/// paired PC, each driving its own pure [PhoneSession] whose signer is a
/// proxy to the UI isolate. Takes commands from the UI (`getState`, `pair`,
/// `revoke`, `refresh`) and publishes `state` snapshots back.
final class LinkCoordinator {
  LinkCoordinator({
    required PhoneStore store,
    required BiometricSigner signer,
    required Clock clock,
    required void Function(Map<String, Object?>) send,
    required LinkFactory linkFactory,
    required Pairer pairer,
  })  : _store = store,
        _signer = signer,
        _send = send,
        _linkFactory = linkFactory,
        _pairer = pairer,
        _clock = clock;

  final PhoneStore _store;
  final BiometricSigner _signer;
  final void Function(Map<String, Object?>) _send;
  final LinkFactory _linkFactory;
  final Pairer _pairer;
  final Clock _clock;

  /// Each link and each pairing attempt gets its own [PhoneSession], so an
  /// in-flight pairing can never be observed (or cancelled) by a link.
  PhoneSession _newSession() => PhoneSession(signer: _signer, clock: _clock);

  final _links = <String, PcLinkApi>{};
  final _online = <String>{};
  final _needsRepair = <String>{};
  var _pcs = <PairedPc>[];
  var _stopped = false;

  /// Serialises [handleCommand] calls into a single FIFO: `refresh`/`pair`/
  /// `revoke` for the same PC would otherwise run concurrently (each
  /// `handleCommand` call is fired un-awaited by [TaskBackend]) and race
  /// `_startLink`/`_stopLink` against one another.
  Future<void> _commandQueue = Future<void>.value();

  /// Test hooks.
  Map<String, PcLinkApi> get links => Map.unmodifiable(_links);
  List<PairedPc> get pcs => List.unmodifiable(_pcs);

  Future<void> start() async {
    _pcs = await _store.pcs();
    for (final pc in _pcs) {
      await _startLink(pc);
    }
    publishState();
  }

  /// Queues [m] behind whatever `handleCommand` call is already running:
  /// `TaskBackend` fires each incoming command un-awaited, so without this
  /// two commands for the same PC (e.g. `pair` then `revoke`, or a
  /// concurrent `refresh`) could interleave their `_startLink`/`_stopLink`
  /// calls. The returned future still carries [m]'s own outcome/error; only
  /// the *queue* swallows errors, so one failed command can't wedge the
  /// ones behind it.
  Future<void> handleCommand(Map<String, Object?> m) {
    final result = _commandQueue.then((_) => _handleCommand(m));
    _commandQueue = result.catchError((Object _, StackTrace _) {});
    return result;
  }

  Future<void> _handleCommand(Map<String, Object?> m) async {
    if (_stopped) return;
    switch (m['op']) {
      case TaskOps.getState:
        publishState();
      case TaskOps.pair:
        await _pair(m['reqId'], m['qr']);
      case TaskOps.revoke:
        final pcId = m['pcId'];
        if (pcId is String) await _revoke(pcId);
        _send({'op': TaskOps.revoked, 'reqId': m['reqId']});
      case TaskOps.setHost:
        await _setHost(m['reqId'], m['pcId'], m['host']);
      case TaskOps.refresh:
        // The UI's key changed (re-enrolment): reconnect everything so each
        // PC sees a fresh `hello` — and says `unknown` if it must re-pair.
        _needsRepair.clear();
        _pcs = await _store.pcs();
        for (final pc in _pcs) {
          await _startLink(pc);
        }
        publishState();
    }
  }

  Future<void> _pair(Object? reqId, Object? rawQr) async {
    try {
      if (rawQr is! String) throw const FormatException('QR manquant');
      final qr = QrPayload.parse(rawQr);
      final pc = await _pairer(qr, _newSession(), _onEffect);
      await _store.upsertPc(pc);
      _pcs = await _store.pcs();
      _needsRepair.remove(pc.pcId);
      await _startLink(pc);
      _send({'op': TaskOps.pairResult, 'reqId': reqId, 'ok': true, 'pc': pc.toJson()});
    } on Object catch (e) {
      _send({'op': TaskOps.pairResult, 'reqId': reqId, 'ok': false, 'error': _describe(e)});
    }
    publishState();
  }

  String _describe(Object e) => switch (e) {
        BiometricCancelled() => 'annulé',
        BiometricFailed(:final message) => message,
        StateError(:final message) => message,
        FormatException(:final message) => message,
        TimeoutException() => 'délai dépassé',
        _ => '$e',
      };

  /// Stops the link to [pcId], forgets it, and — once no PC remains
  /// paired — deletes the biometric key.
  Future<void> _revoke(String pcId) async {
    await _stopLink(pcId);
    _needsRepair.remove(pcId);
    _online.remove(pcId);
    await _store.removePc(pcId);
    _pcs = await _store.pcs();
    if (_pcs.isEmpty) {
      try {
        await _signer.deleteKey();
      } on Object {
        // The key is useless without a paired PC anyway; the next pairing
        // recreates it.
      }
    }
    publishState();
  }

  /// Sets (or, given an empty string, clears) a manual host for [pcId]
  /// (for use over the user's own WireGuard/Tailscale tunnel — BioKey
  /// itself never has a server): validates it, persists it as
  /// [PairedPc.manualHost] — never overwriting [PairedPc.host], the last
  /// known LAN address, which discovery keeps up to date on its own — and
  /// restarts the link so the next connect attempt sees it. An invalid
  /// host, or an unknown [pcId], leaves the store and the link untouched.
  Future<void> _setHost(Object? reqId, Object? pcId, Object? rawHost) async {
    try {
      if (pcId is! String) throw const FormatException('PC manquant');
      final host = (rawHost is String ? rawHost : '').trim();
      if (host.isNotEmpty && !isValidHost(host)) throw const FormatException('Adresse invalide');
      final i = _pcs.indexWhere((p) => p.pcId == pcId);
      if (i < 0) throw StateError('PC inconnu');
      final updated = _pcs[i].copyWith(manualHost: host.isEmpty ? null : host, clearManualHost: host.isEmpty);
      await _store.upsertPc(updated);
      _pcs = await _store.pcs();
      await _startLink(updated);
      _send({'op': TaskOps.setHostResult, 'reqId': reqId, 'ok': true});
    } on Object catch (e) {
      _send({'op': TaskOps.setHostResult, 'reqId': reqId, 'ok': false, 'error': _describe(e)});
    }
    publishState();
  }

  Future<void> _startLink(PairedPc pc) async {
    await _stopLink(pc.pcId); // never two links for the same PC.
    final link = _linkFactory(pc, _newSession(), _onEffect);
    _links[pc.pcId] = link;
    unawaited(link.start());
  }

  Future<void> _stopLink(String pcId) async {
    final link = _links.remove(pcId);
    if (link != null) await link.stop();
  }

  void _onEffect(PhoneEffect e) {
    switch (e) {
      case PhonePairedWith():
        // A revoked PC's link can still be mid-teardown: nothing to update.
        if (_links.containsKey(e.pc.pcId)) unawaited(_onHostUpdated(e.pc));
      case PhoneUnknownByPc():
        _needsRepair.add(e.pcId);
        // The PC no longer knows this pairing: retrying is pointless.
        unawaited(_stopLink(e.pcId));
        publishState();
      case PhoneOnlineChanged():
        if (e.online) {
          _online.add(e.pcId);
        } else {
          _online.remove(e.pcId);
        }
        publishState();
      case PhoneAuthShown():
      case PhoneSend():
      case PhoneClose():
        break;
    }
  }

  Future<void> _onHostUpdated(PairedPc pc) async {
    await _store.upsertPc(pc);
    _pcs = await _store.pcs();
    publishState();
  }

  void publishState() {
    if (_stopped) return;
    _send({
      'op': TaskOps.state,
      'pcs': [for (final pc in _pcs) pc.toJson()],
      'online': _online.toList(),
      'needsRepair': _needsRepair.toList(),
    });
  }

  Future<void> stop() async {
    _stopped = true;
    await Future.wait(_links.values.map((l) => l.stop()));
    _links.clear();
  }
}

/// Handler-side router: feeds signer replies to the [ProxySigner]-like
/// [replies] sink and everything else to [coordinator].
final class TaskBackend {
  TaskBackend({required this.transport, required this.coordinator, required this.replies});

  final TaskTransport transport;
  final LinkCoordinator coordinator;

  /// Returns true when it consumed the message (a signer reply).
  final bool Function(Map<String, Object?>) replies;
  StreamSubscription<Map<String, Object?>>? _sub;

  Future<void> start() async {
    // Listen first: commands sent while the links start must not be lost.
    final early = <Map<String, Object?>>[];
    var started = false;
    _sub = transport.messages.listen((m) {
      if (replies(m)) return;
      if (!started) {
        early.add(m);
        return;
      }
      unawaited(coordinator.handleCommand(m));
    });
    await coordinator.start();
    started = true;
    for (final m in early) {
      unawaited(coordinator.handleCommand(m));
    }
  }

  Future<void> stop() async {
    await _sub?.cancel();
    await coordinator.stop();
  }
}
