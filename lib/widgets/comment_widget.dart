import 'package:flutter/material.dart';
import '../theme/mobile_theme.dart';

/// Comment model for display
class CommentData {
  final String id;
  final String authorId;
  final String authorName;
  final String? authorAvatar;
  final String content;
  final DateTime timestamp;
  final int likes;
  final bool isLiked;
  final bool isAiGenerated;
  final List<CommentData>? replies;
  final int level;
  
  CommentData({
    required this.id,
    required this.authorId,
    required this.authorName,
    this.authorAvatar,
    required this.content,
    required this.timestamp,
    this.likes = 0,
    this.isLiked = false,
    this.isAiGenerated = false,
    this.replies,
    this.level = 0,
  });
}

/// Threaded comment widget
class CommentWidget extends StatelessWidget {
  final CommentData comment;
  final VoidCallback? onLike;
  final VoidCallback? onReply;
  final int maxLevel;
  
  const CommentWidget({
    super.key,
    required this.comment,
    this.onLike,
    this.onReply,
    this.maxLevel = 3,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final indent = comment.level * MobileTheme.spacing24;
    
    return Padding(
      padding: EdgeInsets.only(
        left: indent,
        bottom: MobileTheme.spacing12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Avatar
              CircleAvatar(
                radius: comment.level > 0 ? 14 : 16,
                backgroundColor: MobileTheme.brandPrimary,
                child: Text(
                  comment.authorName.isNotEmpty 
                      ? comment.authorName[0].toUpperCase() 
                      : 'U',
                  style: TextStyle(
                    fontSize: comment.level > 0 ? 12 : 14,
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              
              const SizedBox(width: MobileTheme.spacing8),
              
              // Content
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Author & Time
                    Row(
                      children: [
                        Text(
                          comment.authorName,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: MobileTheme.spacing8),
                        
                        // AI Badge
                        if (comment.isAiGenerated) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  MobileTheme.brandPrimary.withOpacity(0.15),
                                  MobileTheme.brandPrimary.withOpacity(0.05),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: MobileTheme.brandPrimary.withOpacity(0.3),
                                width: 0.5,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.auto_awesome,
                                  size: 10,
                                  color: MobileTheme.brandPrimary,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  'AI',
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                    color: MobileTheme.brandPrimary,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: MobileTheme.spacing8),
                        ],
                        
                        Text(
                          MobileTheme.formatTimeAgo(comment.timestamp),
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: MobileTheme.textTertiary(isDark),
                          ),
                        ),
                      ],
                    ),
                    
                    const SizedBox(height: MobileTheme.spacing4),
                    
                    // Comment text
                    Text(
                      comment.content,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    
                    const SizedBox(height: MobileTheme.spacing8),
                    
                    // Actions
                    Row(
                      children: [
                        // Like
                        InkWell(
                          onTap: onLike,
                          borderRadius: BorderRadius.circular(MobileTheme.radiusFull),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: MobileTheme.spacing8,
                              vertical: MobileTheme.spacing4,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  comment.isLiked ? Icons.favorite : Icons.favorite_border,
                                  size: 16,
                                  color: comment.isLiked 
                                      ? MobileTheme.likeColor 
                                      : MobileTheme.textSecondary(isDark),
                                ),
                                if (comment.likes > 0) ...[
                                  const SizedBox(width: MobileTheme.spacing4),
                                  Text(
                                    MobileTheme.formatCount(comment.likes),
                                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                      color: comment.isLiked 
                                          ? MobileTheme.likeColor 
                                          : MobileTheme.textSecondary(isDark),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                        
                        // Reply (only if under max level)
                        if (comment.level < maxLevel) ...[
                          const SizedBox(width: MobileTheme.spacing8),
                          InkWell(
                            onTap: onReply,
                            borderRadius: BorderRadius.circular(MobileTheme.radiusFull),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: MobileTheme.spacing8,
                                vertical: MobileTheme.spacing4,
                              ),
                              child: Text(
                                'Reply',
                                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                  color: MobileTheme.textSecondary(isDark),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          
          // Replies (recursive)
          if (comment.replies != null && comment.replies!.isNotEmpty) ...[
            const SizedBox(height: MobileTheme.spacing8),
            ...comment.replies!.map((reply) => CommentWidget(
              comment: reply,
              onLike: () {}, // TODO: Handle reply like
              onReply: () {}, // TODO: Handle reply to reply
              maxLevel: maxLevel,
            )),
          ],
        ],
      ),
    );
  }
}

/// Comment input field (for bottom of screen - thumb zone)
class CommentInput extends StatefulWidget {
  final String? replyingTo;
  final VoidCallback? onCancel;
  final Function(String)? onSubmit;
  final TextEditingController? controller;
  
  const CommentInput({
    super.key,
    this.replyingTo,
    this.onCancel,
    this.onSubmit,
    this.controller,
  });

  @override
  State<CommentInput> createState() => _CommentInputState();
}

class _CommentInputState extends State<CommentInput> {
  late TextEditingController _controller;
  bool _hasText = false;
  
  // ✅ Store listener reference for proper cleanup
  late final VoidCallback _textListener;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? TextEditingController();
    
    // ✅ Define listener so we can remove it later
    _textListener = () {
      if (mounted) {
        setState(() {
          _hasText = _controller.text.trim().isNotEmpty;
        });
      }
    };
    _controller.addListener(_textListener);
  }

  @override
  void dispose() {
    // ✅ CRITICAL: Remove listener BEFORE disposing to prevent assertion error
    _controller.removeListener(_textListener);
    
    if (widget.controller == null) {
      _controller.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (_hasText) {
      widget.onSubmit?.call(_controller.text.trim());
      _controller.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Container(
      decoration: BoxDecoration(
        color: isDark ? MobileTheme.darkSurface : MobileTheme.lightSurface,
        border: Border(
          top: BorderSide(
            color: isDark ? MobileTheme.darkDivider : MobileTheme.lightDivider,
            width: 1,
          ),
        ),
      ),
      padding: EdgeInsets.only(
        left: MobileTheme.spacing16,
        right: MobileTheme.spacing16,
        top: MobileTheme.spacing12,
        bottom: MediaQuery.of(context).viewInsets.bottom + MobileTheme.spacing12,
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Reply indicator
            if (widget.replyingTo != null) ...[
              Row(
                children: [
                  Icon(
                    Icons.reply,
                    size: 16,
                    color: MobileTheme.textSecondary(isDark),
                  ),
                  const SizedBox(width: MobileTheme.spacing8),
                  Expanded(
                    child: Text(
                      'Replying to ${widget.replyingTo}',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: MobileTheme.textSecondary(isDark),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: widget.onCancel,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              const SizedBox(height: MobileTheme.spacing8),
            ],
            
            // Input field
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Avatar
                CircleAvatar(
                  radius: 16,
                  backgroundColor: MobileTheme.brandPrimary,
                  child: const Icon(Icons.person, size: 18, color: Colors.white),
                ),
                
                const SizedBox(width: MobileTheme.spacing12),
                
                // Text field
                Expanded(
                  child: TextField(
                    controller: _controller,
                    maxLines: null,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: 'Add a comment...',
                      filled: true,
                      fillColor: isDark 
                          ? MobileTheme.darkBackground 
                          : MobileTheme.lightBackground,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(MobileTheme.radiusLarge),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: MobileTheme.spacing16,
                        vertical: MobileTheme.spacing12,
                      ),
                    ),
                  ),
                ),
                
                const SizedBox(width: MobileTheme.spacing8),
                
                // Send button
                IconButton(
                  onPressed: _hasText ? _submit : null,
                  icon: Icon(
                    Icons.send,
                    color: _hasText 
                        ? MobileTheme.brandPrimary
                        : MobileTheme.textTertiary(isDark),
                  ),
                  iconSize: MobileTheme.iconSizeLarge,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
