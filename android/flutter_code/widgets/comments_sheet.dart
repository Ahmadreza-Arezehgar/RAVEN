import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/comment.dart';
import '../services/api_service.dart';
import '../services/toast_service.dart';
import '../theme/ios_design_system.dart';
import '../models/post_model.dart';

/// Bottom sheet for displaying and adding comments
class CommentsSheet extends StatefulWidget {
  final Post post;
  
  const CommentsSheet({
    super.key,
    required this.post,
  });
  
  /// Show the comments sheet with Liquid Glass animation
  /// - Blur backdrop for glass effect
  /// - Smooth slide up and fade in
  /// - Drag to dismiss with fade out
  static Future<void> show(BuildContext context, Post post) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.4),  // Soft dimmed background
      transitionAnimationController: AnimationController(
        duration: const Duration(milliseconds: 400),  // Smooth animation
        vsync: Navigator.of(context),
      ),
      builder: (context) => _LiquidGlassWrapper(
        child: CommentsSheet(post: post),
      ),
    );
  }

  @override
  State<CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<CommentsSheet> {
  final TextEditingController _commentController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  List<Comment> _comments = [];
  bool _isLoading = true;
  bool _isSubmitting = false;
  String? _replyingToId;
  String? _replyingToName;
  final Set<String> _likingInProgress = {}; // Prevent double-tap

  @override
  void initState() {
    super.initState();
    _loadComments();
    
    // Delayed focus to preserve animation smoothness
    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted) {
        _focusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _commentController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadComments() async {
    try {
      final comments = await ApiService.getPostComments(widget.post.id);
      if (mounted) {
        setState(() {
          _comments = comments;
          _isLoading = false;
        });
      }
    } catch (e) {
      print('❌ Failed to load comments: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _submitComment() async {
    print('🎯 _submitComment called!'); // DEBUG
    final content = _commentController.text.trim();
    print('📄 Content: "$content"'); // DEBUG
    if (content.isEmpty) {
      print('⚠️ Content is empty, returning'); // DEBUG
      return;
    }

    setState(() => _isSubmitting = true);
    HapticFeedback.lightImpact();

    try {
      final newComment = await ApiService.createComment(
        postId: widget.post.id,
        content: content,
        parentCommentId: _replyingToId,
        // ✅ Pass image URL so AI Vision can analyze the image
        postImageUrl: widget.post.imageUrl,
      );
      
      if (newComment != null && mounted) {
        setState(() {
          if (_replyingToId != null) {
            // Find parent and add reply
            _addReplyToComment(_replyingToId!, newComment);
          } else {
            _comments.insert(0, newComment);
          }
          _commentController.clear();
          _replyingToId = null;
          _replyingToName = null;
          _isSubmitting = false;
        });
        HapticFeedback.mediumImpact();
      }
    } catch (e) {
      print('❌ Failed to submit comment: $e');
      if (mounted) {
        setState(() => _isSubmitting = false);
        ToastService.showError('Failed to post comment');
      }
    }
  }

  void _addReplyToComment(String parentId, Comment reply) {
    for (int i = 0; i < _comments.length; i++) {
      if (_comments[i].id == parentId) {
        _comments[i] = _comments[i].copyWith(
          replies: [..._comments[i].replies, reply],
        );
        return;
      }
      // Check nested replies
      for (int j = 0; j < _comments[i].replies.length; j++) {
        if (_comments[i].replies[j].id == parentId) {
          final updatedReplies = List<Comment>.from(_comments[i].replies);
          updatedReplies[j] = updatedReplies[j].copyWith(
            replies: [...updatedReplies[j].replies, reply],
          );
          _comments[i] = _comments[i].copyWith(replies: updatedReplies);
          return;
        }
      }
    }
  }

  void _replyTo(Comment comment) {
    setState(() {
      _replyingToId = comment.id;
      _replyingToName = comment.authorName;
    });
    _focusNode.requestFocus();
  }

  void _cancelReply() {
    setState(() {
      _replyingToId = null;
      _replyingToName = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).viewInsets.bottom;
    final screenHeight = MediaQuery.of(context).size.height;
    
    return Container(
      height: screenHeight * 0.85,
      decoration: const BoxDecoration(
        color: iOSDesignSystem.baseBackground,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // Handle bar
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          
          // Header
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Text(
                  'Comments',
                  style: iOSDesignSystem.textTheme.displaySmall,
                ),
                const SizedBox(width: 8),
                Text(
                  '${widget.post.comments}',
                  style: TextStyle(
                    color: iOSDesignSystem.textSecondary,
                    fontSize: 18,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          
          Divider(
            height: 1,
            color: Colors.white.withOpacity(0.1),
          ),
          
          // Comments list
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(
                      color: iOSDesignSystem.accentBlue,
                    ),
                  )
                : _comments.isEmpty
                    ? _buildEmptyState()
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _comments.length,
                        itemBuilder: (context, index) {
                          return _buildCommentItem(_comments[index], 0);
                        },
                      ),
          ),
          
          // Reply indicator
          if (_replyingToName != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: iOSDesignSystem.surfaceCard,
              child: Row(
                children: [
                  Icon(
                    Icons.reply,
                    size: 16,
                    color: iOSDesignSystem.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Replying to $_replyingToName',
                      style: TextStyle(
                        color: iOSDesignSystem.textSecondary,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    color: iOSDesignSystem.textSecondary,
                    onPressed: _cancelReply,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
          
          // Input field
          Container(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 12,
              bottom: bottomPadding + 12,
            ),
            decoration: BoxDecoration(
              color: iOSDesignSystem.surfaceCard,
              border: Border(
                top: BorderSide(
                  color: Colors.white.withOpacity(0.1),
                ),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  // Avatar
                  const CircleAvatar(
                    radius: 16,
                    backgroundColor: iOSDesignSystem.accentBlue,
                    child: Icon(Icons.person, size: 18, color: Colors.white),
                  ),
                  const SizedBox(width: 12),
                  
                  // Text field
                  Expanded(
                    child: TextField(
                      controller: _commentController,
                      focusNode: _focusNode,
                      style: const TextStyle(color: Colors.white),
                      maxLines: null,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: 'Add a comment...',
                        hintStyle: TextStyle(
                          color: iOSDesignSystem.textTertiary,
                        ),
                        filled: true,
                        fillColor: iOSDesignSystem.surfaceElevated,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  
                  // Send button
                  _isSubmitting
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: iOSDesignSystem.accentBlue,
                          ),
                        )
                      : IconButton(
                          icon: const Icon(Icons.send),
                          color: iOSDesignSystem.accentBlue,
                          onPressed: _submitComment,
                        ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 64,
            color: iOSDesignSystem.textTertiary,
          ),
          const SizedBox(height: 16),
          Text(
            'No comments yet',
            style: iOSDesignSystem.textTheme.headlineMedium?.copyWith(
              color: iOSDesignSystem.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Be the first to comment!',
            style: TextStyle(
              color: iOSDesignSystem.textTertiary,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCommentItem(Comment comment, int level) {
    final indent = level * 24.0;
    
    return Padding(
      padding: EdgeInsets.only(left: indent, bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Avatar
              CircleAvatar(
                radius: level > 0 ? 14 : 16,
                backgroundColor: iOSDesignSystem.surfaceElevated,
                backgroundImage: comment.authorAvatar != null && comment.authorAvatar!.isNotEmpty
                    ? NetworkImage(
                        comment.authorAvatar!.startsWith('http')
                            ? comment.authorAvatar!
                            : '${ApiService.baseUrl}${comment.authorAvatar}'  // ✅ Use dynamic baseUrl
                      )
                    : null,
                child: comment.authorAvatar == null || comment.authorAvatar!.isEmpty
                    ? Text(
                        comment.authorName.isNotEmpty
                            ? comment.authorName[0].toUpperCase()
                            : 'U',
                        style: TextStyle(
                          fontSize: level > 0 ? 12 : 14,
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              
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
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                            fontSize: 14,
                          ),
                        ),
                        
                        // Verified Badge (Blue Tick)
                        if (comment.isVerified) ...[
                          const SizedBox(width: 4),
                          Icon(
                            Icons.verified,
                            size: 14,
                            color: iOSDesignSystem.accentBlue,
                          ),
                        ],
                        
                        // AI Badge
                        if (comment.isAiGenerated) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  iOSDesignSystem.accentBlue.withOpacity(0.3),
                                  iOSDesignSystem.accentPink.withOpacity(0.3),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.auto_awesome,
                                  size: 10,
                                  color: Colors.white,
                                ),
                                SizedBox(width: 3),
                                Text(
                                  'AI',
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        
                        const SizedBox(width: 8),
                        Text(
                          _formatTimeAgo(comment.timestamp),
                          style: TextStyle(
                            fontSize: 12,
                            color: iOSDesignSystem.textTertiary,
                          ),
                        ),
                      ],
                    ),
                    
                    const SizedBox(height: 4),
                    
                    // Comment text
                    Text(
                      comment.content,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        height: 1.4,
                      ),
                    ),
                    
                    const SizedBox(height: 8),
                    
                    // Actions
                    Row(
                      children: [
                        // Like button
                        GestureDetector(
                          onTap: () => _voteComment(comment, 1),
                          child: Icon(
                            comment.myVote == 1
                                ? Icons.thumb_up
                                : Icons.thumb_up_outlined,
                            size: 16,
                            color: comment.myVote == 1
                                ? iOSDesignSystem.accentGreen
                                : iOSDesignSystem.textTertiary,
                          ),
                        ),
                        
                        const SizedBox(width: 16),
                        
                        // Dislike button
                        GestureDetector(
                          onTap: () => _voteComment(comment, -1),
                          child: Icon(
                            comment.myVote == -1
                                ? Icons.thumb_down
                                : Icons.thumb_down_outlined,
                            size: 16,
                            color: comment.myVote == -1
                                ? iOSDesignSystem.accentPink
                                : iOSDesignSystem.textTertiary,
                          ),
                        ),
                        
                        // Reply
                        if (level < 2) ...[
                          const SizedBox(width: 16),
                          GestureDetector(
                            onTap: () => _replyTo(comment),
                            child: Text(
                              'Reply',
                              style: TextStyle(
                                fontSize: 12,
                                color: iOSDesignSystem.textTertiary,
                                fontWeight: FontWeight.w600,
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
          
          // Replies
          if (comment.replies.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Column(
                children: comment.replies
                    .map((reply) => _buildCommentItem(reply, level + 1))
                    .toList(),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _voteComment(Comment comment, int vote) async {
    // Prevent double-tap
    if (_likingInProgress.contains(comment.id)) return;
    
    _likingInProgress.add(comment.id);
    HapticFeedback.lightImpact();
    
    // Toggle logic: if same vote, remove it
    final effectiveVote = comment.myVote == vote ? 0 : vote;
    
    try {
      final response = await ApiService.voteComment(comment.id, effectiveVote);
      
      if (response != null && mounted) {
        final myVote = response['my_vote'] as int? ?? 0;
        final score = response['score'] as int? ?? comment.score;
        
        setState(() {
          _updateCommentVoteFromServer(comment.id, myVote, score);
        });
      }
    } catch (e) {
      print('❌ Failed to vote comment: $e');
    } finally {
      _likingInProgress.remove(comment.id);
    }
  }

  void _updateCommentVoteFromServer(String commentId, int myVote, int score) {
    for (int i = 0; i < _comments.length; i++) {
      if (_comments[i].id == commentId) {
        _comments[i] = _comments[i].copyWith(
          myVote: myVote,
          score: score,
        );
        return;
      }
      // Check replies recursively
      _comments[i] = _updateRepliesVote(_comments[i], commentId, myVote, score);
    }
  }
  
  Comment _updateRepliesVote(Comment comment, String targetId, int myVote, int score) {
    final updatedReplies = comment.replies.map((reply) {
      if (reply.id == targetId) {
        return reply.copyWith(myVote: myVote, score: score);
      }
      return _updateRepliesVote(reply, targetId, myVote, score);
    }).toList();
    return comment.copyWith(replies: updatedReplies);
  }


  // _updateCommentLike removed - now using _updateCommentVoteFromServer

  String _formatTimeAgo(DateTime timestamp) {
    final now = DateTime.now();
    final diff = now.difference(timestamp);
    
    if (diff.inSeconds < 60) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${timestamp.month}/${timestamp.day}';
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Liquid Glass Wrapper - Blur backdrop for Comments Sheet
// ═══════════════════════════════════════════════════════════════════════════════

/// Wraps content in a Liquid Glass styled container with blur backdrop
class _LiquidGlassWrapper extends StatelessWidget {
  final Widget child;
  
  const _LiquidGlassWrapper({required this.child});
  
  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final bottomPadding = MediaQuery.of(context).viewInsets.bottom;
    
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: BackdropFilter(
        // Blur effect for Liquid Glass
        filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
        child: Container(
          constraints: BoxConstraints(
            maxHeight: screenHeight * 0.85,
          ),
          decoration: BoxDecoration(
            // Liquid Glass background
            color: const Color(0xFF1C1C1E).withOpacity(0.85),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            // Glass border
            border: Border.all(
              color: Colors.white.withOpacity(0.12),
              width: 0.5,
            ),
            // Subtle shadow for depth
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.3),
                blurRadius: 20,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

