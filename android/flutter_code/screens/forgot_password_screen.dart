import 'package:flutter/material.dart';
import '../gen_l10n/app_localizations.dart';
import '../theme/ios_design_system.dart';
import '../services/api_service.dart';
import '../services/toast_service.dart';

/// Forgot Password Screen - Step 1: Enter email or phone
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _emailOrPhoneController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailOrPhoneController.dispose();
    super.dispose();
  }

  Future<void> _sendResetCode() async {
    final emailOrPhone = _emailOrPhoneController.text.trim();
    
    if (emailOrPhone.isEmpty) {
      setState(() => _errorMessage = 'Please enter your email or phone number');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await ApiService.forgotPassword(emailOrPhone);
      
      if (mounted) {
        // Navigate to reset password screen
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => ResetPasswordScreen(
              emailOrPhone: emailOrPhone,
            ),
          ),
        );
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
              const SizedBox(height: 20),
              
              const Text(
                'Forgot Password',
                style: TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              
              const SizedBox(height: 12),
              
              Text(
                'Enter your email or phone number and we\'ll send you a code to reset your password.',
                style: TextStyle(
                  fontSize: 16,
                  color: iOSDesignSystem.textSecondary,
                ),
              ),
              
              const SizedBox(height: 40),
              
              // Email or Phone field
              TextField(
                controller: _emailOrPhoneController,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: 'Email or Phone',
                  hintText: 'your@email.com or +34...',
                  filled: true,
                  fillColor: iOSDesignSystem.surfaceCard,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(iOSDesignSystem.radiusButton),
                    borderSide: BorderSide.none,
                  ),
                  prefixIcon: const Icon(Icons.person_outline, color: iOSDesignSystem.textSecondary),
                ),
                style: const TextStyle(color: Colors.white),
                onSubmitted: (_) => _sendResetCode(),
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
              
              // Send Code button
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _sendResetCode,
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
                          'Send Reset Code',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
              
              const SizedBox(height: 24),
              
              // Back to Sign In
              Center(
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text(
                    'Back to Sign In',
                    style: TextStyle(
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


/// Reset Password Screen - Step 2: Enter OTP and new password
class ResetPasswordScreen extends StatefulWidget {
  final String emailOrPhone;
  
  const ResetPasswordScreen({
    super.key,
    required this.emailOrPhone,
  });

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _codeController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  bool get _isPasswordValid {
    final password = _passwordController.text;
    return password.length >= 10 &&
           RegExp(r'[A-Z]').hasMatch(password) &&
           RegExp(r'[a-z]').hasMatch(password) &&
           RegExp(r'\d').hasMatch(password) &&
           RegExp(r'[!@#$%^&*()_+\-=\[\]{}/?.]').hasMatch(password);
  }

  bool get _passwordsMatch {
    return _passwordController.text == _confirmPasswordController.text &&
           _confirmPasswordController.text.isNotEmpty;
  }

  Future<void> _resetPassword() async {
    final code = _codeController.text.trim();
    final password = _passwordController.text;
    final confirmPassword = _confirmPasswordController.text;

    if (code.isEmpty || code.length != 6) {
      setState(() => _errorMessage = 'Please enter the 6-digit code');
      return;
    }

    if (!_isPasswordValid) {
      setState(() => _errorMessage = 'Password does not meet requirements');
      return;
    }

    if (password != confirmPassword) {
      setState(() => _errorMessage = 'Passwords do not match');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final success = await ApiService.resetPassword(
        emailOrPhone: widget.emailOrPhone,
        code: code,
        newPassword: password,
      );
      
      if (success && mounted) {
        ToastService.showSuccess('Password reset successfully!');
        // Go back to sign in
        Navigator.of(context).popUntil((route) => route.isFirst);
        Navigator.of(context).pushReplacementNamed('/signin');
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
              const Text(
                'Reset Password',
                style: TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              
              const SizedBox(height: 12),
              
              Text(
                'Enter the code sent to ${widget.emailOrPhone} and your new password.',
                style: TextStyle(
                  fontSize: 16,
                  color: iOSDesignSystem.textSecondary,
                ),
              ),
              
              const SizedBox(height: 32),
              
              // Verification Code
              TextField(
                controller: _codeController,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: InputDecoration(
                  labelText: 'Verification Code',
                  hintText: '6-digit code',
                  counterText: '',
                  filled: true,
                  fillColor: iOSDesignSystem.surfaceCard,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(iOSDesignSystem.radiusButton),
                    borderSide: BorderSide.none,
                  ),
                  prefixIcon: const Icon(Icons.lock_outline, color: iOSDesignSystem.textSecondary),
                ),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  letterSpacing: 8,
                ),
              ),
              
              const SizedBox(height: 16),
              
              // New Password
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'New Password',
                  filled: true,
                  fillColor: iOSDesignSystem.surfaceCard,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(iOSDesignSystem.radiusButton),
                    borderSide: BorderSide.none,
                  ),
                  prefixIcon: const Icon(Icons.password, color: iOSDesignSystem.textSecondary),
                ),
                style: const TextStyle(color: Colors.white),
                onChanged: (_) => setState(() {}),
              ),
              
              const SizedBox(height: 12),
              
              // Password requirements
              _PasswordRequirement(
                text: '10+ characters',
                isMet: _passwordController.text.length >= 10,
              ),
              _PasswordRequirement(
                text: 'Uppercase letter',
                isMet: RegExp(r'[A-Z]').hasMatch(_passwordController.text),
              ),
              _PasswordRequirement(
                text: 'Lowercase letter',
                isMet: RegExp(r'[a-z]').hasMatch(_passwordController.text),
              ),
              _PasswordRequirement(
                text: 'Number',
                isMet: RegExp(r'\d').hasMatch(_passwordController.text),
              ),
              _PasswordRequirement(
                text: 'Special character',
                isMet: RegExp(r'[!@#$%^&*()_+\-=\[\]{}/?.]').hasMatch(_passwordController.text),
              ),
              
              const SizedBox(height: 16),
              
              // Confirm Password
              TextField(
                controller: _confirmPasswordController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Confirm Password',
                  filled: true,
                  fillColor: iOSDesignSystem.surfaceCard,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(iOSDesignSystem.radiusButton),
                    borderSide: BorderSide.none,
                  ),
                  prefixIcon: const Icon(Icons.password, color: iOSDesignSystem.textSecondary),
                  suffixIcon: _confirmPasswordController.text.isNotEmpty
                      ? Icon(
                          _passwordsMatch ? Icons.check_circle : Icons.cancel,
                          color: _passwordsMatch ? const Color(0xFF34C759) : Colors.red,
                        )
                      : null,
                ),
                style: const TextStyle(color: Colors.white),
                onChanged: (_) => setState(() {}),
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
              
              // Reset Password button
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _isLoading || !_isPasswordValid || !_passwordsMatch
                      ? null
                      : _resetPassword,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isPasswordValid && _passwordsMatch
                        ? iOSDesignSystem.accentBlue
                        : iOSDesignSystem.accentBlue.withOpacity(0.4),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(iOSDesignSystem.radiusButton),
                    ),
                    disabledBackgroundColor: iOSDesignSystem.accentBlue.withOpacity(0.4),
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
                          'Reset Password',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
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

class _PasswordRequirement extends StatelessWidget {
  final String text;
  final bool isMet;

  const _PasswordRequirement({
    required this.text,
    required this.isMet,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            isMet ? Icons.check_circle : Icons.circle_outlined,
            size: 16,
            color: isMet ? const Color(0xFF34C759) : iOSDesignSystem.textSecondary,
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              fontSize: 13,
              color: isMet ? const Color(0xFF34C759) : iOSDesignSystem.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
