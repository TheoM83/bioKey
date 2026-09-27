import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/core/storage/phone_store.dart';
import 'package:biokey/phone/ui/computers_screen.dart';

void main() {
  testWidgets('empty state shows scan CTA; list shows PCs with status', (t) async {
    await t.pumpWidget(MaterialApp(home: ComputersScreen(pcs: const [], isOnline: (_) => false, needsRepair: const {}, onScan: () {}, onRevoke: (_) {}, onSetHost: (a, b) {})));
    expect(find.text('Aucun ordinateur appairé'), findsOneWidget);
    expect(find.text('Scanner un QR'), findsOneWidget);

    await t.pumpWidget(MaterialApp(home: ComputersScreen(
      pcs: const [PairedPc(pcId: 'a', name: 'PC-MAISON', host: 'h', port: 1, fingerprint: 'f', session: 's')],
      isOnline: (id) => id == 'a', needsRepair: const {}, onScan: () {}, onRevoke: (_) {}, onSetHost: (a, b) {})));
    expect(find.text('PC-MAISON'), findsOneWidget);
    expect(find.text('Connecté'), findsOneWidget);
  });

  testWidgets("« Modifier l'adresse… » opens prefilled and saves the trimmed host", (t) async {
    String? savedPcId;
    String? savedHost;
    await t.pumpWidget(MaterialApp(home: ComputersScreen(
      pcs: const [PairedPc(pcId: 'a', name: 'PC-MAISON', host: '192.168.1.5', port: 1, fingerprint: 'f', session: 's')],
      isOnline: (_) => true,
      needsRepair: const {},
      onScan: () {},
      onRevoke: (_) {},
      onSetHost: (pcId, host) {
        savedPcId = pcId;
        savedHost = host;
      },
    )));

    await t.tap(find.byIcon(Icons.more_vert));
    await t.pumpAndSettle();
    await t.tap(find.text("Modifier l'adresse…"));
    await t.pumpAndSettle();

    expect(find.text('192.168.1.5'), findsOneWidget);

    await t.enterText(find.byType(TextFormField), '  pc-maison.tailnet.ts.net  ');
    await t.tap(find.text('Enregistrer'));
    await t.pumpAndSettle();

    expect(savedPcId, 'a');
    expect(savedHost, 'pc-maison.tailnet.ts.net');
  });

  testWidgets("« Modifier l'adresse… » prefills with manualHost when set, not the LAN host", (t) async {
    await t.pumpWidget(MaterialApp(home: ComputersScreen(
      pcs: const [PairedPc(pcId: 'a', name: 'PC-MAISON', host: '192.168.1.5', port: 1, fingerprint: 'f', session: 's', manualHost: 'pc-maison.tailnet.ts.net')],
      isOnline: (_) => true,
      needsRepair: const {},
      onScan: () {},
      onRevoke: (_) {},
      onSetHost: (a, b) {},
    )));

    await t.tap(find.byIcon(Icons.more_vert));
    await t.pumpAndSettle();
    await t.tap(find.text("Modifier l'adresse…"));
    await t.pumpAndSettle();

    expect(find.text('pc-maison.tailnet.ts.net'), findsOneWidget);
    expect(find.text('192.168.1.5'), findsNothing);
  });

  testWidgets("an invalid address shows « Adresse invalide » and does not save", (t) async {
    var called = false;
    await t.pumpWidget(MaterialApp(home: ComputersScreen(
      pcs: const [PairedPc(pcId: 'a', name: 'PC-MAISON', host: '192.168.1.5', port: 1, fingerprint: 'f', session: 's')],
      isOnline: (_) => true,
      needsRepair: const {},
      onScan: () {},
      onRevoke: (_) {},
      onSetHost: (a, b) => called = true,
    )));

    await t.tap(find.byIcon(Icons.more_vert));
    await t.pumpAndSettle();
    await t.tap(find.text("Modifier l'adresse…"));
    await t.pumpAndSettle();

    await t.enterText(find.byType(TextFormField), 'not a host');
    await t.tap(find.text('Enregistrer'));
    await t.pumpAndSettle();

    expect(find.text('Adresse invalide'), findsOneWidget);
    expect(called, isFalse);
  });
}
