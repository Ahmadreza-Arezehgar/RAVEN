import 'dart:ui';
import 'package:flutter/material.dart';
import '../services/mesh_router.dart';

/// Network Mode Capsule - Liquid Glass UI indicator
/// 
/// Shows current network mode (Online/Offline/Mesh) with
/// animated transitions and auto-dismiss after 1.5s
class NetworkModeCapsule extends StatefulWidget {
  final bool isOnline;
  final String? customMessage;
  final VoidCallback? onDismiss;

  const NetworkModeCapsule({
    super.key,
    required this.isOnline,
    this.customMessage,
    this.onDismiss,
  });

  @override
  State<NetworkModeCapsule> createState() => _NetworkModeCapsuleState();
}

class _NetworkModeCapsuleState extends State<NetworkModeCapsule>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _slideAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _slideAnimation = Tween<double>(begin: -50, end: 0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );

    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );

    _controller.forward();

    // Auto-dismiss after 2.5s
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (mounted) {
        _dismiss();
      }
    });
  }

  Future<void> _dismiss() async {
    await _controller.reverse();
    widget.onDismiss?.call();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.customMessage ?? 
        (widget.isOnline ? 'Online • Direct to server' : 'Mesh Mode • Offline');
    
    final icon = widget.isOnline 
        ? Icons.cloud_done_rounded 
        : Icons.bluetooth_searching_rounded;
    
    final accentColor = widget.isOnline
        ? const Color(0xFF30D158)  // iOS green
        : const Color(0xFF0A84FF); // iOS blue

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, _slideAnimation.value),
        child: Opacity(
          opacity: _fadeAnimation.value,
          child: child,
        ),
      ),
      child: Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF1C1C1E).withOpacity(0.8),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Colors.white.withOpacity(0.15),
                  width: 0.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: accentColor.withOpacity(0.3),
                    blurRadius: 15,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: accentColor,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: accentColor.withOpacity(0.5),
                          blurRadius: 6,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Icon(icon, size: 16, color: accentColor),
                  const SizedBox(width: 8),
                  Text(
                    message,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.9),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Controller for showing/hiding NetworkModeCapsule
class NetworkModeCapsuleController {
  static final NetworkModeCapsuleController _instance = 
      NetworkModeCapsuleController._internal();
  static NetworkModeCapsuleController get instance => _instance;
  NetworkModeCapsuleController._internal();

  OverlayEntry? _overlayEntry;
  bool _isShowing = false;

  /// Initialize and listen for network mode changes
  void init() {
    MeshRouter.instance.addNetworkModeListener(_onNetworkModeChange);
  }

  void dispose() {
    MeshRouter.instance.removeNetworkModeListener(_onNetworkModeChange);
    hide();
  }

  void _onNetworkModeChange(bool isOnline) {
    show(isOnline: isOnline);
  }

  /// Show capsule with specific message
  void show({
    required bool isOnline,
    String? customMessage,
  }) {
    // Don't show multiple capsules
    if (_isShowing) {
      hide();
    }

    final overlay = _findOverlay();
    if (overlay == null) return;

    _isShowing = true;
    _overlayEntry = OverlayEntry(
      builder: (_) => Positioned(
        top: MediaQuery.of(_).padding.top + 8,
        left: 0,
        right: 0,
        child: Material(
          color: Colors.transparent,
          child: NetworkModeCapsule(
            isOnline: isOnline,
            customMessage: customMessage,
            onDismiss: hide,
          ),
        ),
      ),
    );

    overlay.insert(_overlayEntry!);
  }

  /// Show specific mesh event
  void showMeshEvent(MeshEvent event) {
    final message = switch (event) {
      MeshEvent.sentViaMesh => '📡 Sent via nearby device',
      MeshEvent.queued => '⏳ Queued until online',
      MeshEvent.uploadedByPeer => '☁️ Uploaded by nearby device',
      MeshEvent.delivered => '✅ Delivered',
    };

    show(
      isOnline: event == MeshEvent.delivered, 
      customMessage: message,
    );
  }

  void hide() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    _isShowing = false;
  }

  OverlayState? _findOverlay() {
    // This requires a BuildContext, so we need to pass it differently
    // For now, return null and handle in actual usage
    return null;
  }
}

/// Mesh events for capsule display
enum MeshEvent {
  sentViaMesh,
  queued,
  uploadedByPeer,
  delivered,
}

/// Widget that shows capsule on network mode changes
class NetworkModeListener extends StatefulWidget {
  final Widget child;

  const NetworkModeListener({super.key, required this.child});

  @override
  State<NetworkModeListener> createState() => _NetworkModeListenerState();
}

class _NetworkModeListenerState extends State<NetworkModeListener> {
  OverlayEntry? _capsuleEntry;

  @override
  void initState() {
    super.initState();
    MeshRouter.instance.addNetworkModeListener(_onNetworkModeChange);
  }

  @override
  void dispose() {
    MeshRouter.instance.removeNetworkModeListener(_onNetworkModeChange);
    _capsuleEntry?.remove();
    super.dispose();
  }

  void _onNetworkModeChange(bool isOnline) {
    _showCapsule(isOnline: isOnline);
  }

  void _showCapsule({required bool isOnline, String? customMessage}) {
    _capsuleEntry?.remove();

    _capsuleEntry = OverlayEntry(
      builder: (_) => Positioned(
        top: MediaQuery.of(context).padding.top + 8,
        left: 0,
        right: 0,
        child: Material(
          color: Colors.transparent,
          child: NetworkModeCapsule(
            isOnline: isOnline,
            customMessage: customMessage,
            onDismiss: () {
              _capsuleEntry?.remove();
              _capsuleEntry = null;
            },
          ),
        ),
      ),
    );

    Overlay.of(context).insert(_capsuleEntry!);
  }

  /// Show mesh event from anywhere
  void showMeshEvent(MeshEvent event) {
    final message = switch (event) {
      MeshEvent.sentViaMesh => '📡 Sent via nearby device',
      MeshEvent.queued => '⏳ Queued until online',
      MeshEvent.uploadedByPeer => '☁️ Uploaded by nearby device',
      MeshEvent.delivered => '✅ Delivered',
    };

    _showCapsule(isOnline: event == MeshEvent.delivered, customMessage: message);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
