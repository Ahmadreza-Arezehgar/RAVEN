import 'dart:io';
import 'package:flutter/material.dart';
import '../theme/mobile_theme.dart';
import '../models/post_model.dart';

/// Twitter-style post card widget
/// Horizontal layout with avatar on left, content on right
class PostCard extends StatelessWidget {
  final Post post;
  final VoidCallback? onTap;
  final VoidCallback? onLike;
  final VoidCallback? onRepost;  // ✅ NEW
  final VoidCallback? onComment;
  final VoidCallback? onShare;
  final bool isLiked;
  final bool isReposted;  // ✅ NEW
  
  // ✅ Visibility controls for different contexts (Comments, Profile, etc.)
  final bool showRepost;
  final bool showShare;
  final bool showMenu;
  final bool showLike;
  final bool showViews;
  final bool showComments;
  
  const PostCard({
    super.key,
    required this.post,
    this.onTap,
    this.onLike,
    this.onRepost,
    this.onComment,
    this.onShare,
    this.isLiked = false,
    this.isReposted = false,
    // All default to true for backward compatibility
    this.showRepost = true,
    this.showShare = true,
    this.showMenu = true,
    this.showLike = true,
    this.showViews = true,
    this.showComments = true,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
            width: 0.5,
          ),
        ),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Avatar on the left (fixed)
              _buildAvatar(),
              
              const SizedBox(width: 12),
              
              // Content on the right (expandable)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header (name, username, time, menu)
                    _buildHeader(context, isDark),
                    
                    const SizedBox(height: 4),
                    
                    // Post content
                    _buildContent(context),
                    
                    // Image (if exists)
                    if (post.imageUrl != null) ...[
                      const SizedBox(height: 12),
                      _buildImage(),
                    ],
                    
                    const SizedBox(height: 12),
                    
