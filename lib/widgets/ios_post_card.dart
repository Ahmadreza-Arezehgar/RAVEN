import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../theme/ios_design_system.dart';
import '../models/post_model.dart';  // For Post and PostSendMethod
import '../utils/datetime_utils.dart';
import '../utils/hashtag_utils.dart';
import '../screens/hashtag_feed_page.dart';
import '../screens/post_detail_screen.dart';
import '../screens/user_profile_page.dart';
import '../widgets/liquid_glass_card.dart';
import '../services/peek_pop_controller.dart';
import '../services/api_service.dart';  // ✅ Added for view recording
import '../services/view_tracker_service.dart';  // ✅ Shared session dedup
import '../main.dart';

// ✅ Use shared ViewTrackerService instead of local Set
// final Set<String> _viewedPostsThisSession = {}; // REMOVED - now using ViewTrackerService

/// iOS-style Post Card with proper elevation
class iOSPostCard extends StatefulWidget {  // ✅ Changed to StatefulWidget
  final Post post;
  final VoidCallback? onTap;
  final VoidCallback? onLike;
  final VoidCallback? onComment;
  final VoidCallback? onForward;  // Replaced onRepost with onForward
  final VoidCallback? onLongPress;  // For edit/delete (owner only)
  final bool isLiked;
  
  const iOSPostCard({
    super.key,
    required this.post,
    this.onTap,
    this.onLike,
    this.onComment,
    this.onForward,  // Changed from onRepost
    this.onLongPress,
    this.isLiked = false,
  });

  @override
  State<iOSPostCard> createState() => _iOSPostCardState();
}

class _iOSPostCardState extends State<iOSPostCard> {
  bool _viewRecorded = false;
  
  @override
  void initState() {
    super.initState();
    // Record view when card is first displayed in feed (if not already done this session)
    _recordViewIfNeeded();
  }
  
