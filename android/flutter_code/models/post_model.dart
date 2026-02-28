enum PostSendMethod { 
  wifi, 
  bluetooth,
  local,    // Added for offline posts
  unknown, // For legacy posts or when method is not tracked
}

/// Post visibility for privacy control
enum PostVisibility {
  public,      // Visible in both Friends AND Local feeds
  friendsOnly, // Visible ONLY to friends, NOT in Local
}

class Post {
  final String id;
  final String authorId;
  final String authorName;
  final String? authorAvatar;
  final String content;
  final String? imageUrl; // Changed from imagePath
  final DateTime timestamp;
  final DateTime? editedAt; // When post was last edited (null if never)
  final int likes;
  final int comments;
  final int reposts; // New field
  final int viewCount; // View count (privacy-first, no viewer list)
  final List<String> likedBy; // New field
  final bool isLiked;  // Track if current user liked this post
  final bool isReposted; // Track if current user reposted this post
  final bool isLocal; // true = broadcast to nearby, false = friends only
  final PostSendMethod sendMethod; // User's intended method
  final PostSendMethod? actualSendMethod; // How it was actually sent (new!)
  final PostVisibility visibility; // NEW: public or friendsOnly

  const Post({
    required this.id,
    required this.authorId,
    required this.authorName,
    this.authorAvatar,
    required this.content,
    this.imageUrl, // Changed from imagePath
    required this.timestamp,
    this.editedAt,
    this.likes = 0,
    this.comments = 0,
    this.reposts = 0,
    this.viewCount = 0,
    this.likedBy = const [],
    this.isLiked = false,  // Default: not liked
    this.isReposted = false, // Default: not reposted
    this.isLocal = true,
    this.sendMethod = PostSendMethod.local, // Changed default value
    this.actualSendMethod, // New constructor parameter
    this.visibility = PostVisibility.public, // Default: public
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'authorId': authorId,
        'authorName': authorName,
        'authorAvatar': authorAvatar,
        'content': content,
        'imageUrl': imageUrl,
        'timestamp': timestamp.toIso8601String(),
        'editedAt': editedAt?.toIso8601String(),
        'likes': likes,
        'comments': comments,
        'reposts': reposts,
        'viewCount': viewCount,
        'likedBy': likedBy,
        'isLiked': isLiked,
        'isReposted': isReposted,
        'isLocal': isLocal,
        'sendMethod': sendMethod.name,
        'actualSendMethod': actualSendMethod?.name,
        'visibility': visibility.name,
      };


  factory Post.fromJson(Map<String, dynamic> json) {
    // ✅ Debug: Log view_count values during parsing
    final rawViewCount = json['viewCount'];
    final rawViewCountSnake = json['view_count'];
    final parsedViewCount = rawViewCount as int? ?? rawViewCountSnake as int? ?? 0;
    
    if (parsedViewCount > 0 || rawViewCount != null || rawViewCountSnake != null) {
      print('👁️ [Post.fromJson] postId=${(json['id'] as String).substring(0, 8)}... viewCount=$rawViewCount view_count=$rawViewCountSnake → $parsedViewCount');
    }
    
    // Parse editedAt
    final rawEditedAt = json['editedAt'] ?? json['edited_at'];
    final parsedEditedAt = rawEditedAt != null ? DateTime.parse(rawEditedAt as String) : null;
    
    return Post(
        id: json['id'] as String,
        authorId: json['authorId'] as String? ?? json['author_id'] as String,
        authorName: json['authorName'] as String? ?? json['author_username'] as String,
        authorAvatar: json['authorAvatar'] as String? ?? json['author_avatar'] as String?,
        content: json['content'] as String,
        imageUrl: json['imageUrl'] as String? ?? json['image_url'] as String? ?? json['imagePath'] as String?,
        timestamp: DateTime.parse(json['timestamp'] as String),
        editedAt: parsedEditedAt,
        likes: json['likes'] as int? ?? 0,
        comments: json['comments'] as int? ?? 0,
        reposts: json['reposts'] as int? ?? 0,
        viewCount: parsedViewCount,
        likedBy: (json['likedBy'] as List?)?.map((e) => e as String).toList() ?? [],
        isLiked: json['isLiked'] as bool? ?? json['is_liked'] as bool? ?? false,
        isReposted: json['isReposted'] as bool? ?? json['is_reposted'] as bool? ?? false,
        isLocal: json['isLocal'] == 1 || json['isLocal'] == true || json['is_local'] == true,
        sendMethod: parseSendMethod(json['sendMethod'] ?? json['send_method']),
        actualSendMethod: parseSendMethod(json['actualSendMethod'] ?? json['actual_send_method']),
        visibility: parseVisibility(json['visibility']),
      );
  }
  
  Post copyWith({
    String? id,
    String? authorId,
    String? authorName,
    String? authorAvatar,
    String? content,
    String? imageUrl,
    DateTime? timestamp,
    DateTime? editedAt,
    int? likes,
    int? comments,
    int? reposts,
    int? viewCount,
    List<String>? likedBy,
    bool? isLiked,
    bool? isReposted,
    bool? isLocal,
    PostSendMethod? sendMethod,
    PostSendMethod? actualSendMethod,
    PostVisibility? visibility,
  }) {
    return Post(
      id: id ?? this.id,
      authorId: authorId ?? this.authorId,
      authorName: authorName ?? this.authorName,
      authorAvatar: authorAvatar ?? this.authorAvatar,
      content: content ?? this.content,
      imageUrl: imageUrl ?? this.imageUrl,
      timestamp: timestamp ?? this.timestamp,
      editedAt: editedAt ?? this.editedAt,
      likes: likes ?? this.likes,
      comments: comments ?? this.comments,
      reposts: reposts ?? this.reposts,
      viewCount: viewCount ?? this.viewCount,
      likedBy: likedBy ?? this.likedBy,
      isLiked: isLiked ?? this.isLiked,
      isReposted: isReposted ?? this.isReposted,
      isLocal: isLocal ?? this.isLocal,
      sendMethod: sendMethod ?? this.sendMethod,
      actualSendMethod: actualSendMethod ?? this.actualSendMethod,
      visibility: visibility ?? this.visibility,
    );
  }
  
  static PostSendMethod parseSendMethod(dynamic value) {
    // ✅ Default to 'wifi' for server posts (which don't have sendMethod field)
    // This allows view recording for posts fetched from server
    if (value == null) return PostSendMethod.wifi;  // Changed from .unknown
    if (value is String) {
      switch (value) {
        case 'wifi':
          return PostSendMethod.wifi;
        case 'bluetooth':
          return PostSendMethod.bluetooth;
        case 'local':
          return PostSendMethod.local;
        default:
          return PostSendMethod.wifi;  // Default to wifi for unknown strings
      }
    }
    return PostSendMethod.wifi;  // Default to wifi
  }
  
  static PostVisibility parseVisibility(dynamic value) {
    if (value == null) return PostVisibility.public;
    if (value is String) {
      switch (value) {
        case 'friendsOnly':
        case 'friends_only':
          return PostVisibility.friendsOnly;
        case 'public':
        default:
          return PostVisibility.public;
      }
    }
    return PostVisibility.public;
  }
}
