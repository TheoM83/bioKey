import 'dart:async';
import 'dart:io';
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

  /// The paired PC this link talks to. Mutated in place when mDNS resolves
  /// a new host after the stored one stops answering; callers should read
  /// this (e.g. to persist it) after a [PhonePairedWith] effect.
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

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    unawaited(_loop());
  }

  @override
  Future<void> stop() async {
    _running = false;
    await _ws?.close();
    _ws = null;
  }

  Future<void> _loop() async {
    while (_running) {
      try {
        final ws = await _connect(pc.host, pc.port, pc.fingerprint);
        _ws = ws;
        _apply(await _session.hello(pc));
        await for (final data in ws) {
          if (!_running) break;
          if (data is! String) break;
          final fx = await _session.onFrame(pc, data);
          if (_isWelcome(data)) _markOnline();
          _apply(fx);
        }
      } on Object {
        // Connect or read failure: fall through to the backoff below.
      }
      _markOffline();
      _ws = null;
      if (!_running) break;
      if (_attempt >= 1 && _resolve != null) {
        final h = await _resolve(pc.pcId);
        if (h != null && h != pc.host) {
          pc = PairedPc(pcId: pc.pcId, name: pc.name, host: h, port: pc.port, fingerprint: pc.fingerprint, session: pc.session);
          onEffect(PhonePairedWith(pc));
        }
      }
      if (!_running) break;
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

  void _markOnline() {
    _attempt = 0;
    if (!online) {
      online = true;
      onEffect(PhoneOnlineChanged(pc.pcId, true));
    }
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
  static Future<PairedPc> pair({
    required QrPayload qr,
    required PhoneSession session,
    required void Function(PhoneEffect) onEffect,
    Connect? connect,
  }) async {
    final ws = await (connect ?? _defaultConnect)(qr.host, qr.port, qr.fingerprint);
    // Only `pc.name` is read by the session before `paired` arrives (for the
    // biometric prompt); the real session secret is not known until then.
    final tmp = PairedPc(pcId: qr.pcId, name: qr.name, host: qr.host, port: qr.port, fingerprint: qr.fingerprint, session: '');
    final done = Completer<PairedPc>();
    late final StreamSubscription<Object?> sub;

    // Stops listening and fully closes the (one-shot) pairing socket before
    // resolving `done`: without this, a caller that immediately opens the
    // real [PcLink] can race the desktop's disconnect handling for this
    // connection — `WebSocket.close()` only waits for *our* sink to flush,
    // not for the desktop to observe the disconnect, so the desktop can
    // still briefly consider this now-defunct connection "the phone" and
    // route frames (e.g. an auth request) to a socket nobody is reading
    // anymore. The short grace delay gives the loopback FIN time to reach
    // the desktop and its disconnect handler time to run before we hand
    // back control.
    Future<void> finish(void Function() complete) async {
      await sub.cancel();
      await ws.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      complete();
    }

    void apply(List<PhoneEffect> fx) {
      for (final e in fx) {
        switch (e) {
          case PhoneSend():
            ws.add(e.frame);
          case PhoneClose():
            unawaited(finish(() {
              if (!done.isCompleted) done.completeError(StateError('appairage refusé'));
            }));
          case PhonePairedWith():
            unawaited(finish(() {
              if (!done.isCompleted) done.complete(e.pc);
            }));
          default:
            onEffect(e);
        }
      }
    }

    apply(await session.beginPairing(qr));
    sub = ws.listen(
      (Object? d) async {
        if (d is String) apply(await session.onFrame(tmp, d));
      },
      onDone: () {
        if (!done.isCompleted) done.completeError(StateError('connexion fermée pendant l’appairage'));
      },
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
    );
    return done.future;
  }
}
