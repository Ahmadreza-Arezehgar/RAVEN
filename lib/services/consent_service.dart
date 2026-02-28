import 'package:shared_preferences/shared_preferences.dart';

/// ConsentService - Manages user consent for features requiring approval
/// 
/// Stores consent state in SharedPreferences for:
/// - Mesh Networking (BLE data sharing)
/// - Gemini AI (sending content to third-party AI)
/// - Age verification for content filtering
class ConsentService {
  static final ConsentService _instance = ConsentService._internal();
  static ConsentService get instance => _instance;
  ConsentService._internal();

  // SharedPreferences keys
  static const String _meshConsentKey = 'consent_mesh_networking';
  static const String _geminiConsentKey = 'consent_gemini_ai';
  static const String _meshConsentShownKey = 'consent_mesh_shown';
  static const String _geminiConsentShownKey = 'consent_gemini_shown';
  static const String _userAgeKey = 'user_age';
  static const String _ageVerifiedKey = 'age_verified';

  // ═══════════════════════════════════════════════════════════════════════════
  // MESH NETWORKING CONSENT
  // ═══════════════════════════════════════════════════════════════════════════

  /// Check if user has given consent for Mesh networking
  Future<bool> hasMeshConsent() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_meshConsentKey) ?? false;
  }

  /// Set Mesh networking consent
  Future<void> setMeshConsent(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_meshConsentKey, value);
    await prefs.setBool(_meshConsentShownKey, true);
    print('🔐 [Consent] Mesh networking consent set to: $value');
  }

  /// Check if Mesh consent dialog has been shown
  Future<bool> hasMeshConsentBeenShown() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_meshConsentShownKey) ?? false;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // GEMINI AI CONSENT
  // ═══════════════════════════════════════════════════════════════════════════

  /// Check if user has given consent for Gemini AI
  Future<bool> hasGeminiConsent() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_geminiConsentKey) ?? false;
  }

  /// Set Gemini AI consent
  Future<void> setGeminiConsent(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_geminiConsentKey, value);
    await prefs.setBool(_geminiConsentShownKey, true);
    print('🔐 [Consent] Gemini AI consent set to: $value');
  }

  /// Check if Gemini consent dialog has been shown
  Future<bool> hasGeminiConsentBeenShown() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_geminiConsentShownKey) ?? false;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // AGE VERIFICATION
  // ═══════════════════════════════════════════════════════════════════════════

  /// Get user's age (null if not set)
  Future<int?> getUserAge() async {
    final prefs = await SharedPreferences.getInstance();
    final age = prefs.getInt(_userAgeKey);
    return age;
  }

  /// Set user's age
  Future<void> setUserAge(int age) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_userAgeKey, age);
    await prefs.setBool(_ageVerifiedKey, true);
    print('🔐 [Consent] User age set to: $age');
  }

  /// Check if user is under 18
  Future<bool> isUserUnder18() async {
    final age = await getUserAge();
    if (age == null) return false; // Default to adult if not set
    return age < 18;
  }

  /// Check if age has been verified
  Future<bool> hasAgeBeenVerified() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_ageVerifiedKey) ?? false;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // UTILITY METHODS
  // ═══════════════════════════════════════════════════════════════════════════

  /// Reset all consent settings (for testing or account deletion)
  Future<void> resetAllConsents() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_meshConsentKey);
    await prefs.remove(_geminiConsentKey);
    await prefs.remove(_meshConsentShownKey);
    await prefs.remove(_geminiConsentShownKey);
    await prefs.remove(_userAgeKey);
    await prefs.remove(_ageVerifiedKey);
    print('🔐 [Consent] All consents have been reset');
  }

  /// Get consent summary for debugging
  Future<Map<String, dynamic>> getConsentSummary() async {
    return {
      'meshConsent': await hasMeshConsent(),
      'meshShown': await hasMeshConsentBeenShown(),
      'geminiConsent': await hasGeminiConsent(),
      'geminiShown': await hasGeminiConsentBeenShown(),
      'userAge': await getUserAge(),
      'ageVerified': await hasAgeBeenVerified(),
      'isUnder18': await isUserUnder18(),
    };
  }
}
