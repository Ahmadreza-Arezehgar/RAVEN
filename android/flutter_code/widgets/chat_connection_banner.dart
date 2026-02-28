import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

enum ChatLink { wifi, cellular, mesh, offline }

String linkLabel(ChatLink link) {
  switch (link) {
    case ChatLink.wifi:
      return 'Connected via Wi-Fi';
    case ChatLink.cellular:
      return 'Connected via Cellular';
    case ChatLink.mesh:
      return 'Connected via Mesh';
    case ChatLink.offline:
      return 'Reconnecting…';
  }
}

/// Liquid Glass Connection Status Banner
/// Shows connection type (Wi-Fi/Mesh/Cellular) below AppBar
class ChatConnectionBanner extends StatefulWidget {
  /// Override link type (e.g., for mesh detection)
  final ChatLink? overrideLink;

  /// When true, banner will show on connection changes
  final bool isStreaming;

  const ChatConnectionBanner({
    super.key,
    this.overrideLink,
    required this.isStreaming,
  });

  @override
  State<ChatConnectionBanner> createState() => _ChatConnectionBannerState();
}

class _ChatConnectionBannerState extends State<ChatConnectionBanner> {
  final _connectivity = Connectivity();
  StreamSubscription? _sub;

  ChatLink _link = ChatLink.offline;
  bool _visible = false;
  Timer? _autoHide;

  @override
  void initState() {
    super.initState();
    _initStatus();
    _sub = _connectivity.onConnectivityChanged.listen((result) {
      _updateFromConnectivity(result);
    });
  }

  Future<void> _initStatus() async {
    final result = await _connectivity.checkConnectivity();
    _updateFromConnectivity(result);
  }

  void _updateFromConnectivity(ConnectivityResult result) {
    ChatLink link;

    if (widget.overrideLink != null) {
      link = widget.overrideLink!;
    } else {
      if (result == ConnectivityResult.wifi) {
        link = ChatLink.wifi;
      } else if (result == ConnectivityResult.mobile) {
        link = ChatLink.cellular;
      } else {
        link = ChatLink.offline;
      }
    }

    if (!mounted) return;  // ✅ Fix: Check mounted before setState
    setState(() => _link = link);

    if (widget.isStreaming && link != ChatLink.offline) {
      _showTemporarily();
    } else if (link == ChatLink.offline) {
      _showTemporarily(duration: const Duration(seconds: 2));
    }
  }

  void _showTemporarily({Duration duration = const Duration(milliseconds: 1500)}) {
    _autoHide?.cancel();
    if (!mounted) return;  // ✅ Fix: Check mounted before setState
    setState(() => _visible = true);

    _autoHide = Timer(duration, () {
      if (mounted) setState(() => _visible = false);
    });
  }

  @override
  void didUpdateWidget(covariant ChatConnectionBanner oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (!oldWidget.isStreaming && widget.isStreaming) {
      if (_link != ChatLink.offline) _showTemporarily();
    }
    
    // Check if override changed
    if (oldWidget.overrideLink != widget.overrideLink && widget.overrideLink != null) {
      setState(() => _link = widget.overrideLink!);
      _showTemporarily();
    }
  }

  @override
  void dispose() {
    _autoHide?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = linkLabel(_link);

    return IgnorePointer(
      ignoring: true,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        opacity: _visible ? 1 : 0,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          scale: _visible ? 1.0 : 0.92,
          child: Center(
            child: _LiquidGlassCapsule(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _StatusDot(state: _link),
                    const SizedBox(width: 8),
                    Text(
                      text,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.9),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  final ChatLink state;
  const _StatusDot({required this.state});

  @override
  Widget build(BuildContext context) {
    Color color;
    switch (state) {
      case ChatLink.wifi:
        color = const Color(0xFF34C759); // iOS green
        break;
      case ChatLink.cellular:
        color = const Color(0xFF5856D6); // iOS purple
        break;
      case ChatLink.mesh:
        color = const Color(0xFF0A84FF); // iOS blue
        break;
      case ChatLink.offline:
        color = Colors.white.withOpacity(0.35);
        break;
    }

    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          if (state != ChatLink.offline)
            BoxShadow(
              color: color.withOpacity(0.35),
              blurRadius: 10,
            ),
        ],
      ),
    );
  }
}

/// Liquid Glass Capsule (matches bottom bar style)
class _LiquidGlassCapsule extends StatelessWidget {
  final Widget child;
  const _LiquidGlassCapsule({required this.child});

  @override
  Widget build(BuildContext context) {
    const blur = 22.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E).withOpacity(0.45),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: Colors.white.withOpacity(0.10),
              width: 0.6,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.22),
                blurRadius: 18,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Stack(
            children: [
              // Sheen highlight
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Colors.white.withOpacity(0.10),
                          Colors.transparent,
                          Colors.black.withOpacity(0.05),
                        ],
                        stops: const [0.0, 0.55, 1.0],
                      ),
                    ),
                  ),
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
