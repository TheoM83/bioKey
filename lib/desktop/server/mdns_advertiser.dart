import 'package:bonsoir/bonsoir.dart';

/// Advertises the desktop's pinned-TLS link service on the LAN via
/// mDNS/Bonjour so the phone can discover it without manual IP entry.
final class MdnsAdvertiser {
  BonsoirBroadcast? _broadcast;

  Future<void> start({required String pcId, required String name, required int port}) async {
    final service = BonsoirService(
      name: 'BioKey $name',
      type: '_biokey._tcp',
      port: port,
      attributes: {'id': pcId, 'v': '1'},
    );
    final broadcast = BonsoirBroadcast(service: service);
    _broadcast = broadcast;
    await broadcast.initialize();
    await broadcast.start();
  }

  Future<void> stop() async {
    await _broadcast?.stop();
    _broadcast = null;
  }
}
