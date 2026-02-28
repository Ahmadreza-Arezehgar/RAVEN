import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Biometric Authentication Service
/// Handles Face ID, Touch ID, and fingerprint authentication
class BiometricService {
  static final BiometricService _instance = BiometricService._internal();
  factory BiometricService() => _instance;
  BiometricService._internal();

  final LocalAuthentication _auth = LocalAuthentication();
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  // Storage keys
  static const String _keyAppLockEnabled = 'app_lock_enabled';
  static const String _keyBiometricEnabled = 'biometric_enabled';
  static const String _keyLockTimeout = 'lock_timeout';
  static const String _keyLockSensitiveTabs = 'lock_sensitive_tabs';
  static const String _keyPasscodeHash = 'passcode_hash';
  static const String _keyLastUnlockTime = 'last_unlock_time';

  // ══════════════════════════════════════════════════════════════
  // CAPABILITY CHECKS
  // ══════════════════════════════════════════════════════════════
  
  /// Check if device supports biometric authentication
  Future<bool> canUseBiometrics() async {
    try {
      final canCheck = await _auth.canCheckBiometrics;
      final isSupported = await _auth.isDeviceSupported();
      return canCheck || isSupported;
    } catch (e) {
      return false;
    }
  }

  /// Get available biometric types
  Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      return await _auth.getAvailableBiometrics();
    } catch (e) {
      return [];
    }
  }

  /// Check if Face ID is available
  Future<bool> hasFaceId() async {
    final biometrics = await getAvailableBiometrics();
    return biometrics.contains(BiometricType.face);
  }

  /// Check if Touch ID / Fingerprint is available
  Future<bool> hasTouchId() async {
    final biometrics = await getAvailableBiometrics();
    return biometrics.contains(BiometricType.fingerprint) ||
           biometrics.contains(BiometricType.strong);
  }

  // ══════════════════════════════════════════════════════════════
  // AUTHENTICATION
  // ══════════════════════════════════════════════════════════════
  
  /// Authenticate user with biometrics
  Future<bool> authenticate({
    String reason = 'Unlock to continue',
    bool biometricOnly = false,
  }) async {
    try {
      final canUse = await canUseBiometrics();
      if (!canUse && biometricOnly) return false;

      HapticFeedback.mediumImpact();
      
      return await _auth.authenticate(
        localizedReason: reason,
        options: AuthenticationOptions(
          biometricOnly: biometricOnly,
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
    } on PlatformException catch (e) {
      // Handle specific errors
      if (e.code == 'NotAvailable') {
        return false;
      }
      if (e.code == 'LockedOut' || e.code == 'PermanentlyLockedOut') {
        return false;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  // ══════════════════════════════════════════════════════════════
  // SETTINGS MANAGEMENT
  // ══════════════════════════════════════════════════════════════
  
  /// Check if app lock is enabled
  Future<bool> isAppLockEnabled() async {
    final value = await _storage.read(key: _keyAppLockEnabled);
    return value == 'true';
  }

  /// Enable/disable app lock
  Future<void> setAppLockEnabled(bool enabled) async {
    await _storage.write(key: _keyAppLockEnabled, value: enabled.toString());
  }

  /// Check if biometric unlock is enabled
  Future<bool> isBiometricEnabled() async {
    final value = await _storage.read(key: _keyBiometricEnabled);
    return value == 'true';
  }

  /// Enable/disable biometric unlock
  Future<void> setBiometricEnabled(bool enabled) async {
    await _storage.write(key: _keyBiometricEnabled, value: enabled.toString());
  }

  /// Get lock timeout in seconds (0 = immediate)
  Future<int> getLockTimeout() async {
    final value = await _storage.read(key: _keyLockTimeout);
    return int.tryParse(value ?? '0') ?? 0;
  }

  /// Set lock timeout in seconds
  Future<void> setLockTimeout(int seconds) async {
    await _storage.write(key: _keyLockTimeout, value: seconds.toString());
  }

  /// Check if sensitive tabs should be locked
  Future<bool> shouldLockSensitiveTabs() async {
    final value = await _storage.read(key: _keyLockSensitiveTabs);
    return value == 'true';
  }

  /// Enable/disable sensitive tabs lock
  Future<void> setLockSensitiveTabs(bool enabled) async {
    await _storage.write(key: _keyLockSensitiveTabs, value: enabled.toString());
  }

  // ══════════════════════════════════════════════════════════════
  // PASSCODE MANAGEMENT
  // ══════════════════════════════════════════════════════════════
  
  /// Check if passcode is set
  Future<bool> hasPasscode() async {
    final hash = await _storage.read(key: _keyPasscodeHash);
    return hash != null && hash.isNotEmpty;
  }

  /// Save passcode (hashed)
  Future<void> setPasscode(String passcode) async {
    // Simple hash for now - in production use bcrypt or similar
    final hash = passcode.hashCode.toString();
    await _storage.write(key: _keyPasscodeHash, value: hash);
  }

  /// Verify passcode
  Future<bool> verifyPasscode(String passcode) async {
    final storedHash = await _storage.read(key: _keyPasscodeHash);
    final inputHash = passcode.hashCode.toString();
    return storedHash == inputHash;
  }

  /// Remove passcode
  Future<void> removePasscode() async {
    await _storage.delete(key: _keyPasscodeHash);
  }

  // ══════════════════════════════════════════════════════════════
  // LOCK STATE MANAGEMENT
  // ══════════════════════════════════════════════════════════════
  
  /// Record unlock time
  Future<void> recordUnlock() async {
    final now = DateTime.now().millisecondsSinceEpoch.toString();
    await _storage.write(key: _keyLastUnlockTime, value: now);
  }

  /// Check if app should be locked based on timeout
  Future<bool> shouldShowLock() async {
    final enabled = await isAppLockEnabled();
    if (!enabled) return false;

    final timeout = await getLockTimeout();
    if (timeout == 0) return true; // Immediate lock

    final lastUnlockStr = await _storage.read(key: _keyLastUnlockTime);
    if (lastUnlockStr == null) return true;

    final lastUnlock = int.tryParse(lastUnlockStr) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final elapsed = (now - lastUnlock) ~/ 1000;

    return elapsed > timeout;
  }

  /// Reset all security settings
  Future<void> resetAll() async {
    await _storage.delete(key: _keyAppLockEnabled);
    await _storage.delete(key: _keyBiometricEnabled);
    await _storage.delete(key: _keyLockTimeout);
    await _storage.delete(key: _keyLockSensitiveTabs);
    await _storage.delete(key: _keyPasscodeHash);
    await _storage.delete(key: _keyLastUnlockTime);
  }
}
