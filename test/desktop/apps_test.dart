import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/core/session/clock.dart';
import 'package:biokey/core/storage/secure_kv.dart';
import 'package:biokey/desktop/apps/app_store.dart';
import 'package:biokey/desktop/apps/cli.dart';
import 'package:biokey/desktop/apps/launcher.dart';
import 'package:biokey/desktop/apps/protected_app.dart';
import 'package:biokey/desktop/apps/single_instance.dart';

void main() {
  test('AppStore CRUD', () async {
    final s = AppStore(InMemorySecureKv());
    final a = ProtectedApp.create(label: 'Mon app', target: r'C:\x.exe');
    await s.upsert(a);
    await s.upsert(a.copyWith(label: 'Renommée'));
    expect((await s.all()).single.label, 'Renommée');
    expect((await s.byId(a.id))!.target, r'C:\x.exe');
    await s.remove(a.id);
    expect(await s.all(), isEmpty);
  });

  test('parseCli', () {
    expect(parseCli(['open', 'abc']), isA<OpenApp>().having((c) => c.id, 'id', 'abc'));
    expect(parseCli([]), isA<ShowWindow>());
    expect(parseCli(['open']), isA<ShowWindow>());
    expect(parseCli(['--hidden']), isA<ShowWindow>());
    expect(parseCli(['--hidden', 'open', 'abc']), isA<OpenApp>().having((c) => c.id, 'id', 'abc'));
  });

  test('WindowsLauncher throws LaunchFailed for missing executable', () async {
    final l = WindowsLauncher();
    expect(() => l.launch(ProtectedApp.create(label: 'x', target: r'C:\definitely\missing.exe')), throwsA(isA<LaunchFailed>()));
  });

  test('UnlockCache honours unlockMinutes', () {
    final clock = FakeClock(1000);
    final c = UnlockCache(clock);
    final always = ProtectedApp.create(label: 'a', target: 't');
    final five = ProtectedApp.create(label: 'b', target: 't', unlockMinutes: 5);
    c.markUnlocked(always); c.markUnlocked(five);
    expect(c.isUnlocked(always), isFalse);
    expect(c.isUnlocked(five), isTrue);
    clock.now += 301;
    expect(c.isUnlocked(five), isFalse);
  });

  group('SingleInstance', () {
    late Directory tmp;
    late String tokenPath;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('biokey_si');
      tokenPath = '${tmp.path}${Platform.pathSeparator}sub${Platform.pathSeparator}instance.token';
    });
    tearDown(() => tmp.delete(recursive: true));

    test('acquire writes a 32-byte token; a second acquire returns null; forward delivers args after ok', () async {
      final got = <List<String>>[];
      final first = await SingleInstance.acquire(onArgs: got.add, port: 0, tokenPath: tokenPath);
      expect(first, isNotNull);
      final token = await File(tokenPath).readAsString();
      expect(base64Url.decode(base64Url.normalize(token)), hasLength(32));

      expect(await SingleInstance.acquire(onArgs: (_) {}, port: first!.port, tokenPath: '$tokenPath.other'), isNull);
      expect(await File(tokenPath).readAsString(), token, reason: 'a losing instance must not clobber the token');

      expect(await SingleInstance.forward(['open', 'id1'], port: first.port, tokenPath: tokenPath), isTrue);
      expect(got.single, ['open', 'id1'], reason: 'ok is only sent once the args were accepted');
      await first.dispose();
    });

    test('a wrong or missing token is ignored and forward reports false', () async {
      final got = <List<String>>[];
      final first = await SingleInstance.acquire(onArgs: got.add, port: 0, tokenPath: tokenPath);
      final wrong = '${tmp.path}${Platform.pathSeparator}wrong.token';
      await File(wrong).writeAsString('not-the-token');
      expect(await SingleInstance.forward(['open', 'evil'], port: first!.port, tokenPath: wrong), isFalse);
      expect(await SingleInstance.forward(['open', 'evil'], port: first.port, tokenPath: '${tmp.path}/missing'), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(got, isEmpty);
      await first.dispose();
    });

    test('forward with nobody listening reports false', () async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final freePort = probe.port;
      await probe.close();
      await File(tokenPath).create(recursive: true);
      await File(tokenPath).writeAsString('x');
      expect(await SingleInstance.forward(['x'], port: freePort, tokenPath: tokenPath), isFalse);
    });

    test('malformed lines do not kill the listener', () async {
      final got = <List<String>>[];
      final first = await SingleInstance.acquire(onArgs: got.add, port: 0, tokenPath: tokenPath);
      expect(first, isNotNull);

      final sock = await Socket.connect(InternetAddress.loopbackIPv4, first!.port);
      sock.write('not json\n');
      sock.write('[1,2]\n');
      sock.write('{"token":1,"args":["a"]}\n');
      await sock.flush();
      await sock.close();

      expect(await SingleInstance.forward(['open', 'ok'], port: first.port, tokenPath: tokenPath), isTrue);
      expect(got.single, ['open', 'ok']);
      await first.dispose();
    });
  });
}
