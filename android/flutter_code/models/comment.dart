import 'package:flutter/foundation.dart';

/// Comment model for post comments
class Comment {
  final String id;
  final String postId;
  final String authorId;
  final String authorName;
  final String? authorAvatar;
  final bool isVerified;  // Blue verified badge
  final String? parentCommentId;
  final String content;
  final DateTime timestamp;
  final int score;  // likes - dislikes
  final int myVote;  // +1 = liked, -1 = disliked, 0 = no vote
  final bool isAiGenerated;
  final List<Comment> replies;
  
  Comment({
    required this.id,
    required this.postId,
    required this.authorId,
    required this.authorName,
    this.authorAvatar,
    this.isVerified = false,
    this.parentCommentId,
    required this.content,
    required this.timestamp,
    this.score = 0,
    this.myVote = 0,
    this.isAiGenerated = false,
    this.replies = const [],
  });
  
  /// Create Comment from JSON
  factory Comment.fromJson(Map<String, dynamic> json) {
    return Comment(
      id: json['id'] as String,
      postId: json['post_id'] as String,
      authorId: json['author_id'] as String,
      authorName: json['author_name'] as String,
      authorAvatar: json['author_avatar'] as String?,
      isVerified: json['is_verified'] as bool? ?? false,
      parentCommentId: json['parent_comment_id'] as String?,
      content: json['content'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      score: json['score'] as int? ?? 0,
      myVote: json['my_vote'] as int? ?? 0,
      isAiGenerated: json['is_ai_generated'] as bool? ?? false,
      replies: (json['replies'] as List<dynamic>?)
          ?.map((reply) => Comment.fromJson(reply as Map<String, dynamic>))
          .toList() ?? [],
    );
  }
  
  /// Convert Comment to JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'post_id': postId,
      'author_id': authorId,
      'author_name': authorName,
      'author_avatar': authorAvatar,
      'is_verified': isVerified,
      'parent_comment_id': parentCommentId,
      'content': content,
      'timestamp': timestamp.toIso8601String(),
      'score': score,
      'my_vote': myVote,
      'is_ai_generated': isAiGenerated,
      'replies': replies.map((r) => r.toJson()).toList(),
    };
  }
  
  /// Create a copy with some fields updated
  Comment copyWith({
    String? id,
    String? postId,
    String? authorId,
    String? authorName,
    String? authorAvatar,
    bool? isVerified,
    String? parentCommentId,
    String? content,
    DateTime? timestamp,
    int? score,
    int? myVote,
    bool? isAiGenerated,
    List<Comment>? replies,
  }) {
    return Comment(
      id: id ?? this.id,
      postId: postId ?? this.postId,
      authorId: authorId ?? this.authorId,
      authorName: authorName ?? this.authorName,
      authorAvatar: authorAvatar ?? this.authorAvatar,
      isVerified: isVerified ?? this.isVerified,
      parentCommentId: parentCommentId ?? this.parentCommentId,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      score: score ?? this.score,
      myVote: myVote ?? this.myVote,
      isAiGenerated: isAiGenerated ?? this.isAiGenerated,
      replies: replies ?? this.replies,
    );
  }
  
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    
    return other is Comment &&
      other.id == id &&
      other.postId == postId &&
      other.authorId == authorId &&
      other.content == content;
  }
  
  @override
  int get hashCode {
    return id.hashCode ^ 
           postId.hashCode ^ 
           authorId.hashCode ^ 
           content.hashCode;
  }
  
  @override
  String toString() {
    return 'Comment(id: $id, author: $authorName, content: ${content.substring(0, content.length > 20 ? 20 : content.length)}...)';
  }
}
