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

  /// An mDNS-resolved host awaiting confirmation: connect attempts prefer
  /// it over [pc]'s stored host, but it only overwrites [pc] (and gets
  /// persisted via a [PhonePairedWith] effect) once a `welcome` actually
  /// arrives on it — resolving a host is not proof it's reachable.
  String? _pendingHost;

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
    await _ws?.close();
    final future = _loopFuture;
    if (future != null) {
      await future.timeout(const Duration(seconds: 6), onTimeout: () {});
    }
    _ws = null;
    _loopFuture = null;
  }

  bool _stale(int gen) => !_running || gen != _gen;

  Future<void> _loop(int gen) async {
    while (!_stale(gen)) {
      WebSocket? ws;
      try {
        final host = _pendingHost ?? pc.host;
        ws = await _connect(host, pc.port, pc.fingerprint);
        if (_stale(gen)) return; // stop() raced the connect: close in finally, don't touch _ws.
        _ws = ws;
        _apply(await _session.hello(pc));
        if (_stale(gen)) return;
        await for (final data in ws) {
          if (_stale(gen)) break;
          if (data is! String) break;
          final fx = await _session.onFrame(pc, data);
          if (_isWelcome(data)) _markOnline(host);
          _apply(fx);
          if (_stale(gen)) break;
        }
      } on Object {
        // Connect or read failure: fall through to the backoff below.
      } finally {
        final leaked = ws;
        if (leaked != null) {
          unawaited(leaked.close());
        }
        if (identical(_ws, ws)) _ws = null;
      }
      _markOffline();
      if (_stale(gen)) return;
      if (_attempt >= 1 && _resolve != null) {
        final h = await _resolve(pc.pcId);
        if (_stale(gen)) return; // e.g. revoked while we were resolving.
        if (h != null && h != pc.host) _pendingHost = h;
      }
      if (_stale(gen)) return;
      await Future<void>.delayed(_backoff(_attempt));
      _attempt++;
    }
  }

  bool _isWelcome(String frame) {
    try {
      return Codec.decode(frame) is WelcomeMsg;
    } on ProtocolException {
      return false;
    }
  }

  void _markOnline(String connectedHost) {
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

  void _markOffline() {
    if (online) {
      online = false;
      onEffect(PhoneOnlineChanged(pc.pcId, false));
    }
  }

  void _apply(List<PhoneEffect> fx) {
    for (final e in fx) {
      switch (e) {
        case PhoneSend():
          _ws?.add(e.frame);
        case PhoneClose():
          unawaited(_ws?.close());
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
  static Future<PairedPc> pair({
    required QrPayload qr,
    required PhoneSession session,
    required void Function(PhoneEffect) onEffect,
    Connect? connect,
  }) async {
    WebSocket? ws;
    try {
      return await _pair(qr: qr, session: session, onEffect: onEffect, connect: connect, bindSocket: (w) => ws = w)
          .timeout(const Duration(seconds: 60));
    } finally {
      // Covers the timeout path: `_pair`'s own try/finally already closes
      // the socket on every path it controls, so this is a best-effort
      // backstop for "the future never even got a chance to unwind" (the
      // 60 s timeout abandons — but doesn't cancel — the original future).
      unawaited(ws?.close());
    }
  }

  static Future<PairedPc> _pair({
    required QrPayload qr,
    required PhoneSession session,
    required void Function(PhoneEffect) onEffect,
    required void Function(WebSocket) bindSocket,
    Connect? connect,
  }) async {
    final ws = await (connect ?? _defaultConnect)(qr.host, qr.port, qr.fingerprint);
    bindSocket(ws);
    final queue = StreamQueue<Object?>(ws);
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
      final tmp = PairedPc(pcId: qr.pcId, name: qr.name, host: qr.host, port: qr.port, fingerprint: qr.fingerprint, session: '');

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
              paired = e.pc;
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
    }
  }
}