  /// Record unique view (once per session, deduped via ViewTrackerService)
  /// Only for posts that exist on server (sendMethod == wifi)
  void _recordViewIfNeeded() {
    if (_viewRecorded) return;
    
    // ✅ Skip posts that don't exist on server (mesh/local posts)
    // Posts sent via bluetooth or local don't sync to server → would get 404
    if (widget.post.sendMethod != PostSendMethod.wifi) {
      print('👁️ [VIEW] Skipping view for mesh/local post ${widget.post.id.substring(0, 8)}... (sendMethod=${widget.post.sendMethod.name})');
      _viewRecorded = true;
      return;
    }
    
    // ✅ Capture postId BEFORE async operation to avoid accessing disposed widget
    final postId = widget.post.id;
    
    // ✅ Use shared ViewTrackerService for session dedup
    if (!ViewTrackerService.instance.shouldRecordView(postId)) {
      _viewRecorded = true;  // Don't try again
      return;
    }
    
    _viewRecorded = true;
    
    // Fire and forget - don't block UI
    // ✅ Use captured postId, not widget.post.id (widget might be disposed)
    ApiService.recordPostView(postId).then((count) {
      // ✅ Double check mounted before any state access
      if (!mounted) return;
      if (count != null) {
        print('👁️ View recorded for post ${postId.substring(0, 8)}... (count: $count)');
        // ✅ Sync to AppModel so ALL widgets showing this post update
        // This ensures feed cards update when returning from detail screen
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final model = Provider.of<AppModel>(context, listen: false);
          model.updateViewCount(postId, count);
        });
      }
    }).catchError((e) {
      print('❌ Record view failed: $e');
    });
  }
  
  /// Helper to get avatar image provider (URL or local file)
  ImageProvider? _getAvatarImage(String? avatarPath) {
    if (avatarPath == null || avatarPath.isEmpty) return null;
    
    // Check if it's a URL
    if (avatarPath.startsWith('http://') || avatarPath.startsWith('https://')) {
      return NetworkImage(avatarPath);
    }
    
    // It's a local file path
    final file = File(avatarPath);
    if (file.existsSync()) {
      return FileImage(file);
    }
    
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final post = widget.post;  // ✅ Use widget.post
    return Column(
      children: [
        // ✅ GestureDetector on entire card -> Opens Comments, Long-press -> Owner Actions
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            HapticFeedback.selectionClick();
            // Navigate to post detail/comments
            Navigator.of(context).push(fadeScaleRoute(
              PostDetailScreen(post: post),
            ));
          },
          onLongPress: widget.onLongPress,  // Owner actions (Edit/Delete)
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left Column: Avatar with tap -> Profile, long-press -> Peek
                GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    // Navigate to user profile
                    Navigator.of(context).push(fadeScaleRoute(
                      UserProfilePage(userId: post.authorId),
                    ));
                  },
                  onLongPressStart: (details) {
                    // Show profile peek preview
                    PeekPopController.instance.showPeek(
                      context: context,
                      anchor: details.globalPosition,
                      onPop: () {
                        // Pop to full profile
                        Navigator.of(context).push(fadeScaleRoute(
                          UserProfilePage(userId: post.authorId),
                        ));
                      },
                      child: ProfilePeekCard(
                        username: post.authorName,
                        avatarUrl: post.authorAvatar,
                        bio: null, // Will show when tapped
                        onMessage: () {
                          PeekPopController.instance.hide();
                          // Start chat with this user
                          final model = Provider.of<AppModel>(context, listen: false);
                          model.startChatWith(post.authorId, post.authorName);
                          Navigator.of(context).pushNamed('/chat');
                        },
                      ),
                    );
                  },
                  child: Container(
                    margin: const EdgeInsets.only(right: 12),
                    child: Hero(
                      tag: 'avatar_${post.authorId}',
                      child: CircleAvatar(
                        radius: 20,
                        backgroundColor: iOSDesignSystem.surfaceElevated,
                        backgroundImage: _getAvatarImage(post.authorAvatar),
                        child: post.authorAvatar == null
                            ? Text(
                                post.authorName.isNotEmpty 
                                    ? post.authorName[0].toUpperCase() 
                                    : 'U',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: iOSDesignSystem.textPrimary,
                                  fontSize: 16,
                                ),
                              )
                            : null,
                      ),
                    ),
                  ),
                ),
              
              // Right Column: Content
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header Row: Name + @username + time (no 3-dot menu per design)
                    Row(
                      children: [
                        // Display Name (SemiBold)
                        Text(
                          post.authorName,
                          style: iOSDesignSystem.textTheme.bodyLarge?.copyWith(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,  // SemiBold
                            letterSpacing: -0.3,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        
                        const SizedBox(width: 4),
                        
                        // @username (lighter)
                        Flexible(
                          child: Text(
                            '@${post.authorName.toLowerCase()}',
                            style: TextStyle(
                              fontSize: 14,  // Smaller for hierarchy
                              fontWeight: FontWeight.w400,
                              color: iOSDesignSystem.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        
                        // Separator
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text(
                            '·',
                            style: TextStyle(
                              fontSize: 14,
                              color: iOSDesignSystem.textSecondary,
                            ),
                          ),
                        ),
                        
                        // Time
                        Text(
                          DateTimeUtils.formatFullTimestamp(post.timestamp),
                          style: TextStyle(
                            fontSize: 14,  // Smaller for hierarchy
                            color: iOSDesignSystem.textSecondary,
                          ),
                        ),
                        
                        // Edited indicator (if post was edited)
                        if (post.editedAt != null) ...[
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Text(
                              _formatEditedLabel(post.editedAt!),
                              style: TextStyle(
                                fontSize: 12,
                                fontStyle: FontStyle.italic,
                                color: iOSDesignSystem.textTertiary,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    
                    const SizedBox(height: 4),
                    
                    // Body: Post content with clickable hashtags
                    Builder(
                      builder: (context) {
                        return buildHashtagRichText(
                          text: post.content,
                          baseStyle: iOSDesignSystem.textTheme.bodyMedium?.copyWith(
                            fontSize: 15,
                            fontWeight: FontWeight.w400,
                            height: 1.4,
                            color: iOSDesignSystem.textPrimary,
                          ) ?? const TextStyle(color: Colors.white),
                          onHashtagTap: (tag) {
                            HapticFeedback.selectionClick();
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => HashtagFeedPage(hashtag: tag),
                              ),
                            );
                          },
                          onMentionTap: (username) {
                            HapticFeedback.selectionClick();
                            // TODO: Navigate to user profile
                          },
                          maxLines: _getMaxLines(post.content),
                          overflow: TextOverflow.fade,
                        );
                      },
                    ),
                    
                    // Image (if exists)
                    if (post.imageUrl != null && post.imageUrl!.isNotEmpty) ...[ 
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: _buildPostImage(post.imageUrl!),
                      ),
                    ],
                    
                    const SizedBox(height: 12),
                    
                    // Action Row: Comment / Like / Views / Forward (no Repost, no Share)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Comment
                        _ActionButton(
                          icon: Icons.chat_bubble_outline,
                          count: post.comments,
                          color: iOSDesignSystem.textTertiary,
                          onPressed: widget.onComment,
                        ),
                        
                        // Like - Enhanced animation with spring pop and glow
                        AnimatedLikeButton(
                          isLiked: post.isLiked,
                          likeCount: post.likes,
                          onLike: widget.onLike,
                        ),
                        
                        // Views (display only, no tap action)
                        // ✅ Use provider cache for consistent view counts across all cards
                        Builder(
                          builder: (context) {
                            final model = context.watch<AppModel>();
                            final viewCount = model.getPostViewCount(post.id, post.viewCount);
                            return _ActionButton(
                              icon: Icons.bar_chart_outlined,
                              count: viewCount,
                              color: iOSDesignSystem.textTertiary,
                              onPressed: null,  // View-only, no action
                            );
                          },
                        ),
                        
                        // Forward (send to chat)
                        _ActionButton(
                          icon: Icons.send_outlined,
                          count: 0,  // Forward doesn't have a count
                          color: iOSDesignSystem.textTertiary,
                          showCount: false,
                          onPressed: widget.onForward,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        ),  // ✅ Close GestureDetector
        // Divider between posts
        Divider(
          height: 1,
          thickness: 1.0,  // 1px divider with low opacity
          color: iOSDesignSystem.textTertiary.withOpacity(0.2),
          indent: 16,
          endIndent: 16,
        ),
      ],
    );
  }
  
  int _getMaxLines(String content) {
    // Adaptive sizing: shorter posts show full, longer posts get limited
    if (content.length < 100) return 5;
    if (content.length < 200) return 4;
    return 3;
  }
  
  /// Format "Edited" label with smart time display
  String _formatEditedLabel(DateTime editedAt) {
    final now = DateTime.now();
    final diff = now.difference(editedAt);
    
    if (diff.inHours < 24) {
      // < 24h: "Edited today at 14:20"
      final hour = editedAt.hour.toString().padLeft(2, '0');
      final minute = editedAt.minute.toString().padLeft(2, '0');
      return 'Edited today at $hour:$minute';
    } else {
      // >= 24h: "Edited on 2026-01-29"
      final date = '${editedAt.year}-${editedAt.month.toString().padLeft(2, '0')}-${editedAt.day.toString().padLeft(2, '0')}';
      return 'Edited on $date';
    }
  }
  
  /// Smart image builder: handles URLs and local paths
  Widget _buildPostImage(String pathOrUrl) {
    const baseUrl = 'https://raven-server-5iwa2y5n3a-ww.a.run.app';
    
    // 1) Full URL (http/https)
    if (pathOrUrl.startsWith('http://') || pathOrUrl.startsWith('https://')) {
      return Image.network(
        pathOrUrl,
        width: double.infinity,
        fit: BoxFit.cover,
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return Container(
            height: 200,
            color: iOSDesignSystem.surfaceElevated,
            child: Center(
              child: CircularProgressIndicator(
                value: loadingProgress.expectedTotalBytes != null
                    ? loadingProgress.cumulativeBytesLoaded / loadingProgress.expectedTotalBytes!
                    : null,
                color: iOSDesignSystem.accentBlue,
                strokeWidth: 2,
              ),
            ),
          );
        },
        errorBuilder: (_, error, __) {
          print('❌ Image load error: $error');
          return Container(
            height: 100,
            color: iOSDesignSystem.surfaceElevated,
            child: const Center(
              child: Icon(Icons.broken_image, color: Colors.grey, size: 32),
            ),
          );
        },
      );
    }
    
    // 2) Server path (e.g., /uploads/xxx.png)
    if (pathOrUrl.startsWith('/uploads/') || pathOrUrl.startsWith('/static/')) {
      return Image.network(
        '$baseUrl$pathOrUrl',
        width: double.infinity,
        fit: BoxFit.cover,
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return Container(
            height: 200,
            color: iOSDesignSystem.surfaceElevated,
            child: const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        },
        errorBuilder: (_, __, ___) => Container(
          height: 100,
          color: iOSDesignSystem.surfaceElevated,
          child: const Center(
            child: Icon(Icons.broken_image, color: Colors.grey, size: 32),
          ),
        ),
      );
    }
    
    // 3) Local file path - verify exists first
    final file = File(pathOrUrl);
    if (file.existsSync()) {
      return Image.file(
        file,
        width: double.infinity,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          height: 100,
          color: iOSDesignSystem.surfaceElevated,
          child: const Center(
            child: Icon(Icons.broken_image, color: Colors.grey, size: 32),
          ),
        ),
      );
    }
    
    // 4) Fallback: nothing to show
    return const SizedBox.shrink();
  }
}

