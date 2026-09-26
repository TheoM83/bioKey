import 'dart:io';

/// One network interface as seen by [pickLanIPv4]: its OS name and IPv4
/// addresses. Extracted from `NetworkInterface` so the choice is testable.
typedef LanInterface = ({String name, List<String> addresses});

/// Interfaces a phone on the Wi-Fi can never reach: hypervisor/WSL virtual
/// switches, loopback adapters and overlay VPNs. Matched case-insensitively
/// against the interface name.
const excludedInterfaceMarkers = ['vEthernet', 'VirtualBox', 'VMware', 'Hyper-V', 'WSL', 'Loopback', 'Tailscale', 'ZeroTier'];

bool _isPrivate(String a) =>
    a.startsWith('192.168.') || a.startsWith('10.') || RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(a);

bool _excluded(String name) {
  final n = name.toLowerCase();
  return excludedInterfaceMarkers.any((m) => n.contains(m.toLowerCase()));
}

/// Picks the address the desktop advertises in its pairing QR.
///
/// 1. The address holding the default route ([defaultRouteAddress]), when
///    known and actually present on an interface — even a `vEthernet` one:
///    with a Hyper-V *external* switch the real NIC's address lives there.
/// 2. Otherwise the first private IPv4 on a non-virtual interface.
/// 3. Otherwise the first IPv4 on a non-virtual interface.
String? pickLanIPv4(List<LanInterface> interfaces, {String? defaultRouteAddress}) {
  final all = [for (final i in interfaces) ...i.addresses];
  if (defaultRouteAddress != null && all.contains(defaultRouteAddress)) return defaultRouteAddress;
  final kept = [
    for (final i in interfaces)
      if (!_excluded(i.name)) ...i.addresses.where((a) => !a.startsWith('127.') && !a.startsWith('169.254.')),
  ];
  for (final a in kept) {
    if (_isPrivate(a)) return a;
  }
  return kept.isEmpty ? null : kept.first;
}

/// Parses the IPv4 route table printed by Windows' `route print 0.0.0.0`
/// and returns the interface address of the lowest-metric default route
/// (`0.0.0.0/0.0.0.0` line: destination, netmask, gateway, interface,
/// metric — the gateway column may be a localised "On-link" text, so only
/// the trailing `interface metric` pair is relied upon).
String? parseDefaultRouteInterface(String routePrint) {
  final line = RegExp(r'^\s*0\.0\.0\.0\s+0\.0\.0\.0\s+.*?(\d{1,3}(?:\.\d{1,3}){3})\s+(\d+)\s*$', multiLine: true);
  String? best;
  var bestMetric = 1 << 30;
  for (final m in line.allMatches(routePrint)) {
    final metric = int.parse(m.group(2)!);
    if (metric < bestMetric) {
      bestMetric = metric;
      best = m.group(1);
    }
  }
  return best;
}

Future<String?> _windowsDefaultRouteAddress() async {
  if (!Platform.isWindows) return null;
  try {
    final r = await Process.run('route', ['print', '0.0.0.0']).timeout(const Duration(seconds: 3));
    if (r.exitCode != 0) return null;
    return parseDefaultRouteInterface('${r.stdout}');
  } on Object {
    return null;
  }
}

/// The LAN IPv4 address to put in the pairing QR (see [pickLanIPv4]).
Future<String?> primaryLanIPv4() async {
  final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
  return pickLanIPv4(
    [for (final i in interfaces) (name: i.name, addresses: [for (final a in i.addresses) a.address])],
    defaultRouteAddress: await _windowsDefaultRouteAddress(),
  );
}
