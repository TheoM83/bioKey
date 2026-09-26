import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/core/storage/secure_kv.dart';
import 'package:biokey/core/storage/desktop_store.dart';
import 'package:biokey/core/storage/phone_store.dart';

void main() {
  test('DesktopStore persists identity, phone, name, port', () async {
    final s = DesktopStore(InMemorySecureKv());
    expect(await s.identity(), isNull);
    await s.saveIdentity('CERT', 'KEY');
    expect((await s.identity())!.certPem, 'CERT');
    expect(await s.pairedPhone(), isNull);
    await s.savePairedPhone(const PairedPhone(name: 'Nothing', pub: 'PUB'));
    expect((await s.pairedPhone())!.pub, 'PUB');
    await s.clearPairedPhone();
    expect(await s.pairedPhone(), isNull);
    expect(await s.port(), 47621);
    await s.savePcName('PC-MAISON');
    expect(await s.pcName(), 'PC-MAISON');
  });

  test('PhoneStore upserts and removes PCs by id', () async {
    final s = PhoneStore(InMemorySecureKv());
    expect(await s.pcs(), isEmpty);
    const a = PairedPc(pcId: 'a', name: 'A', host: '1.1.1.1', port: 1, fingerprint: 'f');
    await s.upsertPc(a);
    await s.upsertPc(const PairedPc(pcId: 'a', name: 'A2', host: '1.1.1.2', port: 2, fingerprint: 'f'));
    await s.upsertPc(const PairedPc(pcId: 'b', name: 'B', host: '2', port: 2, fingerprint: 'g'));
    final l = await s.pcs();
    expect(l.map((p) => p.pcId), ['a', 'b']);
    expect(l.first.name, 'A2');
    await s.removePc('a');
    expect((await s.pcs()).map((p) => p.pcId), ['b']);
    await s.savePubKey('PUB');
    expect(await s.pubKey(), 'PUB');
    await s.clearPubKey();
    expect(await s.pubKey(), isNull);
  });
}
