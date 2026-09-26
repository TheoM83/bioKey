import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/discovery/udp_discovery.dart';

/// Finds a paired PC's current LAN IP by UDP broadcast when its last-known
/// host stops answering (Wi-Fi roaming, DHCP lease change, …) — see
/// `udp_discovery.dart` for the wire protocol.
///
/// A resolved host is never trusted on its own: `PcLink` only adopts it
/// once a pinned `welcome` actually arrives over it.
final class DiscoveryFinder {
  /// Broadcasts a `BIOKEY1?` request and returns the sender address of the
  /// first reply whose `pcId` matches [pcId] (and, when [tcpPort] is
  /// given, whose `tcpPort` also matches — otherwise that reply is
  /// ignored). Returns `null` if nothing matching arrives within [timeout].
  ///
  /// Sends to [targets] when given (tests), otherwise to
  /// `255.255.255.255` plus each interface's subnet-directed broadcast —
  /// all at [port] (defaults to [discoveryPort]; overridable for tests
  /// alongside [targets]).
  Future<String?> resolveHost(
    String pcId, {
    Duration timeout = const Duration(seconds: 3),
    List<InternetAddress>? targets,
    int? tcpPort,
    int port = discoveryPort,
  }) async {
    RawDatagramSocket? socket;
    StreamSubscription<RawSocketEvent>? sub;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final bound = socket;
      bound.broadcastEnabled = true;

      final completer = Completer<String?>();
      sub = bound.listen(
        (event) {
          if (event != RawSocketEvent.read) return;
          final datagram = bound.receive();
          if (datagram == null) return;
          final reply = parseDiscoveryReply(datagram.data);
          if (reply == null) return;
          if (reply.pcId != pcId) return;
          if (tcpPort != null && reply.tcpPort != tcpPort) return;
          if (!completer.isCompleted) completer.complete(datagram.address.address);
        },
        onError: (Object _) {
          // A malformed reply or transient socket error just isn't a
          // match — never crash the lookup over it.
        },
      );

      final dests = targets ?? await _defaultTargets();
      final request = utf8.encode(discoveryRequest);
      for (final dest in dests) {
        try {
          bound.send(request, dest, port);
        } on Object {
          // A target that refuses the send (e.g. no route on that
          // interface right now) shouldn't stop the others from being
          // tried.
        }
      }

      return await completer.future.timeout(timeout, onTimeout: () => null);
    } finally {
      await sub?.cancel();
      socket?.close();
    }
  }

  /// `255.255.255.255` plus each non-loopback IPv4 interface's
  /// subnet-directed broadcast address, assuming a /24 (`dart:io` doesn't
  /// expose the actual prefix length).
  Future<List<InternetAddress>> _defaultTargets() async {
    final targets = <InternetAddress>[InternetAddress('255.255.255.255')];
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length != 4) continue;
          targets.add(InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255'));
        }
      }
    } on Object {
      // No interfaces available (sandboxed/offline test env): fall back
      // to the global broadcast address alone.
    }
    return targets;
  }
}
