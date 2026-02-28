import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Global design constants matching bottom capsule
class GlassRadii {
  static const double capsule = 30; // Match bottom bar capsule style
  static const double capsuleSmall = 24;
  static const double capsuleLarge = 36;
}

/// Action item for Raven-style context menu
class RavenMenuAction {
  final String title;
  final IconData icon;
  final VoidCallback onTap;
  final bool destructive;
  final String? badgeText;

  RavenMenuAction({
    required this.title,
    required this.icon,
    required this.onTap,
    this.destructive = false,
    this.badgeText,
  });
}

/// Raven-style context menu with CAPSULE shape
/// Features: blur background, haptic feedback, spring animations
class RavenContextMenu {
  static OverlayEntry? _entry;

  static void show({
    required BuildContext context,
    required Rect anchorRect,
    required List<RavenMenuAction> actions,
    double menuWidth = 280,
  }) {
    hide();
    HapticFeedback.mediumImpact();

    final overlay = Overlay.of(context);
    final screen = MediaQuery.of(context).size;
    final safe = MediaQuery.of(context).padding;

    // Calculate menu height
    final double menuHeight = (actions.length * 54.0) + 16; // 16 for vertical padding
    
    // Position: Above bottom bar, centered on anchor
    final double left = (anchorRect.center.dx - menuWidth / 2)
        .clamp(16.0, screen.width - menuWidth - 16.0);
    
    // Always show above the anchor (bottom bar)
    final double top = (anchorRect.top - menuHeight - 12)
        .clamp(safe.top + 16, screen.height - menuHeight - 100);

    _entry = OverlayEntry(
      builder: (_) => _CapsuleMenuOverlay(
        actions: actions,
        menuWidth: menuWidth,
        left: left,
        top: top,
        onClose: hide,
      ),
    );

    overlay.insert(_entry!);
  }

  static void hide() {
    _entry?.remove();
    _entry = null;
  }
}

class _CapsuleMenuOverlay extends StatefulWidget {
  final List<RavenMenuAction> actions;
  final double menuWidth;
  final double left;
  final double top;
  final VoidCallback onClose;

  const _CapsuleMenuOverlay({
    required this.actions,
    required this.menuWidth,
    required this.left,
    required this.top,
    required this.onClose,
  });

  @override
  State<_CapsuleMenuOverlay> createState() => _CapsuleMenuOverlayState();
}

class _CapsuleMenuOverlayState extends State<_CapsuleMenuOverlay> 
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnim;
  late Animation<double> _opacityAnim;
  int _hoverIndex = -1;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 280),
      vsync: this,
    );
    
    // Spring-like scale animation (Telegram style)
    _scaleAnim = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeOutBack,
      ),
    );
    
    _opacityAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
      ),
    );
    
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _close() {
    _controller.reverse().then((_) => widget.onClose());
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _close,
        child: Stack(
          children: [
            // ✅ Full screen blur + dim (Raven-style)
            AnimatedBuilder(
              animation: _opacityAnim,
              builder: (context, child) => Opacity(
                opacity: _opacityAnim.value,
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
                  child: Container(
                    color: Colors.black.withOpacity(0.25),
                  ),
                ),
              ),
            ),

            // ✅ Capsule menu panel
            Positioned(
              left: widget.left,
              top: widget.top,
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, child) => Opacity(
                  opacity: _opacityAnim.value,
                  child: Transform.scale(
                    scale: _scaleAnim.value,
                    child: child,
                  ),
                ),
                child: _buildCapsulePanel(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCapsulePanel() {
    return Container(
      width: widget.menuWidth,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(GlassRadii.capsule),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.35),
            blurRadius: 24,
            offset: const Offset(0, 12),
            spreadRadius: -4,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(GlassRadii.capsule),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF0D0D0D).withOpacity(0.78),
              borderRadius: BorderRadius.circular(GlassRadii.capsule),
              border: Border.all(
                color: Colors.white.withOpacity(0.12),
                width: 0.5,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(widget.actions.length, (i) {
                final a = widget.actions[i];
                final bool hovered = _hoverIndex == i;
                final bool isFirst = i == 0;
                final bool isLast = i == widget.actions.length - 1;

                return Column(
                  children: [
                    _CapsuleMenuRow(
                      title: a.title,
                      icon: a.icon,
                      destructive: a.destructive,
                      badgeText: a.badgeText,
                      highlighted: hovered,
                      isFirst: isFirst,
                      isLast: isLast,
                      onHover: () {
                        if (_hoverIndex != i) {
                          _hoverIndex = i;
                          HapticFeedback.selectionClick();
                          setState(() {});
                        }
                      },
                      onTap: () {
                        HapticFeedback.lightImpact();
                        _close();
                        // ✅ FIX: Delay navigation until after overlay removal completes
                        // This prevents !_debugLocked assertion failure
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          a.onTap();
                        });
                      },
                    ),
                    if (!isLast)
                      Container(
                        height: 0.5,
                        margin: const EdgeInsets.symmetric(horizontal: 20),
                        color: Colors.white.withOpacity(0.06),
                      ),
                  ],
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}

class _CapsuleMenuRow extends StatelessWidget {
  final String title;
  final IconData icon;
  final bool destructive;
  final String? badgeText;
  final bool highlighted;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onTap;
  final VoidCallback onHover;

  const _CapsuleMenuRow({
    required this.title,
    required this.icon,
    required this.onTap,
    required this.onHover,
    this.destructive = false,
    this.badgeText,
    this.highlighted = false,
    this.isFirst = false,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    final Color textColor = destructive ? const Color(0xFFFF453A) : Colors.white;
    final Color iconColor = destructive 
        ? const Color(0xFFFF453A) 
        : const Color(0xFF0A84FF);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => onHover(),
      onPanDown: (_) => onHover(),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          color: highlighted 
              ? Colors.white.withOpacity(0.08) 
              : Colors.transparent,
          borderRadius: BorderRadius.vertical(
            top: isFirst ? const Radius.circular(GlassRadii.capsule - 8) : Radius.zero,
            bottom: isLast ? const Radius.circular(GlassRadii.capsule - 8) : Radius.zero,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: iconColor, size: 16),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  color: textColor.withOpacity(0.95),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.3,
                ),
              ),
            ),
            if (badgeText != null) _Badge(badgeText!),
            Icon(
              Icons.chevron_right, 
              color: Colors.white.withOpacity(0.25), 
              size: 14,
            ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  const _Badge(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF0A84FF),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white, 
          fontWeight: FontWeight.bold, 
          fontSize: 11,
        ),
      ),
    );
  }
}

/// Helper to get global rect from a GlobalKey
Rect getGlobalRect(GlobalKey key) {
  final box = key.currentContext?.findRenderObject() as RenderBox?;
  if (box == null) return Rect.zero;
  final pos = box.localToGlobal(Offset.zero);
  return pos & box.size;
}
