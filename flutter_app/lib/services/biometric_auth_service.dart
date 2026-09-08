import 'package:local_auth/local_auth.dart';

/// Wraps device biometrics (fingerprint/Face ID) so the login screen can
/// offer "unlock with fingerprint" as a shortcut for retyping the saved
/// password, instead of the user typing it out by hand every time.
class BiometricAuthService {
  final LocalAuthentication _auth = LocalAuthentication();

  Future<bool> isAvailable() async {
    try {
      final supported = await _auth.isDeviceSupported();
      final canCheck = await _auth.canCheckBiometrics;
      return supported && canCheck;
    } catch (_) {
      return false;
    }
  }

  Future<bool> authenticate() async {
    try {
      return await _auth.authenticate(
        localizedReason: 'Potwierdź tożsamość, aby zalogować się bez wpisywania hasła',
        options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true),
      );
    } catch (_) {
      return false;
    }
  }
}
