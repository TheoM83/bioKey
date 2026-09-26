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

  test('SingleInstance: second acquire returns null and forward delivers args', () async {
    final got = <List<String>>[];
    final first = await SingleInstance.acquire(onArgs: got.add);
    expect(first, isNotNull);
    expect(await SingleInstance.acquire(onArgs: (_) {}), isNull);
    expect(await SingleInstance.forward(['open', 'id1']), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(got.single, ['open', 'id1']);
    await first!.dispose();
  });
}
