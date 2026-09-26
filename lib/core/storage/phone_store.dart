import 'dart:convert';
import 'secure_kv.dart';

final class PairedPc {
  const PairedPc({required this.pcId, required this.name, required this.host, required this.port, required this.fingerprint});
  final String pcId, name, host, fingerprint;
  final int port;
  Map<String, Object?> toJson() => {'pcId': pcId, 'name': name, 'host': host, 'port': port, 'fingerprint': fingerprint};
  static PairedPc fromJson(Map<String, Object?> j) => PairedPc(
        pcId: j['pcId']! as String,
        name: j['name']! as String,
        host: j['host']! as String,
        port: j['port']! as int,
        fingerprint: j['fingerprint']! as String,
      );

  @override
  bool operator ==(Object other) =>
      other is PairedPc && other.pcId == pcId && other.name == name && other.host == host && other.port == port && other.fingerprint == fingerprint;
  @override
  int get hashCode => Object.hash(pcId, name, host, port, fingerprint);
}

final class PhoneStore {
  PhoneStore(this._kv);
  final SecureKv _kv;

  Future<List<PairedPc>> pcs() async {
    final s = await _kv.read('pcs');
    if (s == null) return <PairedPc>[];
    return (jsonDecode(s) as List<Object?>).map((e) => PairedPc.fromJson(e! as Map<String, Object?>)).toList();
  }

  Future<void> _save(List<PairedPc> l) => _kv.write('pcs', jsonEncode(l.map((p) => p.toJson()).toList()));

  Future<void> upsertPc(PairedPc pc) async {
    final l = await pcs();
    final i = l.indexWhere((p) => p.pcId == pc.pcId);
    if (i >= 0) {
      l[i] = pc;
    } else {
      l.add(pc);
    }
    await _save(l);
  }

  Future<void> removePc(String pcId) async => _save((await pcs()).where((p) => p.pcId != pcId).toList());

  Future<String?> pubKey() => _kv.read('pub');
  Future<void> savePubKey(String pub) => _kv.write('pub', pub);
  Future<void> clearPubKey() => _kv.delete('pub');
}
