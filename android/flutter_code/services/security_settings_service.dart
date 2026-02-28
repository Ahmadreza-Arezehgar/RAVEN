import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import '../models/security_settings_model.dart';
import '../services/database_helper.dart';

/// Service for managing security settings and passcode
class SecuritySettingsService {
  static final SecuritySettingsService instance = SecuritySettingsService._init();
  
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final DatabaseHelper _db = DatabaseHelper.instance;
  
  static const String _passcodeKey = 'app_passcode_hash';
  static const String _passcodeEnabledKey = 'passcode_enabled';
  static const String _biometricEnabledKey = 'biometric_enabled';

  SecuritySettingsService._init();

  /// Hash passcode using SHA-256
  String _hashPasscode(String passcode) {
    final bytes = utf8.encode(passcode);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Set passcode
  Future<void> setPasscode(String passcode) async {
    final hash = _hashPasscode(passcode);
    await _secureStorage.write(key: _passcodeKey, value: hash);
    await setPasscodeEnabled(true);
    print('✅ Passcode set successfully');
  }

  /// Verify passcode
  Future<bool> verifyPasscode(String passcode) async {
    final storedHash = await _secureStorage.read(key: _passcodeKey);
    if (storedHash == null) return false;
    
    final inputHash = _hashPasscode(passcode);
    return storedHash == inputHash;
  }

  /// Check if passcode is set
  Future<bool> hasPasscode() async {
    final hash = await _secureStorage.read(key: _passcodeKey);
    return hash != null;
  }

  /// Delete passcode
  Future<void> deletePasscode() async {
    await _secureStorage.delete(key: _passcodeKey);
    await setPasscodeEnabled(false);
    await setBiometricEnabled(false);
    print('✅ Passcode deleted');
  }

  /// Enable/disable passcode lock
  Future<void> setPasscodeEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_passcodeEnabledKey, enabled);
  }

  /// Check if passcode is enabled
  Future<bool> isPasscodeEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_passcodeEnabledKey) ?? false;
  }

  /// Enable/disable biometric authentication
  Future<void> setBiometricEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_biometricEnabledKey, enabled);
  }

  /// Check if biometric is enabled
  Future<bool> isBiometricEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_biometricEnabledKey) ?? false;
  }

  /// Get security settings for a user
  Future<SecuritySettings?> getSecuritySettings(String userId) async {
    return await _db.getSecuritySettings(userId);
  }

  /// Update security settings
  Future<void> updateSecuritySettings(SecuritySettings settings) async {
    await _db.updateSecuritySettings(settings);
    print('✅ Security settings updated');
  }

  /// Get blocked users
  Future<List<Map<String, dynamic>>> getBlockedUsers() async {
    return await _db.getBlockedUsers();
  }

  /// Check if auto-delete is enabled for an user
  Future<bool> isAutoDeleteEnabled(String userId) async {
    final settings = await getSecuritySettings(userId);
    return settings?.autoDeleteEnabled ?? false;
  }

  /// Get auto-delete period in hours
  Future<int> getAutoDeletePeriod(String userId) async {
    final settings = await getSecuritySettings(userId);
    return settings?.autoDeletePeriodHours ?? 0;
  }

  /// Delete expired messages
  Future<void> deleteExpiredMessages() async {
    await _db.deleteExpiredMessages();
    print('✅ Expired messages deleted');
  }
}
