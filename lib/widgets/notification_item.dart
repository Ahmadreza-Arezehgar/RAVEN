import 'dart:io';
import 'package:flutter/material.dart';
import '../models/notification_model.dart';
import '../theme/ios_design_system.dart';

/// Notification Item Widget
class NotificationItem extends StatelessWidget {
  final AppNotification notification;
  final VoidCallback? onTap;
  final VoidCallback? onDismiss;
  final VoidCallback? onAccept; // برای friend request
  final VoidCallback? onDecline; // برای friend request
  
  const NotificationItem({
    super.key,
    required this.notification,
    this.onTap,
    this.onDismiss,
    this.onAccept,
    this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: Key(notification.id),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDismiss?.call(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: Colors.red.withOpacity(0.8),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      child: Container(
        margin: const EdgeInsets.symmetric(
          horizontal: iOSDesignSystem.spacing16,
          vertical: iOSDesignSystem.spacing8,
        ),
        decoration: iOSDesignSystem.cardDecoration(),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              onTap?.call();
            },
            borderRadius: BorderRadius.circular(iOSDesignSystem.radiusCard),
            child: Padding(
              padding: const EdgeInsets.all(iOSDesignSystem.spacing16),
              child: Row(
                children: [
                  // Avatar/Icon
                  _buildIcon(),
                  
                  const SizedBox(width: iOSDesignSystem.spacing12),
                  
                  // Content
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          notification.title,
                          style: iOSDesignSystem.textTheme.headlineMedium?.copyWith(
                            color: notification.isRead 
                                ? iOSDesignSystem.textSecondary
                                : iOSDesignSystem.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          notification.body,
                          style: iOSDesignSystem.textTheme.bodyMedium?.copyWith(
                            color: iOSDesignSystem.textSecondary,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _formatTime(notification.timestamp),
                          style: iOSDesignSystem.textTheme.labelMedium,
                        ),
                        
                        // Action buttons برای friend request
                        if (notification.type == NotificationType.friendRequest && !notification.isRead)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Row(
                              children: [
                                // Accept button (سبز)
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: onAccept,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: iOSDesignSystem.success,
                                      foregroundColor: Colors.white,
                                      elevation: 0,
                                      padding: const EdgeInsets.symmetric(vertical: 8),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                    ),
                                    child: const Text('Accept', style: TextStyle(fontWeight: FontWeight.w600)),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                // Decline button (قرمز)
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: onDecline,
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.red,
                                      side: const BorderSide(color: Colors.red),
                                      padding: const EdgeInsets.symmetric(vertical: 8),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                    ),
                                    child: const Text('Decline', style: TextStyle(fontWeight: FontWeight.w600)),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  
                  // Unread indicator
                  if (!notification.isRead)
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: iOSDesignSystem.accentBlue,
                        shape: BoxShape.circle,
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
  
  Widget _buildIcon() {
    // Avatar یا Icon بسته به نوع
    if (notification.avatarPath != null) {
      return CircleAvatar(
        radius: 24,
        backgroundImage: FileImage(File(notification.avatarPath!)),
      );
    }
    
    IconData icon;
    Color color;
    
    switch (notification.type) {
      case NotificationType.message:
        icon = Icons.chat_bubble;
        color = iOSDesignSystem.accentBlue;
        break;
      case NotificationType.friendRequest:
        icon = Icons.person_add;
        color = iOSDesignSystem.success;
        break;
      case NotificationType.friendRequestSent:
        icon = Icons.check_circle_outline;
        color = iOSDesignSystem.accentBlue;
        break;
      case NotificationType.mention:
        icon = Icons.alternate_email;
        color = const Color(0xFFFF9500);
        break;
      case NotificationType.like:
        icon = Icons.favorite;
        color = iOSDesignSystem.accentPink;
        break;
      case NotificationType.comment:
        icon = Icons.comment;
        color = const Color(0xFF5E5CE6);
        break;
      case NotificationType.presence:
        icon = Icons.location_on_rounded;
        color = iOSDesignSystem.success; // Green for presence
        break;
      case NotificationType.deadDrop:
        icon = Icons.archive_rounded;
        color = const Color(0xFFFF9F0A); // Amber for dead drops
        break;
      case NotificationType.security:
        icon = Icons.security_rounded;
        color = const Color(0xFFFF9500); // Orange for security
        break;
    }
    
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: color, size: 24),
    );
  }
  
  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${(diff.inDays / 7).floor()}w ago';
  }
}
