import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Settings UI Components - Liquid Glass + iOS-style Colorful Icons
///
/// Provides premium settings components inspired by iOS/Telegram:
/// - Colorful icon badges (rounded square with colored background)
/// - Glass section cards with blur
/// - Animated settings rows with haptic feedback
/// - NEW badge capsule

// ═══════════════════════════════════════════════════════════════════════════
// COLOR PALETTE
// ═══════════════════════════════════════════════════════════════════════════

/// iOS-style vibrant colors for settings icons
class SettingsColors {
  static const red = Color(0xFFFF3B30);
  static const orange = Color(0xFFFF9500);
  static const yellow = Color(0xFFFFCC00);
  static const green = Color(0xFF34C759);
  static const teal = Color(0xFF5AC8FA);
  static const blue = Color(0xFF007AFF);
  static const indigo = Color(0xFF5856D6);
  static const purple = Color(0xFFAF52DE);
  static const pink = Color(0xFFFF2D55);
  static const gray = Color(0xFF8E8E93);
}

// ═══════════════════════════════════════════════════════════════════════════
// SETTINGS ICON BADGE
// ═══════════════════════════════════════════════════════════════════════════

/// Colorful rounded-square icon badge (iOS/Telegram style)
class SettingsIconBadge extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  final double iconSize;
  final double borderRadius;

  const SettingsIconBadge({
    super.key,
    required this.icon,
    required this.color,
    this.size = 34,
    this.iconSize = 20,
    this.borderRadius = 8,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.3),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Icon(
        icon,
        color: Colors.white,
        size: iconSize,
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// NEW BADGE
// ═══════════════════════════════════════════════════════════════════════════

/// Glass capsule badge for new features
class NewBadge extends StatelessWidget {
  final String text;
  final Color color;

  const NewBadge({
    super.key,
    this.text = 'NEW',
    this.color = const Color(0xFF007AFF),
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: color.withOpacity(0.2),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: color.withOpacity(0.4),
              width: 0.5,
            ),
          ),
          child: Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SETTINGS SECTION CARD
// ═══════════════════════════════════════════════════════════════════════════

/// Glass capsule card container for settings sections
class SettingsSectionCard extends StatelessWidget {
  final String? title;
  final List<Widget> children;
  final double borderRadius;
  final double blur;

  const SettingsSectionCard({
    super.key,
    this.title,
    required this.children,
    this.borderRadius = 22,
    this.blur = 22,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 10),
            child: Text(
              title!,
              style: TextStyle(
                color: Colors.white.withOpacity(0.6),
                fontSize: 14,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1C1C1E).withOpacity(0.42),
                borderRadius: BorderRadius.circular(borderRadius),
                border: Border.all(
                  color: Colors.white.withOpacity(0.10),
                  width: 0.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.20),
                    blurRadius: 18,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                children: children.asMap().entries.map((entry) {
                  return Column(
                    children: [
                      entry.value,
                      if (entry.key < children.length - 1)
                        Padding(
                          padding: const EdgeInsets.only(left: 62),
                          child: Divider(
                            height: 0.5,
                            thickness: 0.5,
                            color: Colors.white.withOpacity(0.06),
                          ),
                        ),
                    ],
                  );
                }).toList(),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SETTINGS ROW
// ═══════════════════════════════════════════════════════════════════════════

/// Settings row with colorful icon, title, optional subtitle, and chevron
class SettingsRow extends StatefulWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String? subtitle;
  final Widget? badge;
  final VoidCallback? onTap;
  final bool showChevron;

  const SettingsRow({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.title,
    this.subtitle,
    this.badge,
    this.onTap,
    this.showChevron = true,
  });

  @override
  State<SettingsRow> createState() => _SettingsRowState();
}

class _SettingsRowState extends State<SettingsRow> {
  bool _isPressed = false;

  void _handleTapDown(TapDownDetails details) {
    HapticFeedback.lightImpact();
    setState(() => _isPressed = true);
  }

  void _handleTapUp(TapUpDetails details) {
    setState(() => _isPressed = false);
    widget.onTap?.call();
  }

  void _handleTapCancel() {
    setState(() => _isPressed = false);
  }

  @override
  Widget build(BuildContext context) {
    final hasSubtitle = widget.subtitle != null;

    return GestureDetector(
      onTapDown: widget.onTap != null ? _handleTapDown : null,
      onTapUp: widget.onTap != null ? _handleTapUp : null,
      onTapCancel: widget.onTap != null ? _handleTapCancel : null,
      child: AnimatedScale(
        scale: _isPressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOutCubic,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: _isPressed
                ? Colors.white.withOpacity(0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              // Colorful icon badge
              SettingsIconBadge(
                icon: widget.icon,
                color: widget.iconColor,
              ),
              const SizedBox(width: 14),
              
              // Title + subtitle
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (hasSubtitle)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          widget.subtitle!,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.5),
                            fontSize: 13,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
              
              // Optional badge
              if (widget.badge != null) ...[
                widget.badge!,
                const SizedBox(width: 8),
              ],
              
              // Chevron
              if (widget.showChevron)
                Icon(
                  CupertinoIcons.chevron_right,
                  size: 18,
                  color: Colors.white.withOpacity(0.3),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SETTINGS TOGGLE ROW
// ═══════════════════════════════════════════════════════════════════════════

/// Settings row with toggle switch instead of chevron
class SettingsToggleRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const SettingsToggleRow({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final hasSubtitle = subtitle != null;

    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onChanged(!value);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            // Colorful icon badge
            SettingsIconBadge(
              icon: icon,
              color: iconColor,
            ),
            const SizedBox(width: 14),
            
            // Title + subtitle
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (hasSubtitle)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle!,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.5),
                          fontSize: 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
            
            // iOS-style Toggle
            Transform.scale(
              scale: 0.85,
              child: CupertinoSwitch(
                value: value,
                onChanged: (val) {
                  HapticFeedback.lightImpact();
                  onChanged(val);
                },
                activeColor: const Color(0xFF34C759),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// COLLAPSIBLE PROFILE HEADER
// ═══════════════════════════════════════════════════════════════════════════

/// Animated profile header that collapses on scroll
class CollapsibleProfileHeader extends StatelessWidget {
  final double t; // 0 = collapsed, 1 = expanded
  final String? avatarUrl;
  final String name;
  final String? subtitle;
  final VoidCallback? onTap;

  const CollapsibleProfileHeader({
    super.key,
    required this.t,
    this.avatarUrl,
    required this.name,
    this.subtitle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final statusBarHeight = MediaQuery.of(context).padding.top;

    // Interpolate values based on t
    final avatarSize = lerpDouble(34, 70, t)!;
    final left = lerpDouble(14, screenWidth / 2 - 35, t)!;
    final top = lerpDouble(statusBarHeight + 8, 60, t)!;
    final fontSize = lerpDouble(16, 22, t)!;

    return GestureDetector(
      onTap: onTap,
      child: Stack(
        children: [
          // Glass background
          Positioned.fill(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(20),
              ),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.white.withOpacity(0.12),
                        Colors.white.withOpacity(0.06),
                      ],
                    ),
                    border: const Border(
                      bottom: BorderSide(
                        color: Color(0x1AFFFFFF),
                        width: 0.5,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Avatar + Name
          Positioned(
            left: left,
            top: top,
            child: Row(
              children: [
                // Avatar
                Container(
                  width: avatarSize,
                  height: avatarSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        const Color(0xFF0A84FF).withOpacity(0.3),
                        const Color(0xFF5E5CE6).withOpacity(0.2),
                      ],
                    ),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.2),
                      width: 2,
                    ),
                  ),
                  child: ClipOval(
                    child: avatarUrl != null
                        ? Image.network(
                            avatarUrl!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => _buildInitial(),
                          )
                        : _buildInitial(),
                  ),
                ),
                const SizedBox(width: 12),
                
                // Name + subtitle
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: fontSize,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (subtitle != null && t > 0.4)
                      Opacity(
                        opacity: ((t - 0.4) / 0.6).clamp(0.0, 1.0),
                        child: Text(
                          subtitle!,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.6),
                            fontSize: 13,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInitial() {
    return Center(
      child: Text(
        name.isNotEmpty ? name[0].toUpperCase() : '?',
        style: TextStyle(
          fontSize: lerpDouble(14, 28, t),
          fontWeight: FontWeight.bold,
          color: const Color(0xFF0A84FF),
        ),
      ),
    );
  }
}
