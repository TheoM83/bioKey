import 'dart:convert';

/// UDP port used for BioKey's LAN discovery: `DiscoveryResponder` (desktop)
/// listens here, `DiscoveryFinder` (phone) broadcasts here — a tiny
/// hand-rolled request/response protocol (replaces the old mDNS/Bonjour
/// discovery).
const int discoveryPort = 47623;

/// The fixed, ASCII discovery request datagram. A responder answers only
/// this exact byte sequence — anything else (a stray broadcast, garbage, an
/// attacker probing the port) is ignored outright, never echoed back.
const String discoveryRequest = 'BIOKEY1?';

/// True iff [datagram] is exactly the discovery request — an exact-match
/// check, never a prefix/contains one, so a datagram merely starting with
/// the right bytes doesn't pass.
bool isDiscoveryRequest(List<int> datagram) {
  final bytes = utf8.encode(discoveryRequest);
  if (datagram.length != bytes.length) return false;
  for (var i = 0; i < bytes.length; i++) {
    if (datagram[i] != bytes[i]) return false;
  }
  return true;
}

/// A parsed discovery reply: the PC's id, the TCP port its pinned-TLS
/// server listens on, and its display name.
final class DiscoveryReply {
  const DiscoveryReply({required this.pcId, required this.tcpPort, required this.name});

  final String pcId;
  final int tcpPort;
  final String name;

  @override
  String toString() => 'DiscoveryReply(pcId: $pcId, tcpPort: $tcpPort, name: $name)';
}

/// Formats a discovery reply datagram: `BIOKEY1`, a space, [pcId], a
/// space, [tcpPort], a space, then [name] base64url-encoded (no padding)
/// rather than raw text — so a name containing spaces or non-ASCII
/// characters can't break the space-delimited wire format.
String formatDiscoveryReply({required String pcId, required int tcpPort, required String name}) {
  final nameB64 = base64UrlEncode(utf8.encode(name)).replaceAll('=', '');
  return 'BIOKEY1 $pcId $tcpPort $nameB64';
}

/// Parses a reply datagram, or returns `null` if it isn't a well-formed
/// discovery reply — never throws, however malformed or adversarial
/// [datagram] is.
DiscoveryReply? parseDiscoveryReply(List<int> datagram) {
  String text;
  try {
    text = utf8.decode(datagram);
  } on FormatException {
    return null;
  }
  final parts = text.split(' ');
  if (parts.length != 4 || parts[0] != 'BIOKEY1') return null;
  final tcpPort = int.tryParse(parts[2]);
  if (tcpPort == null) return null;
  String name;
  try {
    name = utf8.decode(base64Url.decode(_withPadding(parts[3])));
  } on FormatException {
    return null;
  }
  return DiscoveryReply(pcId: parts[1], tcpPort: tcpPort, name: name);
}

/// `base64Url.decode` requires padding; the wire format omits it.
String _withPadding(String s) {
  final rem = s.length % 4;
  return rem == 0 ? s : s + '=' * (4 - rem);
}
