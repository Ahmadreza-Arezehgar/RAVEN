import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Security service for handling app lock, passcodes, and biometric authentication
class SecurityService {
  static final SecurityService instance = SecurityService._internal();
  factory SecurityService() => instance;
  SecurityService._internal();

  // Use AndroidOptions and IOSOptions for platform-specific configuration
  final _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
  );

  static const String _passcodeKey = 'app_passcode';
  static const String _biometricEnabledKey = 'biometric_enabled';
  static const String _autoDeletePeriodKey = 'auto_delete_period';

  /// Check if a passcode is set
  Future<bool> hasPasscode() async {
    final passcode = await _secureStorage.read(key: _passcodeKey);
    return passcode != null && passcode.isNotEmpty;
  }

  /// Set a new passcode (hashed)
  Future<void> setPasscode(String passcode) async {
    final hashedPasscode = _hashPasscode(passcode);
    await _secureStorage.write(key: _passcodeKey, value: hashedPasscode);
  }

  /// Verify passcode
  Future<bool> verifyPasscode(String passcode) async {
    final storedHash = await _secureStorage.read(key: _passcodeKey);
    if (storedHash == null) return false;
    
    final inputHash = _hashPasscode(passcode);
    return storedHash == inputHash;
  }

  /// Remove passcode
  Future<void> removePasscode() async {
    await _secureStorage.delete(key: _passcodeKey);
  }

  /// Enable/disable biometric authentication
  Future<void> setBiometricEnabled(bool enabled) async {
    await _secureStorage.write(
      key: _biometricEnabledKey,
      value: enabled.toString(),
    );
  }

  /// Check if biometric is enabled
  Future<bool> isBiometricEnabled() async {
    final value = await _secureStorage.read(key: _biometricEnabledKey);
    return value == 'true';
  }

  /// Set auto-delete period (in hours, 0 = disabled)
  Future<void> setAutoDeletePeriod(int hours) async {
    await _secureStorage.write(
      key: _autoDeletePeriodKey,
      value: hours.toString(),
    );
  }

  /// Get auto-delete period
  Future<int> getAutoDeletePeriod() async {
    final value = await _secureStorage.read(key: _autoDeletePeriodKey);
    return value != null ? int.tryParse(value) ?? 0 : 0;
  }

  /// Hash passcode for storage
  String _hashPasscode(String passcode) {
    final bytes = utf8.encode(passcode);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }
}
