import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../gen_l10n/app_localizations.dart';
import '../theme/ios_design_system.dart';
import '../services/api_service.dart';
import '../services/oauth_service.dart';
import '../services/toast_service.dart';
import '../main.dart';

/// Username Selection Screen - shown after OAuth authentication
/// Users must choose a unique username before proceeding to the app
class UsernameSelectionScreen extends StatefulWidget {
  final OAuthUserData oAuthData;
  final String tempToken; // Temporary JWT token for authenticated API calls

  const UsernameSelectionScreen({
    super.key,
    required this.oAuthData,
    required this.tempToken,
  });

  @override
  State<UsernameSelectionScreen> createState() => _UsernameSelectionScreenState();
}

class _UsernameSelectionScreenState extends State<UsernameSelectionScreen> {
  final _usernameController = TextEditingController();
  bool _isLoading = false;
  bool _isCheckingAvailability = false;
  String? _errorMessage;
  String? _availabilityMessage;
  bool _isUsernameAvailable = false;

  @override
  void dispose() {
    _usernameController.dispose();
    super.dispose();
  }

  /// Check username availability in real-time
  Future<void> _checkUsernameAvailability(String username) async {
    if (username.isEmpty || username.length < 3) {
      setState(() {
        _availabilityMessage = null;
        _isUsernameAvailable = false;
      });
      return;
    }

    setState(() {
      _isCheckingAvailability = true;
      _availabilityMessage = null;
    });

    try {
      final isAvailable = await ApiService.checkUsernameAvailability(username);
      
      setState(() {
        _isCheckingAvailability = false;
        _isUsernameAvailable = isAvailable;
        _availabilityMessage = isAvailable 
            ? '✓ Username available' 
            : '✗ Username taken';
      });
    } catch (e) {
      setState(() {
        _isCheckingAvailability = false;
        _availabilityMessage = null;
      });
    }
  }

  /// Complete sign-up by setting username
  Future<void> _completeSignUp() async {
    final l10n = AppLocalizations.of(context)!;
    final username = _usernameController.text.trim();
    
    setState(() {
      _errorMessage = null;
      _isLoading = true;
    });

    // Validation
    if (username.isEmpty) {
      setState(() {
        _errorMessage = l10n.errorUsername;
        _isLoading = false;
      });
      return;
    }

    if (username.length < 3) {
      setState(() {
        _errorMessage = 'Username must be at least 3 characters';
        _isLoading = false;
      });
      return;
    }

    if (!_isUsernameAvailable) {
      setState(() {
        _errorMessage = 'Please choose an available username';
        _isLoading = false;
      });
      return;
    }

    try {
      // Call API to set username
      final result = await ApiService.setUsername(
        username: username,
        tempToken: widget.tempToken,
      );

      if (mounted) {
        // Set current user in AppModel
        final model = context.read<AppModel>();
        await model.setCurrentUserFromOAuth(
          userId: result['user_id'],
          username: username,
          email: widget.oAuthData.email,
        );

        print('✅ Username set successfully: $username');

        // Navigate to home
        Navigator.of(context).pushNamedAndRemoveUntil('/home', (route) => false);

        ToastService.showSuccess('Account setup complete!');
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

    return WillPopScope(
      // Prevent going back - user must complete username selection
      onWillPop: () async => false,
      child: Scaffold(
        backgroundColor: iOSDesignSystem.background,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          automaticallyImplyLeading: false, // Remove back button
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Welcome message
                Text(
                  'Welcome, ${widget.oAuthData.fullName}!',
                  style: const TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                
                const SizedBox(height: 16),
                
                Text(
                  'Choose a username to complete your account setup',
                  style: TextStyle(
                    fontSize: 17,
                    color: iOSDesignSystem.textSecondary,
                  ),
                ),
                
                const SizedBox(height: 48),
                
                // Username input
                TextField(
                  controller: _usernameController,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: l10n.username,
                    hintText: 'e.g., john_doe',
                    filled: true,
                    fillColor: iOSDesignSystem.surfaceCard,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(iOSDesignSystem.radiusButton),
                      borderSide: BorderSide.none,
                    ),
                    suffixIcon: _isCheckingAvailability
                        ? const Padding(
                            padding: EdgeInsets.all(12.0),
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : _availabilityMessage != null
                            ? Icon(
                                _isUsernameAvailable ? Icons.check_circle : Icons.cancel,
                                color: _isUsernameAvailable ? Colors.green : Colors.red,
                              )
                            : null,
                  ),
                  style: const TextStyle(color: Colors.white),
                  onChanged: (value) {
                    // Debounce username availability check
                    Future.delayed(const Duration(milliseconds: 500), () {
                      if (_usernameController.text == value) {
                        _checkUsernameAvailability(value);
                      }
                    });
                  },
                  onSubmitted: (_) => _completeSignUp(),
                ),
                
                const SizedBox(height: 8),
                
                // Availability message
                if (_availabilityMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 12, top: 4),
                    child: Text(
                      _availabilityMessage!,
                      style: TextStyle(
                        color: _isUsernameAvailable ? Colors.green : Colors.red,
                        fontSize: 14,
                      ),
                    ),
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
                    ),
                  ),
                
                // Complete button
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: (_isLoading || !_isUsernameAvailable) ? null : _completeSignUp,
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
                        : const Text(
                            'Complete Sign Up',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                ),
                
                const SizedBox(height: 24),
                
                // Info text
                Center(
                  child: Text(
                    'This username will be used for interactions in the app',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: iOSDesignSystem.textSecondary,
                      fontSize: 13,
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
