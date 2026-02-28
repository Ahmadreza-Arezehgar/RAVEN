import 'package:local_auth/local_auth.dart';
import 'package:flutter/services.dart';

/// Service for handling biometric authentication (Face ID/Touch ID)
class BiometricAuthService {
  static final BiometricAuthService instance = BiometricAuthService._init();
  final LocalAuthentication _auth = LocalAuthentication();

  BiometricAuthService._init();

  /// Check if the device supports biometric authentication
  Future<bool> canCheckBiometrics() async {
    try {
      return await _auth.canCheckBiometrics;
    } on PlatformException catch (e) {
      print('❌ Error checking biometrics: $e');
      return false;
    }
  }

  /// Check if device has biometric hardware and enrolled biometrics
  Future<bool> isDeviceSupported() async {
    try {
      final canCheck = await canCheckBiometrics();
      if (!canCheck) return false;

      final availableBiometrics = await _auth.getAvailableBiometrics();
      return availableBiometrics.isNotEmpty;
    } catch (e) {
      print('❌ Error checking device support: $e');
      return false;
    }
  }

  /// Get available biometric types
  Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      return await _auth.getAvailableBiometrics();
    } catch (e) {
      print('❌ Error getting biometrics: $e');
      return [];
    }
  }

  /// Authenticate using biometrics
  Future<bool> authenticate({
    required String reason,
    bool useErrorDialogs = true,
    bool stickyAuth = true,
  }) async {
    try {
      final isSupported = await isDeviceSupported();
      if (!isSupported) {
        print('⚠️ Biometric authentication not supported');
        return false;
      }

      return await _auth.authenticate(
        localizedReason: reason,
        options: AuthenticationOptions(
          useErrorDialogs: useErrorDialogs,
          stickyAuth: stickyAuth,
          biometricOnly: false, // Allow passcode fallback
        ),
      );
    } on PlatformException catch (e) {
      print('❌ Authentication error: $e');
      return false;
    }
  }

  /// Get the name of available biometric (Face ID, Touch ID, etc.)
  Future<String> getBiometricName() async {
    final biometrics = await getAvailableBiometrics();
    
    if (biometrics.contains(BiometricType.face)) {
      return 'Face ID';
    } else if (biometrics.contains(BiometricType.fingerprint)) {
      return 'Touch ID';
    } else if (biometrics.contains(BiometricType.iris)) {
      return 'Iris';
    } else if (biometrics.contains(BiometricType.strong) || 
               biometrics.contains(BiometricType.weak)) {
      return 'Biometric';
    }
    
    return 'Biometric';
  }

  /// Stop authentication (if in progress)
  Future<void> stopAuthentication() async {
    try {
      await _auth.stopAuthentication();
    } catch (e) {
      print('❌ Error stopping authentication: $e');
    }
  }
}
