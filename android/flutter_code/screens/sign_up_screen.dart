import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl_phone_field/intl_phone_field.dart';
import 'package:intl_phone_field/phone_number.dart';
import '../gen_l10n/app_localizations.dart';
import '../theme/ios_design_system.dart';
import '../services/api_service.dart';
import '../services/database_helper.dart';
import '../services/oauth_service.dart';
import '../services/toast_service.dart';
import '../models/user_model.dart';
import '../utils/password_validator.dart';
import '../widgets/password_strength_checklist.dart';
import '../main.dart';
import 'username_selection_screen.dart';
import 'verify_email_screen.dart';



/// Sign Up Screen
class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _birthYearController = TextEditingController();
  final _emailController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;
  
  // Password validation state
  PasswordValidationResult _passwordValidation = const PasswordValidationResult(
    hasMinLength: false,
    hasUppercase: false,
    hasLowercase: false,
    hasNumber: false,
    hasSpecialChar: false,
  );
  
  // Phone number in E.164 format (e.g., +34612345678)
  String? _phoneNumber;
  bool _isPhoneValid = false;


  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _birthYearController.dispose();
    _emailController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  /// Sign up with Google
  Future<void> _signUpWithGoogle() async {
    setState(() {
      _errorMessage = null;
      _isLoading = true;
    });

    try {
      final oauthService = OAuthService();
      final oauthData = await oauthService.signInWithGoogle();

      if (oauthData == null) {
        // User cancelled
        setState(() => _isLoading = false);
        return;
      }

      // Call backend OAuth endpoint
      final result = await ApiService.oauthGoogle(
        idToken: oauthData.idToken!,
      );

      if (mounted) {
        final requiresUsername = result['requires_username'] == true;
        final username = result['username'] as String?;
        
        if (requiresUsername || username == null) {
          // New user OR existing user without username
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (context) => UsernameSelectionScreen(
                oAuthData: oauthData,
                tempToken: result['token'],
              ),
            ),
          );
        } else {
          // User already has username, proceed to home
          final model = context.read<AppModel>();
          await model.setCurrentUserFromOAuth(
            userId: result['user_id'],
            username: username,
            email: oauthData.email,
          );
          
          Navigator.of(context).pushReplacementNamed('/home');
        }
      }
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  /// Sign up with Apple
  Future<void> _signUpWithApple() async {
    setState(() {
      _errorMessage = null;
      _isLoading = true;
    });

    try {
      final oauthService = OAuthService();
      final oauthData = await oauthService.signInWithApple();

      if (oauthData == null) {
        // User cancelled
        setState(() => _isLoading = false);
        return;
      }

      // Call backend OAuth endpoint
      final result = await ApiService.oauthApple(
        identityToken: oauthData.idToken!,
        authorizationCode: oauthData.authorizationCode!,
      );

      if (mounted) {
        final requiresUsername = result['requires_username'] == true;
        final username = result['username'] as String?;
        
        if (requiresUsername || username == null) {
          // New user OR existing user without username
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (context) => UsernameSelectionScreen(
                oAuthData: oauthData,
                tempToken: result['token'],
              ),
            ),
          );
        } else {
          // User already has username, proceed to home
          final model = context.read<AppModel>();
          await model.setCurrentUserFromOAuth(
            userId: result['user_id'],
            username: username,
            email: oauthData.email,
          );
          
          Navigator.of(context).pushReplacementNamed('/home');
        }
      }
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
        _isLoading = false;
      });
    }
  }


  Future<void> _signUp() async {
    final l10n = AppLocalizations.of(context)!;
    
    setState(() {
      _errorMessage = null;
      _isLoading = true;
    });

    final firstName = _firstNameController.text.trim();
    final lastName = _lastNameController.text.trim();
    final birthYearStr = _birthYearController.text.trim();
    final email = _emailController.text.trim();
    final username = _usernameController.text.trim();
    final phone = _phoneNumber; // E.164 format from IntlPhoneField
    final password = _passwordController.text;
    final confirmPassword = _confirmPasswordController.text;

    // Validation
    if (firstName.isEmpty) {
      setState(() {
        _errorMessage = l10n.errorFirstName;
        _isLoading = false;
      });
      return;
    }

    if (lastName.isEmpty) {
      setState(() {
        _errorMessage = l10n.errorLastName;
        _isLoading = false;
      });
      return;
    }

    if (birthYearStr.isEmpty) {
      setState(() {
        _errorMessage = l10n.errorBirthYear;
        _isLoading = false;
      });
      return;
    }

    final birthYear = int.tryParse(birthYearStr);
    if (birthYear == null || birthYear < 1900 || birthYear > DateTime.now().year) {
      setState(() {
        _errorMessage = 'Invalid birth year';
        _isLoading = false;
      });
      return;
    }

    // Email is REQUIRED
    if (email.isEmpty) {
      setState(() {
        _errorMessage = 'Email is required';
        _isLoading = false;
      });
      ToastService.showError('Email is required to create an account');
      return;
    }

    // Username is REQUIRED
    if (username.isEmpty) {
      setState(() {
        _errorMessage = l10n.errorUsername;
        _isLoading = false;
      });
      return;
    }

    // Username format validation
    if (username.length < 3) {
      setState(() {
        _errorMessage = 'Username must be at least 3 characters';
        _isLoading = false;
      });
      return;
    }

    if (password.isEmpty) {
      setState(() {
        _errorMessage = l10n.errorPassword;
        _isLoading = false;
      });
      return;
    }

    if (password != confirmPassword) {
      setState(() {
        _errorMessage = l10n.errorPasswordMatch;
        _isLoading = false;
      });
      return;
    }

    // Strong password validation
    final passwordValidation = PasswordValidator.validate(password, username: username);
    if (!passwordValidation.isValid) {
      setState(() {
        _errorMessage = PasswordValidator.getFirstError(passwordValidation);
        _isLoading = false;
      });
      return;
    }

    // Validate email format
    if (!email.contains('@') || !email.contains('.')) {
      setState(() {
        _errorMessage = 'Invalid email format';
        _isLoading = false;
      });
      ToastService.showError('Please enter a valid email address');
      return;
    }

    // Phone is already validated by IntlPhoneField (E.164 format)

    // Phone is already validated by IntlPhoneField (E.164 format)

    try {
      // Call server API to register
      final result = await ApiService.register(
        username: username,
        password: password,
        firstName: firstName,
        lastName: lastName,
        birthYear: birthYear,
        email: email,
        phone: phone?.isNotEmpty == true ? phone : null,
      );
      
      // Success! Create local user and set in AppModel
      if (mounted) {
        final userId = result['user_id'];
        final token = result['token'];
        print('✅ Registration successful! User ID: $userId');
        print('🔑 Token: $token');
        
        // Create User object
        final user = User(
          id: userId,
          username: username,
          email: email,
          phone: phone?.isNotEmpty == true ? phone : null,
          createdAt: DateTime.now(),
        );
        
        // Save to local database
        final db = DatabaseHelper.instance;
        await db.insertUser(user);
        
        // Set current user in AppModel
        final model = context.read<AppModel>();
        await model.setCurrentUser(user);
        
        print('✅ User set in AppModel: ${user.username}');
        
        // ✅ Send verification code to email
        try {
          await ApiService.sendVerificationCode(
            identifier: email,
            channel: 'email',
            purpose: 'verify_email',
          );
          print('📧 Verification code sent to $email');
        } catch (e) {
          print('⚠️ Could not send verification code: $e');
          // Show user-friendly message but still proceed to verify screen
          ToastService.showError(
            'Could not send code',
            subtitle: 'Tap "Resend" on the next screen',
          );
        }
        
        // ✅ Navigate to verify email screen
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (context) => VerifyEmailScreen(
              email: email,
              userId: userId,
            ),
          ),
        );
        
        ToastService.showSuccess('Account created! Please verify your email.');
      }
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    return Scaffold(
      backgroundColor: iOSDesignSystem.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: iOSDesignSystem.accentBlue),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusScope.of(context).unfocus(),
        child: SafeArea(
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.only(left: 24.0, right: 24.0, top: 24.0, bottom: 100.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
              Text(
                l10n.signUp,
                style: const TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              
              const SizedBox(height: 32),
              
              // Apple Sign-In Button - DISABLED (requires paid Apple Developer account)
              // Personal Teams don't support Apple Sign-In capability
              /*
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton.icon(
                  onPressed: _isLoading ? null : _signUpWithApple,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(iOSDesignSystem.radiusButton),
                    ),
                  ),
                  icon: const Icon(Icons.apple, size: 24),
                  label: const Text(
                    'Continue with Apple',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              
              const SizedBox(height: 16),
              */
              
              // Google Sign-In Button
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton.icon(
                  onPressed: _isLoading ? null : _signUpWithGoogle,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black87,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(iOSDesignSystem.radiusButton),
                      side: const BorderSide(color: Colors.grey, width: 0.5),
                    ),
                  ),
                  icon: Image.asset(
                    'assets/google_logo.png',
                    height: 24,
                    width: 24,
                    errorBuilder: (context, error, stackTrace) => const Icon(Icons.g_mobiledata, size: 28),
                  ),
                  label: const Text(
                    'Continue with Google',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              
              const SizedBox(height: 32),
              
              // Divider with "OR"
              Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 1,
                      color: iOSDesignSystem.textSecondary.withOpacity(0.3),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'OR',
                      style: TextStyle(
                        color: iOSDesignSystem.textSecondary,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Container(
                      height: 1,
                      color: iOSDesignSystem.textSecondary.withOpacity(0.3),
                    ),
                  ),
                ],
              ),
              
              const SizedBox(height: 32),
              
              // First Name
              TextField(
                controller: _firstNameController,
                decoration: InputDecoration(
                  labelText: l10n.firstName,
                  filled: true,
                  fillColor: iOSDesignSystem.surfaceCard,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(iOSDesignSystem.radiusButton),
                    borderSide: BorderSide.none,
                  ),
                ),
                style: const TextStyle(color: Colors.white),
              ),
              
              const SizedBox(height: 16),
              
              // Last Name
              TextField(
                controller: _lastNameController,
                decoration: InputDecoration(
                  labelText: l10n.lastName,
                  filled: true,
                  fillColor: iOSDesignSystem.surfaceCard,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(iOSDesignSystem.radiusButton),
                    borderSide: BorderSide.none,
                  ),
                ),
                style: const TextStyle(color: Colors.white),
              ),
              
              const SizedBox(height: 16),
              
              // Birth Year
              TextField(
                controller: _birthYearController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: l10n.birthYear,
                  filled: true,
                  fillColor: iOSDesignSystem.surfaceCard,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(iOSDesignSystem.radiusButton),
                    borderSide: BorderSide.none,
                  ),
                ),
                style: const TextStyle(color: Colors.white),
              ),
              
              const SizedBox(height: 16),
              
              // Email (Required)
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: 'Email (Required)',
                  hintText: 'your@email.com',
                  filled: true,
                  fillColor: iOSDesignSystem.surfaceCard,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(iOSDesignSystem.radiusButton),
                    borderSide: BorderSide.none,
                  ),
                ),
                style: const TextStyle(color: Colors.white),
              ),
              
              const SizedBox(height: 16),
              
              // Phone (Optional) - International Phone Field with Country Picker
              IntlPhoneField(
                decoration: InputDecoration(
                  labelText: 'Phone (Optional)',
                  filled: true,
                  fillColor: iOSDesignSystem.surfaceCard,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(iOSDesignSystem.radiusButton),
                    borderSide: BorderSide.none,
                  ),
                  counterText: '', // Hide character counter
                ),
                style: const TextStyle(color: Colors.white),
                dropdownTextStyle: const TextStyle(color: Colors.white),
                initialCountryCode: 'ES', // Spain as default
                disableLengthCheck: true, // Allow any length
                showCountryFlag: true,
                showDropdownIcon: true,
                dropdownIconPosition: IconPosition.trailing,
                flagsButtonPadding: const EdgeInsets.only(left: 12),
                onChanged: (PhoneNumber phone) {
                  setState(() {
                    _phoneNumber = phone.completeNumber; // E.164 format: +34612345678
                    _isPhoneValid = phone.isValidNumber();
                  });
                },
                onCountryChanged: (country) {
                  // Country changed - reset validation
                  setState(() {
                    _isPhoneValid = false;
                  });
                },
              ),
              
              const SizedBox(height: 16),
              
              // Username
              TextField(
                controller: _usernameController,
                decoration: InputDecoration(
                  labelText: l10n.username,
                  hintText: '@username',
                  filled: true,
                  fillColor: iOSDesignSystem.surfaceCard,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(iOSDesignSystem.radiusButton),
                    borderSide: BorderSide.none,
                  ),
                  prefixIcon: const Icon(Icons.alternate_email, color: iOSDesignSystem.textSecondary),
                ),
                style: const TextStyle(color: Colors.white),
              ),
              
              const SizedBox(height: 16),
              
              // Password
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: l10n.password,
                  filled: true,
                  fillColor: iOSDesignSystem.surfaceCard,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(iOSDesignSystem.radiusButton),
                    borderSide: BorderSide.none,
                  ),
                ),
                style: const TextStyle(color: Colors.white),
                onChanged: (value) {
                  // Update password validation in real-time
                  setState(() {
                    _passwordValidation = PasswordValidator.validate(value);
                  });
                },
              ),
              
              const SizedBox(height: 12),
              
              // Password Strength Checklist (TikTok-style)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: PasswordStrengthChecklist(
                  password: _passwordController.text,
                ),
              ),
              
              const SizedBox(height: 16),
              
              // Confirm Password
              TextField(
                controller: _confirmPasswordController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: l10n.confirmPassword,
                  filled: true,
                  fillColor: iOSDesignSystem.surfaceCard,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(iOSDesignSystem.radiusButton),
                    borderSide: BorderSide.none,
                  ),
                  // Show match indicator
                  suffixIcon: _confirmPasswordController.text.isNotEmpty
                      ? Icon(
                          _passwordController.text == _confirmPasswordController.text
                              ? Icons.check_circle
                              : Icons.cancel,
                          color: _passwordController.text == _confirmPasswordController.text
                              ? const Color(0xFF34C759)
                              : Colors.red.shade400,
                        )
                      : null,
                ),
                style: const TextStyle(color: Colors.white),
                onChanged: (_) => setState(() {}), // Refresh to update match indicator
                onSubmitted: (_) => _signUp(),
              ),
              
              const SizedBox(height: 16),
              
              // Error message
              if (_errorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    _errorMessage!,
                    style: const TextStyle(
                      color: Colors.red,
                      fontSize: 14,
                    ),
                  ),
                ),
              
              // Sign Up button - Disabled until password is valid
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _isLoading || !_passwordValidation.isValid || 
                             _passwordController.text != _confirmPasswordController.text ||
                             _confirmPasswordController.text.isEmpty
                      ? null 
                      : _signUp,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _passwordValidation.isValid && 
                                     _passwordController.text == _confirmPasswordController.text &&
                                     _confirmPasswordController.text.isNotEmpty
                        ? iOSDesignSystem.accentBlue 
                        : iOSDesignSystem.accentBlue.withOpacity(0.4),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(iOSDesignSystem.radiusButton),
                    ),
                    disabledBackgroundColor: iOSDesignSystem.accentBlue.withOpacity(0.4),
                    disabledForegroundColor: Colors.white.withOpacity(0.6),
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        )
                      : Text(
                          l10n.signUp,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),

              
              const SizedBox(height: 24),
              
              // Sign in link
              Center(
                child: TextButton(
                  onPressed: () {
                    Navigator.of(context).pushReplacementNamed('/signin');
                  },
                  child: Text(
                    '${l10n.alreadyHaveAccount} ${l10n.signIn}',
                    style: const TextStyle(
                      color: iOSDesignSystem.accentBlue,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }
}