                    // Action buttons (comment, repost, like, views)
                    _buildActionButtons(context, isDark),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _buildAvatar() {
    return CircleAvatar(
      radius: 20,
      backgroundImage: post.authorAvatar != null && post.authorAvatar!.isNotEmpty
          ? NetworkImage(post.authorAvatar!)  // ✅ Server sends URL, not local path
          : null,
      child: post.authorAvatar == null || post.authorAvatar!.isEmpty
          ? Text(
              post.authorName.isNotEmpty 
                  ? post.authorName[0].toUpperCase() 
                  : 'U',
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 16,
              ),
            )
          : null,
    );
  }
  
  Widget _buildHeader(BuildContext context, bool isDark) {
    return Row(
      children: [
        // Display name (bold)
        Flexible(
          child: Text(
            post.authorName,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
              fontSize: 15,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        
        const SizedBox(width: 4),
        
        // Verified badge (if applicable)
        // Icon(Icons.verified, size: 16, color: Colors.blue),
        
        // Username handle
        Text(
          '@${post.authorName.toLowerCase().replaceAll(' ', '')}',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: MobileTheme.textSecondary(isDark),
            fontSize: 15,
          ),
        ),
        
        const SizedBox(width: 4),
        
        // Dot separator
        Text(
          '·',
          style: TextStyle(
            color: MobileTheme.textSecondary(isDark),
            fontSize: 15,
          ),
        ),
        
        const SizedBox(width: 4),
        
        // Timestamp
        Text(
          _formatTimestamp(post.timestamp),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: MobileTheme.textSecondary(isDark),
            fontSize: 15,
          ),
        ),
        
        const Spacer(),
        
        // More menu (smaller) - conditionally shown
        if (showMenu)
          SizedBox(
            width: 32,
            height: 32,
            child: IconButton(
              icon: const Icon(Icons.more_horiz),
              iconSize: 18,
              padding: EdgeInsets.zero,
              color: MobileTheme.textSecondary(isDark),
              onPressed: () {
                // TODO: Show post menu
              },
            ),
          ),
      ],
    );
  }
  
  Widget _buildContent(BuildContext context) {
    return Text(
      post.content,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        fontSize: 15,
        height: 1.4,
      ),
    );
  }
  
  String _formatTimestamp(DateTime timestamp) {
    final now = DateTime.now();
    final diff = now.difference(timestamp);
    
    if (diff.inSeconds < 60) return '${diff.inSeconds}s';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${timestamp.day}/${timestamp.month}';
  }

  Widget _buildImage() {
    final pathOrUrl = post.imageUrl!;
    const baseUrl = 'https://raven-server-5iwa2y5n3a-ww.a.run.app';
    
    // Get the correct image URL
    String imageUrl;
    if (pathOrUrl.startsWith('http://') || pathOrUrl.startsWith('https://')) {
      imageUrl = pathOrUrl;
    } else if (pathOrUrl.startsWith('/uploads/') || pathOrUrl.startsWith('/static/')) {
      imageUrl = '$baseUrl$pathOrUrl';
    } else {
      // Local file
      final file = File(pathOrUrl);
      if (file.existsSync()) {
        return _buildTappableLocalImage(file);
      }
      return const SizedBox.shrink();
    }
    
    // Network image with tap to zoom
    return _buildTappableNetworkImage(imageUrl);
  }
  
  /// Tappable network image that opens fullscreen viewer
  Widget _buildTappableNetworkImage(String url) {
    return Builder(
      builder: (context) => GestureDetector(
        onTap: () => _openFullscreenImage(context, url),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Image.network(
            url,
            width: double.infinity,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
  
  /// Tappable local image that opens fullscreen viewer  
  Widget _buildTappableLocalImage(File file) {
    return Builder(
      builder: (context) {
        // We need to pass the file path for fullscreen
        return GestureDetector(
          onTap: () => _openFullscreenLocalImage(context, file),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.file(
              file,
              width: double.infinity,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
        );
      },
    );
  }
  
  /// Open fullscreen image viewer with zoom
  void _openFullscreenImage(BuildContext context, String url) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            iconTheme: const IconThemeData(color: Colors.white),
          ),
          extendBodyBehindAppBar: true,
          body: Center(
            child: InteractiveViewer(
              minScale: 1.0,
              maxScale: 4.0,
              child: Image.network(url, fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }
  
  /// Open fullscreen local image viewer
  void _openFullscreenLocalImage(BuildContext context, File file) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            iconTheme: const IconThemeData(color: Colors.white),
          ),
          extendBodyBehindAppBar: true,
          body: Center(
            child: InteractiveViewer(
              minScale: 1.0,
              maxScale: 4.0,
              child: Image.file(file, fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }  

  Widget _buildActionButtons(BuildContext context, bool isDark) {
    final buttonColor = MobileTheme.textSecondary(isDark);
    
    // ✅ Build list of visible buttons only
    final buttons = <Widget>[];
    
    // Comment
    if (showComments) {
      buttons.add(_ActionButton(
        icon: Icons.chat_bubble_outline,
        label: MobileTheme.formatCount(post.comments),
        color: buttonColor,
        onPressed: onComment,
      ));
    }
    
    // Repost (conditionally shown)
    if (showRepost) {
      buttons.add(_ActionButton(
        icon: isReposted ? Icons.repeat : Icons.repeat,
        label: post.reposts > 0 ? MobileTheme.formatCount(post.reposts) : '',
        color: isReposted ? const Color(0xFF00C853) : buttonColor,
        onPressed: onRepost,
      ));
    }
    
    // Like
    if (showLike) {
      buttons.add(_ActionButton(
        icon: isLiked ? Icons.favorite : Icons.favorite_border,
        label: MobileTheme.formatCount(post.likes),
        color: isLiked ? MobileTheme.likeColor : buttonColor,
        onPressed: onLike,
      ));
    }
    
    // Views
    if (showViews) {
      buttons.add(_ActionButton(
        icon: Icons.bar_chart,
        label: _formatViews(post.viewCount),
        color: buttonColor,
        onPressed: null,
      ));
    }
    
    // Share (conditionally shown)
    if (showShare) {
      buttons.add(_ActionButton(
        icon: Icons.ios_share,
        label: '',
        color: buttonColor,
        onPressed: onShare,
      ));
    }
    
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: buttons,
    );
  }
  
  String _formatViews(int views) {
    if (views < 1000) return views.toString();
    if (views < 10000) return '${(views / 1000).toStringAsFixed(1)}K';
    if (views < 1000000) return '${(views / 1000).toStringAsFixed(0)}K';
    return '${(views / 1000000).toStringAsFixed(1)}M';
  }
}

/// Twitter-style action button
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
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: color),
            if (label.isNotEmpty) ...[
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: color,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
