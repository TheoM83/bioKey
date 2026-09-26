import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/core/storage/phone_store.dart';
import 'package:biokey/phone/ui/computers_screen.dart';

void main() {
  testWidgets('empty state shows scan CTA; list shows PCs with status', (t) async {
    await t.pumpWidget(MaterialApp(home: ComputersScreen(pcs: const [], isOnline: (_) => false, needsRepair: const {}, onScan: () {}, onRevoke: (_) {})));
    expect(find.text('Aucun ordinateur appairé'), findsOneWidget);
    expect(find.text('Scanner un QR'), findsOneWidget);

    await t.pumpWidget(MaterialApp(home: ComputersScreen(
      pcs: const [PairedPc(pcId: 'a', name: 'PC-MAISON', host: 'h', port: 1, fingerprint: 'f', session: 's')],
      isOnline: (id) => id == 'a', needsRepair: const {}, onScan: () {}, onRevoke: (_) {})));
    expect(find.text('PC-MAISON'), findsOneWidget);
    expect(find.text('Connecté'), findsOneWidget);
  });
}
