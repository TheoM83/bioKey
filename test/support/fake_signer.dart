import 'package:biokey/core/session/biometric_signer.dart';
import 'test_keys.dart';

class FakeSigner implements BiometricSigner {
  final keys = TestKeys();
  final prompts = <String>[];
  bool cancelNext = false, failNext = false, throwNext = false, timeoutNext = false;
  int deleteCalls = 0;

  @override
  Future<String> ensurePublicKey() async => keys.pubSpkiB64;

  @override
  Future<String> sign({required String payload, required String prompt}) async {
    prompts.add(prompt);
    if (cancelNext) {
      cancelNext = false;
      throw BiometricCancelled();
    }
    if (failNext) {
      failNext = false;
      throw BiometricFailed('lockout');
    }
    if (timeoutNext) {
      timeoutNext = false;
      throw BiometricTimeout('application en arrière-plan');
    }
    if (throwNext) {
      throwNext = false;
      throw StateError('boom');
    }
    return keys.sign(payload);
  }

  @override
  Future<void> deleteKey() async {
    deleteCalls++;
  }
}
