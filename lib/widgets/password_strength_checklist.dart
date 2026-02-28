import 'package:flutter/material.dart';
import '../utils/password_validator.dart';
import '../theme/ios_design_system.dart';

/// TikTok-style password strength checklist widget
/// Shows checkmarks for each password criterion as they are met
class PasswordStrengthChecklist extends StatelessWidget {
  final String password;
  final String? username;
  final bool showUsernameCheck;
  final bool showCommonPasswordCheck;

  const PasswordStrengthChecklist({
    super.key,
    required this.password,
    this.username,
    this.showUsernameCheck = false,
    this.showCommonPasswordCheck = false,
  });

  @override
  Widget build(BuildContext context) {
    final result = PasswordValidator.validate(
      password,
      username: username,
      checkCommonPasswords: showCommonPasswordCheck,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ChecklistItem(
          label: '10+ characters',
          isValid: result.hasMinLength,
          isEmpty: password.isEmpty,
        ),
        const SizedBox(height: 6),
        _ChecklistItem(
          label: 'Uppercase letter (A-Z)',
          isValid: result.hasUppercase,
          isEmpty: password.isEmpty,
        ),
        const SizedBox(height: 6),
        _ChecklistItem(
          label: 'Lowercase letter (a-z)',
          isValid: result.hasLowercase,
          isEmpty: password.isEmpty,
        ),
        const SizedBox(height: 6),
        _ChecklistItem(
          label: 'Number (0-9)',
          isValid: result.hasNumber,
          isEmpty: password.isEmpty,
        ),
        const SizedBox(height: 6),
        _ChecklistItem(
          label: 'Special character (!@#\$%...)',
          isValid: result.hasSpecialChar,
          isEmpty: password.isEmpty,
        ),
        if (showUsernameCheck && username != null && username!.isNotEmpty) ...[
          const SizedBox(height: 6),
          _ChecklistItem(
            label: 'Does not contain username',
            isValid: result.doesNotContainUsername,
            isEmpty: password.isEmpty,
          ),
        ],
        if (showCommonPasswordCheck && password.isNotEmpty && !result.isNotCommonPassword) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 16,
                color: Colors.orange.shade400,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'This password is too common',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.orange.shade400,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _ChecklistItem extends StatelessWidget {
  final String label;
  final bool isValid;
  final bool isEmpty;

  const _ChecklistItem({
    required this.label,
    required this.isValid,
    required this.isEmpty,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      child: Row(
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (child, animation) {
              return ScaleTransition(scale: animation, child: child);
            },
            child: isEmpty
                ? Icon(
                    Icons.circle_outlined,
                    key: const ValueKey('empty'),
                    size: 18,
                    color: iOSDesignSystem.textSecondary.withOpacity(0.5),
                  )
                : isValid
                    ? const Icon(
                        Icons.check_circle,
                        key: ValueKey('valid'),
                        size: 18,
                        color: Color(0xFF34C759), // iOS green
                      )
                    : Icon(
                        Icons.cancel,
                        key: const ValueKey('invalid'),
                        size: 18,
                        color: Colors.red.shade400,
                      ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 200),
              style: TextStyle(
                fontSize: 13,
                color: isEmpty
                    ? iOSDesignSystem.textSecondary.withOpacity(0.7)
                    : isValid
                        ? const Color(0xFF34C759)
                        : Colors.red.shade400,
                fontWeight: isValid ? FontWeight.w500 : FontWeight.normal,
              ),
              child: Text(label),
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact password strength indicator (progress bar style)
class PasswordStrengthBar extends StatelessWidget {
  final String password;
  final String? username;

  const PasswordStrengthBar({
    super.key,
    required this.password,
    this.username,
  });

  @override
  Widget build(BuildContext context) {
    final result = PasswordValidator.validate(password, username: username);
    final strength = result.strengthPercentage;
    
    Color barColor;
    String strengthLabel;
    
    if (password.isEmpty) {
      barColor = iOSDesignSystem.textSecondary.withOpacity(0.3);
      strengthLabel = '';
    } else if (strength < 0.4) {
      barColor = Colors.red.shade400;
      strengthLabel = 'Weak';
    } else if (strength < 0.8) {
      barColor = Colors.orange.shade400;
      strengthLabel = 'Medium';
    } else if (!result.isValid) {
      barColor = Colors.orange.shade400;
      strengthLabel = 'Almost there';
    } else {
      barColor = const Color(0xFF34C759);
      strengthLabel = 'Strong';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            height: 4,
            child: Stack(
              children: [
                // Background
                Container(
                  width: double.infinity,
                  color: iOSDesignSystem.textSecondary.withOpacity(0.2),
                ),
                // Progress
                FractionallySizedBox(
                  widthFactor: password.isEmpty ? 0 : strength,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    color: barColor,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (strengthLabel.isNotEmpty) ...[
          const SizedBox(height: 6),
          AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 200),
            style: TextStyle(
              fontSize: 12,
              color: barColor,
              fontWeight: FontWeight.w500,
            ),
            child: Text(strengthLabel),
          ),
        ],
      ],
    );
  }
}
