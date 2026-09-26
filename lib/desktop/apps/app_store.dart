import 'dart:convert';
import '../../core/storage/secure_kv.dart';
import 'protected_app.dart';

final class AppStore {
  AppStore(this._kv);
  final SecureKv _kv;

  Future<List<ProtectedApp>> all() async {
    final s = await _kv.read('apps');
    if (s == null) return <ProtectedApp>[];
    try {
      return (jsonDecode(s) as List<Object?>).map((e) => ProtectedApp.fromJson(e! as Map<String, Object?>)).toList();
    } on Object {
      return <ProtectedApp>[];
    }
  }

  Future<void> _save(List<ProtectedApp> l) => _kv.write('apps', jsonEncode(l.map((a) => a.toJson()).toList()));

  Future<void> upsert(ProtectedApp app) async {
    final l = await all();
    final i = l.indexWhere((a) => a.id == app.id);
    if (i >= 0) {
      l[i] = app;
    } else {
      l.add(app);
    }
    await _save(l);
  }

  Future<void> remove(String id) async => _save((await all()).where((a) => a.id != id).toList());

  Future<ProtectedApp?> byId(String id) async {
    for (final a in await all()) {
      if (a.id == id) return a;
    }
    return null;
  }
}
