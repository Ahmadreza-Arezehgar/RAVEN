import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../widgets/glass_header_components.dart';
import '../widgets/liquid_glass_menu.dart';
import '../widgets/global_notification_overlay.dart';
import '../theme/ios_design_system.dart';

/// Dynamic Glass Header برای هر tab
class DynamicGlassHeader extends StatefulWidget {
  final String title;
  final int currentTab; // 0=Home, 1=Nearby, 2=Notifications, 3=Profile
  final VoidCallback? onAvatarTap;
  final VoidCallback? onMessagesTap;
  final VoidCallback? onFriendsTap;
  final VoidCallback? onNotificationTap;  // Optional legacy callback
  final Widget? customContent;
  
  const DynamicGlassHeader({
    super.key,
    required this.title,
    required this.currentTab,
    this.onAvatarTap,
    this.onMessagesTap,
    this.onFriendsTap,
    this.onNotificationTap,
    this.customContent,
  });

  @override
  State<DynamicGlassHeader> createState() => _DynamicGlassHeaderState();
}

class _DynamicGlassHeaderState extends State<DynamicGlassHeader> {
  // ✅ GlobalKey for Bell positioning
  final GlobalKey _bellKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    final notifController = context.watch<NotificationOverlayController>();

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(20)),
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: LiquidGlassPresets.navigation.blur,
          sigmaY: LiquidGlassPresets.navigation.blur,
        ),
        child: Container(
          padding: EdgeInsets.only(top: top),
          decoration: BoxDecoration(
            color: LiquidGlassPresets.navigation.tint
                .withOpacity(LiquidGlassPresets.navigation.opacity),
            border: const Border(
              bottom: BorderSide(
                color: iOSDesignSystem.glassBorderMedium,
                width: iOSDesignSystem.glassBorderWidth,
              ),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Row 1: Title (center) + Notification (right)
              // ✅ CLEANED: Removed left avatar per design spec
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    // Empty space for symmetry (same width as bell button)
                    const SizedBox(width: 40),

                    const Spacer(),

                    Text(
                      widget.title,
                      style: iOSDesignSystem.textTheme.headlineMedium?.copyWith(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: iOSDesignSystem.textPrimary,
                      ),
                    ),

                    const Spacer(),

                    // ✅ Global Notification Bell Button
                    NotificationBellButton(
                      bellKey: _bellKey,
                      controller: notifController,
                      unreadCount: notifController.unreadCount,
                      onTap: () => notifController.toggle(),
                    ),
                  ],
                ),
              ),

              if (widget.customContent != null) ...[
                const SizedBox(height: 8),
                widget.customContent!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
