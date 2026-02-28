import '../models/post_model.dart';

/// Feed Algorithm - Twitter/Instagram-inspired ranking
class FeedAlgorithm {
  /// Rank posts برای Local feed
  /// 
  /// Algorithm:
  /// - Engagement (40%): likes + comments
  /// - Recency (30%): تازگی پست
  /// - Proximity (20%): نزدیکی جغرافیایی (فعلاً placeholder)
  /// - User Interest (10%): based on interaction history
  static List<Post> rankPosts(
    List<Post> posts, {
    String? currentUserId,
    Map<String, int>? userInteractions, // authorId -> interaction count
  }) {
    if (posts.isEmpty) return posts;
    
    // Calculate scores
    final scoredPosts = posts.map((post) {
      final score = _calculateScore(
        post,
        currentUserId: currentUserId,
        userInteractions: userInteractions,
      );
      return _ScoredPost(post, score);
    }).toList();
    
    // Sort by score (descending)
    scoredPosts.sort((a, b) => b.score.compareTo(a.score));
    
    // Return sorted posts
    return scoredPosts.map((sp) => sp.post).toList();
  }
  
  /// Calculate score for a single post
  static double _calculateScore(
    Post post, {
    String? currentUserId,
    Map<String, int>? userInteractions,
  }) {
    // 1. Engagement Score (40%)
    final engagementScore = _engagementScore(post);
    
    // 2. Recency Score (30%)
    final recencyScore = _recencyScore(post);
    
    // 3. Proximity Score (20%)
    // TODO: Implement با Bluetooth signal strength
    final proximityScore = 0.5; // Placeholder
    
    // 4. User Interest Score (10%)
    final interestScore = _userInterestScore(
      post,
      currentUserId: currentUserId,
      userInteractions: userInteractions,
    );
    
    // Weighted sum
    return (engagementScore * 0.4) +
           (recencyScore * 0.3) +
           (proximityScore * 0.2) +
           (interestScore * 0.1);
  }
  
  /// Engagement: normalized likes + comments
  static double _engagementScore(Post post) {
    final total = post.likes + post.comments;
    
    // Normalize با log scale (جلوگیری از viral posts dominating)
    if (total == 0) return 0.0;
    
    // log10(total + 1) normalized to 0-1
    // Assuming max engagement ~1000
    final normalized = (total / 1000).clamp(0.0, 1.0);
    return normalized;
  }
  
  /// Recency: exponential decay
  static double _recencyScore(Post post) {
    final now = DateTime.now();
    final age = now.difference(post.timestamp);
    
    // Decay بعد از 24 ساعت
    final hours = age.inHours.toDouble();
    
    if (hours < 1) return 1.0; // خیلی تازه
    if (hours > 72) return 0.1; // خیلی قدیمی
    
    // Exponential decay: e^(-0.05 * hours)
    final score = 1.0 / (1.0 + (hours / 24.0));
    return score.clamp(0.0, 1.0);
  }
  
  /// User Interest: based on past interactions
  static double _userInterestScore(
    Post post, {
    String? currentUserId,
    Map<String, int>? userInteractions,
  }) {
    if (userInteractions == null || post.authorId == currentUserId) {
      return 0.5; // Neutral
    }
    
    final interactions = userInteractions[post.authorId] ?? 0;
    
    // Normalize: more interactions = higher interest
    // Assuming max 50 interactions با یک user
    final normalized = (interactions / 50.0).clamp(0.0, 1.0);
    return normalized;
  }
}

/// Internal class برای scoring
class _ScoredPost {
  final Post post;
  final double score;
  
  _ScoredPost(this.post, this.score);
}
