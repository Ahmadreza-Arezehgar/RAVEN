import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Toast types for different scenarios
enum ToastType { success, info, warning, error }

/// Global Toast Service for Apple Liquid Glass toasts
/// Replaces all SnackBars with unified top capsule toasts
class ToastService {
  static OverlayEntry? _currentEntry;
  static final List<_ToastRequest> _queue = [];
  static bool _isShowing = false;
  static BuildContext? _context;
  
  /// Initialize with root context (call in MaterialApp builder)
  static void init(BuildContext context) {
    _context = context;
  }
  
  /// Show success toast (green accent)
  static void showSuccess(String title, {String? subtitle, VoidCallback? onTap}) {
    _enqueue(_ToastRequest(
      type: ToastType.success,
      title: title,
      subtitle: subtitle,
      onTap: onTap,
    ));
  }
  
  /// Show info toast (blue accent)
  static void showInfo(String title, {String? subtitle, VoidCallback? onTap}) {
    _enqueue(_ToastRequest(
      type: ToastType.info,
      title: title,
      subtitle: subtitle,
      onTap: onTap,
    ));
  }
  
  /// Show warning toast (orange accent)
  static void showWarning(String title, {String? subtitle, VoidCallback? onTap}) {
    _enqueue(_ToastRequest(
      type: ToastType.warning,
      title: title,
      subtitle: subtitle,
      onTap: onTap,
    ));
  }
  
  /// Show error toast (red accent)
  static void showError(String title, {String? subtitle, VoidCallback? onTap}) {
    _enqueue(_ToastRequest(
      type: ToastType.error,
      title: title,
      subtitle: subtitle,
      onTap: onTap,
    ));
  }
  
  /// Generic show method
  static void show({
    required ToastType type,
    required String title,
    String? subtitle,
    VoidCallback? onTap,
    Duration duration = const Duration(milliseconds: 1500),
  }) {
    _enqueue(_ToastRequest(
      type: type,
      title: title,
      subtitle: subtitle,
      onTap: onTap,
      duration: duration,
    ));
  }
  
  static void _enqueue(_ToastRequest request) {
    _queue.add(request);
    _processQueue();
  }
  
  static void _processQueue() async {
    if (_isShowing || _queue.isEmpty || _context == null) return;
    
    _isShowing = true;
    final request = _queue.removeAt(0);
    
    await _showToast(request);
    
    _isShowing = false;
    if (_queue.isNotEmpty) {
      // Small delay between toasts
      await Future.delayed(const Duration(milliseconds: 200));
      _processQueue();
    }
  }
  
  static Future<void> _showToast(_ToastRequest request) async {
    final overlay = Overlay.of(_context!);
    final completer = Completer<void>();
    
    // Haptic feedback based on type
    if (request.type == ToastType.success) {
      HapticFeedback.lightImpact();
    } else if (request.type == ToastType.error) {
      HapticFeedback.mediumImpact();
    } else {
      HapticFeedback.selectionClick();
    }
    
    _currentEntry = OverlayEntry(
      builder: (context) => _LiquidGlassToastOverlay(
        request: request,
        onDismiss: () {
          _currentEntry?.remove();
          _currentEntry = null;
          if (!completer.isCompleted) completer.complete();
        },
      ),
    );
    
    overlay.insert(_currentEntry!);
    
    // Wait for toast to complete
    await completer.future;
  }
  
  /// Dismiss current toast immediately
  static void dismiss() {
    _currentEntry?.remove();
    _currentEntry = null;
    _isShowing = false;
  }
}

class _ToastRequest {
  final ToastType type;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Duration duration;
  
  _ToastRequest({
    required this.type,
    required this.title,
    this.subtitle,
    this.onTap,
    this.duration = const Duration(milliseconds: 1500),
  });
}

class _LiquidGlassToastOverlay extends StatefulWidget {
  final _ToastRequest request;
  final VoidCallback onDismiss;
  
  const _LiquidGlassToastOverlay({
    required this.request,
    required this.onDismiss,
  });
  
  @override
  State<_LiquidGlassToastOverlay> createState() => _LiquidGlassToastOverlayState();
}

class _LiquidGlassToastOverlayState extends State<_LiquidGlassToastOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnim;
  late Animation<double> _scaleAnim;
  late Animation<Offset> _slideAnim;
  
  @override
  void initState() {
    super.initState();
    
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      reverseDuration: const Duration(milliseconds: 200),
      vsync: this,
    );
    
    _fadeAnim = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    
    _scaleAnim = Tween<double>(begin: 0.96, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, -0.3),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    ));
    
    // Start animation
    _controller.forward();
    
    // Auto-dismiss after duration
    Future.delayed(widget.request.duration, () {
      if (mounted) _dismiss();
    });
  }
  
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
  
  void _dismiss() async {
    await _controller.reverse();
    widget.onDismiss();
  }
  
  @override
  Widget build(BuildContext context) {
    final safeTop = MediaQuery.of(context).padding.top;
    
    return Positioned(
      top: safeTop + 12,
      left: 0,
      right: 0,
      child: Center(
        child: FadeTransition(
          opacity: _fadeAnim,
          child: SlideTransition(
            position: _slideAnim,
            child: ScaleTransition(
              scale: _scaleAnim,
              child: GestureDetector(
                onTap: () {
                  widget.request.onTap?.call();
                  _dismiss();
                },
                child: _LiquidGlassCapsuleToast(
                  type: widget.request.type,
                  title: widget.request.title,
                  subtitle: widget.request.subtitle,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The actual toast widget with Liquid Glass design
class _LiquidGlassCapsuleToast extends StatelessWidget {
  final ToastType type;
  final String title;
  final String? subtitle;
  
  const _LiquidGlassCapsuleToast({
    required this.type,
    required this.title,
    this.subtitle,
  });
  
  Color get _accentColor {
    switch (type) {
      case ToastType.success: return const Color(0xFF34C759);
      case ToastType.info: return const Color(0xFF0A84FF);
      case ToastType.warning: return const Color(0xFFFF9F0A);
      case ToastType.error: return const Color(0xFFFF3B30);
    }
  }
  
  IconData get _icon {
    switch (type) {
      case ToastType.success: return Icons.check_rounded;
      case ToastType.info: return Icons.info_outline_rounded;
      case ToastType.warning: return Icons.warning_amber_rounded;
      case ToastType.error: return Icons.close_rounded;
    }
  }
  
  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    
    return Container(
      constraints: BoxConstraints(
        maxWidth: screenWidth * 0.86,
        minHeight: 52,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: 20,
            offset: const Offset(0, 6),
            spreadRadius: -4,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E).withOpacity(0.65),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(
                color: Colors.white.withOpacity(0.12),
                width: 0.5,
              ),
              // Subtle sheen gradient
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withOpacity(0.08),
                  Colors.transparent,
                  Colors.black.withOpacity(0.05),
                ],
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Icon circle
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _accentColor.withOpacity(0.18),
                    border: Border.all(
                      color: _accentColor.withOpacity(0.3),
                      width: 0.5,
                    ),
                  ),
                  child: Icon(
                    _icon,
                    color: _accentColor,
                    size: 18,
                  ),
                ),
                
                const SizedBox(width: 12),
                
                // Text content
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          height: 1.2,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.65),
                            fontSize: 12,
                            height: 1.2,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
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
