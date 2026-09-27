import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/core/discovery/udp_discovery.dart';
import 'package:biokey/phone/net/discovery_finder.dart';

/// A minimal fake `DiscoveryResponder`-alike: replies to every `BIOKEY1?`
/// request it receives with a fixed [pcId]/[tcpPort]/[name], regardless of
/// who asked — used to simulate a second BioKey desktop (or some other
/// service) answering on the discovery port with the right pcId but a
/// different (wrong) tcpPort, the case [DiscoveryFinder.resolveHost]'s
/// `tcpPort` filter exists to reject.
final class _FakeResponder {
  _FakeResponder(this.pcId, this.tcpPort, this.name);
  final String pcId;
  final int tcpPort;
  final String name;

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _sub;

  Future<int> start() async {
    final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    _socket = socket;
    final reply = utf8.encode(formatDiscoveryReply(pcId: pcId, tcpPort: tcpPort, name: name));
    _sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      if (!isDiscoveryRequest(datagram.data)) return;
      socket.send(reply, datagram.address, datagram.port);
    });
    return socket.port;
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _socket?.close();
  }
}

void main() {
  test('resolveHost accepts a reply whose tcpPort matches', () async {
    final responder = _FakeResponder('pc-1', 47621, 'PC');
    final port = await responder.start();
    addTearDown(responder.stop);

    final host = await DiscoveryFinder().resolveHost(
      'pc-1',
      targets: [InternetAddress.loopbackIPv4],
      port: port,
      tcpPort: 47621,
      timeout: const Duration(seconds: 2),
    );
    expect(host, InternetAddress.loopbackIPv4.address);
  });

  test('resolveHost ignores a reply for the right pcId but the wrong tcpPort', () async {
    // Simulates the exact scenario foreground.dart's per-PC tcpPort
    // closure guards against: something else on the LAN answers
    // discovery for the same pcId but on a different port than the one
    // this PC was actually paired on.
    final responder = _FakeResponder('pc-1', 9999, 'Impostor');
    final port = await responder.start();
    addTearDown(responder.stop);

    final host = await DiscoveryFinder().resolveHost(
      'pc-1',
      targets: [InternetAddress.loopbackIPv4],
      port: port,
      tcpPort: 47621,
      timeout: const Duration(milliseconds: 500),
    );
    expect(host, isNull);
  });

  test('resolveHost with no tcpPort given accepts any port for a matching pcId', () async {
    final responder = _FakeResponder('pc-1', 9999, 'Whatever');
    final port = await responder.start();
    addTearDown(responder.stop);

    final host = await DiscoveryFinder().resolveHost(
      'pc-1',
      targets: [InternetAddress.loopbackIPv4],
      port: port,
      timeout: const Duration(seconds: 2),
    );
    expect(host, InternetAddress.loopbackIPv4.address);
  });
}
