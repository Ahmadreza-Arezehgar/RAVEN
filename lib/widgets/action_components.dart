import 'package:flutter/material.dart';
import '../theme/mobile_theme.dart';

/// Follow/Friend button with multiple states
class FollowButton extends StatefulWidget {
  final FollowStatus status;
  final VoidCallback? onPressed;
  final bool compact;
  
  const FollowButton({
    super.key,
    required this.status,
    this.onPressed,
    this.compact = false,
  });

  @override
  State<FollowButton> createState() => _FollowButtonState();
}

class _FollowButtonState extends State<FollowButton> 
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTap() {
    _controller.forward().then((_) => _controller.reverse());
    widget.onPressed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    Color backgroundColor;
    Color foregroundColor;
    IconData? icon;
    String label;
    
    switch (widget.status) {
      case FollowStatus.notFollowing:
        backgroundColor = MobileTheme.brandPrimary;
        foregroundColor = Colors.white;
        icon = Icons.person_add_outlined;
        label = widget.compact ? 'Add' : 'Add Friend';
        break;
      case FollowStatus.pending:
        backgroundColor = isDark ? MobileTheme.darkSurface : MobileTheme.lightDivider;
        foregroundColor = MobileTheme.textSecondary(isDark);
        icon = Icons.schedule_outlined;
        label = widget.compact ? 'Sent' : 'Request Sent';
        break;
      case FollowStatus.following:
        backgroundColor = isDark ? MobileTheme.darkSurface : MobileTheme.lightDivider;
        foregroundColor = MobileTheme.textPrimary(isDark);
        icon = Icons.check;
        label = widget.compact ? 'Friends' : 'Friends';
        break;
    }
    
    return ScaleTransition(
      scale: _scaleAnimation,
      child: widget.compact
          ? _buildCompactButton(backgroundColor, foregroundColor, icon, label)
          : _buildFullButton(backgroundColor, foregroundColor, icon, label),
    );
  }
  
  Widget _buildFullButton(
    Color backgroundColor,
    Color foregroundColor,
    IconData? icon,
    String label,
  ) {
    return ElevatedButton.icon(
      onPressed: widget.status != FollowStatus.pending ? _handleTap : null,
      style: ElevatedButton.styleFrom(
        backgroundColor: backgroundColor,
        foregroundColor: foregroundColor,
        elevation: 0,
        padding: const EdgeInsets.symmetric(
          horizontal: MobileTheme.spacing20,
          vertical: MobileTheme.spacing12,
        ),
      ),
      icon: icon != null ? Icon(icon, size: MobileTheme.iconSizeSmall) : const SizedBox.shrink(),
      label: Text(label),
    );
  }
  
  Widget _buildCompactButton(
    Color backgroundColor,
    Color foregroundColor,
    IconData? icon,
    String label,
  ) {
    return ElevatedButton(
      onPressed: widget.status != FollowStatus.pending ? _handleTap : null,
      style: ElevatedButton.styleFrom(
        backgroundColor: backgroundColor,
        foregroundColor: foregroundColor,
        elevation: 0,
        padding: const EdgeInsets.symmetric(
          horizontal: MobileTheme.spacing16,
          vertical: MobileTheme.spacing8,
        ),
        minimumSize: const Size(80, 36),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    );
  }
}

enum FollowStatus {
  notFollowing,
  pending,
  following,
}

/// Reaction bar for posts and comments
class ReactionBar extends StatelessWidget {
  final int likes;
  final int comments;
  final int? shares;
  final bool isLiked;
  final VoidCallback? onLike;
  final VoidCallback? onComment;
  final VoidCallback? onShare;
  final VoidCallback? onSave;
  
  const ReactionBar({
    super.key,
    required this.likes,
    required this.comments,
    this.shares,
    this.isLiked = false,
    this.onLike,
    this.onComment,
    this.onShare,
    this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Row(
      children: [
        // Like
        _ActionButton(
          icon: isLiked ? Icons.favorite : Icons.favorite_border,
          label: MobileTheme.formatCount(likes),
          color: isLiked ? MobileTheme.likeColor : MobileTheme.textSecondary(isDark),
          onPressed: onLike,
        ),
        
        const SizedBox(width: MobileTheme.spacing4),
        
        // Comment
        _ActionButton(
          icon: Icons.chat_bubble_outline,
          label: MobileTheme.formatCount(comments),
          color: MobileTheme.textSecondary(isDark),
          onPressed: onComment,
        ),
        
        if (shares != null) ...[
          const SizedBox(width: MobileTheme.spacing4),
          _ActionButton(
            icon: Icons.share_outlined,
            label: MobileTheme.formatCount(shares!),
            color: MobileTheme.textSecondary(isDark),
            onPressed: onShare,
          ),
        ],
        
        const Spacer(),
        
        // Save (optional)
        if (onSave != null)
          IconButton(
            icon: const Icon(Icons.bookmark_border),
            iconSize: MobileTheme.iconSize,
            color: MobileTheme.textSecondary(isDark),
            onPressed: onSave,
            tooltip: 'Save',
          ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onPressed;
  
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(MobileTheme.radiusFull),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MobileTheme.spacing12,
          vertical: MobileTheme.spacing8,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: MobileTheme.iconSize, color: color),
            const SizedBox(width: MobileTheme.spacing4),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Stats display widget
class StatsWidget extends StatelessWidget {
  final int count;
  final String label;
  final VoidCallback? onTap;
  
  const StatsWidget({
    super.key,
    required this.count,
    required this.label,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(MobileTheme.radiusSmall),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MobileTheme.spacing8,
          vertical: MobileTheme.spacing4,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              MobileTheme.formatCount(count),
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: MobileTheme.textPrimary(isDark),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: MobileTheme.textSecondary(isDark),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
