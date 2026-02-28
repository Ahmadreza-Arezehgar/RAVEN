import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Native Liquid Glass Navigation Bar
/// 
/// Uses TRUE iOS UIVisualEffectView with spring animations
/// on iOS, falls back to styled container on Android
class LiquidGlassNavigation extends StatefulWidget {
  final int selectedIndex;
  final int unreadCount;
  final Function(int) onTap;

  const LiquidGlassNavigation({
    Key? key,
    required this.selectedIndex,
    required this.unreadCount,
    required this.onTap,
  }) : super(key: key);

  @override
  State<LiquidGlassNavigation> createState() => _LiquidGlassNavigationState();
}

class _LiquidGlassNavigationState extends State<LiquidGlassNavigation> {
  MethodChannel? _methodChannel;
  bool _disposed = false;

  @override
  Widget build(BuildContext context) {
    if (Platform.isIOS) {
      return SizedBox(
        height: 86, // 70pt bar + 16pt padding
        child: Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: UiKitView(
            viewType: 'liquid_glass_navigation',
            creationParams: {
              'selectedIndex': widget.selectedIndex,
              'unreadCount': widget.unreadCount,
            },
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: _onPlatformViewCreated,
          ),
        ),
      );
    }

    // Android fallback
    return _buildFallbackNavigation();
  }

  void _onPlatformViewCreated(int id) {
    if (_disposed) return;
    _methodChannel = MethodChannel('liquid_glass_navigation_$id');
    _methodChannel!.setMethodCallHandler(_handleMethodCall);
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    // CRITICAL: Check mounted before any widget interaction
    if (!mounted || _disposed) return;
    
    if (call.method == 'onTap') {
      final index = call.arguments as int;
      widget.onTap(index);
    }
  }

  @override
  void didUpdateWidget(LiquidGlassNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    if (_disposed || !mounted) return;
    
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      _methodChannel?.invokeMethod('setActive', widget.selectedIndex);
    }
    
    if (oldWidget.unreadCount != widget.unreadCount) {
      _methodChannel?.invokeMethod('setBadge', {
        'index': 2, // Notifications tab
        'count': widget.unreadCount,
      });
    }
  }

  @override
  void dispose() {
    _disposed = true;
    // Clean up the method channel
    _methodChannel?.setMethodCallHandler(null);
    _methodChannel = null;
    super.dispose();
  }

  Widget _buildFallbackNavigation() {
    // Simple fallback for Android
    return Container(
      height: 70,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.8),
        borderRadius: BorderRadius.circular(35),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildFallbackItem(0, Icons.home, 'Home'),
          _buildFallbackItem(1, Icons.bluetooth, 'Nearby'),
          _buildFallbackItem(2, Icons.notifications, 'Notif'),
          _buildFallbackItem(3, Icons.people, 'Friends'),
        ],
      ),
    );
  }

  Widget _buildFallbackItem(int index, IconData icon, String label) {
    final isActive = widget.selectedIndex == index;
    final showBadge = index == 2 && widget.unreadCount > 0; // Notifications tab
    
    return GestureDetector(
      onTap: () => widget.onTap(index),
      child: Container(
        width: 70, // ≥44pt touch target
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? Colors.white.withOpacity(0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(28),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  icon,
                  size: 24,
                  color: isActive ? Colors.blue : Colors.white.withOpacity(0.6),
                ),
                // iOS systemRed badge
                if (showBadge)
                  Positioned(
                    right: -8,
                    top: -4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF3B30), // iOS systemRed
                        borderRadius: BorderRadius.circular(10),
                      ),
                      constraints: const BoxConstraints(
                        minWidth: 18,
                        minHeight: 18,
                      ),
                      child: Text(
                        widget.unreadCount > 99 ? '99+' : '${widget.unreadCount}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          height: 1.0,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                color: isActive ? Colors.blue : Colors.white.withOpacity(0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
