import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show visibleForTesting;
import '../../core/crypto/identity.dart';
import '../../core/protocol/codec.dart';
import '../../core/protocol/framing.dart';
import '../../core/protocol/messages.dart';
import '../../core/session/desktop_session.dart';

/// The operations [DesktopController] needs from a link server, extracted
/// so tests can inject a [LinkServerApi] fake instead of binding a real TLS
/// socket.
abstract interface class LinkServerApi {
  Future<void> start({String address = '0.0.0.0', required int port});
  int get port;
  Future<void> stop();
  void apply(List<DesktopEffect> fx);
}

/// Pinned-TLS raw-socket server: accepts connections from the phone over
/// length-prefixed JSON frames (`framing.dart`), feeds incoming frames into
/// the pure [DesktopSession] state machine, and executes the
/// [DesktopEffect]s it returns (send/close), plus a periodic tick and a
/// protocol-level keep-alive ping on every open connection.
///
/// Hardening: at most [maxConnections] sockets are served at once (a
/// connection over the cap still completes its TLS handshake — that can't
/// be avoided with `SecureServerSocket`, which only yields already-connected
/// sockets — but is destroyed immediately, before any frame is read), a
/// socket that hasn't authenticated (no `welcome`/`paired` sent to it yet)
/// is closed after [unauthIdle] without a frame — extended to [pairingIdle]
/// once it has been sent a `pair_challenge`, since the user is then looking
/// at a fingerprint prompt — and, once authenticated, a socket that has sent
/// no frame at all for [livenessTimeout] is closed too. That liveness rule
/// replaces a transport-level ping/pong: the phone sends a protocol `ping`
/// every 30 s when otherwise idle, which is enough to keep resetting it.
final class TlsServer implements LinkServerApi {
  TlsServer({
    required this.identity,
    required this.session,
    required this.onEffect,
    this.unauthIdle = const Duration(seconds: 10),
    this.pairingIdle = const Duration(seconds: DesktopSession.pairingTtl),
    this.livenessTimeout = const Duration(seconds: 60),
  });

  static const pingInterval = Duration(seconds: 45);
  static const maxConnections = 8;

  final DesktopIdentity identity;
  final DesktopSession session;
  final void Function(DesktopEffect) onEffect;
  final Duration unauthIdle;
  final Duration pairingIdle;
  final Duration livenessTimeout;

  SecureServerSocket? _server;
  StreamSubscription<SecureSocket>? _serverSub;
  final _conns = <String, SecureSocket>{};
  final _authed = <String>{};
  final _idle = <String, Timer>{};
  final _idleFor = <String, Duration>{};
  int _seq = 0;
  Timer? _tick;
  Timer? _ping;

  @override
  int get port => _server?.port ?? 0;

  /// The live server-side sockets, for tests asserting per-socket settings.
  @visibleForTesting
  Iterable<SecureSocket> get connections => _conns.values;

  @override
  Future<void> start({String address = '0.0.0.0', required int port}) async {
    _server = await SecureServerSocket.bind(address, port, identity.securityContext());
    _serverSub = _server!.listen(_onConnection, onError: (Object _) {});
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => apply(session.tick()));
    _ping = Timer.periodic(pingInterval, (_) {
      final frame = encodeFrame(Codec.encode(const PingMsg()));
      // Snapshot the ids first: a failed write drops the connection (see
      // _dropConnection), which mutates _conns — iterating it directly
      // while removing entries from it would throw.
      for (final connId in _conns.keys.toList()) {
        final socket = _conns[connId];
        if (socket == null) continue;
        try {
          socket.add(frame);
        } on Object {
          _dropConnection(connId);
        }
      }
    });
  }

  void _onConnection(SecureSocket socket) {
    if (_conns.length >= maxConnections) {
      socket.destroy();
      return;
    }
    socket.setOption(SocketOption.tcpNoDelay, true);
    final connId = 'c${++_seq}';
    _conns[connId] = socket;
    _armIdle(connId, unauthIdle);

    FrameDecoder().bind(socket).listen(
      (payload) {
        _armIdle(connId, _idleFor[connId] ?? unauthIdle);
        apply(session.onFrame(connId, payload));
      },
      onDone: () => _dropConnection(connId),
      onError: (Object _) => _dropConnection(connId),
      cancelOnError: true,
    );
  }

  /// Idempotent teardown for one connection: destroys the socket (unless
  /// already forgotten) and applies the session's `onDisconnect` effects.
  /// Called both when the socket's own stream ends/errors and when a write
  /// to it fails (a socket that can no longer be written to — e.g. the
  /// peer reset the connection — is just as gone as one whose read side
  /// closed; dropping it here, rather than letting the exception escape
  /// [apply] or the ping timer, keeps one dead socket from taking either
  /// down).
  void _dropConnection(String connId) {
    final socket = _conns[connId];
    if (socket == null) return;
    _forget(connId);
    socket.destroy();
    apply(session.onDisconnect(connId));
  }

  void _armIdle(String connId, Duration d) {
    _idle.remove(connId)?.cancel();
    _idleFor[connId] = d;
    _idle[connId] = Timer(d, () {
      _idle.remove(connId);
      _idleFor.remove(connId);
      apply([CloseConn(connId)]);
    });
  }

  void _forget(String connId) {
    _conns.remove(connId);
    _authed.remove(connId);
    _idle.remove(connId)?.cancel();
    _idleFor.remove(connId);
  }

  /// Tracks authentication/pairing progress from the frames we send, so the
  /// idle/liveness rule above knows which duration currently applies.
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
        _armIdle(connId, livenessTimeout);
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
          final socket = _conns[e.connId];
          if (socket != null) {
            _observeOutgoing(e.connId, e.frame);
            try {
              socket.add(encodeFrame(e.frame));
            } on Object {
              _dropConnection(e.connId);
            }
          }
        case CloseConn():
          final socket = _conns[e.connId];
          _forget(e.connId);
          socket?.destroy();
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
    for (final socket in _conns.values.toList()) {
      socket.destroy();
    }
    _conns.clear();
    _authed.clear();
    await _serverSub?.cancel();
    _serverSub = null;
    await _server?.close();
    _server = null;
  }
}
