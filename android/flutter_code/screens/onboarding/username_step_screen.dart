import 'package:flutter/material.dart';
import 'dart:async';
import '../../theme/ios_design_system.dart';
import '../../services/api_service.dart';
import 'password_step_screen.dart';

/// Step 3: Username Selection Screen
/// Beautiful animated username input with real-time availability check
class UsernameStepScreen extends StatefulWidget {
  final String email;

  const UsernameStepScreen({super.key, required this.email});

  @override
  State<UsernameStepScreen> createState() => _UsernameStepScreenState();
}

class _UsernameStepScreenState extends State<UsernameStepScreen>
    with SingleTickerProviderStateMixin {
  final _usernameController = TextEditingController();
  final _focusNode = FocusNode();

  bool _isLoading = false;
  bool _isChecking = false;
  bool? _isAvailable;
  String? _errorMessage;
  String? _suggestion;
  Timer? _debounceTimer;

  late AnimationController _animController;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;

  // Username validation regex
  final _usernameRegex = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{2,19}$');

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _fadeAnim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOut),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _animController, curve: Curves.easeOut));

    _animController.forward();

    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _focusNode.dispose();
    _animController.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  String? _validateUsername(String username) {
    if (username.isEmpty) return null;
    if (username.length < 3 || username.length > 20) {
      return 'Use 3–20 characters, letters/numbers/underscore.';
    }
    if (!RegExp(r'^[a-zA-Z]').hasMatch(username)) {
      return 'Use 3–20 characters, letters/numbers/underscore.';
    }
    if (!_usernameRegex.hasMatch(username)) {
      return 'Use 3–20 characters, letters/numbers/underscore.';
    }
    return null;
  }

  void _onUsernameChanged(String value) {
    setState(() {
      _isAvailable = null;
      _suggestion = null;
      _errorMessage = _validateUsername(value);
    });

    _debounceTimer?.cancel();

    if (value.length >= 3 && _errorMessage == null) {
      _debounceTimer = Timer(const Duration(milliseconds: 500), () {
        _checkAvailability(value);
      });
    }
  }

  Future<void> _checkAvailability(String username) async {
    setState(() => _isChecking = true);

    try {
      final result = await ApiService.checkUsername(username: username);
      
      if (mounted && _usernameController.text == username) {
        setState(() {
          _isAvailable = result['available'] == true;
          _suggestion = result['suggestion'] as String?;
          _isChecking = false;
        });
      }
    } catch (e) {
      // Silently fail - user can still try to submit
      setState(() => _isChecking = false);
    }
  }

  Future<void> _continue() async {
    final username = _usernameController.text.trim().toLowerCase();
    final validationError = _validateUsername(username);

    if (validationError != null) {
      setState(() => _errorMessage = validationError);
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Final availability check
      final result = await ApiService.checkUsername(username: username);

      if (result['available'] != true) {
        setState(() {
          _isAvailable = false;
          _suggestion = result['suggestion'] as String?;
          _isLoading = false;
        });
        return;
      }

      if (mounted) {
        Navigator.of(context).push(
          PageRouteBuilder(
            pageBuilder: (context, animation, secondaryAnimation) =>
                PasswordStepScreen(
              email: widget.email,
              username: username,
            ),
            transitionsBuilder:
                (context, animation, secondaryAnimation, child) {
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
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  void _useSuggestion() {
    if (_suggestion != null) {
      _usernameController.text = _suggestion!;
      _onUsernameChanged(_suggestion!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final username = _usernameController.text.trim();
    final canContinue = username.length >= 3 &&
        _errorMessage == null &&
        _isAvailable == true &&
        !_isLoading;

    return Scaffold(
      backgroundColor: iOSDesignSystem.background,
      body: SafeArea(
        child: Stack(
          children: [
            // Background orbs
            Positioned(
              top: -100,
              right: -50,
              child: Container(
                width: 280,
                height: 280,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      const Color(0xFFFF9500).withOpacity(0.12),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: -80,
              left: -100,
              child: Container(
                width: 300,
                height: 300,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      iOSDesignSystem.accentPurple.withOpacity(0.08),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),

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
                              color:
                                  const Color(0xFFFF9500).withOpacity(0.15),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Text(
                              'Step 3 of 4',
                              style: TextStyle(
                                color: Color(0xFFFF9500),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),

                          const SizedBox(height: 24),

                          const Text(
                            'Choose your\nusername',
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
                            'This is how others will find and mention you.',
                            style: TextStyle(
                              fontSize: 16,
                              color: iOSDesignSystem.textSecondary,
                              height: 1.4,
                            ),
                          ),

                          const SizedBox(height: 40),

                          // Username input
                          Container(
                            decoration: BoxDecoration(
                              color: iOSDesignSystem.surfaceCard,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: _isAvailable == true
                                    ? const Color(0xFF34C759)
                                    : _isAvailable == false
                                        ? Colors.redAccent
                                        : _focusNode.hasFocus
                                            ? iOSDesignSystem.accentBlue
                                            : Colors.white.withOpacity(0.1),
                                width: 1.5,
                              ),
                              boxShadow: [
                                if (_isAvailable == true)
                                  BoxShadow(
                                    color: const Color(0xFF34C759)
                                        .withOpacity(0.15),
                                    blurRadius: 20,
                                    spreadRadius: 0,
                                  ),
                              ],
                            ),
                            child: TextField(
                              controller: _usernameController,
                              focusNode: _focusNode,
                              autocorrect: false,
                              textInputAction: TextInputAction.done,
                              onSubmitted: (_) => _continue(),
                              onChanged: _onUsernameChanged,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w500,
                              ),
                              decoration: InputDecoration(
                                hintText: 'username',
                                hintStyle: TextStyle(
                                  color: iOSDesignSystem.textSecondary
                                      .withOpacity(0.5),
                                  fontSize: 18,
                                ),
                                prefixIcon: Icon(
                                  Icons.alternate_email,
                                  color: _isAvailable == true
                                      ? const Color(0xFF34C759)
                                      : iOSDesignSystem.textSecondary,
                                ),
                                suffixIcon: _isChecking
                                    ? const Padding(
                                        padding: EdgeInsets.all(14),
                                        child: SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            valueColor:
                                                AlwaysStoppedAnimation<Color>(
                                              iOSDesignSystem.accentBlue,
                                            ),
                                          ),
                                        ),
                                      )
                                    : _isAvailable == true
                                        ? const Icon(
                                            Icons.check_circle,
                                            color: Color(0xFF34C759),
                                          )
                                        : _isAvailable == false
                                            ? const Icon(
                                                Icons.cancel,
                                                color: Colors.redAccent,
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

                          // Status messages
                          const SizedBox(height: 12),

                          if (_errorMessage != null)
                            _buildStatusMessage(
                              _errorMessage!,
                              Colors.redAccent,
                              Icons.info_outline,
                            )
                          else if (_isAvailable == false)
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildStatusMessage(
                                  'Username is taken. Try another.',
                                  Colors.redAccent,
                                  Icons.close,
                                ),
                                if (_suggestion != null) ...[
                                  const SizedBox(height: 8),
                                  GestureDetector(
                                    onTap: _useSuggestion,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 8,
                                      ),
                                      decoration: BoxDecoration(
                                        color: iOSDesignSystem.accentBlue
                                            .withOpacity(0.1),
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(
                                          color: iOSDesignSystem.accentBlue
                                              .withOpacity(0.3),
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            'Try: ',
                                            style: TextStyle(
                                              color:
                                                  iOSDesignSystem.textSecondary,
                                              fontSize: 14,
                                            ),
                                          ),
                                          Text(
                                            '@$_suggestion',
                                            style: const TextStyle(
                                              color: iOSDesignSystem.accentBlue,
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          const Icon(
                                            Icons.arrow_forward,
                                            size: 14,
                                            color: iOSDesignSystem.accentBlue,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            )
                          else if (_isAvailable == true)
                            _buildStatusMessage(
                              'Username is available!',
                              const Color(0xFF34C759),
                              Icons.check_circle_outline,
                            )
                          else
                            Row(
                              children: [
                                Icon(
                                  Icons.info_outline,
                                  size: 14,
                                  color: iOSDesignSystem.textSecondary,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  'Letters, numbers, underscores. 3-20 chars.',
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
                      gradient: canContinue
                          ? const LinearGradient(
                              colors: [
                                Color(0xFFFF9500),
                                Color(0xFFFF6B00),
                              ],
                            )
                          : null,
                      color: canContinue ? null : iOSDesignSystem.surfaceCard,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: canContinue
                          ? [
                              BoxShadow(
                                color:
                                    const Color(0xFFFF9500).withOpacity(0.4),
                                blurRadius: 20,
                                offset: const Offset(0, 8),
                              ),
                            ]
                          : null,
                    ),
                    child: ElevatedButton(
                      onPressed: canContinue ? _continue : null,
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
                                    color: canContinue
                                        ? Colors.white
                                        : iOSDesignSystem.textSecondary,
                                  ),
                                ),
                                if (canContinue) ...[
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

                  const SizedBox(height: 40),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusMessage(String text, Color color, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Text(
          text,
          style: TextStyle(
            fontSize: 14,
            color: color,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
