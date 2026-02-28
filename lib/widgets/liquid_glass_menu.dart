import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/ios_design_system.dart';

/// Liquid Glass Presets - predefined glass material configurations
class LiquidGlassPreset {
  final double blur;
  final Color tint;
  final double opacity;
  final Color borderColor;

  const LiquidGlassPreset({
    required this.blur,
    required this.tint,
    required this.opacity,
    required this.borderColor,
  });
}

class LiquidGlassPresets {
  static const menu = LiquidGlassPreset(
    blur: 20.0,
    tint: Color(0xFF1C1C1E),
    opacity: 0.8,
    borderColor: Color(0x33FFFFFF),
  );

  static const subtle = LiquidGlassPreset(
    blur: 10.0,
    tint: Color(0xFF1C1C1E),
    opacity: 0.6,
    borderColor: Color(0x1AFFFFFF),
  );

  static const searchBar = LiquidGlassPreset(
    blur: 15.0,
    tint: Color(0xFF2C2C2E),
    opacity: 0.7,
    borderColor: Color(0x26FFFFFF),
  );

  static const navigation = LiquidGlassPreset(
    blur: 30.0,
    tint: Color(0xFF000000),
    opacity: 0.6,
    borderColor: Color(0x1AFFFFFF),
  );

  static const modal = LiquidGlassPreset(
    blur: 25.0,
    tint: Color(0xFF1C1C1E),
    opacity: 0.75,
    borderColor: Color(0x33FFFFFF),
  );
}

/// Liquid Glass Menu Widget
/// Implements Apple's Liquid Glass design for menus and popovers
/// with rounded corners and peek effect

class LiquidGlassMenu extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final BorderRadius? borderRadius;
  final double? width;
  final double? maxHeight;

  const LiquidGlassMenu({
    super.key,
    required this.child,
    this.padding,
    this.borderRadius,
    this.width,
    this.maxHeight,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      constraints: maxHeight != null
          ? BoxConstraints(maxHeight: maxHeight!)
          : null,
      child: ClipRRect(
        borderRadius: borderRadius ?? BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: LiquidGlassPresets.menu.blur,
            sigmaY: LiquidGlassPresets.menu.blur,
          ),
          child: Container(
            padding: padding ?? const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: LiquidGlassPresets.menu.tint
                  .withOpacity(LiquidGlassPresets.menu.opacity),
              border: Border.all(
                color: LiquidGlassPresets.menu.borderColor,
                width: iOSDesignSystem.glassBorderWidth,
              ),
              borderRadius: borderRadius ?? BorderRadius.circular(20),
              boxShadow: iOSDesignSystem.elevatedShadow,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Action Menu Item - for context menus and action sheets
class LiquidGlassMenuItem extends StatefulWidget {
  final IconData? icon;
  final String label;
  final VoidCallback onTap;
  final bool isDestructive;
  final bool isDisabled;

  const LiquidGlassMenuItem({
    super.key,
    this.icon,
    required this.label,
    required this.onTap,
    this.isDestructive = false,
    this.isDisabled = false,
  });

  @override
  State<LiquidGlassMenuItem> createState() => _LiquidGlassMenuItemState();
}

class _LiquidGlassMenuItemState extends State<LiquidGlassMenuItem> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.isDestructive
        ? iOSDesignSystem.accentPink
        : widget.isDisabled
            ? iOSDesignSystem.textDisabled
            : iOSDesignSystem.textPrimary;

    return GestureDetector(
      onTapDown: widget.isDisabled ? null : (_) => setState(() => _isPressed = true),
      onTapUp: widget.isDisabled ? null : (_) {
        setState(() => _isPressed = false);
        widget.onTap();
      },
      onTapCancel: widget.isDisabled ? null : () => setState(() => _isPressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: _isPressed
              ? iOSDesignSystem.glassSegmentActive
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            if (widget.icon != null) ...[
              Icon(
                widget.icon,
                size: 20,
                color: color,
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Text(
                widget.label,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w400,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Dropdown Menu with Liquid Glass
class LiquidGlassDropdown<T> extends StatelessWidget {
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;
  final String? hint;

  const LiquidGlassDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: LiquidGlassPresets.subtle.blur,
          sigmaY: LiquidGlassPresets.subtle.blur,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: LiquidGlassPresets.subtle.tint
                .withOpacity(LiquidGlassPresets.subtle.opacity),
            border: Border.all(
              color: LiquidGlassPresets.subtle.borderColor,
              width: iOSDesignSystem.glassBorderWidth,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: value,
              items: items,
              onChanged: onChanged,
              hint: hint != null
                  ? Text(
                      hint!,
                      style: const TextStyle(
                        color: iOSDesignSystem.textSecondary,
                      ),
                    )
                  : null,
              dropdownColor: iOSDesignSystem.surfaceCard,
              style: const TextStyle(
                color: iOSDesignSystem.textPrimary,
                fontSize: 16,
              ),
              icon: const Icon(
                Icons.arrow_drop_down,
                color: iOSDesignSystem.textSecondary,
              ),
              isExpanded: true,
            ),
          ),
        ),
      ),
    );
  }
}

/// Context Menu Wrapper - shows menu on long press
class LiquidGlassContextMenu extends StatelessWidget {
  final Widget child;
  final List<LiquidGlassMenuItem> menuItems;

  const LiquidGlassContextMenu({
    super.key,
    required this.child,
    required this.menuItems,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: () => _showContextMenu(context),
      child: child,
    );
  }

  void _showContextMenu(BuildContext context) {
    showMenu(
      context: context,
      position: const RelativeRect.fromLTRB(100, 100, 100, 100),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      color: Colors.transparent,
      elevation: 0,
      items: [
        PopupMenuItem(
          enabled: false,
          padding: EdgeInsets.zero,
          child: LiquidGlassMenu(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: menuItems,
            ),
          ),
        ),
      ],
    );
  }
}

/// Search Bar with Liquid Glass
class LiquidGlassSearchBar extends StatelessWidget {
  final TextEditingController? controller;
  final String? hintText;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onClear;

  const LiquidGlassSearchBar({
    super.key,
    this.controller,
    this.hintText,
    this.onChanged,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: LiquidGlassPresets.searchBar.blur,
          sigmaY: LiquidGlassPresets.searchBar.blur,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: LiquidGlassPresets.searchBar.tint
                .withOpacity(LiquidGlassPresets.searchBar.opacity),
            border: Border.all(
              color: LiquidGlassPresets.searchBar.borderColor,
              width: iOSDesignSystem.glassBorderWidth,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: TextField(
            controller: controller,
            onChanged: onChanged,
            style: const TextStyle(
              color: iOSDesignSystem.textPrimary,
              fontSize: 16,
            ),
            decoration: InputDecoration(
              hintText: hintText ?? 'Search...',
              hintStyle: const TextStyle(
                color: iOSDesignSystem.textTertiary,
              ),
              prefixIcon: const Icon(
                Icons.search,
                color: iOSDesignSystem.textSecondary,
              ),
              suffixIcon: controller != null && controller!.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(
                        Icons.clear,
                        color: iOSDesignSystem.textSecondary,
                      ),
                      onPressed: () {
                        controller!.clear();
                        onClear?.call();
                      },
                    )
                  : null,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
