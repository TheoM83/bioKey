import 'dart:convert';
import 'dart:io' show Platform;
import 'secure_kv.dart';

final class PairedPhone {
  const PairedPhone({required this.name, required this.pub, required this.session});
  final String name, pub, session;
  Map<String, Object?> toJson() => {'name': name, 'pub': pub, 'session': session};
  static PairedPhone fromJson(Map<String, Object?> j) =>
      PairedPhone(name: j['name']! as String, pub: j['pub']! as String, session: j['session']! as String);

  @override
  bool operator ==(Object other) => other is PairedPhone && other.name == name && other.pub == pub && other.session == session;
  @override
  int get hashCode => Object.hash(name, pub, session);
}

final class DesktopStore {
  DesktopStore(this._kv);
  final SecureKv _kv;
  static const defaultPort = 47621;

  Future<({String certPem, String keyPem})?> identity() async {
    final c = await _kv.read('cert');
    final k = await _kv.read('key');
    if (c == null || k == null) return null;
    return (certPem: c, keyPem: k);
  }

  Future<void> saveIdentity(String certPem, String keyPem) async {
    await _kv.write('cert', certPem);
    await _kv.write('key', keyPem);
  }

  Future<PairedPhone?> pairedPhone() async {
    final s = await _kv.read('phone');
    if (s == null) return null;
    try {
      return PairedPhone.fromJson(jsonDecode(s) as Map<String, Object?>);
    } on Object {
      return null;
    }
  }

  Future<void> savePairedPhone(PairedPhone p) => _kv.write('phone', jsonEncode(p.toJson()));
  Future<void> clearPairedPhone() => _kv.delete('phone');

  Future<String> pcName() async => await _kv.read('pcName') ?? Platform.localHostname;
  Future<void> savePcName(String n) => _kv.write('pcName', n);

  Future<int> port() async {
    final s = await _kv.read('port');
    if (s != null) {
      try {
        return int.parse(s);
      } on Object {
        // corrupt value: fall through and rewrite the default below.
      }
    }
    await _kv.write('port', '$defaultPort');
    return defaultPort;
  }
}
