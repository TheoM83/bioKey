import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/discovery/udp_discovery.dart';

/// Answers UDP discovery requests on the LAN so the phone can find this
/// PC's current IP without manual entry — see `udp_discovery.dart` for the
/// wire protocol.
///
/// Never trusts or echoes attacker-controlled data: only the fixed
/// `BIOKEY1?` request gets a reply, and the reply's content comes entirely
/// from [start]'s own arguments, never from the request. Replies are
/// rate-limited (20/s) so a flood of requests — including ones with a
/// spoofed source address — can't turn this into a traffic amplifier or
/// peg the process.
final class DiscoveryResponder {
  static const _maxRepliesPerSecond = 20;

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _sub;

  /// Binds a UDP socket ([bind] defaults to `INADDR_ANY`; [port] defaults
  /// to [discoveryPort] — both overridable for tests) and starts answering
  /// `BIOKEY1?` requests with a reply built from [pcId]/[tcpPort]/[name].
  Future<void> start({
    required String pcId,
    required String name,
    required int tcpPort,
    InternetAddress? bind,
    int port = discoveryPort,
  }) async {
    final socket = await RawDatagramSocket.bind(bind ?? InternetAddress.anyIPv4, port, reuseAddress: true);
    socket.broadcastEnabled = true;
    final reply = utf8.encode(formatDiscoveryReply(pcId: pcId, tcpPort: tcpPort, name: name));

    var windowStart = DateTime.now();
    var sentInWindow = 0;

    _socket = socket;
    _sub = socket.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram == null) return;
        if (!isDiscoveryRequest(datagram.data)) return;

        final now = DateTime.now();
        if (now.difference(windowStart) >= const Duration(seconds: 1)) {
          windowStart = now;
          sentInWindow = 0;
        }
        if (sentInWindow >= _maxRepliesPerSecond) return;
        sentInWindow++;
        try {
          socket.send(reply, datagram.address, datagram.port);
        } on Object {
          // A send that fails (e.g. the interface just went down) must not
          // take the responder down — the next request gets a fresh try.
        }
      },
      onError: (Object _) {
        // A transient socket error must never take the responder down —
        // just drop it and keep listening.
      },
    );
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _socket?.close();
    _socket = null;
  }
}
