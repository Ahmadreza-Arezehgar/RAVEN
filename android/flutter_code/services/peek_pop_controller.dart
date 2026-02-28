import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// iOS-style Peek-Pop Preview Controller
/// Long press → Peek (mini preview) → Tap → Pop (full page)
class PeekPopController {
  static final PeekPopController _instance = PeekPopController._internal();
  static PeekPopController get instance => _instance;
  PeekPopController._internal();

  OverlayEntry? _overlayEntry;
  AnimationController? _animationController;
  bool _isShowing = false;

  bool get isShowing => _isShowing;

  /// Show peek preview card at anchor position
  void showPeek({
    required BuildContext context,
    required Offset anchor,
    required Widget child,
    VoidCallback? onPop,
  }) {
    if (_isShowing) return;
    _isShowing = true;

    // Light haptic for peek
    HapticFeedback.lightImpact();

    final overlay = Overlay.of(context);
    
    _overlayEntry = OverlayEntry(
      builder: (_) => _PeekOverlay(
        anchor: anchor,
        onDismiss: () => hide(),
        onPop: () {
          HapticFeedback.mediumImpact();
          hide();
          onPop?.call();
        },
        child: child,
      ),
    );

    overlay.insert(_overlayEntry!);
  }

  /// Hide peek preview
  void hide() {
    if (!_isShowing) return;
    _isShowing = false;
    _overlayEntry?.remove();
    _overlayEntry = null;
  }
}

/// Peek Overlay Widget with animation and dismiss handling
class _PeekOverlay extends StatefulWidget {
  final Offset anchor;
  final VoidCallback onDismiss;
  final VoidCallback onPop;
  final Widget child;

  const _PeekOverlay({
    required this.anchor,
    required this.onDismiss,
    required this.onPop,
    required this.child,
  });

  @override
  State<_PeekOverlay> createState() => _PeekOverlayState();
}

