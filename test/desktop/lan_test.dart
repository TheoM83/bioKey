import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/desktop/server/lan.dart';

void main() {
  group('pickLanIPv4', () {
    test('skips hypervisor, WSL, VPN and loopback adapters', () {
      final ifaces = <LanInterface>[
        (name: 'vEthernet (WSL (Hyper-V firewall))', addresses: ['172.25.16.1']),
        (name: 'vEthernet (Default Switch)', addresses: ['172.19.0.1']),
        (name: 'VirtualBox Host-Only Network', addresses: ['192.168.56.1']),
        (name: 'VMware Network Adapter VMnet8', addresses: ['192.168.200.1']),
        (name: 'Tailscale', addresses: ['100.64.0.5']),
        (name: 'ZeroTier One [abcd]', addresses: ['10.147.17.3']),
        (name: 'Loopback Pseudo-Interface 1', addresses: ['127.0.0.1']),
        (name: 'Wi-Fi', addresses: ['192.168.1.42']),
      ];
      expect(pickLanIPv4(ifaces), '192.168.1.42');
    });

    test('prefers the default-route address when known', () {
      final ifaces = <LanInterface>[
        (name: 'Ethernet 2', addresses: ['10.0.0.8']),
        (name: 'Wi-Fi', addresses: ['192.168.1.42']),
      ];
      expect(pickLanIPv4(ifaces, defaultRouteAddress: '192.168.1.42'), '192.168.1.42');
    });

    test('trusts the default route even on a vEthernet external switch', () {
      final ifaces = <LanInterface>[
        (name: 'vEthernet (External)', addresses: ['192.168.1.42']),
        (name: 'vEthernet (WSL)', addresses: ['172.25.16.1']),
      ];
      expect(pickLanIPv4(ifaces, defaultRouteAddress: '192.168.1.42'), '192.168.1.42');
    });

    test('ignores a default-route address no interface holds', () {
      final ifaces = <LanInterface>[(name: 'Wi-Fi', addresses: ['192.168.1.42'])];
      expect(pickLanIPv4(ifaces, defaultRouteAddress: '10.9.9.9'), '192.168.1.42');
    });

    test('falls back to a non-private address, then null', () {
      expect(pickLanIPv4([(name: 'Ethernet', addresses: ['203.0.113.7'])]), '203.0.113.7');
      expect(pickLanIPv4([(name: 'vEthernet (WSL)', addresses: ['172.25.16.1'])]), isNull);
      expect(pickLanIPv4([]), isNull);
    });
  });

  test('parseDefaultRouteInterface picks the lowest-metric default route', () {
    const out = '''
===========================================================================
IPv4 Route Table
===========================================================================
Active Routes:
Network Destination        Netmask          Gateway       Interface  Metric
          0.0.0.0          0.0.0.0      192.168.1.1     192.168.1.42     35
          0.0.0.0          0.0.0.0         10.0.0.1         10.0.0.8     25
===========================================================================
Persistent Routes:
  None
''';
    expect(parseDefaultRouteInterface(out), '10.0.0.8');
    expect(parseDefaultRouteInterface('          0.0.0.0          0.0.0.0     Sur la liaison     192.168.1.42    281'), '192.168.1.42');
    expect(parseDefaultRouteInterface('nothing here'), isNull);
  });
}
