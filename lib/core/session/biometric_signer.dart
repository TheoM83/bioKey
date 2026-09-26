abstract interface class BiometricSigner {
  /// Creates the biometric-bound key if missing; returns SPKI DER base64.
  Future<String> ensurePublicKey();

  /// Shows the system biometric prompt and signs [payload] (SHA-256/ECDSA, DER, base64).
  Future<String> sign({required String payload, required String prompt});

  Future<void> deleteKey();
}

class BiometricCancelled implements Exception {}

class BiometricFailed implements Exception {
  BiometricFailed(this.message);
  final String message;
  @override
  String toString() => 'BiometricFailed: $message';
}

/// The biometric prompt could not be shown in time (e.g. the app never came
/// to the foreground): reported to the PC as `timeout`, not as a biometric
/// failure. Still a [BiometricFailed] for callers that don't care.
class BiometricTimeout extends BiometricFailed {
  BiometricTimeout(super.message);
  @override
  String toString() => 'BiometricTimeout: $message';
}
