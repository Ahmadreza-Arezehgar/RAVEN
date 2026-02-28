import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../models/post_model.dart';
import '../models/comment.dart';
import '../services/comment_service.dart';
import '../services/api_service.dart';
import '../services/view_tracker_service.dart';  // ✅ Session dedup
import '../theme/mobile_theme.dart';
import '../widgets/post_card.dart';
import '../widgets/comment_widget.dart';
import '../widgets/system_components.dart';

/// Post detail screen with comments
class PostDetailScreen extends StatefulWidget {
  final Post post;
  
  const PostDetailScreen({
    super.key,
    required this.post,
  });

  @override
  State<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends State<PostDetailScreen> {
  List<Comment> _comments = [];
  String? _replyingTo;
  String? _replyingToId;
  final _commentController = TextEditingController();
  bool _isLoading = false;
  bool _isSubmitting = false;
  String? _error;

  late CommentService _commentService;

  @override
  void initState() {
    super.initState();
    _commentService = CommentService();
    _loadComments();
    _recordView(); // ✅ Record view when post opens
  }

  /// Record unique view (privacy-first, only count tracked)
  /// ✅ Uses ViewTrackerService for session dedup
  /// ✅ Skips mesh/local posts that don't exist on server
  /// ✅ Syncs view count to AppModel for consistent UI
  Future<void> _recordView() async {
    // ✅ Skip posts that don't exist on server (mesh/local posts)
    if (widget.post.sendMethod != PostSendMethod.wifi) {
      print('👁️ [VIEW] Skipping mesh/local post (sendMethod=${widget.post.sendMethod.name})');
      return;
    }
    
    // ✅ Check session dedup BEFORE calling API
    if (!ViewTrackerService.instance.shouldRecordView(widget.post.id)) {
      print('👁️ View already recorded this session, skipping API call');
      return;
    }
    
    try {
      final count = await ApiService.recordPostView(widget.post.id);
      if (count != null && mounted) {
        print('👁️ View count for post: $count');
        // ✅ Sync to AppModel so feed cards update when going back
        final model = Provider.of<AppModel>(context, listen: false);
        model.updateViewCount(widget.post.id, count);
      }
    } catch (e) {
      print('❌ Failed to record view: $e');
    }
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _loadComments() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final comments = await _commentService.getPostComments(widget.post.id);
      setState(() {
        _comments = comments;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to load comments';
        _isLoading = false;
      });
      print('Error loading comments: $e');
    }
  }

  Future<void> _submitComment(String text) async {
    if (text.trim().isEmpty || _isSubmitting) return;
    
    setState(() {
      _isSubmitting = true;
    });

    try {
      final newComment = await _commentService.createComment(
        postId: widget.post.id,
        content: text,
        parentCommentId: _replyingToId,
      );

      // Show success message
      if (mounted) {
        ToastNotification.show(
          context,
          message: text.contains('@time_ask') 
              ? 'Comment posted! AI is generating response...' 
              : 'Comment posted!',
          type: ToastType.success,
        );
      }

      // Reload comments to get the full tree including AI response
      // We'll wait a bit if AI trigger was detected to give it time to respond
      if (text.contains('@time_ask')) {
        await Future.delayed(const Duration(seconds: 2));
      }
      
      await _loadComments();

      setState(() {
        _replyingTo = null;
        _replyingToId = null;
        _isSubmitting = false;
      });
    } catch (e) {
      setState(() {
        _isSubmitting = false;
      });
      
      if (mounted) {
        ToastNotification.show(
          context,
          message: 'Failed to post comment',
          type: ToastType.error,
        );
      }
      print('Error submitting comment: $e');
    }
  }

  // Convert Comment model to CommentData for display
  List<CommentData> _convertToCommentData(List<Comment> comments, {int level = 0}) {
    return comments.map((comment) {
      return CommentData(
        id: comment.id,
        authorId: comment.authorId,
        authorName: comment.authorName,
        authorAvatar: comment.authorAvatar,
        content: comment.content,
        timestamp: comment.timestamp,
        likes: comment.score,  // Use score for likes display
        isLiked: comment.myVote > 0,  // myVote > 0 means liked
        isAiGenerated: comment.isAiGenerated,
        level: level,
        replies: _convertToCommentData(comment.replies, level: level + 1),
      );
    }).toList();
  }

  Future<void> _handleCommentLike(String commentId) async {
    try {
      // Toggle vote: if already liked (+1), remove vote (0), else like (+1)
      final comment = _comments.firstWhere((c) => c.id == commentId, orElse: () => _comments.first);
      final newVote = comment.myVote > 0 ? 0 : 1;
      await _commentService.voteComment(commentId, newVote);
      await _loadComments(); // Reload to get updated vote status
    } catch (e) {
      if (mounted) {
        ToastNotification.show(
          context,
          message: 'Failed to update like',
          type: ToastType.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final displayComments = _convertToCommentData(_comments);
    
    // ✅ Get fresh viewCount from AppModel cache (updated by _recordView)
    final model = context.watch<AppModel>();
    final freshViewCount = model.getPostViewCount(widget.post.id, widget.post.viewCount);
    final freshPost = widget.post.copyWith(viewCount: freshViewCount);
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Post'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isLoading ? null : _loadComments,
          ),
        ],
      ),
      body: Column(
        children: [
          // Post at top
          Expanded(
            child: _error != null
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 64,
                          color: MobileTheme.textSecondary(isDark),
                        ),
                        const SizedBox(height: MobileTheme.spacing16),
                        Text(
                          _error!,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                        const SizedBox(height: MobileTheme.spacing16),
                        ElevatedButton.icon(
                          onPressed: _loadComments,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  )
                : ListView(
                    children: [
                      // ✅ Use freshPost with updated viewCount
                      // ✅ Compact variant for Comments screen - hide repost/share/menu
                      PostCard(
                        post: freshPost,
                        showRepost: false,  // Hide repost in Comments
                        showShare: false,   // Hide share in Comments
                        showMenu: false,    // Hide 3-dot menu in Comments
                        onLike: () {
                          ToastNotification.show(
                            context,
                            message: 'Liked!',
                            type: ToastType.success,
                          );
                        },
                      ),
                      
                      // Divider
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: MobileTheme.spacing16,
                          vertical: MobileTheme.spacing8,
                        ),
                        child: Row(
                          children: [
                            Text(
                              'Comments (${_comments.length})',
                              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                                color: MobileTheme.textSecondary(isDark),
                              ),
                            ),
                            if (_isLoading) ...[
                              const SizedBox(width: MobileTheme.spacing8),
                              SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: MobileTheme.brandPrimary,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      
                      // Comments
                      if (_comments.isEmpty && !_isLoading)
                        Padding(
                          padding: const EdgeInsets.all(MobileTheme.spacing32),
                          child: EmptyState(
                            icon: Icons.comment_outlined,
                            title: 'No comments yet',
                            subtitle: 'Be the first to comment! Try @time_ask to get AI help.',
                          ),
                        )
                      else
                        ...displayComments.map((comment) => CommentWidget(
                          comment: comment,
                          onLike: () => _handleCommentLike(comment.id),
                          onReply: () {
                            setState(() {
                              _replyingTo = comment.authorName;
                              _replyingToId = comment.id;
                            });
                          },
                        )),
                    ],
                  ),
          ),
          
          // Comment input at bottom (thumb zone)
          CommentInput(
            controller: _commentController,
            replyingTo: _replyingTo,
            onCancel: () {
              setState(() {
                _replyingTo = null;
                _replyingToId = null;
              });
            },
            onSubmit: _submitComment,
          ),
        ],
      ),
    );
  }
}
