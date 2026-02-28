import 'consent_service.dart';

/// ContentFilterService - Filters inappropriate content for users under 18
/// 
/// Provides:
/// - Profanity word list filtering
/// - Content age rating check
/// - Safe mode enforcement for minors
class ContentFilterService {
  static final ContentFilterService _instance = ContentFilterService._internal();
  static ContentFilterService get instance => _instance;
  ContentFilterService._internal();

  final ConsentService _consentService = ConsentService.instance;

  // Common inappropriate words/patterns to filter (minimal list for safety)
  // Note: In production, this would be a more comprehensive list with AI moderation
  static const List<String> _blockedPatterns = [
    // Violence
    'kill', 'murder', 'attack', 'terrorist',
    // Adult content
    'porn', 'xxx', 'nsfw', 'nude',
    // Drugs
    'cocaine', 'heroin', 'meth',
    // Slurs and hate speech (partial list)
    'hate', 'racist',
  ];

  // Age-restricted content categories
  static const List<String> _adultCategories = [
    'violence',
    'adult',
    'gambling',
    'alcohol',
    'tobacco',
    'cannabis',
  ];

  // ═══════════════════════════════════════════════════════════════════════════
  // PUBLIC METHODS
  // ═══════════════════════════════════════════════════════════════════════════

  /// Check if content should be filtered for current user
  Future<bool> shouldFilterContent() async {
    return await _consentService.isUserUnder18();
  }

  /// Filter text content - returns cleaned text
  String filterText(String text) {
    String filtered = text.toLowerCase();
    
    for (final pattern in _blockedPatterns) {
      // Replace blocked words with asterisks
      final regex = RegExp(pattern, caseSensitive: false);
      filtered = filtered.replaceAll(regex, '*' * pattern.length);
    }
    
    return filtered;
  }

  /// Check if text contains inappropriate content
  bool containsInappropriateContent(String text) {
    final lowerText = text.toLowerCase();
    
    for (final pattern in _blockedPatterns) {
      if (lowerText.contains(pattern)) {
        return true;
      }
    }
    
    return false;
  }

  /// Check if a post/content should be shown based on user's age
  Future<bool> shouldShowContent({
    String? content,
    String? category,
    bool isNsfw = false,
  }) async {
    // If explicitly marked as NSFW, filter for minors
    if (isNsfw && await shouldFilterContent()) {
      return false;
    }

    // Check category
    if (category != null && _adultCategories.contains(category.toLowerCase())) {
      if (await shouldFilterContent()) {
        return false;
      }
    }

    // Check content text
    if (content != null && containsInappropriateContent(content)) {
      if (await shouldFilterContent()) {
        return false;
      }
    }

    return true;
  }

  /// Moderate a post before publishing
  /// Returns null if OK, or error message if blocked
  Future<String?> moderateBeforePost(String content) async {
    if (containsInappropriateContent(content)) {
      return 'Your post contains content that violates our community guidelines. Please revise and try again.';
    }
    return null;
  }

  /// Get content warning for post
  String? getContentWarning(String content) {
    if (containsInappropriateContent(content)) {
      return '⚠️ This content may not be suitable for all audiences';
    }
    return null;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // AGE GATE HELPERS
  // ═══════════════════════════════════════════════════════════════════════════

  /// Check if user needs to verify age
  Future<bool> needsAgeVerification() async {
    return !(await _consentService.hasAgeBeenVerified());
  }

  /// Get minimum age for unrestricted content
  int getMinimumAge() => 18;

  /// Validate age input
  bool isValidAge(int age) {
    return age >= 13 && age <= 120;
  }
}
