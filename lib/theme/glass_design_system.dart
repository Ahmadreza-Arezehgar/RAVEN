import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Apple WWDC25 Liquid Glass Design System
/// Floating surfaces with blur, minimal tint, hairline borders

// ═══════════════════════════════════════════════════════════════════════════
// GLASS CAPSULE - For text inputs, buttons, and pill-shaped containers
// ═══════════════════════════════════════════════════════════════════════════

class GlassCapsule extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final double blur;
  final Color tintColor;
  final double tintOpacity;

  const GlassCapsule({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    this.radius = 18,
    this.blur = 18,
    this.tintColor = Colors.white,
    this.tintOpacity = 0.08,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: tintColor.withValues(alpha: tintOpacity),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.14),
              width: 0.6,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// GLASS TEXT FIELD - Styled TextField with glass background
// ═══════════════════════════════════════════════════════════════════════════

class GlassTextField extends StatelessWidget {
  final TextEditingController? controller;
  final String? hintText;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onEditingComplete;
  final TextInputType? keyboardType;
  final int? maxLines;
  final int? maxLength;
  final bool autofocus;
  final Widget? suffix;

  const GlassTextField({
    super.key,
    this.controller,
    this.hintText,
    this.focusNode,
    this.onChanged,
    this.onEditingComplete,
    this.keyboardType,
    this.maxLines = 1,
    this.maxLength,
    this.autofocus = false,
    this.suffix,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCapsule(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              onChanged: onChanged,
              onEditingComplete: onEditingComplete,
              keyboardType: keyboardType,
              maxLines: maxLines,
              maxLength: maxLength,
              autofocus: autofocus,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
              ),
              decoration: InputDecoration(
                hintText: hintText,
                hintStyle: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 16,
                ),
                border: InputBorder.none,
                isDense: true,
                counterText: '',
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          if (suffix != null) ...[
            const SizedBox(width: 8),
            suffix!,
          ],
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// GLASS SHEET - Modal bottom sheet wrapper with blur
// ═══════════════════════════════════════════════════════════════════════════

class GlassSheet extends StatelessWidget {
  final Widget child;
  final double topRadius;
  final double blur;

  const GlassSheet({
    super.key,
    required this.child,
    this.topRadius = 24,
    this.blur = 22,
  });

  /// Show as modal bottom sheet
  static Future<T?> show<T>({
    required BuildContext context,
    required Widget Function(BuildContext) builder,
    bool isScrollControlled = true,
  }) {
    HapticFeedback.mediumImpact();
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: isScrollControlled,
      builder: (ctx) => GlassSheet(child: builder(ctx)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return ClipRRect(
      borderRadius: BorderRadius.vertical(top: Radius.circular(topRadius)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.vertical(top: Radius.circular(topRadius)),
            border: Border(
              top: BorderSide(
                color: Colors.white.withValues(alpha: 0.15),
                width: 0.5,
              ),
            ),
          ),
          padding: EdgeInsets.only(
            bottom: bottomInset + bottomPadding,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle bar
              Container(
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// GLASS MESSAGE INPUT - Chat input with send button
// ═══════════════════════════════════════════════════════════════════════════

class GlassMessageInput extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final VoidCallback? onSend;
  final VoidCallback? onAttachment;
  final String hintText;
  final bool enabled;

  const GlassMessageInput({
    super.key,
    required this.controller,
    this.focusNode,
    this.onSend,
    this.onAttachment,
    this.hintText = 'Message…',
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCapsule(
      radius: 999, // Full pill shape
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          // Attachment button
          if (onAttachment != null)
            GestureDetector(
              onTap: onAttachment,
              child: Container(
                padding: const EdgeInsets.all(6),
                child: Icon(
                  Icons.add_circle_outline,
                  color: Colors.white.withValues(alpha: 0.6),
                  size: 22,
                ),
              ),
            ),
          
          const SizedBox(width: 8),
          
          // Text input
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              enabled: enabled,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
              ),
              decoration: InputDecoration(
                hintText: hintText,
                hintStyle: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 16,
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              onSubmitted: (_) => onSend?.call(),
            ),
          ),
          
          const SizedBox(width: 8),
          
          // Send button
          GestureDetector(
            onTap: () {
              if (controller.text.trim().isNotEmpty) {
                HapticFeedback.lightImpact();
                onSend?.call();
              }
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: controller.text.trim().isNotEmpty
                    ? const Color(0xFF0A84FF)
                    : Colors.transparent,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.arrow_upward,
                color: controller.text.trim().isNotEmpty
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.4),
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// GLASS SEARCH BAR - Search input with icon
// ═══════════════════════════════════════════════════════════════════════════

class GlassSearchBar extends StatelessWidget {
  final TextEditingController? controller;
  final String hintText;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onClear;

  const GlassSearchBar({
    super.key,
    this.controller,
    this.hintText = 'Search…',
    this.onChanged,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCapsule(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Icon(
            Icons.search,
            color: Colors.white.withValues(alpha: 0.5),
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
              ),
              decoration: InputDecoration(
                hintText: hintText,
                hintStyle: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 16,
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          if (controller?.text.isNotEmpty == true && onClear != null)
            GestureDetector(
              onTap: onClear,
              child: Icon(
                Icons.close,
                color: Colors.white.withValues(alpha: 0.5),
                size: 18,
              ),
            ),
        ],
      ),
    );
  }
}
