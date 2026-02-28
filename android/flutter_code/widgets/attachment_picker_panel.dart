import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Attachment type enum
enum AttachmentType { image, file, schedule }

/// Attachment picker result
class AttachmentPickerResult {
  final AttachmentType type;
  
  AttachmentPickerResult(this.type);
}

/// Liquid Glass Attachment Picker Panel
/// Shows Image/File options with beautiful capsule animation
class AttachmentPickerPanel {
  static OverlayEntry? _entry;
  
  /// Show the attachment picker anchored to a widget
  static void show({
    required BuildContext context,
    required GlobalKey anchorKey,
    required Function(AttachmentType) onSelect,
  }) {
    hide();
    HapticFeedback.mediumImpact();
    
    // Get anchor position
    final RenderBox? renderBox = anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    
    final anchorOffset = renderBox.localToGlobal(Offset.zero);
    final anchorSize = renderBox.size;
    
    _entry = OverlayEntry(
      builder: (_) => _AttachmentPickerOverlay(
        anchorOffset: anchorOffset,
        anchorSize: anchorSize,
        onSelect: (type) {
          hide();
          // Delay to let close animation complete
          Future.delayed(const Duration(milliseconds: 150), () {
            onSelect(type);
          });
        },
        onClose: hide,
      ),
    );
    
    Overlay.of(context).insert(_entry!);
  }
  
  static void hide() {
    _entry?.remove();
    _entry = null;
  }
}

class _AttachmentPickerOverlay extends StatefulWidget {
  final Offset anchorOffset;
  final Size anchorSize;
  final Function(AttachmentType) onSelect;
  final VoidCallback onClose;
  
  const _AttachmentPickerOverlay({
    required this.anchorOffset,
    required this.anchorSize,
    required this.onSelect,
    required this.onClose,
  });
  
  @override
  State<_AttachmentPickerOverlay> createState() => _AttachmentPickerOverlayState();
}

class _AttachmentPickerOverlayState extends State<_AttachmentPickerOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnim;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;
  
  @override
  void initState() {
    super.initState();
    
    _controller = AnimationController(
      duration: const Duration(milliseconds: 350),
      vsync: this,
    );
    
    // Spring-like scale animation
    _scaleAnim = CurvedAnimation(
      parent: _controller,
      curve: Curves.elasticOut,
    );
    
    // Fade animation
    _fadeAnim = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    );
    
    // Slide from bottom animation
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.3),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    ));
    
    _controller.forward();
  }
  
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
  
  void _close() async {
    await _controller.reverse();
    widget.onClose();
  }
  
  @override
  Widget build(BuildContext context) {
    // Position panel above the anchor (+ button)
    const double panelWidth = 60;
    const double panelHeight = 185; // 3 items * 54 + padding + dividers
    
    // Calculate position - above and centered on anchor
    final double left = widget.anchorOffset.dx + (widget.anchorSize.width / 2) - (panelWidth / 2);
    final double bottom = MediaQuery.of(context).size.height - widget.anchorOffset.dy + 12;
    
    return Stack(
      children: [
        // Dismiss overlay
        Positioned.fill(
          child: GestureDetector(
            onTap: _close,
            behavior: HitTestBehavior.opaque,
            child: Container(color: Colors.transparent),
          ),
        ),
        
        // Capsule panel
        Positioned(
          left: left,
          bottom: bottom,
          child: FadeTransition(
            opacity: _fadeAnim,
            child: SlideTransition(
              position: _slideAnim,
              child: ScaleTransition(
                scale: _scaleAnim,
                alignment: Alignment.bottomCenter,
                child: _buildCapsulePanel(),
              ),
            ),
          ),
        ),
      ],
    );
  }
  
  Widget _buildCapsulePanel() {
    return Container(
      width: 60,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.4),
            blurRadius: 24,
            offset: const Offset(0, 8),
            spreadRadius: -4,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(30),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E).withOpacity(0.85),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(
                color: Colors.white.withOpacity(0.15),
                width: 0.5,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Image option
                _buildOption(
                  icon: Icons.photo_library_rounded,
                  color: const Color(0xFF0A84FF),
                  onTap: () => widget.onSelect(AttachmentType.image),
                ),
                
                // Divider
                Container(
                  height: 0.5,
                  width: 30,
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  color: Colors.white.withOpacity(0.1),
                ),
                
                // File option
                _buildOption(
                  icon: Icons.insert_drive_file_rounded,
                  color: const Color(0xFFFF9F0A),
                  onTap: () => widget.onSelect(AttachmentType.file),
                ),
                
                // Divider
                Container(
                  height: 0.5,
                  width: 30,
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  color: Colors.white.withOpacity(0.1),
                ),
                
                // ✅ Schedule option
                _buildOption(
                  icon: Icons.schedule_rounded,
                  color: const Color(0xFF32D74B), // Green like iOS timer
                  onTap: () => widget.onSelect(AttachmentType.schedule),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
  
  Widget _buildOption({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          shape: BoxShape.circle,
          border: Border.all(
            color: color.withOpacity(0.3),
            width: 0.5,
          ),
        ),
        child: Icon(
          icon,
          color: color,
          size: 22,
        ),
      ),
    );
  }
}
