/// Password validation utility with strong password policy
/// 
/// Policy:
/// - Minimum 10 characters
/// - At least 1 uppercase letter (A-Z)
/// - At least 1 lowercase letter (a-z)
/// - At least 1 number (0-9)
/// - At least 1 special character (!@#$%^&*()_+-=[]{}/?.)
/// - Cannot contain username (optional)
/// - Rejects common passwords (optional)

class PasswordValidationResult {
  final bool hasMinLength;
  final bool hasUppercase;
  final bool hasLowercase;
  final bool hasNumber;
  final bool hasSpecialChar;
  final bool doesNotContainUsername;
  final bool isNotCommonPassword;

  const PasswordValidationResult({
    required this.hasMinLength,
    required this.hasUppercase,
    required this.hasLowercase,
    required this.hasNumber,
    required this.hasSpecialChar,
    this.doesNotContainUsername = true,
    this.isNotCommonPassword = true,
  });

  /// Returns true if all required criteria are met
  bool get isValid =>
      hasMinLength &&
      hasUppercase &&
      hasLowercase &&
      hasNumber &&
      hasSpecialChar &&
      doesNotContainUsername &&
      isNotCommonPassword;

  /// Returns the number of criteria met (out of 5 main ones)
  int get criteriaMetCount {
    int count = 0;
    if (hasMinLength) count++;
    if (hasUppercase) count++;
    if (hasLowercase) count++;
    if (hasNumber) count++;
    if (hasSpecialChar) count++;
    return count;
  }

  /// Returns strength as percentage (0.0 to 1.0)
  double get strengthPercentage => criteriaMetCount / 5.0;
}

class PasswordValidator {
  static const int minLength = 10;

  /// Common passwords that should be rejected
  static const List<String> commonPasswords = [
    '123456',
    '12345678',
    '1234567890',
    'password',
    'password123',
    'qwerty',
    'qwerty123',
    'abc123',
    'letmein',
    'welcome',
    'admin',
    'login',
    'master',
    'dragon',
    'passw0rd',
    'iloveyou',
    'sunshine',
    'princess',
    'football',
    'monkey',
    'shadow',
    'michael',
    'jennifer',
    'trustno1',
    '123123',
    '654321',
    'superman',
    'batman',
    'whatever',
  ];

  /// Validates a password against the strong password policy
  /// 
  /// [password] - The password to validate
  /// [username] - Optional username to check if password contains it
  /// [checkCommonPasswords] - Whether to reject common passwords
  static PasswordValidationResult validate(
    String password, {
    String? username,
    bool checkCommonPasswords = true,
  }) {
    final hasMinLength = password.length >= minLength;
    final hasUppercase = RegExp(r'[A-Z]').hasMatch(password);
    final hasLowercase = RegExp(r'[a-z]').hasMatch(password);
    final hasNumber = RegExp(r'\d').hasMatch(password);
    final hasSpecialChar = RegExp(r'[!@#$%^&*()_+\-=\[\]{}/?.,<>:;"|\\`~]').hasMatch(password);
    
    // Check if password contains username (case-insensitive)
    final doesNotContainUsername = username == null ||
        username.isEmpty ||
        !password.toLowerCase().contains(username.toLowerCase());
    
    // Check against common passwords
    final isNotCommonPassword = !checkCommonPasswords ||
        !commonPasswords.contains(password.toLowerCase());

    return PasswordValidationResult(
      hasMinLength: hasMinLength,
      hasUppercase: hasUppercase,
      hasLowercase: hasLowercase,
      hasNumber: hasNumber,
      hasSpecialChar: hasSpecialChar,
      doesNotContainUsername: doesNotContainUsername,
      isNotCommonPassword: isNotCommonPassword,
    );
  }

  /// Quick check if password is valid (meets all criteria)
  static bool isValid(String password, {String? username}) {
    return validate(password, username: username).isValid;
  }

  /// Regex pattern for client-side validation (basic check)
  /// Note: This doesn't check for username or common passwords
  static final RegExp strongPasswordRegex = RegExp(
    r'^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[!@#$%^&*()_+\-=\[\]{}/?.,<>:;"|\\`~]).{10,}$',
  );

  /// Get a human-readable error message for the first failing criterion
  static String? getFirstError(PasswordValidationResult result) {
    if (!result.hasMinLength) {
      return 'Password must be at least $minLength characters';
    }
    if (!result.hasUppercase) {
      return 'Password must contain at least one uppercase letter';
    }
    if (!result.hasLowercase) {
      return 'Password must contain at least one lowercase letter';
    }
    if (!result.hasNumber) {
      return 'Password must contain at least one number';
    }
    if (!result.hasSpecialChar) {
      return 'Password must contain at least one special character';
    }
    if (!result.doesNotContainUsername) {
      return 'Password cannot contain your username';
    }
    if (!result.isNotCommonPassword) {
      return 'This password is too common. Please choose a stronger one';
    }
    return null;
  }
}
