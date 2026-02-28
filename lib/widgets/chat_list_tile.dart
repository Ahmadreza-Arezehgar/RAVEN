import 'package:flutter/material.dart';
import 'package:hybrid_messenger/widgets/liquid_glass.dart';

class ChatListTile extends StatelessWidget {
  final String name;
  final String? subtitle;
  final String? avatarUrl;
  final int unreadCount;
  final DateTime? lastMessageTime;
  final bool isPinned;
  final bool isMuted;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const ChatListTile({
    super.key,
    required this.name,
    this.subtitle,
    this.avatarUrl,
    this.unreadCount = 0,
    this.lastMessageTime,
    this.isPinned = false,
    this.isMuted = false,
    this.onTap,
    this.onLongPress,
  });

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m';
    if (diff.inDays < 1) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${time.day}/${time.month}';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: LiquidGlassContainer(
        padding: const EdgeInsets.all(12),
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Stack(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl!) : null,
                child: avatarUrl == null ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?') : null,
              ),
              if (isPinned)
                Positioned(
                  top: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
                      color: Colors.amber,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.push_pin, size: 12, color: Colors.white),
                  ),
                ),
            ],
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (lastMessageTime != null)
                Text(
                  _formatTime(lastMessageTime!),
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withOpacity(0.6),
                  ),
                ),
            ],
          ),
          subtitle: Row(
            children: [
              if (isMuted)
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Icon(Icons.volume_off, size: 14, color: Colors.grey),
                ),
              Expanded(
                child: Text(
                  subtitle ?? '',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white.withOpacity(0.7),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          trailing: unreadCount > 0
              ? Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.blue,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    unreadCount > 99 ? '99+' : '$unreadCount',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                )
              : null,
          onTap: onTap,
          onLongPress: onLongPress,
        ),
      ),
    );
  }
}
