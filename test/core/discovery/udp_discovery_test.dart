import 'dart:convert';
import 'dart:io';

import 'package:biokey/core/discovery/udp_discovery.dart';
import 'package:biokey/desktop/server/discovery_responder.dart';
import 'package:biokey/phone/net/discovery_finder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('wire format', () {
    test('isDiscoveryRequest matches the exact request bytes', () {
      expect(isDiscoveryRequest(utf8.encode('BIOKEY1?')), isTrue);
    });

    test('isDiscoveryRequest rejects anything else', () {
      expect(isDiscoveryRequest(utf8.encode('BIOKEY1?x')), isFalse);
      expect(isDiscoveryRequest(utf8.encode('BIOKEY1')), isFalse);
      expect(isDiscoveryRequest(utf8.encode('')), isFalse);
      expect(isDiscoveryRequest([0xff, 0x00, 0x01, 0x02]), isFalse);
    });

    test('format/parse round-trips pcId, tcpPort and name', () {
      final wire = formatDiscoveryReply(pcId: 'abc123', tcpPort: 4433, name: 'Théo’s PC');
      expect(wire, startsWith('BIOKEY1 abc123 4433 '));
      final parsed = parseDiscoveryReply(utf8.encode(wire));
      expect(parsed, isNotNull);
      expect(parsed!.pcId, 'abc123');
      expect(parsed.tcpPort, 4433);
      expect(parsed.name, 'Théo’s PC');
    });

    test('name survives spaces (base64url-encoded, not raw)', () {
      final wire = formatDiscoveryReply(pcId: 'p', tcpPort: 1, name: 'My PC With Spaces');
      final parsed = parseDiscoveryReply(utf8.encode(wire));
      expect(parsed!.name, 'My PC With Spaces');
      // The wire datagram itself must still be exactly 4 space-separated
      // tokens: the name is encoded, not embedded raw.
      expect(utf8.decode(utf8.encode(wire)).split(' '), hasLength(4));
    });

    test('parseDiscoveryReply never throws on garbage', () {
      expect(parseDiscoveryReply([0xff, 0xfe, 0x00, 0x01]), isNull);
      expect(parseDiscoveryReply(utf8.encode('')), isNull);
      expect(parseDiscoveryReply(utf8.encode('BIOKEY1 onlytwo')), isNull);
      expect(parseDiscoveryReply(utf8.encode('WRONG pcid 123 bmFtZQ')), isNull);
      expect(parseDiscoveryReply(utf8.encode('BIOKEY1 pcid notaport bmFtZQ')), isNull);
      expect(parseDiscoveryReply(utf8.encode('BIOKEY1 pcid 123 !!!not-b64!!!')), isNull);
    });
  });

  group('loopback discovery', () {
    late DiscoveryResponder responder;
    late int responderPort;

    Future<int> startResponder({required String pcId, required String name, required int tcpPort}) async {
      final r = DiscoveryResponder();
      // Bind to an ephemeral port by asking the OS for one directly, then
      // reuse it for the responder — RawDatagramSocket.bind(0) picks a
      // free port; we grab it, close, and hand the same number to start().
      final probe = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      probe.close();
      await r.start(pcId: pcId, name: name, tcpPort: tcpPort, bind: InternetAddress.loopbackIPv4, port: port);
      responder = r;
      return port;
    }

    tearDown(() async {
      await responder.stop();
    });

    test('resolves the matching pcId over loopback', () async {
      responderPort = await startResponder(pcId: 'pc-1', name: 'Desktop', tcpPort: 4433);
      final finder = DiscoveryFinder();
      final host = await finder.resolveHost(
        'pc-1',
        targets: [InternetAddress.loopbackIPv4],
        port: responderPort,
        timeout: const Duration(seconds: 2),
      );
      expect(host, InternetAddress.loopbackIPv4.address);
    });

    test('a reply for a different pcId is ignored', () async {
      responderPort = await startResponder(pcId: 'pc-other', name: 'Desktop', tcpPort: 4433);
      final finder = DiscoveryFinder();
      final host = await finder.resolveHost(
        'pc-1',
        targets: [InternetAddress.loopbackIPv4],
        port: responderPort,
        timeout: const Duration(milliseconds: 500),
      );
      expect(host, isNull);
    });

    test('a reply with the wrong tcpPort is ignored', () async {
      responderPort = await startResponder(pcId: 'pc-1', name: 'Desktop', tcpPort: 9999);
      final finder = DiscoveryFinder();
      final host = await finder.resolveHost(
        'pc-1',
        targets: [InternetAddress.loopbackIPv4],
        port: responderPort,
        tcpPort: 4433,
        timeout: const Duration(milliseconds: 500),
      );
      expect(host, isNull);
    });

    test('garbage datagrams do not crash the responder, which keeps answering', () async {
      responderPort = await startResponder(pcId: 'pc-1', name: 'Desktop', tcpPort: 4433);
      final probe = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      probe.send([0xff, 0x00, 0x13, 0x37], InternetAddress.loopbackIPv4, responderPort);
      probe.send(utf8.encode('not the request'), InternetAddress.loopbackIPv4, responderPort);
      probe.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final finder = DiscoveryFinder();
      final host = await finder.resolveHost(
        'pc-1',
        targets: [InternetAddress.loopbackIPv4],
        port: responderPort,
        timeout: const Duration(seconds: 2),
      );
      expect(host, InternetAddress.loopbackIPv4.address);
    });

    test('times out with null when nothing answers', () async {
      final finder = DiscoveryFinder();
      final probe = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final unusedPort = probe.port;
      probe.close();
      final host = await finder.resolveHost(
        'pc-1',
        targets: [InternetAddress.loopbackIPv4],
        port: unusedPort,
        timeout: const Duration(milliseconds: 300),
      );
      expect(host, isNull);
    });
  });
}