class _PeekOverlayState extends State<_PeekOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );

    _scaleAnimation = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    await _controller.reverse();
    widget.onDismiss();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final safeArea = MediaQuery.of(context).padding;

    // Calculate position (center horizontally, above anchor if possible)
    const cardWidth = 280.0;
    const cardHeight = 180.0;
    
    double left = widget.anchor.dx - cardWidth / 2;
    double top = widget.anchor.dy - cardHeight - 20;

    // Clamp to screen bounds
    left = left.clamp(16.0, size.width - cardWidth - 16);
    top = top.clamp(safeArea.top + 16, size.height - cardHeight - safeArea.bottom - 16);
    
    // If above doesn't fit, show below
    if (widget.anchor.dy - cardHeight - 20 < safeArea.top + 16) {
      top = widget.anchor.dy + 60;
    }

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _dismiss,
      child: Material(
        color: Colors.transparent,
        child: Stack(
          children: [
            // Dimmed background
            AnimatedBuilder(
              animation: _fadeAnimation,
              builder: (context, _) => Container(
                color: Colors.black.withOpacity(0.3 * _fadeAnimation.value),
              ),
            ),
            
            // Preview Card
            Positioned(
              left: left,
              top: top,
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, child) => Transform.scale(
                  scale: _scaleAnimation.value,
                  child: Opacity(
                    opacity: _fadeAnimation.value,
                    child: child,
                  ),
                ),
                child: GestureDetector(
                  onTap: widget.onPop,
                  child: _buildCard(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
        child: Container(
          width: 280,
          constraints: const BoxConstraints(minHeight: 120, maxHeight: 300),
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E).withOpacity(0.85),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withOpacity(0.15),
              width: 0.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.4),
                blurRadius: 30,
                spreadRadius: 5,
              ),
            ],
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// PROFILE PEEK CARD
// ══════════════════════════════════════════════════════════════════════════

class ProfilePeekCard extends StatelessWidget {
  final String username;
  final String? avatarUrl;
  final String? bio;
  final int? followersCount;
  final VoidCallback? onMessage;
  final VoidCallback? onFollow;

  const ProfilePeekCard({
    super.key,
    required this.username,
    this.avatarUrl,
    this.bio,
    this.followersCount,
    this.onMessage,
    this.onFollow,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Avatar + Username
          Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl!) : null,
                backgroundColor: const Color(0xFF3A3A3C),
                child: avatarUrl == null
                    ? Text(
                        username.isNotEmpty ? username[0].toUpperCase() : '?',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '@$username',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (followersCount != null)
                      Text(
                        '$followersCount followers',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.5),
                          fontSize: 13,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          
          // Bio
          if (bio != null && bio!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              bio!,
              style: TextStyle(
                color: Colors.white.withOpacity(0.7),
                fontSize: 14,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          
          // Quick Actions
          const SizedBox(height: 16),
          Row(
            children: [
              if (onMessage != null)
                Expanded(
                  child: _QuickActionButton(
                    icon: Icons.message_rounded,
                    label: 'Message',
                    onTap: onMessage!,
                  ),
                ),
              if (onMessage != null && onFollow != null)
                const SizedBox(width: 8),
              if (onFollow != null)
                Expanded(
                  child: _QuickActionButton(
                    icon: Icons.person_add_rounded,
                    label: 'Follow',
                    onTap: onFollow!,
                    isPrimary: true,
                  ),
                ),
            ],
          ),
          
          // Hint
          const SizedBox(height: 12),
          Text(
            'Tap to view full profile',
            style: TextStyle(
              color: Colors.white.withOpacity(0.4),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// MESSAGE PEEK CARD
// ══════════════════════════════════════════════════════════════════════════

class MessagePeekCard extends StatelessWidget {
  final String contactName;
  final String? avatarUrl;
  final String? lastMessage;
  final DateTime? lastMessageTime;
  final int unreadCount;
  final VoidCallback? onMarkRead;
  final VoidCallback? onDelete;
  final VoidCallback? onSetNickname;
  final String? peerId;
  final String? username;

  const MessagePeekCard({
    super.key,
    required this.contactName,
    this.avatarUrl,
    this.lastMessage,
    this.lastMessageTime,
    this.unreadCount = 0,
    this.onMarkRead,
    this.onDelete,
    this.onSetNickname,
    this.peerId,
    this.username,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Avatar + Name
          Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl!) : null,
                backgroundColor: const Color(0xFF3A3A3C),
                child: avatarUrl == null
                    ? Text(
                        contactName.isNotEmpty ? contactName[0].toUpperCase() : '?',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      contactName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (lastMessageTime != null)
                      Text(
                        _formatTime(lastMessageTime!),
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.5),
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
              if (unreadCount > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A84FF),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    unreadCount > 99 ? '99+' : unreadCount.toString(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          
          // Last Message Preview
          if (lastMessage != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                lastMessage!,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.8),
                  fontSize: 14,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          
          // Quick Actions
          const SizedBox(height: 16),
          Row(
            children: [
              // Nickname button
              if (onSetNickname != null)
                Expanded(
                  child: _QuickActionButton(
                    icon: Icons.edit_rounded,
                    label: 'Nickname',
                    onTap: onSetNickname!,
                  ),
                ),
              if (onSetNickname != null && (onMarkRead != null || onDelete != null))
                const SizedBox(width: 8),
              if (onMarkRead != null && unreadCount > 0)
                Expanded(
                  child: _QuickActionButton(
                    icon: Icons.check_rounded,
                    label: 'Read',
                    onTap: onMarkRead!,
                  ),
                ),
              if (onMarkRead != null && unreadCount > 0 && onDelete != null)
                const SizedBox(width: 8),
              if (onDelete != null)
                Expanded(
                  child: _QuickActionButton(
                    icon: Icons.delete_outline_rounded,
                    label: 'Delete',
                    onTap: onDelete!,
                    isDestructive: true,
                  ),
                ),
            ],
          ),
          
          // Hint
          const SizedBox(height: 12),
          Text(
            'Tap to open chat',
            style: TextStyle(
              color: Colors.white.withOpacity(0.4),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${time.day}/${time.month}';
  }
}

// ══════════════════════════════════════════════════════════════════════════
// QUICK ACTION BUTTON
// ══════════════════════════════════════════════════════════════════════════

class _QuickActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isPrimary;
  final bool isDestructive;

  const _QuickActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isPrimary = false,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor = isPrimary
        ? const Color(0xFF0A84FF)
        : isDestructive
            ? const Color(0xFFFF3B30).withOpacity(0.2)
            : Colors.white.withOpacity(0.1);
    
    final fgColor = isDestructive
        ? const Color(0xFFFF3B30)
        : Colors.white;

    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: fgColor),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: fgColor,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
