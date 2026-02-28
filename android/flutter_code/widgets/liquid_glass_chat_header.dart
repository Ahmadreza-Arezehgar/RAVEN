import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Three-part Liquid Glass Chat Header
/// Left: Back button | Center: Name + Last Seen | Right: Avatar
class LiquidGlassChatHeader extends StatefulWidget implements PreferredSizeWidget {
  final String fullName;
  final String lastSeenText;
  final String? avatarUrl;
  final bool isOnline;
  final VoidCallback onBack;
  final VoidCallback? onOpenProfile;
  final VoidCallback? onTapName;

  const LiquidGlassChatHeader({
    super.key,
    required this.fullName,
    required this.lastSeenText,
    this.avatarUrl,
    this.isOnline = false,
    required this.onBack,
    this.onOpenProfile,
    this.onTapName,
  });

  @override
  Size get preferredSize => const Size.fromHeight(72);

  @override
  State<LiquidGlassChatHeader> createState() => _LiquidGlassChatHeaderState();
}

class _LiquidGlassChatHeaderState extends State<LiquidGlassChatHeader>
    with SingleTickerProviderStateMixin {
  late AnimationController _entranceController;
  late Animation<double> _slideAnim;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );

    _slideAnim = Tween<double>(begin: -20, end: 0).animate(
      CurvedAnimation(parent: _entranceController, curve: Curves.easeOutCubic),
    );
    _fadeAnim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _entranceController, curve: Curves.easeOut),
    );

    _entranceController.forward();
  }

  @override
  void dispose() {
    _entranceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final safeTop = MediaQuery.of(context).padding.top;
    final screenWidth = MediaQuery.of(context).size.width;

    return AnimatedBuilder(
      animation: _entranceController,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, _slideAnim.value),
        child: Opacity(
          opacity: _fadeAnim.value,
          child: child,
        ),
      ),
      child: Container(
        padding: EdgeInsets.only(top: safeTop + 8, left: 14, right: 14, bottom: 10),
        height: safeTop + 72,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // ═══════════════════════════════════════════════════════════════
            // LEFT: Back Button (absolute position)
            // ═══════════════════════════════════════════════════════════════
            Positioned(
              left: 0,
              child: _GlassCapsuleButton(
                onTap: widget.onBack,
                size: const Size(48, 44),
                child: const Icon(
                  Icons.chevron_left_rounded,
                  color: Colors.white,
                  size: 26,
                ),
              ),
            ),

            // ═══════════════════════════════════════════════════════════════
            // CENTER: Name Capsule (true center, independent of sides)
            // ═══════════════════════════════════════════════════════════════
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: screenWidth * 0.55, // Max 55% of screen
                ),
                child: GestureDetector(
                  onTap: () {
                    if (widget.onTapName != null) {
                      HapticFeedback.selectionClick();
                      widget.onTapName!();
                    }
                  },
                  child: _GlassCapsule(
                    useIntrinsicHeight: true, // ✅ Dynamic height to prevent overflow
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6), // ✅ Reduced vertical padding
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Name with animation
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 250),
                          switchInCurve: Curves.easeOut,
                          switchOutCurve: Curves.easeIn,
                          child: Text(
                            widget.fullName,
                            key: ValueKey(widget.fullName),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 15.5, // ✅ Slightly smaller
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                              letterSpacing: -0.3,
                            ),
                          ),
                        ),
                        const SizedBox(height: 1), // ✅ Reduced spacing
                        // Online/Last seen
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 180),
                          child: Text(
                            widget.lastSeenText,
                            key: ValueKey(widget.lastSeenText),
                            maxLines: 1, // ✅ Prevent vertical overflow
                            overflow: TextOverflow.ellipsis, // ✅ Truncate long status
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 10.5, // ✅ Slightly smaller
                              color: widget.isOnline
                                  ? const Color(0xFF30D158) // Green for online
                                  : Colors.white.withOpacity(0.55),
                              fontWeight: widget.isOnline ? FontWeight.w500 : FontWeight.w400,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // ═══════════════════════════════════════════════════════════════
            // RIGHT: Avatar (absolute position)
            // ═══════════════════════════════════════════════════════════════
            Positioned(
              right: 0,
              child: _GlassCapsuleButton(
                onTap: widget.onOpenProfile,
                size: const Size(48, 44),
                child: ClipOval(
                  child: widget.avatarUrl != null && widget.avatarUrl!.isNotEmpty
                      ? Image.network(
                          widget.avatarUrl!,
                          width: 36,
                          height: 36,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _InitialsCircle(
                            fullName: widget.fullName,
                          ),
                        )
                      : _InitialsCircle(fullName: widget.fullName),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// GLASS CAPSULE - Base container with blur
// ═══════════════════════════════════════════════════════════════════════════
class _GlassCapsule extends StatelessWidget {
  final Widget child;
  final double? height;
  final bool useIntrinsicHeight;
  final EdgeInsets padding;
  final double borderRadius;

  const _GlassCapsule({
    required this.child,
    this.height,
    this.useIntrinsicHeight = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    this.borderRadius = 22,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          height: useIntrinsicHeight ? null : height,
          constraints: useIntrinsicHeight ? const BoxConstraints(minHeight: 44) : null,
          padding: padding,
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E).withOpacity(0.45),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              color: Colors.white.withOpacity(0.12),
              width: 0.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.20),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Sheen highlight
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(borderRadius),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Colors.white.withOpacity(0.08),
                          Colors.transparent,
                          Colors.black.withOpacity(0.04),
                        ],
                        stops: const [0.0, 0.5, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
              // Content - centered to prevent overflow
              Center(child: child),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// GLASS CAPSULE BUTTON - Tappable capsule with micro-animation
// ═══════════════════════════════════════════════════════════════════════════
class _GlassCapsuleButton extends StatefulWidget {
  final VoidCallback? onTap;
  final Widget child;
  final Size size;

  const _GlassCapsuleButton({
    this.onTap,
    required this.child,
    this.size = const Size(48, 44),
  });

  @override
  State<_GlassCapsuleButton> createState() => _GlassCapsuleButtonState();
}

class _GlassCapsuleButtonState extends State<_GlassCapsuleButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _scaleController;
  late Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _scaleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: 0.96).animate(
      CurvedAnimation(parent: _scaleController, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _scaleController.dispose();
    super.dispose();
  }

  void _onTapDown(_) {
    _scaleController.forward();
  }

  void _onTapUp(_) {
    _scaleController.reverse();
  }

  void _onTapCancel() {
    _scaleController.reverse();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      onTap: () {
        HapticFeedback.lightImpact();
        widget.onTap?.call();
      },
      child: AnimatedBuilder(
        animation: _scaleController,
        builder: (context, child) => Transform.scale(
          scale: _scaleAnim.value,
          child: child,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.size.height / 2),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
            child: Container(
              width: widget.size.width,
              height: widget.size.height,
              decoration: BoxDecoration(
                color: const Color(0xFF1C1C1E).withOpacity(0.45),
                borderRadius: BorderRadius.circular(widget.size.height / 2),
                border: Border.all(
                  color: Colors.white.withOpacity(0.12),
                  width: 0.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.20),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Stack(
                children: [
                  // Sheen highlight
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(widget.size.height / 2),
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Colors.white.withOpacity(0.08),
                              Colors.transparent,
                              Colors.black.withOpacity(0.04),
                            ],
                            stops: const [0.0, 0.5, 1.0],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Center(child: widget.child),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// INITIALS CIRCLE - Fallback when no avatar image
// ═══════════════════════════════════════════════════════════════════════════
class _InitialsCircle extends StatelessWidget {
  final String fullName;

  const _InitialsCircle({required this.fullName});

  String _getInitials() {
    final parts = fullName.trim().split(' ');
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return '${parts[0][0]}${parts.last[0]}'.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF5856D6),
            Color(0xFF0A84FF),
          ],
        ),
      ),
      child: Center(
        child: Text(
          _getInitials(),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
