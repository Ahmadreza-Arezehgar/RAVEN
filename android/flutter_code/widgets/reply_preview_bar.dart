import 'package:flutter/material.dart';
import 'dart:ui';
import '../models/message_model.dart';

/// ✅ Liquid Glass Reply Preview Bar
/// Shows above composer when replying to a message
class ReplyPreviewBar extends StatelessWidget {
  final ChatMessage message;
  final VoidCallback onCancel;

  const ReplyPreviewBar({
    super.key,
    required this.message,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      tween: Tween(begin: 0, end: 1),
      builder: (context, value, child) {
        return Transform.translate(
          offset: Offset(0, 20 * (1 - value)),
          child: Opacity(opacity: value, child: child),
        );
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            margin: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: Colors.white.withOpacity(0.10),
              border: Border.all(color: Colors.white.withOpacity(0.14)),
            ),
            child: Row(
              children: [
                // Accent strip
                Container(
                  width: 3,
                  height: 36,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(2),
                    color: Colors.white.withOpacity(0.55),
                  ),
                ),
                const SizedBox(width: 10),
                
                // Type icon
                Icon(
                  _getTypeIcon(),
                  size: 16,
                  color: Colors.white.withOpacity(0.6),
                ),
                const SizedBox(width: 8),
                
                // Content: sender + preview
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        message.senderName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _getPreviewText(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.7),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                
                const SizedBox(width: 10),
                
                // Close button
                GestureDetector(
                  onTap: onCancel,
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withOpacity(0.10),
                    ),
                    child: Icon(
                      Icons.close,
                      size: 16,
                      color: Colors.white.withOpacity(0.8),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData _getTypeIcon() {
    switch (message.type) {
      case MessageType.voice:
        return Icons.mic;
      case MessageType.image:
        return Icons.photo;
      case MessageType.file:
        return Icons.insert_drive_file;
      default:
        return Icons.chat_bubble_outline;
    }
  }

  String _getPreviewText() {
    switch (message.type) {
      case MessageType.voice:
        return '🎤 Voice message';
      case MessageType.image:
        return '🖼 Photo';
      case MessageType.file:
        return '📄 ${message.fileName ?? "Document"}';
      default:
        final text = message.text;
        return text.length > 50 ? '${text.substring(0, 50)}...' : text;
    }
  }
}
