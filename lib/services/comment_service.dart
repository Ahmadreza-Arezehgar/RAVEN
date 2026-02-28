import '../models/comment.dart';
import 'api_service.dart';

/// Service for managing post comments - uses static ApiService methods
class CommentService {
  /// Create a new comment on a post
  /// [postImageUrl] - Pass post's image URL if AI should analyze it (Vision API)
  /// [enableSearch] - Enable AI web search for fact-checking
  Future<Comment?> createComment({
    required String postId,
    required String content,
    String? parentCommentId,
    String? postImageUrl,  // ✅ For AI Vision analysis
    bool enableSearch = true,  // ✅ For AI Internet Search
  }) async {
    return await ApiService.createComment(
      postId: postId,
      content: content,
      parentCommentId: parentCommentId,
      postImageUrl: postImageUrl,
      enableSearch: enableSearch,
    );
  }

  
  /// Get all comments for a specific post
  Future<List<Comment>> getPostComments(String postId) async {
    return await ApiService.getPostComments(postId);
  }
  
  /// Vote on a comment (like/dislike)
  /// vote: +1 = like, -1 = dislike, 0 = remove vote
  Future<void> voteComment(String commentId, int vote) async {
    await ApiService.voteComment(commentId, vote);
  }
}
