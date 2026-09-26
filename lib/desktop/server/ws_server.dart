import 'dart:async';
import 'dart:io';
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
final class WsServer implements WsServerApi {
  WsServer({required this.identity, required this.session, required this.onEffect});

  final DesktopIdentity identity;
  final DesktopSession session;
  final void Function(DesktopEffect) onEffect;

  HttpServer? _http;
  final _conns = <String, WebSocket>{};
  int _seq = 0;
  Timer? _tick;
  Timer? _ping;

  @override
  int get port => _http?.port ?? 0;

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
    final ws = await WebSocketTransformer.upgrade(req);
    final connId = 'c${++_seq}';
    _conns[connId] = ws;
    ws.listen(
      (Object? data) {
        if (data is String) {
          apply(session.onFrame(connId, data));
        } else {
          apply([CloseConn(connId)]);
        }
      },
      onDone: () {
        _conns.remove(connId);
        apply(session.onDisconnect(connId));
      },
      onError: (Object _) {
        _conns.remove(connId);
        apply(session.onDisconnect(connId));
      },
      cancelOnError: true,
    );
  }

  /// Executes every [SendFrame]/[CloseConn] effect against the live
  /// connections, then forwards every effect (including the others) to
  /// [onEffect] so the caller can react (e.g. update UI state).
  @override
  void apply(List<DesktopEffect> fx) {
    for (final e in fx) {
      switch (e) {
        case SendFrame():
          _conns[e.connId]?.add(e.frame);
        case CloseConn():
          unawaited(_conns.remove(e.connId)?.close(WebSocketStatus.policyViolation));
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
    for (final ws in _conns.values) {
      await ws.close();
    }
    _conns.clear();
    await _http?.close(force: true);
    _http = null;
  }
}
