import 'package:flutter/material.dart';
import '../../theme/ios_design_system.dart';
import '../../services/api_service.dart';
import 'verify_email_screen.dart';

/// Step 1: Email Entry Screen
/// Beautiful animated email input with Liquid Glass design
class EmailStepScreen extends StatefulWidget {
  const EmailStepScreen({super.key});

  @override
  State<EmailStepScreen> createState() => _EmailStepScreenState();
}

class _EmailStepScreenState extends State<EmailStepScreen>
    with SingleTickerProviderStateMixin {
  final _emailController = TextEditingController();
  final _focusNode = FocusNode();
  bool _isLoading = false;
  String? _errorMessage;
  bool _isEmailValid = false;

  late AnimationController _animController;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeAnim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOut),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _animController, curve: Curves.easeOut));

    _animController.forward();
    
    // Auto focus email field
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _focusNode.dispose();
    _animController.dispose();
    super.dispose();
  }

  bool _validateEmail(String email) {
    final emailRegex = RegExp(r'^[\w\.-]+@[\w\.-]+\.\w{2,}$');
    return emailRegex.hasMatch(email.trim());
  }

  Future<void> _continueWithEmail() async {
    final email = _emailController.text.trim().toLowerCase();

    if (!_validateEmail(email)) {
      setState(() => _errorMessage = 'Please enter a valid email address');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // First check if email exists (for better UX)
      // Then send verification code
      await ApiService.sendVerificationCode(
        identifier: email,
        channel: 'email',
        purpose: 'registration',
      );

      if (mounted) {
        Navigator.of(context).push(
          PageRouteBuilder(
            pageBuilder: (context, animation, secondaryAnimation) =>
                VerifyEmailScreen(email: email),
            transitionsBuilder: (context, animation, secondaryAnimation, child) {
              return SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(1, 0),
                  end: Offset.zero,
                ).animate(CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutCubic,
                )),
                child: child,
              );
            },
            transitionDuration: const Duration(milliseconds: 400),
          ),
        );
      }
    } catch (e) {
      String errorMsg = e.toString().replaceAll('Exception: ', '');
      
      // Handle specific errors
      if (errorMsg.contains('already exists') || errorMsg.contains('Email already')) {
        errorMsg = 'This email is already registered. Try signing in instead.';
      }
      
      setState(() {
        _errorMessage = errorMsg;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: iOSDesignSystem.background,
      body: SafeArea(
        child: Stack(
          children: [
            // Background gradient orbs
            Positioned(
              top: -100,
              right: -100,
              child: Container(
                width: 300,
                height: 300,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      iOSDesignSystem.accentBlue.withOpacity(0.15),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: -50,
              left: -80,
              child: Container(
                width: 250,
                height: 250,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      iOSDesignSystem.accentPurple.withOpacity(0.1),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),

            // Main content
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 16),

                  // Back button
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(
                      Icons.arrow_back_ios_new,
                      color: iOSDesignSystem.accentBlue,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),

                  const Spacer(flex: 2),

                  // Animated content
                  FadeTransition(
                    opacity: _fadeAnim,
                    child: SlideTransition(
                      position: _slideAnim,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Step indicator
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: iOSDesignSystem.accentBlue.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Text(
                              'Step 1 of 4',
                              style: TextStyle(
                                color: iOSDesignSystem.accentBlue,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),

                          const SizedBox(height: 24),

                          // Title
                          const Text(
                            "What's your\nemail?",
                            style: TextStyle(
                              fontSize: 40,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                              height: 1.1,
                              letterSpacing: -0.5,
                            ),
                          ),

                          const SizedBox(height: 12),

                          Text(
                            "We'll send a verification code to this email.",
                            style: TextStyle(
                              fontSize: 16,
                              color: iOSDesignSystem.textSecondary,
                              height: 1.4,
                            ),
                          ),

                          const SizedBox(height: 40),

                          // Email input with Liquid Glass style
                          Container(
                            decoration: BoxDecoration(
                              color: iOSDesignSystem.surfaceCard,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: _focusNode.hasFocus
                                    ? iOSDesignSystem.accentBlue
                                    : Colors.white.withOpacity(0.1),
                                width: 1.5,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: iOSDesignSystem.accentBlue.withOpacity(
                                    _focusNode.hasFocus ? 0.15 : 0,
                                  ),
                                  blurRadius: 20,
                                  spreadRadius: 0,
                                ),
                              ],
                            ),
                            child: TextField(
                              controller: _emailController,
                              focusNode: _focusNode,
                              keyboardType: TextInputType.emailAddress,
                              autocorrect: false,
                              textInputAction: TextInputAction.done,
                              onSubmitted: (_) => _continueWithEmail(),
                              onChanged: (value) {
                                setState(() {
                                  _isEmailValid = _validateEmail(value);
                                  _errorMessage = null;
                                });
                              },
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w500,
                              ),
                              decoration: InputDecoration(
                                hintText: 'name@example.com',
                                hintStyle: TextStyle(
                                  color: iOSDesignSystem.textSecondary
                                      .withOpacity(0.5),
                                  fontSize: 18,
                                ),
                                prefixIcon: Icon(
                                  Icons.email_outlined,
                                  color: _isEmailValid
                                      ? iOSDesignSystem.accentBlue
                                      : iOSDesignSystem.textSecondary,
                                ),
                                suffixIcon: _isEmailValid
                                    ? const Icon(
                                        Icons.check_circle,
                                        color: Color(0xFF34C759),
                                      )
                                    : null,
                                border: InputBorder.none,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 18,
                                ),
                              ),
                            ),
                          ),

                          // Error message
                          if (_errorMessage != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 12, left: 4),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.error_outline,
                                    color: Colors.redAccent,
                                    size: 16,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      _errorMessage!,
                                      style: const TextStyle(
                                        color: Colors.redAccent,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),

                          const SizedBox(height: 12),

                          // Info text
                          Row(
                            children: [
                              Icon(
                                Icons.info_outline,
                                size: 14,
                                color: iOSDesignSystem.textSecondary,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'Email is required for account security',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: iOSDesignSystem.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),

                  const Spacer(flex: 3),

                  // Continue button
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: double.infinity,
                    height: 56,
                    decoration: BoxDecoration(
                      gradient: _isEmailValid && !_isLoading
                          ? const LinearGradient(
                              colors: [
                                Color(0xFF6366F1),
                                Color(0xFF8B5CF6),
                              ],
                            )
                          : null,
                      color: _isEmailValid && !_isLoading
                          ? null
                          : iOSDesignSystem.surfaceCard,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: _isEmailValid && !_isLoading
                          ? [
                              BoxShadow(
                                color: const Color(0xFF6366F1).withOpacity(0.4),
                                blurRadius: 20,
                                offset: const Offset(0, 8),
                              ),
                            ]
                          : null,
                    ),
                    child: ElevatedButton(
                      onPressed:
                          _isEmailValid && !_isLoading ? _continueWithEmail : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.transparent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                valueColor:
                                    AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            )
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  'Continue',
                                  style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w600,
                                    color: _isEmailValid
                                        ? Colors.white
                                        : iOSDesignSystem.textSecondary,
                                  ),
                                ),
                                if (_isEmailValid) ...[
                                  const SizedBox(width: 8),
                                  const Icon(
                                    Icons.arrow_forward,
                                    size: 20,
                                    color: Colors.white,
                                  ),
                                ],
                              ],
                            ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Already have account
                  Center(
                    child: TextButton(
                      onPressed: () {
                        Navigator.of(context).pushReplacementNamed('/signin');
                      },
                      child: RichText(
                        text: TextSpan(
                          style: TextStyle(
                            fontSize: 15,
                            color: iOSDesignSystem.textSecondary,
                          ),
                          children: const [
                            TextSpan(text: 'Already have an account? '),
                            TextSpan(
                              text: 'Sign in',
                              style: TextStyle(
                                color: iOSDesignSystem.accentBlue,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 32),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
