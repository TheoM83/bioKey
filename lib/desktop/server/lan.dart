import 'dart:io';

/// First non-loopback IPv4 address found on the machine, preferring a
/// private-range address (`192.168.x`, `10.x`, `172.16-31.x`) over any
/// other non-loopback IPv4 (e.g. a public/VPN address), so the desktop
/// advertises an address the phone can actually reach on the LAN.
Future<String?> primaryLanIPv4() async {
  final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
  final addresses = <String>[
    for (final interface in interfaces)
      for (final addr in interface.addresses) addr.address,
  ];

  bool isPrivate(String a) =>
      a.startsWith('192.168.') || a.startsWith('10.') || RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(a);

  for (final a in addresses) {
    if (isPrivate(a)) return a;
  }
  return addresses.isEmpty ? null : addresses.first;
}
