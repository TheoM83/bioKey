import 'dart:async';
import 'dart:io';
import 'package:async/async.dart' show StreamQueue;
import '../../core/pairing/qr_payload.dart';
import '../../core/protocol/codec.dart';
import '../../core/protocol/messages.dart';
import '../../core/session/phone_session.dart';
import '../../core/storage/phone_store.dart';
import 'pinned_socket.dart';

typedef Connect = Future<WebSocket> Function(String host, int port, String fp);
typedef Backoff = Duration Function(int attempt);

/// 1, 2, 4, 8, 15, 30 s, then capped at 30 s.
Duration defaultBackoff(int attempt) => Duration(seconds: const [1, 2, 4, 8, 15, 30][attempt.clamp(0, 5)]);

/// The operations [PhoneController] needs from a PC link, extracted so
/// tests can inject a fake instead of a real (pinned-TLS) socket — mirrors
/// [WsServerApi] on the desktop side.
abstract interface class PcLinkApi {
  PairedPc get pc;
  bool get online;
  Future<void> start();
  Future<void> stop();
}

/// One reconnecting WebSocket link between the phone and a single paired PC.
///
/// Drives the pure [PhoneSession] state machine against a real (pinned-TLS)
/// socket: connects, sends `hello`, applies every effect the session emits
/// (`PhoneSend` → write to the socket, `PhoneClose` → close it, everything
/// else forwarded to [onEffect]), and reconnects with backoff on
/// disconnect/failure. Emits [PhoneOnlineChanged] itself (the session never
/// does) so callers can track connectivity without polling [online].
///
/// Lifecycle: every loop iteration is tagged with the generation it was
/// started under (bumped by [start]); every resume point re-checks
/// `_running` and its generation before touching shared state or the
/// socket, so a `stop()` that races an in-flight connect can never leave an
/// authenticated socket open or a second loop running after `start()` is
/// called again.
final class PcLink implements PcLinkApi {
  PcLink({
    required this.pc,
    required PhoneSession session,
    required this.onEffect,
    Connect? connect,
    Future<String?> Function(String pcId)? resolveHost,
    Backoff? backoff,
  })  : _session = session,
        _connect = connect ?? _defaultConnect,
        _resolve = resolveHost,
        _backoff = backoff ?? defaultBackoff;

  static Future<WebSocket> _defaultConnect(String h, int p, String fp) => connectPinned(host: h, port: p, fingerprint: fp);

  /// The paired PC this link talks to. Only updated once mDNS has resolved
  /// a new host *and* a `welcome` has actually been received on it (see
  /// [_pendingHost]) — never on the mere hope that a resolved host works.
  @override
  PairedPc pc;
  final PhoneSession _session;
  final void Function(PhoneEffect) onEffect;
  final Connect _connect;
  final Future<String?> Function(String)? _resolve;
  final Backoff _backoff;

  WebSocket? _ws;
  bool _running = false;
  @override
  bool online = false;
  int _attempt = 0;
  int _gen = 0;
  Future<void>? _loopFuture;

  /// Completed by [stop] to interrupt whichever of the backoff sleep or a
  /// `resolveHost` lookup the loop is currently waiting on, so `stop()`
  /// doesn't have to sit through a long (up to 30s) backoff — see
  /// [_delayOrWake]/[_resolveOrWake].
  Completer<void>? _wakeCompleter;

