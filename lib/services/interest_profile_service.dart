import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/post_model.dart';
import '../utils/hashtag_utils.dart';

/// Interest Profile Service
/// Tracks user interests and scores posts for "For You" ranking
class InterestProfileService {
  static final InterestProfileService _instance = InterestProfileService._internal();
  factory InterestProfileService() => _instance;
  InterestProfileService._internal();

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  static const String _keyTagWeights = 'interest_tag_weights';
  static const String _keyAuthorWeights = 'interest_author_weights';

  // In-memory cache
  Map<String, double> _tagWeights = {};
  Map<String, double> _authorWeights = {};
  bool _loaded = false;

  // ══════════════════════════════════════════════════════════════
  // WEIGHT CONSTANTS
  // ══════════════════════════════════════════════════════════════
  static const double likeBoost = 2.0;
  static const double commentBoost = 3.0;
  static const double shareBoost = 4.0;
  static const double viewBoost = 0.5;
  static const double dwellTimeBoost = 0.2; // per second
  static const double hashtagTapBoost = 1.5;
  static const double decayFactor = 0.95;

  // ══════════════════════════════════════════════════════════════
  // INITIALIZATION
  // ══════════════════════════════════════════════════════════════
  
  /// Load interest profile from storage
  Future<void> load() async {
    if (_loaded) return;

    try {
      final tagJson = await _storage.read(key: _keyTagWeights);
      if (tagJson != null) {
        final decoded = jsonDecode(tagJson) as Map<String, dynamic>;
        _tagWeights = decoded.map((k, v) => MapEntry(k, (v as num).toDouble()));
      }

      final authorJson = await _storage.read(key: _keyAuthorWeights);
      if (authorJson != null) {
        final decoded = jsonDecode(authorJson) as Map<String, dynamic>;
        _authorWeights = decoded.map((k, v) => MapEntry(k, (v as num).toDouble()));
      }

      _loaded = true;
    } catch (e) {
      _tagWeights = {};
      _authorWeights = {};
    }
  }

  /// Save interest profile to storage
  Future<void> _save() async {
    await _storage.write(key: _keyTagWeights, value: jsonEncode(_tagWeights));
    await _storage.write(key: _keyAuthorWeights, value: jsonEncode(_authorWeights));
  }

  // ══════════════════════════════════════════════════════════════
  // WEIGHT MANAGEMENT
  // ══════════════════════════════════════════════════════════════
  
  /// Boost hashtag weight
  void boostTag(String tag, double weight) {
    final key = tag.toLowerCase();
    _tagWeights[key] = (_tagWeights[key] ?? 0) + weight;
    _save();
  }

  /// Boost author weight
  void boostAuthor(String authorId, double weight) {
    _authorWeights[authorId] = (_authorWeights[authorId] ?? 0) + weight;
    _save();
  }

  /// Apply decay to all weights (call periodically, e.g., daily)
  void decay() {
    for (final key in _tagWeights.keys.toList()) {
      _tagWeights[key] = (_tagWeights[key]! * decayFactor);
      if (_tagWeights[key]! < 0.1) _tagWeights.remove(key);
    }
    for (final key in _authorWeights.keys.toList()) {
      _authorWeights[key] = (_authorWeights[key]! * decayFactor);
      if (_authorWeights[key]! < 0.1) _authorWeights.remove(key);
    }
    _save();
  }

  // ══════════════════════════════════════════════════════════════
  // EVENT TRACKING
  // ══════════════════════════════════════════════════════════════
  
  /// Track user liked a post
  void trackLike(Post post) {
    final tags = extractHashtags(post.content);
    for (final tag in tags) {
      boostTag(tag, likeBoost);
    }
    boostAuthor(post.authorId, likeBoost);
  }

  /// Track user commented on a post
  void trackComment(Post post) {
    final tags = extractHashtags(post.content);
    for (final tag in tags) {
      boostTag(tag, commentBoost);
    }
    boostAuthor(post.authorId, commentBoost);
  }

  /// Track user shared a post
  void trackShare(Post post) {
    final tags = extractHashtags(post.content);
    for (final tag in tags) {
      boostTag(tag, shareBoost);
    }
    boostAuthor(post.authorId, shareBoost);
  }

  /// Track user viewed a post (dwell time in seconds)
  void trackDwellTime(Post post, double seconds) {
    if (seconds < 2) return; // Ignore very short views
    
    final boost = seconds * dwellTimeBoost;
    final tags = extractHashtags(post.content);
    for (final tag in tags) {
      boostTag(tag, boost);
    }
    boostAuthor(post.authorId, viewBoost);
  }

  /// Track user tapped a hashtag
  void trackHashtagTap(String tag) {
    boostTag(tag, hashtagTapBoost);
  }

  // ══════════════════════════════════════════════════════════════
  // POST SCORING
  // ══════════════════════════════════════════════════════════════
  
  /// Calculate score for a post based on user interests
  double scorePost(Post post) {
    double score = 0;

    // Hashtag match
    final postTags = extractHashtags(post.content);
    for (final tag in postTags) {
      score += (_tagWeights[tag.toLowerCase()] ?? 0);
    }

    // Author match
    score += (_authorWeights[post.authorId] ?? 0);

    // Freshness bonus (posts < 24h get bonus)
    final ageHours = DateTime.now().difference(post.timestamp).inHours;
    if (ageHours <= 24) {
      final freshness = 1.0 - (ageHours / 24.0);
      score += freshness * 2; // Up to 2 points for fresh posts
    }

    // Engagement bonus
    final engagementScore = (post.likes * 0.1) + (post.comments * 0.2);
    score += engagementScore.clamp(0, 5); // Cap at 5 points

    return score;
  }

  /// Sort posts by score (For You)
  List<Post> sortByScore(List<Post> posts) {
    final scored = posts.toList();
    scored.sort((a, b) => scorePost(b).compareTo(scorePost(a)));
    return scored;
  }

  /// Get top interests (for debugging/display)
  Map<String, double> getTopTags({int limit = 10}) {
    final sorted = _tagWeights.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Map.fromEntries(sorted.take(limit));
  }

  /// Reset all interests
  Future<void> reset() async {
    _tagWeights = {};
    _authorWeights = {};
    await _storage.delete(key: _keyTagWeights);
    await _storage.delete(key: _keyAuthorWeights);
  }
}
