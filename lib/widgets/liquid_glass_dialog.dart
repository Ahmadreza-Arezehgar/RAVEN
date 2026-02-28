import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/ios_design_system.dart';

/// Liquid Glass Dialog - Modern iOS 26 style dialog
/// Features:
/// - Backdrop blur (saturation + blur)
/// - Translucent glass background
/// - Soft white border
/// - Capsule-shaped buttons
/// - Smooth fade + scale animation
class LiquidGlassDialog extends StatelessWidget {
  final String title;
  final String? message;
  final Widget? content; // Custom content instead of message
  final List<LiquidGlassAction> actions;
  final IconData? icon;
  final Color? iconColor;

  const LiquidGlassDialog({
    super.key,
    required this.title,
    this.message,
    this.content,
    required this.actions,
    this.icon,
    this.iconColor,
  });

  /// Show the dialog with animation
  static Future<T?> show<T>({
    required BuildContext context,
    required String title,
    String? message,
    Widget? content,
    required List<LiquidGlassAction> actions,
    IconData? icon,
    Color? iconColor,
    bool barrierDismissible = true,
  }) {
    HapticFeedback.mediumImpact();
    
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      barrierLabel: 'Dismiss',
      barrierColor: Colors.black.withOpacity(0.5),
      transitionDuration: const Duration(milliseconds: 300),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curvedAnimation = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        
        return FadeTransition(
          opacity: curvedAnimation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.85, end: 1.0).animate(curvedAnimation),
            child: child,
          ),
        );
      },
      pageBuilder: (context, animation, secondaryAnimation) {
        return LiquidGlassDialog(
          title: title,
          message: message,
          content: content,
          actions: actions,
          icon: icon,
          iconColor: iconColor,
        );
      },
    );
  }

  /// Convenience method for confirmation dialogs (Cancel/Confirm)
  static Future<bool> confirm({
    required BuildContext context,
    required String title,
    required String message,
    String cancelText = 'Cancel',
    String confirmText = 'Confirm',
    bool isDestructive = false,
  }) async {
    final result = await show<bool>(
      context: context,
      title: title,
      message: message,
      actions: [
        LiquidGlassAction(
          label: cancelText,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        LiquidGlassAction(
          label: confirmText,
          isDestructive: isDestructive,
          isPrimary: !isDestructive,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    return result ?? false;
  }

  /// Convenience method for action sheet style dialogs
  static Future<int?> actionSheet({
    required BuildContext context,
    required String title,
    String? message,
    required List<String> options,
    int? destructiveIndex,
  }) async {
    return show<int>(
      context: context,
      title: title,
      message: message,
      actions: options.asMap().entries.map((entry) {
        return LiquidGlassAction(
          label: entry.value,
          isDestructive: entry.key == destructiveIndex,
          onPressed: () => Navigator.of(context).pop(entry.key),
        );
      }).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 340),
              decoration: BoxDecoration(
                // Glass background
                color: iOSDesignSystem.surfaceElevated.withOpacity(0.85),
                borderRadius: BorderRadius.circular(24),
                // Soft border
                border: Border.all(
                  color: Colors.white.withOpacity(0.15),
                  width: 1,
                ),
                // Subtle shadow
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: 40,
                    spreadRadius: 0,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Header
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 28, 24, 0),
                    child: Column(
                      children: [
                        // Icon (optional)
                        if (icon != null) ...[
                          Container(
                            width: 56,
                            height: 56,
                            decoration: BoxDecoration(
                              color: (iconColor ?? iOSDesignSystem.accentBlue).withOpacity(0.15),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              icon,
                              size: 28,
                              color: iconColor ?? iOSDesignSystem.accentBlue,
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                        
                        // Title
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                            letterSpacing: -0.4,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        
                        // Message
                        if (message != null) ...[
                          const SizedBox(height: 10),
                          Text(
                            message!,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w400,
                              color: Colors.white.withOpacity(0.65),
                              height: 1.4,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                        
                        // Custom content
                        if (content != null) ...[
                          const SizedBox(height: 16),
                          content!,
                        ],
                      ],
                    ),
                  ),
                  
                  const SizedBox(height: 24),
                  
                  // Actions
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    child: _buildActions(context),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActions(BuildContext context) {
    if (actions.length == 2) {
      // Two buttons side by side
      return Row(
        children: [
          Expanded(child: _buildActionButton(actions[0])),
          const SizedBox(width: 12),
          Expanded(child: _buildActionButton(actions[1])),
        ],
      );
    } else {
      // Vertical stack for more actions
      return Column(
        children: actions.map((action) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SizedBox(
              width: double.infinity,
              child: _buildActionButton(action),
            ),
          );
        }).toList(),
      );
    }
  }

  Widget _buildActionButton(LiquidGlassAction action) {
    Color backgroundColor;
    Color textColor;
    
    if (action.isDestructive) {
      // Red tinted glass for destructive actions
      backgroundColor = const Color(0xFFFF453A).withOpacity(0.2);
      textColor = const Color(0xFFFF453A);
    } else if (action.isPrimary) {
      // Blue for primary action
      backgroundColor = iOSDesignSystem.accentBlue.withOpacity(0.2);
      textColor = iOSDesignSystem.accentBlue;
    } else {
      // Gray glass for cancel/secondary
      backgroundColor = Colors.white.withOpacity(0.1);
      textColor = Colors.white.withOpacity(0.85);
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          action.onPressed();
        },
        borderRadius: BorderRadius.circular(14),
        child: Container(
          height: 50,
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Colors.white.withOpacity(0.08),
              width: 1,
            ),
          ),
          child: Center(
            child: Text(
              action.label,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: textColor,
                letterSpacing: -0.2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Action button for LiquidGlassDialog
class LiquidGlassAction {
  final String label;
  final VoidCallback onPressed;
  final bool isDestructive;
  final bool isPrimary;

  const LiquidGlassAction({
    required this.label,
    required this.onPressed,
    this.isDestructive = false,
    this.isPrimary = false,
  });
}

// ═══════════════════════════════════════════════════════════════════════════════
// LiquidGlassActionSheet - For picker-style dialogs (Image Source, etc.)
// ═══════════════════════════════════════════════════════════════════════════════

class LiquidGlassActionSheet extends StatelessWidget {
  final String title;
  final List<LiquidGlassSheetOption> options;

  const LiquidGlassActionSheet({
    super.key,
    required this.title,
    required this.options,
  });

  static Future<T?> show<T>({
    required BuildContext context,
    required String title,
    required List<LiquidGlassSheetOption> options,
  }) {
    HapticFeedback.mediumImpact();
    
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.5),
      isScrollControlled: true,
      builder: (context) => LiquidGlassActionSheet(
        title: title,
        options: options,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 12,
        right: 12,
        bottom: MediaQuery.of(context).padding.bottom + 12,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: Container(
            decoration: BoxDecoration(
              color: iOSDesignSystem.surfaceElevated.withOpacity(0.9),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.white.withOpacity(0.12),
                width: 1,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Handle bar
                Container(
                  margin: const EdgeInsets.only(top: 10),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                
                // Title
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                      letterSpacing: -0.3,
                    ),
                  ),
                ),
                
                // Divider
                Container(
                  height: 1,
                  color: Colors.white.withOpacity(0.08),
                ),
                
                // Options
                ...options.map((option) => _buildOption(context, option)),
                
                const SizedBox(height: 8),
                
                // Cancel button
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        Navigator.of(context).pop();
                      },
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        height: 50,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Center(
                          child: Text(
                            'Cancel',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Colors.white.withOpacity(0.8),
                            ),
                          ),
                        ),
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

  Widget _buildOption(BuildContext context, LiquidGlassSheetOption option) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          Navigator.of(context).pop();
          option.onTap();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: Colors.white.withOpacity(0.06),
                width: 1,
              ),
            ),
          ),
          child: Row(
            children: [
              // Icon
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: (option.iconColor ?? iOSDesignSystem.accentBlue).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  option.icon,
                  size: 20,
                  color: option.iconColor ?? iOSDesignSystem.accentBlue,
                ),
              ),
              
              const SizedBox(width: 14),
              
              // Label
              Expanded(
                child: Text(
                  option.label,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: Colors.white,
                  ),
                ),
              ),
              
              // Chevron
              Icon(
                Icons.chevron_right,
                size: 20,
                color: Colors.white.withOpacity(0.3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Option for LiquidGlassActionSheet
class LiquidGlassSheetOption {
  final String label;
  final IconData icon;
  final Color? iconColor;
  final VoidCallback onTap;

  const LiquidGlassSheetOption({
    required this.label,
    required this.icon,
    this.iconColor,
    required this.onTap,
  });
}