class _ActionButton extends StatefulWidget {
  final IconData icon;
  final int count;
  final Color? color;
  final VoidCallback? onPressed;
  final bool isActive;
  final bool showCount;  // Whether to show count (Forward doesn't need count)
  
  const _ActionButton({
    required this.icon,
    required this.count,
    this.color,
    this.onPressed,
    this.isActive = false,
    this.showCount = true,  // Default to showing count
  });
  
  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<Color?> _colorAnimation;
  
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),  // Smooth animation
      vsync: this,
    );
    
    // Scale animation (subtle bounce)
    _scaleAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 1.2),
        weight: 50,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.2, end: 1.0),
        weight: 50,
      ),
    ]).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOutBack,
    ));
    
    // Color animation
    _updateColorAnimation();
  }
  
  void _updateColorAnimation() {
    _colorAnimation = ColorTween(
      begin: iOSDesignSystem.textTertiary,
      end: widget.color ?? iOSDesignSystem.textTertiary,
    ).animate(_controller);
  }
  
  @override
  void didUpdateWidget(_ActionButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.color != widget.color) {
      _updateColorAnimation();
    }
  }
  
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
  
  void _handleTap() {
    // Haptic feedback
    HapticFeedback.lightImpact();
    
    // Call the callback immediately for responsive UI
    widget.onPressed?.call();
    
    // Play animation concurrently
    _controller.forward().then((_) => _controller.reverse());
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scaleAnimation,
      child: InkWell(
        onTap: _handleTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          constraints: const BoxConstraints(
            minHeight: 44,  // Minimum 44px touch target
            minWidth: 44,
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 8,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedBuilder(
                animation: _colorAnimation,
                builder: (context, child) {
                  return Icon(
                    widget.icon,
                    size: 18,
                    color: _colorAnimation.value,
                  );
                },
              ),
              // Only show count if showCount is true
              if (widget.showCount) ...[
                const SizedBox(width: 4),
                AnimatedBuilder(
                  animation: _colorAnimation,
                  builder: (context, child) {
                    return Text(
                      widget.count > 999 
                          ? '${(widget.count / 1000).toStringAsFixed(1)}k' 
                          : '${widget.count}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: _colorAnimation.value,
                        letterSpacing: -0.1,
                      ),
                    );
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// AnimatedLikeButton - Professional Like Animation with Spring Pop & Glow
// ═══════════════════════════════════════════════════════════════════════════════

/// A professional like button with smooth animations:
/// - Spring-like scale pop (1.0 → 1.35 → 1.0)
/// - Color transition to red
/// - Subtle glow/halo effect (~0.2s)
/// - Optimistic UI (animates before server response)
class AnimatedLikeButton extends StatefulWidget {
  final bool isLiked;
  final int likeCount;
  final VoidCallback? onLike;
  
  const AnimatedLikeButton({
    super.key,
    required this.isLiked,
    required this.likeCount,
    this.onLike,
  });
  
  @override
  State<AnimatedLikeButton> createState() => _AnimatedLikeButtonState();
}

class _AnimatedLikeButtonState extends State<AnimatedLikeButton> 
    with TickerProviderStateMixin {
  
  late AnimationController _scaleController;
  late AnimationController _glowController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _glowAnimation;
  late Animation<Color?> _colorAnimation;
  
  // Optimistic UI state
  bool _optimisticLiked = false;
  bool _isAnimating = false;
  
  // Colors
  static const Color _likedColor = Color(0xFFFF2D55);  // iOS System Red/Pink
  static final Color _unlikedColor = iOSDesignSystem.textTertiary;
  
  @override
  void initState() {
    super.initState();
    _optimisticLiked = widget.isLiked;
    
    // Scale animation controller - spring-like with overshoot
    _scaleController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    
    // Glow animation controller - quick fade
    _glowController = AnimationController(
      duration: const Duration(milliseconds: 250),
      vsync: this,
    );
    
    // Spring-like scale: 1.0 → 1.35 → 0.9 → 1.0 (bounce effect)
    _scaleAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 1.35)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 35,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.35, end: 0.92)
            .chain(CurveTween(curve: Curves.easeInOut)),
        weight: 30,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.92, end: 1.0)
            .chain(CurveTween(curve: Curves.elasticOut)),
        weight: 35,
      ),
    ]).animate(_scaleController);
    
    // Glow animation: 0 → 1 → 0 (pulse)
    _glowAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.0, end: 1.0),
        weight: 40,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 0.0),
        weight: 60,
      ),
    ]).animate(CurvedAnimation(
      parent: _glowController,
      curve: Curves.easeOut,
    ));
    
    // Color animation
    _updateColorAnimation();
  }
  
  void _updateColorAnimation() {
    _colorAnimation = ColorTween(
      begin: _optimisticLiked ? _unlikedColor : _likedColor,
      end: _optimisticLiked ? _likedColor : _unlikedColor,
    ).animate(CurvedAnimation(
      parent: _scaleController,
      curve: const Interval(0.0, 0.5, curve: Curves.easeOut),
    ));
  }
  
  @override
  void didUpdateWidget(AnimatedLikeButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    // Sync with server state (in case of failure/success)
    if (oldWidget.isLiked != widget.isLiked && !_isAnimating) {
      _optimisticLiked = widget.isLiked;
      _updateColorAnimation();
    }
  }
  
  @override
  void dispose() {
    _scaleController.dispose();
    _glowController.dispose();
    super.dispose();
  }
  
  void _handleTap() async {
    if (_isAnimating) return;
    
    // Haptic feedback - medium for like
    HapticFeedback.mediumImpact();
    
    // Optimistic update
    setState(() {
      _isAnimating = true;
      _optimisticLiked = !_optimisticLiked;
      _updateColorAnimation();
    });
    
    // Play animations (only on like, not unlike)
    if (_optimisticLiked) {
      // Like animation - full spring + glow
      _scaleController.forward(from: 0);
      _glowController.forward(from: 0);
    } else {
      // Unlike - subtle shrink animation
      _scaleController.forward(from: 0.3);  // Start from middle for shorter animation
    }
    
    // Call the callback
    widget.onLike?.call();
    
    // Wait for animation to complete
    await Future.delayed(const Duration(milliseconds: 400));
    
    if (mounted) {
      setState(() => _isAnimating = false);
    }
  }
  
  @override
  Widget build(BuildContext context) {
    final displayLiked = _isAnimating ? _optimisticLiked : widget.isLiked;
    final displayCount = widget.likeCount + 
        (_isAnimating && _optimisticLiked && !widget.isLiked ? 1 : 0) +
        (_isAnimating && !_optimisticLiked && widget.isLiked ? -1 : 0);
    
    return GestureDetector(
      onTap: _handleTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        constraints: const BoxConstraints(
          minHeight: 44,
          minWidth: 44,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: AnimatedBuilder(
          animation: Listenable.merge([_scaleController, _glowController]),
          builder: (context, child) {
            return Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                // Glow effect (behind the icon)
                if (_optimisticLiked && _glowAnimation.value > 0)
                  Positioned.fill(
                    child: Transform.scale(
                      scale: 1.8 + (_glowAnimation.value * 0.5),
                      child: Opacity(
                        opacity: _glowAnimation.value * 0.4,
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                _likedColor.withOpacity(0.6),
                                _likedColor.withOpacity(0.0),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                
                // Icon and count
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Heart icon with scale
                    Transform.scale(
                      scale: _scaleAnimation.value,
                      child: Icon(
                        displayLiked ? Icons.favorite : Icons.favorite_border,
                        size: 18,
                        color: _colorAnimation.value ?? 
                            (displayLiked ? _likedColor : _unlikedColor),
                      ),
                    ),
                    const SizedBox(width: 4),
                    // Count
                    Text(
                      displayCount > 999 
                          ? '${(displayCount / 1000).toStringAsFixed(1)}k' 
                          : '$displayCount',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: displayLiked ? _likedColor : _unlikedColor,
                        letterSpacing: -0.1,
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Modern Composer Button - Twitter/X Style
class iOSComposer extends StatelessWidget {
  final VoidCallback onTap;
  final String? userAvatar;
  final String userName;
  
  const iOSComposer({
    super.key,
    required this.onTap,
    this.userAvatar,
    required this.userName,
  });

  /// Helper to get avatar image provider (URL or local file)
  ImageProvider? _getAvatarImage(String? avatarPath) {
    if (avatarPath == null || avatarPath.isEmpty) return null;
    
    // Check if it's a URL
    if (avatarPath.startsWith('http://') || avatarPath.startsWith('https://')) {
      return NetworkImage(avatarPath);
    }
    
    // Check if it's a server path that needs base URL
    if (avatarPath.startsWith('/uploads/') || avatarPath.startsWith('/static/')) {
      const baseUrl = 'https://raven-server-5iwa2y5n3a-ww.a.run.app';
      return NetworkImage('$baseUrl$avatarPath');
    }
    
    // It's a local file path
    final file = File(avatarPath);
    if (file.existsSync()) {
      return FileImage(file);
    }
    
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque, // ✅ Ensure taps are captured
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.04), // ✅ Apple-style ultra-low opacity
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: Colors.white.withOpacity(0.08),
                width: 0.5,
              ),
            ),
        child: Row(
          children: [
            // Avatar with gradient border
            Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [
                    iOSDesignSystem.accentBlue,
                    const Color(0xFF9B59B6), // Purple
                    const Color(0xFFE91E63), // Pink
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: CircleAvatar(
                radius: 18,
                backgroundColor: const Color(0xFF15202B),
                backgroundImage: _getAvatarImage(userAvatar),
                child: _getAvatarImage(userAvatar) == null
                    ? Text(
                        userName.isNotEmpty ? userName[0].toUpperCase() : 'U',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      )
                    : null,
              ),
            ),
            
            const SizedBox(width: 12),
            
            // Placeholder text
            Expanded(
              child: Text(
                "What's happening?",
                style: TextStyle(
                  color: Colors.white.withOpacity(0.5),
                  fontSize: 16,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
            
            // Image icon
            Icon(
              Icons.image_outlined,
              color: iOSDesignSystem.accentBlue.withOpacity(0.7),
              size: 22,
            ),
          ],
        ),
      ),  // ← Container
    ),    // ← BackdropFilter
  ),      // ← ClipRRect
);
  }
}

