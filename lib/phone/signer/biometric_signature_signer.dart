import 'package:biometric_signature/biometric_signature.dart';
import '../../core/session/biometric_signer.dart';
import '../../core/storage/phone_store.dart';

/// [BiometricSigner] backed by `biometric_signature`: a hardware-bound
/// (Keystore/StrongBox on Android, Secure Enclave on iOS) P-256 key that
/// never leaves secure hardware. Every [sign] call requires a fresh
/// biometric prompt.
final class BiometricSignatureSigner implements BiometricSigner {
  BiometricSignatureSigner(this._store);

  final PhoneStore _store;
  final _bs = BiometricSignature();

  @override
  Future<String> ensurePublicKey() async {
    final cached = await _store.pubKey();
    if (cached != null && await _bs.biometricKeyExists(checkValidity: true)) {
      return cached;
    }
    final result = await _bs.createKeys(
      config: CreateKeysConfig(signatureType: SignatureType.ecdsa, useDeviceCredentials: false),
    );
    final pub = result.publicKey;
    if (pub == null || result.error != null) {
      throw BiometricFailed(result.error ?? 'création de clé impossible');
    }
    final spki = _normalizeSpki(pub);
    await _store.savePubKey(spki);
    return spki;
  }

  @override
  Future<String> sign({required String payload, required String prompt}) async {
    final result = await _bs.createSignature(
      payload: payload,
      promptMessage: prompt,
      config: CreateSignatureConfig(cancelButtonText: 'Annuler'),
    );
    final sig = result.signature;
    if (sig != null && result.error == null) return sig;
    if (result.code == BiometricError.userCanceled) throw BiometricCancelled();
    throw BiometricFailed(result.error ?? result.code?.name ?? 'signature impossible');
  }

  @override
  Future<void> deleteKey() async {
    await _bs.deleteKeys();
    await _store.clearPubKey();
  }

  /// The plugin's `KeyFormat.base64` default is already a base64
  /// SubjectPublicKeyInfo DER, but strip any PEM armor/whitespace
  /// defensively in case a platform ever returns PEM instead.
  String _normalizeSpki(String pub) => pub.replaceAll(RegExp(r'-----[A-Z ]+-----'), '').replaceAll(RegExp(r'\s'), '');
}
