import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Native Liquid Glass Container using iOS UIVisualEffectView
/// 
/// On iOS: Uses real UIBlurEffect with vibrancy
/// On Android: Falls back to translucent container with blur simulation
class NativeGlassContainer extends StatelessWidget {
  final Widget? child;
  final double? height;
  final double? width;
  final double cornerRadius;
  final EdgeInsetsGeometry? padding;
  final String blurStyle; // 'dark', 'light', or 'regular'

  const NativeGlassContainer({
    Key? key,
    this.child,
    this.height,
    this.width,
    this.cornerRadius = 0,
    this.padding,
    this.blurStyle = 'dark',
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (Platform.isIOS) {
      return SizedBox(
        height: height,
        width: width,
        child: Stack(
          children: [
            // Native iOS Glass Background
            UiKitView(
              viewType: 'native_glass_view',
              creationParams: {
                'style': blurStyle,
                'cornerRadius': cornerRadius,
              },
              creationParamsCodec: const StandardMessageCodec(),
            ),
            // Flutter content on top
            if (child != null)
              Container(
                padding: padding,
                child: child,
              ),
          ],
        ),
      );
    }

    // Android fallback - translucent with backdrop filter
    return Container(
      height: height,
      width: width,
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.7),
        borderRadius: cornerRadius > 0 
            ? BorderRadius.circular(cornerRadius) 
            : null,
      boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: padding,
      child: child,
    );
  }
}

/// Animated Glass Container with slide-up animation
class AnimatedGlassContainer extends StatefulWidget {
  final Widget child;
  final double height;
  final bool isVisible;
  final Duration duration;
  final double cornerRadius;

  const AnimatedGlassContainer({
    Key? key,
    required this.child,
    required this.height,
    this.isVisible = true,
    this.duration = const Duration(milliseconds: 300),
    this.cornerRadius = 0,
  }) : super(key: key);

  @override
  State<AnimatedGlassContainer> createState() => _AnimatedGlassContainerState();
}

class _AnimatedGlassContainerState extends State<AnimatedGlassContainer>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: widget.duration,
      vsync: this,
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    ));

    if (widget.isVisible) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(AnimatedGlassContainer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isVisible != oldWidget.isVisible) {
      if (widget.isVisible) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _slideAnimation,
      child: NativeGlassContainer(
        height: widget.height,
        cornerRadius: widget.cornerRadius,
        child: widget.child,
      ),
    );
  }
}
