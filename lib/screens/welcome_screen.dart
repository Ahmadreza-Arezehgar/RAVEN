import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../gen_l10n/app_localizations.dart';
import '../theme/ios_design_system.dart';
import '../services/oauth_service.dart';
import '../services/api_service.dart';
import '../main.dart';
import 'sign_in_screen.dart';
import 'sign_up_screen.dart';
import 'username_selection_screen.dart';

/// Welcome screen with language selector and auth options
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  bool _isLoading = false;
  String? _errorMessage;

  Future<void> _continueWithGoogle() async {
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
          // New user OR existing user without username - navigate to username selection
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => UsernameSelectionScreen(
                oAuthData: oauthData,
                tempToken: result['token'],
              ),
            ),
          );
        } else {
          // Existing user with username - auto login
          final model = context.read<AppModel>();
          await model.setCurrentUserFromOAuth(
            userId: result['user_id'],
            username: username,
            email: oauthData.email,
          );
          
          Navigator.of(context).pushReplacementNamed('/home');
        }
        
        setState(() => _isLoading = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().replaceAll('Exception: ', '');
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    return Scaffold(
      backgroundColor: iOSDesignSystem.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(),
              
              // App Logo/Icon
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(30),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF0A84FF).withOpacity(0.3),
                      blurRadius: 30,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(30),
                  child: Image.asset(
                    'assets/raven_logo.png',
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) {
                      return Container(
                        decoration: BoxDecoration(
                          color: iOSDesignSystem.accentBlue,
                          borderRadius: BorderRadius.circular(30),
                        ),
                        child: const Icon(
                          Icons.chat_bubble,
                          size: 50,
                          color: Colors.white,
                        ),
                      );
                    },
                  ),
                ),
              ),
              
              const SizedBox(height: 32),
              
              // App Title
              const Text(
                'Raven',
                style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: 1,
                ),
              ),
              
              const SizedBox(height: 8),
              
              // Subtitle
              Text(
                l10n.appSubtitle,
                style: const TextStyle(
                  fontSize: 16,
                  color: iOSDesignSystem.textSecondary,
                ),
              ),
              
              const Spacer(),
              
              // Google Sign-In Button
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton.icon(
                  onPressed: _isLoading ? null : _continueWithGoogle,
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
                  label: _isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text(
                          'Continue with Google',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
              
              const SizedBox(height: 24),
              
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
              
              const SizedBox(height: 24),
              
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
                    textAlign: TextAlign.center,
                  ),
                ),
              
              // Sign In Button
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const SignInScreen()),
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: iOSDesignSystem.accentBlue,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(iOSDesignSystem.radiusButton),
                    ),
                  ),
                  child: Text(
                    l10n.signIn,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              
              const SizedBox(height: 16),
              
              // Sign Up Button
              SizedBox(
                width: double.infinity,
                height: 56,
                child: OutlinedButton(
                  onPressed: _isLoading ? null : () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const SignUpScreen()),
                    );
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: iOSDesignSystem.accentBlue,
                    side: const BorderSide(color: iOSDesignSystem.accentBlue),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(iOSDesignSystem.radiusButton),
                    ),
                  ),
                  child: Text(
                    l10n.signUp,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              
              const SizedBox(height: 32),
              
              // Language selector
              _buildLanguageSelector(context),
              
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _buildLanguageSelector(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    // TODO: Get current language from settings
    final currentLanguage = Localizations.localeOf(context).languageCode;
    
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          '${l10n.language}:',
          style: const TextStyle(
            color: iOSDesignSystem.textSecondary,
            fontSize: 14,
          ),
        ),
        const SizedBox(width: 8),
        DropdownButton<String>(
          value: currentLanguage,
          dropdownColor: iOSDesignSystem.surfaceCard,
          underline: Container(),
          style: const TextStyle(
            color: iOSDesignSystem.accentBlue,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
          items: [
            DropdownMenuItem(value: 'en', child: Text(l10n.english)),
            DropdownMenuItem(value: 'fa', child: Text(l10n.persian)),
            DropdownMenuItem(value: 'zh', child: Text(l10n.chinese)),
            DropdownMenuItem(value: 'es', child: Text(l10n.spanish)),
          ],
          onChanged: (String? newLang) {
            if (newLang != null) {
              // TODO: Implement language change
              print('Language changed to: $newLang');
            }
          },
        ),
      ],
    );
  }
}
