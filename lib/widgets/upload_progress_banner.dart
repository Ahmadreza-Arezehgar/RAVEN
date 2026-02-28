import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:hybrid_messenger/theme/modern_theme.dart';

/// Upload status states
enum UploadStatus { uploading, sent, failed }

/// Liquid Glass styled upload progress banner
/// Shows below AppBar during file uploads with real-time progress
class UploadProgressBanner extends StatelessWidget {
  final bool visible;
  final double progress; // 0.0 to 1.0
  final String filename;
  final UploadStatus status;
  final VoidCallback? onRetry;

  const UploadProgressBanner({
    super.key,
    required this.visible,
    required this.progress,
    required this.filename,
    required this.status,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      offset: visible ? Offset.zero : const Offset(0, -0.5),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 220),
        opacity: visible ? 1 : 0,
        child: IgnorePointer(
          ignoring: !visible,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    color: _getBackgroundColor(),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.14),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.2),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header row: icon + filename + retry button
                      Row(
                        children: [
                          Icon(
                            _getIcon(),
                            size: 18,
                            color: _getIconColor(),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              filename,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          if (status == UploadStatus.failed && onRetry != null)
                            GestureDetector(
                              onTap: onRetry,
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(
                                  Icons.refresh,
                                  size: 18,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      // Progress bar
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: LinearProgressIndicator(
                          value: status == UploadStatus.sent ? 1.0 : progress.clamp(0.0, 1.0),
                          minHeight: 6,
                          backgroundColor: Colors.white.withOpacity(0.10),
                          valueColor: AlwaysStoppedAnimation<Color>(_getProgressColor()),
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Status text
                      Text(
                        _getStatusText(),
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.75),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Color _getBackgroundColor() {
    switch (status) {
      case UploadStatus.sent:
        return ModernTheme.success.withOpacity(0.15);
      case UploadStatus.failed:
        return Colors.red.withOpacity(0.15);
      case UploadStatus.uploading:
        return Colors.white.withOpacity(0.08);
    }
  }

  IconData _getIcon() {
    switch (status) {
      case UploadStatus.sent:
        return Icons.check_circle;
      case UploadStatus.failed:
        return Icons.error;
      case UploadStatus.uploading:
        return Icons.upload_file;
    }
  }

  Color _getIconColor() {
    switch (status) {
      case UploadStatus.sent:
        return ModernTheme.success;
      case UploadStatus.failed:
        return Colors.redAccent;
      case UploadStatus.uploading:
        return Colors.white;
    }
  }

  Color _getProgressColor() {
    switch (status) {
      case UploadStatus.sent:
        return ModernTheme.success;
      case UploadStatus.failed:
        return Colors.redAccent;
      case UploadStatus.uploading:
        return ModernTheme.accentBlue;
    }
  }

  String _getStatusText() {
    switch (status) {
      case UploadStatus.sent:
        return 'Sent ✓';
      case UploadStatus.failed:
        return 'Failed – Tap to retry';
      case UploadStatus.uploading:
        return '${(progress * 100).toStringAsFixed(0)}% • Uploading…';
    }
  }
}
