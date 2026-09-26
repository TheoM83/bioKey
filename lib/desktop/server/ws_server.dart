import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show visibleForTesting;
import '../../core/crypto/identity.dart';
import '../../core/protocol/codec.dart';
import '../../core/protocol/messages.dart';
import '../../core/session/desktop_session.dart';

/// The operations [DesktopController] needs from a WebSocket server,
/// extracted so tests can inject a [WsServerApi] fake instead of binding a
/// real TLS socket.
abstract interface class WsServerApi {
  Future<void> start({String address = '0.0.0.0', required int port});
  int get port;
  Future<void> stop();
  void apply(List<DesktopEffect> fx);
}

/// Pinned-TLS WebSocket server: accepts connections from the phone,
/// feeds incoming frames into the pure [DesktopSession] state machine,
/// and executes the [DesktopEffect]s it returns (send/close), plus a
/// periodic tick and keep-alive ping on the paired connection.
///
/// Hardening: every socket gets a 15 s WebSocket-level ping (so a phone
/// that vanished from the network is detected as offline within ~30 s
/// instead of waiting for TCP to give up), at most [maxConnections] sockets
/// are served at once, a text frame larger than [maxFrameBytes] closes the
/// socket, and a socket that hasn't authenticated (no `welcome`/`paired`
/// sent to it yet) is closed after [unauthIdle] without a frame — extended
/// to [pairingIdle] once it has been sent a `pair_challenge`, since the
/// user is then looking at a fingerprint prompt.
final class WsServer implements WsServerApi {
  WsServer({
    required this.identity,
    required this.session,
    required this.onEffect,
    this.unauthIdle = const Duration(seconds: 10),
    this.pairingIdle = const Duration(seconds: DesktopSession.pairingTtl),
  });

  static const pingInterval = Duration(seconds: 15);
  static const maxConnections = 8;
  static const maxFrameBytes = 64 * 1024;

  final DesktopIdentity identity;
  final DesktopSession session;
  final void Function(DesktopEffect) onEffect;
  final Duration unauthIdle;
  final Duration pairingIdle;

  HttpServer? _http;
  final _conns = <String, WebSocket>{};
  final _authed = <String>{};
  final _idle = <String, Timer>{};
  final _idleFor = <String, Duration>{};
  int _seq = 0;
  int _upgrading = 0;
  Timer? _tick;
  Timer? _ping;

  @override
  int get port => _http?.port ?? 0;

  /// The live server-side sockets, for tests asserting per-socket settings.
  @visibleForTesting
  Iterable<WebSocket> get connections => _conns.values;

  @override
  Future<void> start({String address = '0.0.0.0', required int port}) async {
    _http = await HttpServer.bindSecure(address, port, identity.securityContext(), shared: false);
    _http!.listen((req) => unawaited(_onRequest(req)), onError: (Object _) {});
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => apply(session.tick()));
    _ping = Timer.periodic(const Duration(seconds: 45), (_) {
      for (final ws in _conns.values) {
        ws.add(Codec.encode(const PingMsg()));
      }
    });
  }

  Future<void> _onRequest(HttpRequest req) async {
    if (!WebSocketTransformer.isUpgradeRequest(req)) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    if (_conns.length + _upgrading >= maxConnections) {
      req.response.statusCode = HttpStatus.serviceUnavailable;
      await req.response.close();
      return;
    }
    _upgrading++;
    final WebSocket ws;
    try {
      ws = await WebSocketTransformer.upgrade(req);
    } on Object {
      return;
    } finally {
      _upgrading--;
    }
    ws.pingInterval = pingInterval;
    final connId = 'c${++_seq}';
    _conns[connId] = ws;
    _armIdle(connId, unauthIdle);
    void gone() {
      _forget(connId);
      apply(session.onDisconnect(connId));
    }

    ws.listen(
      (Object? data) {
        if (data is String && !_tooBig(data)) {
          final idleFor = _idleFor[connId];
          if (!_authed.contains(connId) && idleFor != null) _armIdle(connId, idleFor);
          apply(session.onFrame(connId, data));
        } else {
          apply([CloseConn(connId)]);
        }
      },
      onDone: gone,
      onError: (Object _) => gone(),
      cancelOnError: true,
    );
  }

  bool _tooBig(String s) => s.length > maxFrameBytes || (s.length * 3 > maxFrameBytes && utf8.encode(s).length > maxFrameBytes);

  void _armIdle(String connId, Duration d) {
    _idle.remove(connId)?.cancel();
    _idleFor[connId] = d;
    _idle[connId] = Timer(d, () {
      _idle.remove(connId);
      _idleFor.remove(connId);
      if (!_authed.contains(connId)) apply([CloseConn(connId)]);
    });
  }

  void _forget(String connId) {
    _conns.remove(connId);
    _authed.remove(connId);
    _idle.remove(connId)?.cancel();
    _idleFor.remove(connId);
  }

  /// Tracks authentication/pairing progress from the frames we send, so the
  /// idle rule above knows which sockets it applies to.
  void _observeOutgoing(String connId, String frame) {
    final Message m;
    try {
      m = Codec.decode(frame);
    } on ProtocolException {
      return;
    }
    switch (m) {
      case WelcomeMsg() || PairedMsg():
        _authed.add(connId);
        _idle.remove(connId)?.cancel();
        _idleFor.remove(connId);
      case PairChallengeMsg():
        _armIdle(connId, pairingIdle);
      default:
        break;
    }
  }

  /// Executes every [SendFrame]/[CloseConn] effect against the live
  /// connections, then forwards every effect (including the others) to
  /// [onEffect] so the caller can react (e.g. update UI state).
  @override
  void apply(List<DesktopEffect> fx) {
    for (final e in fx) {
      switch (e) {
        case SendFrame():
          final ws = _conns[e.connId];
          if (ws != null) {
            _observeOutgoing(e.connId, e.frame);
            ws.add(e.frame);
          }
        case CloseConn():
          final ws = _conns[e.connId];
          _forget(e.connId);
          unawaited(ws?.close(WebSocketStatus.policyViolation));
        case AuthResolved():
        case PhonePaired():
        case PhoneOnline():
        case PairingExpired():
        case PairingInvalid():
          break;
      }
      onEffect(e);
    }
  }

  @override
  Future<void> stop() async {
    _tick?.cancel();
    _ping?.cancel();
    _tick = null;
    _ping = null;
    for (final t in _idle.values) {
      t.cancel();
    }
    _idle.clear();
    _idleFor.clear();
    for (final ws in _conns.values.toList()) {
      await ws.close();
    }
    _conns.clear();
    _authed.clear();
    await _http?.close(force: true);
    _http = null;
  }
}