  /// An mDNS-resolved host awaiting confirmation: connect attempts prefer
  /// it over [pc]'s stored host, but it only overwrites [pc] (and gets
  /// persisted via a [PhonePairedWith] effect) once a `welcome` actually
  /// arrives on it — resolving a host is not proof it's reachable.
  ///
  /// Cleared (not just left stale) whenever `resolveHost` returns `null`
  /// or the already-stored host, so one bad/transient mDNS answer can't
  /// strand the link on it forever; while it *is* set, connect attempts
  /// alternate between it and [pc]'s stored host (see [_preferPending]) so
  /// a resolved-but-wrong host doesn't crowd out retrying the one that's
  /// known to have worked before.
  String? _pendingHost;
  bool _preferPending = true;

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    final gen = ++_gen;
    final future = _loop(gen);
    _loopFuture = future;
    unawaited(future);
  }

  @override
  Future<void> stop() async {
    _running = false;
    _wakeCompleter?.complete();
    await _ws?.close();
    final future = _loopFuture;
    if (future != null) {
      await future.timeout(const Duration(seconds: 6), onTimeout: () {});
    }
    _ws = null;
    _loopFuture = null;
    // The loop's own offline transition is generation-gated (see
    // _markOffline) so a stale generation can't touch shared state after
    // this bound expires; stop() is therefore the one place that must
    // guarantee the link is reported offline.
    if (online) {
      online = false;
      onEffect(PhoneOnlineChanged(pc.pcId, false));
    }
  }

  bool _stale(int gen) => !_running || gen != _gen;

  /// Sleeps for [d], but returns as soon as [stop] wakes it — so a slow
  /// backoff never makes `stop()` block for the full duration.
  Future<void> _delayOrWake(Duration d) async {
    final wake = Completer<void>();
    _wakeCompleter = wake;
    await Future.any([Future<void>.delayed(d), wake.future]);
    if (identical(_wakeCompleter, wake)) _wakeCompleter = null;
  }

  /// Awaits `_resolve(pcId)`, but returns `null` as soon as [stop] wakes
  /// it (the caller must check staleness before trusting a `null` result
  /// as "no host found" versus "we gave up waiting"). The underlying
  /// lookup itself can't be cancelled, only abandoned.
  Future<String?> _resolveOrWake(String pcId) async {
    final wake = Completer<void>();
    _wakeCompleter = wake;
    final race = Completer<String?>();
    unawaited(_resolve!(pcId).then((v) {
      if (!race.isCompleted) race.complete(v);
    }, onError: (Object _) {
      if (!race.isCompleted) race.complete(null);
    }));
    unawaited(wake.future.then((_) {
      if (!race.isCompleted) race.complete(null);
    }));
    final result = await race.future;
    if (identical(_wakeCompleter, wake)) _wakeCompleter = null;
    return result;
  }

  Future<void> _loop(int gen) async {
    while (!_stale(gen)) {
      WebSocket? ws;
      try {
        final host = (_pendingHost != null && _preferPending) ? _pendingHost! : pc.host;
        ws = await _connect(host, pc.port, pc.fingerprint);
        if (_stale(gen)) return; // stop() raced the connect: close in finally, don't touch _ws.
        _ws = ws;
        _apply(await _session.hello(pc), ws, gen);
        if (_stale(gen)) return;
        // The socket is read continuously — never paused while a frame is
        // being handled — so WebSocket-level pings keep being answered
        // during a (possibly long) biometric prompt; frames themselves are
        // still handled strictly in order through [chain].
        var chain = Future<void>.value();
        final socket = ws;
        await for (final data in socket) {
          if (_stale(gen)) break;
          if (data is! String) break;
          chain = chain.then((_) => _handle(data, socket, host, gen));
        }
        // That connect attempt is now settled (success or failure): the
        // *next* one alternates to the other candidate host, so a
        // pendingHost that keeps failing doesn't crowd out retrying the
        // stored one, and vice versa.
        if (_pendingHost != null) _preferPending = !_preferPending;
      } on Object {
        if (_pendingHost != null) _preferPending = !_preferPending;
      } finally {
        final leaked = ws;
        if (leaked != null) {
          unawaited(leaked.close());
        }
        if (identical(_ws, ws)) _ws = null;
      }
      _markOffline(gen);
      if (_stale(gen)) return;
      if (_attempt >= 1 && _resolve != null) {
        final h = await _resolveOrWake(pc.pcId);
        if (_stale(gen)) return; // e.g. revoked/stopped while we were resolving.
        final newPendingHost = (h != null && h != pc.host) ? h : null;
        // Only reset the alternation to "try it first" for a genuinely
        // new candidate; re-resolving the *same* host we're already
        // alternating against must not keep clobbering the toggle back to
        // "prefer pending", or the alternation above never gets a chance
        // to actually try the stored host again.
        if (newPendingHost != _pendingHost) _preferPending = true;
        _pendingHost = newPendingHost;
      }
      if (_stale(gen)) return;
      await _delayOrWake(_backoff(_attempt));
      if (_stale(gen)) return; // woken by stop(): don't touch _attempt.
      _attempt++;
    }
  }

  Future<void> _handle(String data, WebSocket ws, String host, int gen) async {
    if (_stale(gen)) return;
    try {
      final fx = await _session.onFrame(pc, data);
      if (_isWelcome(data)) _markOnline(host, gen);
      _apply(fx, ws, gen);
    } on Object {
      // A frame that blows up must not stall the frames queued behind it.
    }
  }

  bool _isWelcome(String frame) {
    try {
      return Codec.decode(frame) is WelcomeMsg;
    } on ProtocolException {
      return false;
    }
  }

  void _markOnline(String connectedHost, int gen) {
    if (_stale(gen)) return;
    _attempt = 0;
    if (!online) {
      online = true;
      onEffect(PhoneOnlineChanged(pc.pcId, true));
    }
    if (_pendingHost != null && _pendingHost == connectedHost && _pendingHost != pc.host) {
      pc = PairedPc(pcId: pc.pcId, name: pc.name, host: _pendingHost!, port: pc.port, fingerprint: pc.fingerprint, session: pc.session);
      onEffect(PhonePairedWith(pc));
    }
    _pendingHost = null;
  }

  void _markOffline(int gen) {
    // stop() already guarantees the offline transition for a generation
    // it just tore down; a stale generation reporting it too could race a
    // *newer* generation's online state after stop()'s 6s bound expires.
    if (_stale(gen)) return;
    if (online) {
      online = false;
      onEffect(PhoneOnlineChanged(pc.pcId, false));
    }
  }

  /// Applies [fx] against the socket local to *this* loop iteration/
  /// generation (never the shared [_ws] field, which may already belong
  /// to a newer generation by the time a stale one's `onFrame` — e.g. a
  /// slow biometric sign — finally resolves) and drops every effect
  /// outright once stale, instead of forwarding them to [onEffect].
  void _apply(List<PhoneEffect> fx, WebSocket ws, int gen) {
    if (_stale(gen)) return;
    for (final e in fx) {
      switch (e) {
        case PhoneSend():
          try {
            ws.add(e.frame);
          } on Object {
            // Socket already closed underneath us: the reconnect loop owns it.
          }
        case PhoneClose():
          unawaited(ws.close());
        default:
          onEffect(e);
      }
    }
  }

  /// One-shot pairing connection: connects, runs [PhoneSession.beginPairing]
  /// against [qr], resolves with the newly-[PairedPc] on `paired`, and
  /// throws (or rejects) on any failure — bad fingerprint, refused/closed
  /// connection, or a session that declines to complete pairing.
  ///
  /// Bounded by an overall 60 s timeout (closes the socket and rejects on
  /// expiry). Frame handling is serialised through a [StreamQueue] (never
  /// an un-awaited `async` listener callback), and the socket is always
  /// closed — on success, on a refused/cancelled pairing, if
  /// [PhoneSession.beginPairing] throws, or on a stream error.
  ///
  /// If the QR's host can't be reached (the PC advertised the wrong
  /// interface, e.g. a virtual switch), the PC is looked up by id via
  /// [resolveHost] (mDNS) and the connection retried once there — still
  /// pinned to the QR's certificate fingerprint. The returned [PairedPc]
  /// records the host that actually worked.
  static Future<PairedPc> pair({
    required QrPayload qr,
    required PhoneSession session,
    required void Function(PhoneEffect) onEffect,
    Connect? connect,
    Future<String?> Function(String pcId)? resolveHost,
  }) async {
    WebSocket? ws;
    var cancelled = false;
    final attempt = _pair(
      qr: qr,
      session: session,
      onEffect: onEffect,
      connect: connect,
      resolveHost: resolveHost,
      bindSocket: (w) => ws = w,
      isCancelled: () => cancelled,
    );
    try {
      return await attempt.timeout(const Duration(seconds: 60));
    } on Object {
      session.cancelPairing();
      rethrow;
    } finally {
      // Covers the timeout path: `_pair`'s own try/finally already closes
      // the socket on every path it controls, so this is a best-effort
      // backstop for "the future never even got a chance to unwind" (the
      // 60 s timeout abandons — but doesn't cancel — the original future).
      // `cancelled` additionally stops a connect that was still pending
      // when the timeout fired from proceeding to actually pair once it
      // finally resolves — without it, the desktop could complete pairing
      // on its side after the phone already reported failure to its
      // caller.
      cancelled = true;
      unawaited(ws?.close());
      // The abandoned attempt still runs to completion internally (Dart's
      // Future.timeout doesn't cancel it); observe its eventual result so
      // it doesn't surface as an unhandled zone error once `cancelled`
      // makes it throw.
      unawaited(attempt.then((_) {}, onError: (_) {}));
    }
  }

  static Future<PairedPc> _pair({
    required QrPayload qr,
    required PhoneSession session,
    required void Function(PhoneEffect) onEffect,
    required void Function(WebSocket) bindSocket,
    required bool Function() isCancelled,
    Connect? connect,
    Future<String?> Function(String pcId)? resolveHost,
  }) async {
    final doConnect = connect ?? _defaultConnect;
    var host = qr.host;
    WebSocket ws;
    try {
      ws = await doConnect(host, qr.port, qr.fingerprint);
    } on Object {
      final resolved = (resolveHost == null || isCancelled()) ? null : await resolveHost(qr.pcId).catchError((Object _) => null);
      if (resolved == null || resolved == qr.host || isCancelled()) rethrow;
      host = resolved;
      ws = await doConnect(host, qr.port, qr.fingerprint);
    }
    bindSocket(ws);
    if (isCancelled()) {
      await ws.close();
      throw StateError('appairage: délai dépassé pendant la connexion');
    }
    // Buffer through a controller so the socket itself is never paused
    // while we wait on the fingerprint prompt (a StreamQueue pauses its
    // source between requests), which would stop WebSocket pings from
    // being answered and let the PC drop us mid-pairing.
    final inbox = StreamController<Object?>();
    final sub = ws.listen(inbox.add, onError: inbox.addError, onDone: () => unawaited(inbox.close()));
    final queue = StreamQueue<Object?>(inbox.stream);
    var closed = false;
    Future<void> closeWs() async {
      if (closed) return;
      closed = true;
      await ws.close();
    }

    try {
      // Only `tmp.name` is read by the session before `paired` arrives (for
      // the biometric prompt); the real session secret is not known until
      // then.
      final tmp = PairedPc(pcId: qr.pcId, name: qr.name, host: host, port: qr.port, fingerprint: qr.fingerprint, session: '');

      for (final e in await session.beginPairing(qr)) {
        if (e is PhoneSend) ws.add(e.frame);
      }

      PairedPc? paired;
      while (paired == null) {
        if (!await queue.hasNext) {
          throw StateError('connexion fermée pendant l’appairage');
        }
        final data = await queue.next;
        if (data is! String) continue;
        for (final e in await session.onFrame(tmp, data)) {
          switch (e) {
            case PhoneSend():
              ws.add(e.frame);
            case PhoneClose():
              await closeWs();
              throw StateError('appairage refusé');
            case PhonePairedWith():
              paired = host == e.pc.host
                  ? e.pc
                  : PairedPc(pcId: e.pc.pcId, name: e.pc.name, host: host, port: e.pc.port, fingerprint: e.pc.fingerprint, session: e.pc.session);
            default:
              onEffect(e);
          }
        }
      }

      // Deterministic teardown: close, but keep draining the (uncancelled)
      // queue so the peer's close echo is observed — the desktop runs its
      // own `onDisconnect` in the same turn it sends that echo, so by the
      // time this settles a caller that immediately opens a fresh [PcLink]
      // can't race a stale "the phone is still on this now-defunct
      // connection" state on the desktop. Bounded: a peer that never
      // echoes the close still lets pairing succeed after 5 s.
      unawaited(closeWs());
      await Future(() async {
        while (await queue.hasNext) {
          await queue.next;
        }
      }).timeout(const Duration(seconds: 5), onTimeout: () {});
      return paired;
    } finally {
      await closeWs();
      final cancelled = queue.cancel(immediate: true);
      if (cancelled != null) unawaited(cancelled.catchError((_) {}));
      unawaited(sub.cancel());
      if (!inbox.isClosed) unawaited(inbox.close());
    }
  }
}
