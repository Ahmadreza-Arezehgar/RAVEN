import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/biometric_service.dart';

/// App Lock Screen - Full-screen lock overlay with Face ID
class AppLockScreen extends StatefulWidget {
  final Widget child;
  final VoidCallback? onUnlocked;

  const AppLockScreen({
    super.key,
    required this.child,
    this.onUnlocked,
  });

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> with WidgetsBindingObserver {
  final BiometricService _biometric = BiometricService();
  bool _isLocked = false;
  bool _isAuthenticating = false;
  String _passcodeInput = '';
  bool _passcodeError = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkLockState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkLockState();
    } else if (state == AppLifecycleState.paused) {
      _onAppPaused();
    }
  }

  Future<void> _checkLockState() async {
    final shouldLock = await _biometric.shouldShowLock();
    if (shouldLock && mounted) {
      setState(() => _isLocked = true);
      _attemptBiometricUnlock();
    }
  }

  void _onAppPaused() {
    // App is going to background
  }

  Future<void> _attemptBiometricUnlock() async {
    final biometricEnabled = await _biometric.isBiometricEnabled();
    if (!biometricEnabled) return;

    setState(() => _isAuthenticating = true);

    final success = await _biometric.authenticate(
      reason: 'Unlock RAVEN',
    );

    if (mounted) {
      setState(() => _isAuthenticating = false);
      
      if (success) {
        _unlock();
      }
    }
  }

  Future<void> _verifyPasscode() async {
    if (_passcodeInput.length < 4) return;

    final valid = await _biometric.verifyPasscode(_passcodeInput);
    
    if (valid) {
      _unlock();
    } else {
      HapticFeedback.notificationError();
      setState(() {
        _passcodeError = true;
        _passcodeInput = '';
      });
      
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) {
        setState(() => _passcodeError = false);
      }
    }
  }

  void _unlock() {
    HapticFeedback.mediumImpact();
    _biometric.recordUnlock();
    setState(() {
      _isLocked = false;
      _passcodeInput = '';
    });
    widget.onUnlocked?.call();
  }

  void _onPasscodeDigit(String digit) {
    if (_passcodeInput.length >= 6) return;
    
    HapticFeedback.selectionClick();
    setState(() => _passcodeInput += digit);
    
    if (_passcodeInput.length >= 4) {
      _verifyPasscode();
    }
  }

  void _onPasscodeDelete() {
    if (_passcodeInput.isEmpty) return;
    
    HapticFeedback.selectionClick();
    setState(() {
      _passcodeInput = _passcodeInput.substring(0, _passcodeInput.length - 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        
        if (_isLocked)
          _buildLockOverlay(context),
      ],
    );
  }

  Widget _buildLockOverlay(BuildContext context) {
    final safeTop = MediaQuery.of(context).padding.top;
    final safeBottom = MediaQuery.of(context).padding.bottom;

    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
      child: Container(
        color: Colors.black.withOpacity(0.85),
        child: SafeArea(
          child: Column(
            children: [
              SizedBox(height: safeTop + 60),
              
              // App Logo / Icon
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFF0A84FF),
                      const Color(0xFF0A84FF).withOpacity(0.6),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF0A84FF).withOpacity(0.3),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.lock_outline,
                  color: Colors.white,
                  size: 40,
                ),
              ),
              
              const SizedBox(height: 32),
              
              // Title
              const Text(
                'RAVEN is Locked',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              
              const SizedBox(height: 8),
              
              Text(
                _isAuthenticating 
                    ? 'Authenticating...'
                    : 'Enter passcode or use Face ID',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.6),
                  fontSize: 15,
                ),
              ),
              
              const SizedBox(height: 48),
              
              // Passcode dots
              _buildPasscodeDots(),
              
              const Spacer(),
              
              // Numpad
              _buildNumpad(),
              
              const SizedBox(height: 24),
              
              // Face ID button
              _buildFaceIdButton(),
              
              SizedBox(height: safeBottom + 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPasscodeDots() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(6, (index) {
        final filled = index < _passcodeInput.length;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.symmetric(horizontal: 8),
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _passcodeError
                ? const Color(0xFFFF453A)
                : (filled 
                    ? const Color(0xFF0A84FF) 
                    : Colors.white.withOpacity(0.3)),
            boxShadow: filled && !_passcodeError
                ? [
                    BoxShadow(
                      color: const Color(0xFF0A84FF).withOpacity(0.4),
                      blurRadius: 8,
                    ),
                  ]
                : null,
          ),
        );
      }),
    );
  }

  Widget _buildNumpad() {
    final digits = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['', '0', '⌫'],
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 48),
      child: Column(
        children: digits.map((row) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: row.map((digit) {
                if (digit.isEmpty) {
                  return const SizedBox(width: 72, height: 72);
                }
                
                return _NumpadButton(
                  digit: digit,
                  onTap: digit == '⌫' 
                      ? _onPasscodeDelete 
                      : () => _onPasscodeDigit(digit),
                );
              }).toList(),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildFaceIdButton() {
    return GestureDetector(
      onTap: _attemptBiometricUnlock,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.1),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: Colors.white.withOpacity(0.2),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.face,
              color: Colors.white.withOpacity(0.8),
              size: 24,
            ),
            const SizedBox(width: 8),
            Text(
              'Use Face ID',
              style: TextStyle(
                color: Colors.white.withOpacity(0.8),
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// NUMPAD BUTTON
// ══════════════════════════════════════════════════════════════════════════
class _NumpadButton extends StatelessWidget {
  final String digit;
  final VoidCallback onTap;

  const _NumpadButton({
    required this.digit,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withOpacity(0.08),
          border: Border.all(
            color: Colors.white.withOpacity(0.15),
            width: 1,
          ),
        ),
        child: Center(
          child: digit == '⌫'
              ? Icon(
                  Icons.backspace_outlined,
                  color: Colors.white.withOpacity(0.8),
                  size: 24,
                )
              : Text(
                  digit,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w300,
                  ),
                ),
        ),
      ),
    );
  }
}
