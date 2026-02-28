import 'dart:ui';
import 'package:flutter/material.dart';

/// Glass Pill Button (برای header)
class GlassPillButton extends StatelessWidget {
  final IconData? icon;
  final List<IconData>? icons; // برای دو آیکون
  final String? label;
  final VoidCallback? onTap;
  final double height;
  
  const GlassPillButton({
    super.key,
    this.icon,
    this.icons,
    this.label,
    this.onTap,
    this.height = 44,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(height / 2),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            height: height,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.10),
              borderRadius: BorderRadius.circular(height / 2),
              border: Border.all(
                color: Colors.white.withOpacity(0.10),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null)
                  Icon(icon, size: 20, color: Colors.white.withOpacity(0.90)),
                if (icons != null && icons!.isNotEmpty) ...[
                  Icon(icons![0], size: 18, color: Colors.white.withOpacity(0.90)),
                  if (icons!.length > 1) ...[
                    const SizedBox(width: 8),
                    Icon(icons![1], size: 18, color: Colors.white.withOpacity(0.90)),
                  ],
                ],
                if (label != null) ...[
                  if (icon != null || icons != null) const SizedBox(width: 6),
                  Text(
                    label!,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.white.withOpacity(0.90),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Glass Search Bar
class GlassSearchBar extends StatelessWidget {
  final String placeholder;
  final VoidCallback? onTap;
  final double height;
  
  const GlassSearchBar({
    super.key,
    this.placeholder = 'Search',
    this.onTap,
    this.height = 46,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(height / 2),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            height: height,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(height / 2),
              border: Border.all(
                color: Colors.white.withOpacity(0.08),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.search,
                  size: 20,
                  color: Colors.white.withOpacity(0.50),
                ),
                const SizedBox(width: 10),
                Text(
                  placeholder,
                  style: TextStyle(
                    fontSize: 15,
                    color: Colors.white.withOpacity(0.50),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Glass Filter Chip با badge
class GlassFilterChip extends StatelessWidget {
  final String label;
  final int? badge;
  final bool isSelected;
  final VoidCallback? onTap;
  
  const GlassFilterChip({
    super.key,
    required this.label,
    this.badge,
    this.isSelected = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected 
              ? Colors.white.withOpacity(0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: isSelected
              ? Border.all(
                  color: Colors.white.withOpacity(0.10),
                  width: 0.5,
                )
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                color: isSelected 
                    ? Colors.white
                    : Colors.white.withOpacity(0.60),
              ),
            ),
            if (badge != null && badge! > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF0A84FF),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  badge! > 99 ? '99+' : '$badge',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Glass Filter Bar (کانتینر برای chips)
class GlassFilterBar extends StatelessWidget {
  final List<Widget> children;
  
  const GlassFilterBar({
    super.key,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: Colors.white.withOpacity(0.08),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        ),
      ),
    );
  }
}
