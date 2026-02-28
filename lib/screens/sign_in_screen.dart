import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../gen_l10n/app_localizations.dart';
import '../theme/ios_design_system.dart';
import '../services/api_service.dart';
import '../services/database_helper.dart';
import '../services/oauth_service.dart';
import '../services/toast_service.dart';
import '../models/user_model.dart';
import '../main.dart';
import 'username_selection_screen.dart';


/// Sign In Screen
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    final l10n = AppLocalizations.of(context)!;
    
    setState(() {
      _errorMessage = null;
      _isLoading = true;
    });

    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    // Validation
    if (username.isEmpty) {
      setState(() {
        _errorMessage = l10n.errorUsername;
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

    try {
      // CHANGED: Call server API instead of local database
      final result = await ApiService.login(
        username: username,
        password: password,
      );
      
      // Success! Fetch user data and set in AppModel
      if (mounted) {
        final userId = result['user_id'];
        final token = result['token'];
        final username = result['username'];
        print('✅ Login successful! User ID: $userId');
        print('🔑 Token: $token');
        
        // Create User object (we'll need to fetch full details from server later)
        final user = User(
          id: userId,
          username: username,
          createdAt: DateTime.now(),
        );
        
        // Save to local database
        final db = DatabaseHelper.instance;
        await db.insertUser(user);
        
        // Set current user in AppModel
        final model = context.read<AppModel>();
        await model.setCurrentUser(user);
        
        print('✅ User set in AppModel: ${user.username}');
        
        Navigator.of(context).pushReplacementNamed('/home');
        
        ToastService.showSuccess(l10n.signInSuccess);
      }
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  // Reuse same OAuth methods as sign-up screen
  Future<void> _signInWithGoogle() async {
    setState(() {
      _errorMessage = null;
      _isLoading = true;
    });

    try {
      final oauthService = OAuthService();
      final oauthData = await oauthService.signInWithGoogle();

      if (oauthData == null) {
        setState(() => _isLoading = false);
        return;
      }

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
          // Existing user with username
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

  Future<void> _signInWithApple() async {
    setState(() {
      _errorMessage = null;
      _isLoading = true;
    });

    try {
      final oauthService = OAuthService();
      final oauthData = await oauthService.signInWithApple();

      if (oauthData == null) {
        setState(() => _isLoading = false);
        return;
      }

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
          // Existing user with username
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
            padding: const EdgeInsets.all(24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
              Text(
                l10n.signIn,
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
                  onPressed: _isLoading ? null : () => _signInWithApple(),
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
                  onPressed: _isLoading ? null : () => _signInWithGoogle(),
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
              
              const SizedBox(height: 40),
              
              // Username field
              TextField(
                controller: _usernameController,
                decoration: InputDecoration(
                  labelText: l10n.username,
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
              
              // Password field
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
                onSubmitted: (_) => _signIn(),
              ),
              const SizedBox(height: 8),
              
              // Forgot Password link
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () {
                    Navigator.pushNamed(context, '/forgot-password');
                  },
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    'Forgot password?',
                    style: TextStyle(
                      color: iOSDesignSystem.accentBlue,
                      fontSize: 14,
                    ),
                  ),
                ),
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
              
              // Sign In button
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _signIn,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: iOSDesignSystem.accentBlue,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(iOSDesignSystem.radiusButton),
                    ),
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
                          l10n.signIn,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
              
              const SizedBox(height: 24),
              
              // Sign up link
              Center(
                child: TextButton(
                  onPressed: () {
                    Navigator.of(context).pushReplacementNamed('/signup');
                  },
                  child: Text(
                    '${l10n.dontHaveAccount} ${l10n.signUp}',
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
