import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/core/storage/phone_store.dart';
import 'package:biokey/core/storage/secure_kv.dart';
import 'package:biokey/phone/phone_app.dart';
import 'package:biokey/phone/phone_controller.dart';
import '../support/fake_foreground_gate.dart';
import '../support/fake_signer.dart';
import '../support/in_memory_task_transport.dart';

void main() {
  testWidgets('an app-detached lifecycle event shuts the controller down', (tester) async {
    final gate = FakeForegroundGate();
    final controller = PhoneController(
      transport: InMemoryTaskLink().ui,
      store: PhoneStore(InMemorySecureKv()),
      signer: FakeSigner(),
      gate: gate,
      stateRetry: const Duration(hours: 1),
    );
    await controller.init();

    final kv = InMemorySecureKv();
    // Keep the one-time battery guide dialog out of this test — it isn't
    // what's under test here, and a dangling dialog route would otherwise
    // sit open after the pump below.
    await kv.write('batteryGuideShown', '1');
    await kv.write('fullScreenGuideShown', '1');

    await tester.pumpWidget(PhoneApp(controller: controller, kv: kv));
    await tester.pump();

    expect(gate.detached, isFalse, reason: 'sanity: shutdown() has not run yet');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    // shutdown() is fired un-awaited from the synchronous lifecycle
    // callback (PhoneApp's didChangeAppLifecycleState); let it settle.
    await tester.pump(Duration.zero);

    expect(gate.detached, isTrue, reason: 'controller.shutdown() must run on app detach');
  });
}
