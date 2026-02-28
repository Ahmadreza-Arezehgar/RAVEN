import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/ios_design_system.dart';

/// Snap Viewer - One-shot photo/video viewer with screenshot protection
/// 
/// Features:
/// - Auto-close after view_duration seconds
/// - Black overlay on screenshot/screen recording detected
/// - One-time view enforcement
class SnapViewer extends StatefulWidget {
  final String mediaUrl;
  final String mediaType; // image/video
  final int viewDuration; // seconds
  final VoidCallback onViewed;
  final VoidCallback? onScreenshotDetected;
  
  const SnapViewer({
    super.key,
    required this.mediaUrl,
    this.mediaType = 'image',
    this.viewDuration = 8,
    required this.onViewed,
    this.onScreenshotDetected,
  });

  @override
  State<SnapViewer> createState() => _SnapViewerState();
}

class _SnapViewerState extends State<SnapViewer> with WidgetsBindingObserver {
  bool _showSecurityOverlay = false;
  Timer? _countdownTimer;
  int _remainingSeconds = 0;
  bool _isViewing = false;
  
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _remainingSeconds = widget.viewDuration;
    _checkScreenCapture();
    _startCountdown();
  }
  
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _countdownTimer?.cancel();
    super.dispose();
  }
  
  void _checkScreenCapture() {
    // iOS: Check for screen recording via platform channel
    // This is a simplified version - real implementation needs native code
    // For now, we rely on app lifecycle changes as a proxy
  }
  
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // If app goes to background while viewing, assume screenshot attempt
    if (state == AppLifecycleState.inactive && _isViewing) {
      _onSecurityBreach();
    }
  }
  
  void _startCountdown() {
    _isViewing = true;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_remainingSeconds <= 1) {
        timer.cancel();
        _closeSnap();
      } else {
        if (!mounted) return;  // ✅ Fix
        setState(() => _remainingSeconds--);
      }
    });
  }
  
  void _onSecurityBreach() {
    HapticFeedback.heavyImpact();
    setState(() => _showSecurityOverlay = true);
    widget.onScreenshotDetected?.call();
    
    // Close after 2 seconds
    Future.delayed(const Duration(seconds: 2), _closeSnap);
  }
  
  void _closeSnap() {
    _countdownTimer?.cancel();
    widget.onViewed();
    if (mounted) Navigator.of(context).pop();
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Media content
          if (!_showSecurityOverlay)
            GestureDetector(
              onTap: _closeSnap,
              child: widget.mediaType == 'image'
                  ? Image.network(
                      widget.mediaUrl,
                      fit: BoxFit.contain,
                      loadingBuilder: (_, child, progress) {
                        if (progress == null) return child;
                        return Center(
                          child: CircularProgressIndicator(
                            value: progress.expectedTotalBytes != null
                                ? progress.cumulativeBytesLoaded / progress.expectedTotalBytes!
                                : null,
                            color: Colors.white,
                          ),
                        );
                      },
                    )
                  : const Center(
                      child: Icon(Icons.play_circle_outline, color: Colors.white, size: 80),
                    ),
            ),
          
          // Countdown timer
          if (!_showSecurityOverlay)
            Positioned(
              top: MediaQuery.of(context).padding.top + 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.timer, color: Colors.white, size: 16),
                    const SizedBox(width: 6),
                    Text(
                      '$_remainingSeconds',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          
          // Close button
          if (!_showSecurityOverlay)
            Positioned(
              top: MediaQuery.of(context).padding.top + 16,
              left: 16,
              child: GestureDetector(
                onTap: _closeSnap,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.5),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close, color: Colors.white, size: 24),
                ),
              ),
            ),
          
          // ═══════════════════════════════════════════════════════════
          // SECURITY OVERLAY - Shows on screenshot/recording attempt
          // ═══════════════════════════════════════════════════════════
          if (_showSecurityOverlay)
            Container(
              color: Colors.black,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.red.withOpacity(0.2),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.screenshot_outlined,
                        color: Colors.red,
                        size: 48,
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'You cannot take a screenshot',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'The sender has been notified',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.6),
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}


/// Security service for platform-specific screenshot protection
class ScreenshotProtectionService {
  static const _channel = MethodChannel('com.raven/screenshot');
  
  /// Enable FLAG_SECURE on Android (blocks screenshots entirely)
  static Future<void> enableSecureMode() async {
    try {
      await _channel.invokeMethod('enableSecureMode');
    } catch (e) {
      print('⚠️ Screenshot protection not available: $e');
    }
  }
  
  /// Disable FLAG_SECURE on Android
  static Future<void> disableSecureMode() async {
    try {
      await _channel.invokeMethod('disableSecureMode');
    } catch (e) {
      print('⚠️ Screenshot protection not available: $e');
    }
  }
  
  /// Check if screen is being captured (iOS only)
  static Future<bool> isScreenBeingCaptured() async {
    try {
      return await _channel.invokeMethod('isScreenBeingCaptured') ?? false;
    } catch (e) {
      return false;
    }
  }
}
