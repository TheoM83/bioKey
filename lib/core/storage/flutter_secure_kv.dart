import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'secure_kv.dart';

final class FlutterSecureKv implements SecureKv {
  FlutterSecureKv()
      : _s = const FlutterSecureStorage(
          // ignore: deprecated_member_use
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
          wOptions: WindowsOptions(),
        );
  final FlutterSecureStorage _s;
  @override
  Future<String?> read(String key) => _s.read(key: key);
  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _s.delete(key: key);
}
