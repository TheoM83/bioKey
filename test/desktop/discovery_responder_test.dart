import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/core/discovery/udp_discovery.dart';
import 'package:biokey/desktop/server/discovery_responder.dart';

void main() {
  late DiscoveryResponder responder;

  tearDown(() => responder.stop());

  test('two sources flooding are each capped independently; a third quiet source still gets a reply', () async {
    responder = DiscoveryResponder();
    await responder.start(pcId: 'pc1', name: 'PC', tcpPort: 1234, bind: InternetAddress.anyIPv4, port: 0);
    final port = responder.port;

    // Three distinct source addresses on loopback (127.0.0.0/8 is all
    // loopback) so the responder sees genuinely different senders without
    // needing real separate machines.
    final flooderA = await RawDatagramSocket.bind(InternetAddress('127.0.0.2'), 0);
    final flooderB = await RawDatagramSocket.bind(InternetAddress('127.0.0.3'), 0);
    final quiet = await RawDatagramSocket.bind(InternetAddress('127.0.0.4'), 0);

    final repliesTo = <String, int>{'A': 0, 'B': 0, 'quiet': 0};
    void countReplies(RawDatagramSocket s, String who) {
      s.listen((event) {
        if (event != RawSocketEvent.read) return;
        final d = s.receive();
        if (d != null) repliesTo[who] = (repliesTo[who] ?? 0) + 1;
      });
    }

    countReplies(flooderA, 'A');
    countReplies(flooderB, 'B');
    countReplies(quiet, 'quiet');

    final request = discoveryRequest.codeUnits;
    final dest = InternetAddress('127.0.0.1');

    // Each flooder sends well over the per-source cap (20/s) within the
    // same one-second window. Paced in small bursts (rather than one tight
    // loop) so the OS socket buffers on a busy CI box don't just drop a
    // pile of back-to-back datagrams before the responder ever sees them —
    // that would understate the count without proving anything about the
    // rate limiter itself.
    for (var i = 0; i < 40; i++) {
      flooderA.send(request, dest, port);
      flooderB.send(request, dest, port);
      if (i % 5 == 0) await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    // The quiet source sends just once.
    quiet.send(request, dest, port);

    // Let the responder work through the flood and the quiet request.
    await Future<void>.delayed(const Duration(milliseconds: 700));

    // Exact counts can wobble slightly with real UDP scheduling, but the
    // cap must always hold, and it must be doing something (nowhere near
    // all 40 sent per flooder get a reply).
    expect(repliesTo['A'], inInclusiveRange(10, 20), reason: 'flooder A is capped at (around) the per-source limit');
    expect(repliesTo['B'], inInclusiveRange(10, 20), reason: "flooder B is capped independently of A's flood");
    expect(repliesTo['quiet'], 1, reason: 'a quiet third source still gets its reply despite the concurrent floods');

    flooderA.close();
    flooderB.close();
    quiet.close();
  });

  test('a second start() replaces the first responder instead of leaving two bound', () async {
    responder = DiscoveryResponder();
    await responder.start(pcId: 'pc1', name: 'PC', tcpPort: 1, bind: InternetAddress.anyIPv4, port: 0);
    final firstPort = responder.port;

    // Rebinding to the same port must succeed — if the first socket were
    // still alive, this bind would fail with "address in use".
    await responder.start(pcId: 'pc1', name: 'PC', tcpPort: 2, bind: InternetAddress.anyIPv4, port: firstPort);
    expect(responder.port, firstPort);

    final client = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final reply = Completer<DiscoveryReply>();
    client.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = client.receive();
      if (d == null) return;
      final parsed = parseDiscoveryReply(d.data);
      if (parsed != null && !reply.isCompleted) reply.complete(parsed);
    });
    client.send(discoveryRequest.codeUnits, InternetAddress('127.0.0.1'), firstPort);
    final got = await reply.future.timeout(const Duration(seconds: 2));
    expect(got.tcpPort, 2, reason: 'the second start() is the one actually answering, not a leaked first one');
    client.close();
  });
}
