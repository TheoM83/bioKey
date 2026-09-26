import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/pairing/qr_payload.dart';
import '../core/session/biometric_signer.dart';
import '../core/session/clock.dart';
import '../core/session/phone_session.dart';
import '../core/storage/phone_store.dart';
import 'net/pc_link.dart';
import 'service/foreground.dart';
import 'service/foreground_gate.dart';

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
    AuthNotifierApi? authNotifier,
    ForegroundGateApi? gate,
  })  : _store = store,
        _signer = signer,
        _linkFactory = linkFactory ?? ((pc, session, onEffect) => PcLink(pc: pc, session: session, onEffect: onEffect)),
        _authNotifier = authNotifier ?? AuthNotifier(),
        _gate = gate ?? (ForegroundGate()..attach()) {
    _session = PhoneSession(signer: signer, clock: clock, onAuthShown: _onAuthShownEarly);
  }

  final PhoneStore _store;
  final BiometricSigner _signer;
  late final PhoneSession _session;
  final LinkFactory _linkFactory;
  final AuthNotifierApi _authNotifier;
  final ForegroundGateApi _gate;

  final _links = <String, PcLinkApi>{};
  final _onlinePcIds = <String>{};

  /// PCs whose link reported us as `unknown` — the stored pairing is stale
  /// (e.g. the desktop was reinstalled/re-paired with a different phone)
  /// and this PC needs to be re-paired from scratch.
  final needsRepair = <String>{};

  var _pcs = <PairedPc>[];
  var _disposed = false;

  /// Completed by [shutdown] to interrupt any in-flight
  /// "wait for resume, then cancel the notification" waits (see
  /// [_showAndAutoCancel]) instead of leaving them running past disposal.
  final _shutdownSignal = Completer<void>();

  /// Every currently-in-flight [_showAndAutoCancel] call, keyed by
  /// notification id, so [shutdown] can await all of them finishing
  /// (which happens promptly once [_shutdownSignal] wakes them).
  final _pendingAuthCancel = <int, Future<void>>{};

  List<PairedPc> get pcs => List.unmodifiable(_pcs);
  bool isOnline(String pcId) => _onlinePcIds.contains(pcId);

  Future<void> init() async {
    _pcs = await _store.pcs();
    for (final pc in _pcs) {
      await _startLink(pc);
    }
    _notify();
  }

  /// Runs the pairing handshake against [qr]'s desktop, persists the
  /// resulting [PairedPc], and (re)starts its reconnecting link — stopping
  /// any previous link for the same PC first, so re-pairing an already
  /// paired PC never leaves an orphaned link running alongside the new one.
  Future<PairedPc> pair(QrPayload qr) async {
    final pc = await PcLink.pair(qr: qr, session: _session, onEffect: _onEffect);
    await _store.upsertPc(pc);
    _pcs = await _store.pcs();
    needsRepair.remove(pc.pcId);
    await _startLink(pc);
    _notify();
    return pc;
  }

  /// Stops the link to [pcId], forgets it, and — once no PC remains paired
  /// — deletes the biometric key (there is nothing left for it to prove
  /// possession of).
  Future<void> revoke(String pcId) async {
    await _stopLink(pcId);
    needsRepair.remove(pcId);
    _onlinePcIds.remove(pcId);
    await _store.removePc(pcId);
    _pcs = await _store.pcs();
    if (_pcs.isEmpty) {
      await _signer.deleteKey();
    }
    _notify();
  }

  Future<void> _startLink(PairedPc pc) async {
    await _stopLink(pc.pcId); // never let two links for the same PC run at once.
    final link = _linkFactory(pc, _session, _onEffect);
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
        // A revoked PC's link can still be mid-teardown when it resolves a
        // host it was already trying before stop(): ignore it, there's
        // nothing to persist a rediscovered host onto anymore.
        if (_links.containsKey(e.pc.pcId)) {
          unawaited(_onHostUpdated(e.pc));
        }
      case PhoneUnknownByPc():
        needsRepair.add(e.pcId);
        // This session will never succeed — the desktop no longer
        // recognises it — so stop retrying with it; needsRepair prompts
        // the user to re-pair from scratch instead.
        unawaited(_stopLink(e.pcId));
        _notify();
      case PhoneOnlineChanged():
        if (e.online) {
          _onlinePcIds.add(e.pcId);
        } else {
          _onlinePcIds.remove(e.pcId);
        }
        _notify();
      case PhoneAuthShown():
        // Handled synchronously via PhoneSession's onAuthShown callback
        // (see the constructor) so the notification can appear *before*
        // the (blocking) biometric prompt, not after; this effect is a
        // no-op here to avoid double-firing it.
        break;
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
  /// when the app isn't in the foreground — the biometric prompt itself
  /// cannot even be shown from a backgrounded Android activity until the
  /// user brings BioKey forward, so this needs to fire *before* `sign()`
  /// runs, not after (see [PhoneSession]'s `onAuthShown` callback).
  void _onAuthShownEarly(PhoneAuthShown e) {
    if (_gate.isResumed) return;
    final id = _authNotificationId(e.label, e.pcName);
    final future = _showAndAutoCancel(id, e);
    _pendingAuthCancel[id] = future;
    unawaited(future.whenComplete(() => _pendingAuthCancel.remove(id)));
  }

  Future<void> _showAndAutoCancel(int id, PhoneAuthShown e) async {
    await _authNotifier.init();
    await _authNotifier.showAuthPrompt(id: id, label: e.label, pcName: e.pcName);
    // Whichever comes first: the app resumes, the 35s bound expires (the
    // auth request itself has its own, shorter, server-side TTL), or
    // shutdown() is asked to tear everything down early.
    await Future.any([
      _gate.whenResumed(timeout: const Duration(seconds: 35)).catchError((_) {}),
      _shutdownSignal.future,
    ]);
    await _authNotifier.cancel(id);
  }

  /// A stable-per-request (not fixed) notification id, so two different
  /// concurrent auth requests (different PCs, or a retried request with a
  /// different label) don't clobber each other's notification.
  int _authNotificationId(String label, String pcName) => Object.hash(label, pcName) & 0x7fffffff;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Stops and awaits every link, detaches the foreground gate, and
  /// cancels any pending "wait for resume, then cancel the notification"
  /// waits (and the notifications they'd otherwise leave shown) — the
  /// fully-awaited teardown [dispose] itself cannot provide, since
  /// `ChangeNotifier.dispose()` is synchronous.
  ///
  /// Callers should `await controller.shutdown()` before dropping the
  /// controller rather than relying on [dispose] alone.
  Future<void> shutdown() async {
    if (!_shutdownSignal.isCompleted) _shutdownSignal.complete();
    await Future.wait(_pendingAuthCancel.values.toList());
    await Future.wait(_links.values.map((l) => l.stop()));
    _links.clear();
    _gate.detach();
  }

  /// `ChangeNotifier.dispose()` is synchronous, so it cannot itself await
  /// [shutdown]'s link-stop/notification-cancel work — callers that need
  /// a fully-awaited teardown should call `await controller.shutdown()`
  /// before disposing. This is a best-effort fire-and-forget backstop for
  /// callers that don't.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(shutdown());
    super.dispose();
  }
}
