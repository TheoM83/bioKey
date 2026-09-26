import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../core/discovery/udp_discovery.dart';

/// Answers UDP discovery requests on the LAN so the phone can find this
/// PC's current IP without manual entry — see `udp_discovery.dart` for the
/// wire protocol.
///
/// Never trusts or echoes attacker-controlled data: only the fixed
/// `BIOKEY1?` request gets a reply, and the reply's content comes entirely
/// from [start]'s own arguments, never from the request. Replies are
/// rate-limited both per source address ([_maxRepliesPerSecondPerSource])
/// and overall ([_maxRepliesPerSecondGlobal]), so a flood from one spoofed
/// or real source can't starve replies to every other one, and a flood
/// from many sources at once still can't turn this into a traffic
/// amplifier or peg the process.
final class DiscoveryResponder {
  static const _maxRepliesPerSecondPerSource = 20;
  static const _maxRepliesPerSecondGlobal = 100;

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _sub;

  /// The bound UDP port, for tests that bind an ephemeral one.
  @visibleForTesting
  int get port => _socket?.port ?? 0;

  /// Binds a UDP socket ([bind] defaults to `INADDR_ANY`; [port] defaults
  /// to [discoveryPort] — both overridable for tests) and starts answering
  /// `BIOKEY1?` requests with a reply built from [pcId]/[tcpPort]/[name].
  ///
  /// A call while already running stops the previous socket first, rather
  /// than binding a second one alongside it — [start] always leaves exactly
  /// one responder alive, never two racing for the same port.
  Future<void> start({
    required String pcId,
    required String name,
    required int tcpPort,
    InternetAddress? bind,
    int port = discoveryPort,
  }) async {
    await stop();

    // reuseAddress is deliberately false. Exactly one DesktopController —
    // and so exactly one DiscoveryResponder — ever runs per machine (see
    // the single-instance guard in desktop/apps/single_instance.dart);
    // there is no legitimate reason for a second process to share this
    // port, and reuseAddress: true would let that happen silently instead
    // of failing loudly with an "address in use" error.
    final socket = await RawDatagramSocket.bind(bind ?? InternetAddress.anyIPv4, port, reuseAddress: false);
    socket.broadcastEnabled = true;
    final reply = utf8.encode(formatDiscoveryReply(pcId: pcId, tcpPort: tcpPort, name: name));

    var windowStart = DateTime.now();
    var globalInWindow = 0;
    final perSourceInWindow = <String, int>{};

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
          globalInWindow = 0;
          perSourceInWindow.clear();
        }
        if (globalInWindow >= _maxRepliesPerSecondGlobal) return;

        final source = datagram.address.address;
        final sourceCount = perSourceInWindow[source] ?? 0;
        if (sourceCount >= _maxRepliesPerSecondPerSource) return;

        globalInWindow++;
        perSourceInWindow[source] = sourceCount + 1;
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
