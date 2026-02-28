import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/modern_theme.dart';
import '../widgets/upload_progress_banner.dart'; // UploadStatus enum

/// Liquid Glass "RaveShot" pill chip for snap photo messages.
///
/// A compact, frosted-glass capsule that replaces bulky image bubbles
/// for one-time-view snap photos. Tapping opens the SnapViewer.
class RaveShotChip extends StatefulWidget {
  final bool isMe;
  final DateTime timestamp;
  final String statusText; // 'sent', 'delivered', 'read', 'pending'
  final VoidCallback? onTap;

  // Upload progress (optimistic UI)
  final double? uploadProgress; // 0.0–1.0 while uploading
  final UploadStatus? uploadStatus; // null = complete
  final VoidCallback? onRetry;

  const RaveShotChip({
    super.key,
    required this.isMe,
    required this.timestamp,
    this.statusText = 'sent',
    this.onTap,
    this.uploadProgress,
    this.uploadStatus,
    this.onRetry,
  });

  @override
  State<RaveShotChip> createState() => _RaveShotChipState();
}

class _RaveShotChipState extends State<RaveShotChip>
    with SingleTickerProviderStateMixin {
  bool _pressed = false;

  // ── Spec Constants ──
  static const double _height = 40;
  static const double _radius = 20; // half height → full pill
  static const double _hPad = 15;
  static const double _iconSize = 17;
  static const double _gap = 8;
  static const double _fontSize = 15.5;
  static const double _progressSize = 15;

  // ── Colours ──
  static const Color _tint = Color(0xFF4B63FF); // blue-purple
  static const double _tintOpacity = 0.24;
  static const double _borderOpacity = 0.14;
  static const double _textOpacity = 0.92;

  @override
  Widget build(BuildContext context) {
    final isUploading =
        widget.uploadStatus != null && widget.uploadStatus != UploadStatus.sent;
    final isFailed = widget.uploadStatus == UploadStatus.failed;

    return Align(
      alignment: widget.isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: EdgeInsets.only(
          left: widget.isMe ? 60 : ModernTheme.spacing16,
          right: widget.isMe ? ModernTheme.spacing16 : 60,
          bottom: ModernTheme.spacing8,
        ),
        child: Column(
          crossAxisAlignment:
              widget.isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // ───── The Pill ─────
            GestureDetector(
              onTapDown: (_) => setState(() => _pressed = true),
              onTapUp: (_) {
                setState(() => _pressed = false);
                HapticFeedback.lightImpact();
                if (isFailed) {
                  widget.onRetry?.call();
                } else if (!isUploading) {
                  widget.onTap?.call();
                }
              },
              onTapCancel: () => setState(() => _pressed = false),
              child: AnimatedScale(
                scale: _pressed ? 0.98 : 1.0,
                duration: const Duration(milliseconds: 120),
                curve: Curves.easeOutCubic,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(_radius),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                    child: Container(
                      height: _height,
                      padding:
                          const EdgeInsets.symmetric(horizontal: _hPad),
                      decoration: BoxDecoration(
                        color: _tint.withOpacity(_tintOpacity),
                        borderRadius: BorderRadius.circular(_radius),
                        border: Border.all(
                          color: Colors.white.withOpacity(_borderOpacity),
                          width: 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.12),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Icon
                          Icon(
                            Icons.camera_alt_outlined,
                            size: _iconSize,
                            color: Colors.white.withOpacity(_textOpacity),
                          ),
                          const SizedBox(width: _gap),
                          // Label
                          Text(
                            'RaveShot',
                            style: TextStyle(
                              fontFamily: ModernTheme.fontFamily,
                              fontSize: _fontSize,
                              fontWeight: FontWeight.w600,
                              color:
                                  Colors.white.withOpacity(_textOpacity),
                              letterSpacing: -0.2,
                            ),
                          ),
                          // Upload progress indicator
                          if (isUploading && !isFailed) ...[
                            const SizedBox(width: 10),
                            SizedBox(
                              width: _progressSize,
                              height: _progressSize,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.8,
                                value: (widget.uploadProgress ?? 0) > 0
                                    ? widget.uploadProgress
                                    : null,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.white.withOpacity(0.8),
                                ),
                              ),
                            ),
                          ],
                          // Upload complete checkmark
                          if (widget.uploadStatus == UploadStatus.sent) ...[
                            const SizedBox(width: 10),
                            Icon(
                              Icons.check_circle,
                              size: _progressSize,
                              color: ModernTheme.success,
                            ),
                          ],
                          // Failed icon
                          if (isFailed) ...[
                            const SizedBox(width: 10),
                            Icon(
                              Icons.error_outline,
                              size: _progressSize,
                              color: Colors.redAccent,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // ───── Subtle Timestamp ─────
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _formatTime(widget.timestamp),
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w400,
                      color: Colors.white.withOpacity(0.38),
                    ),
                  ),
                  if (widget.isMe) ...[
                    const SizedBox(width: 4),
                    Icon(
                      _statusIcon(),
                      size: 11,
                      color: _statusColor(),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Helpers ──

  String _formatTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  IconData _statusIcon() {
    switch (widget.statusText) {
      case 'delivered':
      case 'read':
        return Icons.done_all;
      case 'sent':
        return Icons.check;
      default:
        return Icons.access_time;
    }
  }

  Color _statusColor() {
    switch (widget.statusText) {
      case 'read':
        return ModernTheme.accentBlue;
      case 'delivered':
        return Colors.white.withOpacity(0.7);
      default:
        return Colors.white.withOpacity(0.5);
    }
  }
}
