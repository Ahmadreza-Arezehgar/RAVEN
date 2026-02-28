import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../theme/ios_design_system.dart';
import '../../services/api_service.dart';
import '../../services/database_helper.dart';
import '../../models/user_model.dart';
import '../../main.dart';
import '../../utils/password_validator.dart';
import '../../widgets/password_strength_checklist.dart';

/// Step 4: Password & Personal Info Screen
/// Final step to complete registration
class PasswordStepScreen extends StatefulWidget {
  final String email;
  final String username;

  const PasswordStepScreen({
    super.key,
    required this.email,
    required this.username,
  });

  @override
  State<PasswordStepScreen> createState() => _PasswordStepScreenState();
}

class _PasswordStepScreenState extends State<PasswordStepScreen>
    with SingleTickerProviderStateMixin {
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _birthYearController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _isLoading = false;
  bool _isSuccess = false;
  String? _errorMessage;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;

  late AnimationController _animController;
  late Animation<double> _fadeAnim;

  PasswordValidationResult _passwordValidation = const PasswordValidationResult(
    hasMinLength: false,
    hasUppercase: false,
    hasLowercase: false,
    hasNumber: false,
    hasSpecialChar: false,
  );

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOut),
    );
    _animController.forward();
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _birthYearController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _animController.dispose();
    super.dispose();
  }

  bool get _isFormValid {
    return _firstNameController.text.trim().isNotEmpty &&
        _lastNameController.text.trim().isNotEmpty &&
        _birthYearController.text.trim().length == 4 &&
        _passwordValidation.isValid &&
        _passwordController.text == _confirmPasswordController.text &&
        _confirmPasswordController.text.isNotEmpty;
  }

  Future<void> _completeSignUp() async {
    if (!_isFormValid) return;

    final firstName = _firstNameController.text.trim();
    final lastName = _lastNameController.text.trim();
    final birthYear = int.tryParse(_birthYearController.text.trim());
    final password = _passwordController.text;

    if (birthYear == null || birthYear < 1900 || birthYear > DateTime.now().year) {
      setState(() => _errorMessage = 'Please enter a valid birth year');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final result = await ApiService.register(
        username: widget.username,
        password: password,
        firstName: firstName,
        lastName: lastName,
        birthYear: birthYear,
        email: widget.email,
        phone: null,
      );

      // Success!
      HapticFeedback.heavyImpact();
      setState(() => _isSuccess = true);

      if (mounted) {
        final userId = result['user_id'];

        // Create local user
        final user = User(
          id: userId,
          username: widget.username,
          email: widget.email,
          createdAt: DateTime.now(),
        );

        await DatabaseHelper.instance.insertUser(user);

        final model = context.read<AppModel>();
        await model.setCurrentUser(user);

        // Show success animation then navigate
        await Future.delayed(const Duration(milliseconds: 1200));

        if (mounted) {
          Navigator.of(context).pushNamedAndRemoveUntil('/home', (_) => false);
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
    return Scaffold(
      backgroundColor: iOSDesignSystem.background,
      body: SafeArea(
        child: Stack(
          children: [
            // Background orbs
            Positioned(
              top: -80,
              left: -100,
              child: Container(
                width: 280,
                height: 280,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      iOSDesignSystem.accentPurple.withOpacity(0.15),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: -100,
              right: -80,
              child: Container(
                width: 300,
                height: 300,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      const Color(0xFF34C759).withOpacity(0.1),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),

            // Success overlay
            if (_isSuccess)
              Container(
                color: iOSDesignSystem.background,
                child: Center(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: const Duration(milliseconds: 600),
                    curve: Curves.elasticOut,
                    builder: (context, value, child) {
                      return Transform.scale(
                        scale: value,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 100,
                              height: 100,
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [
                                    Color(0xFF34C759),
                                    Color(0xFF30D158),
                                  ],
                                ),
                                borderRadius: BorderRadius.circular(30),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFF34C759)
                                        .withOpacity(0.4),
                                    blurRadius: 30,
                                    offset: const Offset(0, 10),
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.check_rounded,
                                size: 50,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 24),
                            const Text(
                              'Welcome to RAVEN!',
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '@${widget.username}',
                              style: TextStyle(
                                fontSize: 18,
                                color: iOSDesignSystem.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),

            if (!_isSuccess)
              SingleChildScrollView(
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

                    const SizedBox(height: 32),

                    FadeTransition(
                      opacity: _fadeAnim,
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
                              color:
                                  iOSDesignSystem.accentPurple.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Text(
                              'Step 4 of 4 - Almost done!',
                              style: TextStyle(
                                color: iOSDesignSystem.accentPurple,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),

                          const SizedBox(height: 24),

                          const Text(
                            'Complete your\nprofile',
                            style: TextStyle(
                              fontSize: 36,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                              height: 1.1,
                              letterSpacing: -0.5,
                            ),
                          ),

                          const SizedBox(height: 12),

                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: iOSDesignSystem.surfaceCard,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  '@${widget.username}',
                                  style: const TextStyle(
                                    color: iOSDesignSystem.accentBlue,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Icon(
                                Icons.check_circle,
                                size: 16,
                                color: const Color(0xFF34C759),
                              ),
                            ],
                          ),

                          const SizedBox(height: 32),

                          // First Name
                          _buildTextField(
                            controller: _firstNameController,
                            label: 'First Name',
                            icon: Icons.person_outline,
                            textCapitalization: TextCapitalization.words,
                          ),

                          const SizedBox(height: 16),

                          // Last Name
                          _buildTextField(
                            controller: _lastNameController,
                            label: 'Last Name',
                            icon: Icons.person_outline,
                            textCapitalization: TextCapitalization.words,
                          ),

                          const SizedBox(height: 16),

                          // Birth Year
                          _buildTextField(
                            controller: _birthYearController,
                            label: 'Birth Year',
                            icon: Icons.cake_outlined,
                            keyboardType: TextInputType.number,
                            maxLength: 4,
                            hintText: 'e.g. 1995',
                          ),

                          const SizedBox(height: 24),

                          // Divider
                          Row(
                            children: [
                              Expanded(
                                child: Container(
                                  height: 1,
                                  color: Colors.white.withOpacity(0.1),
                                ),
                              ),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 16),
                                child: Text(
                                  'Create Password',
                                  style: TextStyle(
                                    color: iOSDesignSystem.textSecondary,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Container(
                                  height: 1,
                                  color: Colors.white.withOpacity(0.1),
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 24),

                          // Password
                          _buildTextField(
                            controller: _passwordController,
                            label: 'Password',
                            icon: Icons.lock_outline,
                            obscureText: _obscurePassword,
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscurePassword
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                                color: iOSDesignSystem.textSecondary,
                              ),
                              onPressed: () => setState(
                                  () => _obscurePassword = !_obscurePassword),
                            ),
                            onChanged: (value) {
                              setState(() {
                                _passwordValidation = PasswordValidator.validate(
                                  value,
                                  username: widget.username,
                                );
                              });
                            },
                          ),

                          const SizedBox(height: 12),

                          // Password strength checklist
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: PasswordStrengthChecklist(
                              password: _passwordController.text,
                              username: widget.username,
                              showUsernameCheck: true,
                            ),
                          ),

                          const SizedBox(height: 16),

                          // Confirm Password
                          _buildTextField(
                            controller: _confirmPasswordController,
                            label: 'Confirm Password',
                            icon: Icons.lock_outline,
                            obscureText: _obscureConfirm,
                            suffixIcon: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_confirmPasswordController.text.isNotEmpty)
                                  Icon(
                                    _passwordController.text ==
                                            _confirmPasswordController.text
                                        ? Icons.check_circle
                                        : Icons.cancel,
                                    color: _passwordController.text ==
                                            _confirmPasswordController.text
                                        ? const Color(0xFF34C759)
                                        : Colors.redAccent,
                                  ),
                                IconButton(
                                  icon: Icon(
                                    _obscureConfirm
                                        ? Icons.visibility_off
                                        : Icons.visibility,
                                    color: iOSDesignSystem.textSecondary,
                                  ),
                                  onPressed: () => setState(
                                      () => _obscureConfirm = !_obscureConfirm),
                                ),
                              ],
                            ),
                            onChanged: (_) => setState(() {}),
                          ),

                          // Error message
                          if (_errorMessage != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.red.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: Colors.red.withOpacity(0.3),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(
                                      Icons.error_outline,
                                      color: Colors.redAccent,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 10),
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
                            ),

                          const SizedBox(height: 32),

                          // Complete button
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            width: double.infinity,
                            height: 56,
                            decoration: BoxDecoration(
                              gradient: _isFormValid && !_isLoading
                                  ? const LinearGradient(
                                      colors: [
                                        Color(0xFF34C759),
                                        Color(0xFF30D158),
                                      ],
                                    )
                                  : null,
                              color: _isFormValid && !_isLoading
                                  ? null
                                  : iOSDesignSystem.surfaceCard,
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: _isFormValid && !_isLoading
                                  ? [
                                      BoxShadow(
                                        color: const Color(0xFF34C759)
                                            .withOpacity(0.4),
                                        blurRadius: 20,
                                        offset: const Offset(0, 8),
                                      ),
                                    ]
                                  : null,
                            ),
                            child: ElevatedButton(
                              onPressed: _isFormValid && !_isLoading
                                  ? _completeSignUp
                                  : null,
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
                                            AlwaysStoppedAnimation<Color>(
                                                Colors.white),
                                      ),
                                    )
                                  : Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          'Complete Sign Up',
                                          style: TextStyle(
                                            fontSize: 17,
                                            fontWeight: FontWeight.w600,
                                            color: _isFormValid
                                                ? Colors.white
                                                : iOSDesignSystem.textSecondary,
                                          ),
                                        ),
                                        if (_isFormValid) ...[
                                          const SizedBox(width: 8),
                                          const Icon(
                                            Icons.check,
                                            size: 20,
                                            color: Colors.white,
                                          ),
                                        ],
                                      ],
                                    ),
                            ),
                          ),

                          const SizedBox(height: 100),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool obscureText = false,
    TextInputType? keyboardType,
    int? maxLength,
    String? hintText,
    Widget? suffixIcon,
    TextCapitalization textCapitalization = TextCapitalization.none,
    void Function(String)? onChanged,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: iOSDesignSystem.surfaceCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Colors.white.withOpacity(0.1),
        ),
      ),
      child: TextField(
        controller: controller,
        obscureText: obscureText,
        keyboardType: keyboardType,
        maxLength: maxLength,
        textCapitalization: textCapitalization,
        onChanged: (value) {
          setState(() {});
          onChanged?.call(value);
        },
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
        ),
        decoration: InputDecoration(
          labelText: label,
          hintText: hintText,
          hintStyle: TextStyle(
            color: iOSDesignSystem.textSecondary.withOpacity(0.5),
          ),
          labelStyle: TextStyle(
            color: iOSDesignSystem.textSecondary,
          ),
          prefixIcon: Icon(
            icon,
            color: iOSDesignSystem.textSecondary,
          ),
          suffixIcon: suffixIcon,
          border: InputBorder.none,
          counterText: '',
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
        ),
      ),
    );
  }
}
