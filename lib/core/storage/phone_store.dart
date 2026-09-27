import 'dart:convert';
import 'secure_kv.dart';

final class PairedPc {
  const PairedPc({
    required this.pcId,
    required this.name,
    required this.host,
    required this.port,
    required this.fingerprint,
    required this.session,
    this.manualHost,
  });
  final String pcId, name, host, fingerprint, session;
  final int port;

  /// A user-typed host (e.g. a WireGuard/Tailscale tunnel address),
  /// set via the "Modifier l'adresse…" dialog and never touched by LAN
  /// discovery — only [host] (the last known LAN address) is ever
  /// overwritten by a discovery result. `null` means the user hasn't set
  /// one, so only [host] is tried.
  final String? manualHost;

  Map<String, Object?> toJson() => {
        'pcId': pcId,
        'name': name,
        'host': host,
        'port': port,
        'fingerprint': fingerprint,
        'session': session,
        if (manualHost != null) 'manualHost': manualHost,
      };
  static PairedPc fromJson(Map<String, Object?> j) => PairedPc(
        pcId: j['pcId']! as String,
        name: j['name']! as String,
        host: j['host']! as String,
        port: j['port']! as int,
        fingerprint: j['fingerprint']! as String,
        session: j['session']! as String,
        manualHost: j['manualHost'] as String?,
      );

  /// [clearManualHost] wins over [manualHost] — pass it to explicitly drop
  /// a previously-set manual host (e.g. the user emptied the field);
  /// leaving both out keeps whatever [manualHost] this instance already
  /// has.
  PairedPc copyWith({
    String? pcId,
    String? name,
    String? host,
    int? port,
    String? fingerprint,
    String? session,
    String? manualHost,
    bool clearManualHost = false,
  }) => PairedPc(
        pcId: pcId ?? this.pcId,
        name: name ?? this.name,
        host: host ?? this.host,
        port: port ?? this.port,
        fingerprint: fingerprint ?? this.fingerprint,
        session: session ?? this.session,
        manualHost: clearManualHost ? null : (manualHost ?? this.manualHost),
      );

  @override
  bool operator ==(Object other) =>
      other is PairedPc &&
      other.pcId == pcId &&
      other.name == name &&
      other.host == host &&
      other.port == port &&
      other.fingerprint == fingerprint &&
      other.session == session &&
      other.manualHost == manualHost;
  @override
  int get hashCode => Object.hash(pcId, name, host, port, fingerprint, session, manualHost);
}

final class PhoneStore {
  PhoneStore(this._kv);
  final SecureKv _kv;

  Future<List<PairedPc>> pcs() async {
    final s = await _kv.read('pcs');
    if (s == null) return <PairedPc>[];
    try {
      return (jsonDecode(s) as List<Object?>).map((e) => PairedPc.fromJson(e! as Map<String, Object?>)).toList();
    } on Object {
      return <PairedPc>[];
    }
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
