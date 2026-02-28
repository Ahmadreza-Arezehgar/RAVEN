/// ViewTracker Service - Session-level deduplication for view events
/// 
/// Prevents duplicate view API calls within a single app session.
/// All view recording should go through this service.
/// 
/// ✅ Now persists across hot reloads using SharedPreferences

import 'package:shared_preferences/shared_preferences.dart';

class ViewTrackerService {
  // Singleton pattern
  static final ViewTrackerService _instance = ViewTrackerService._();
  static ViewTrackerService get instance => _instance;
  ViewTrackerService._() {
    _loadFromStorage();  // Load persisted views on init
  }
  
  /// Set of postIds that have been viewed in this session
  final Set<String> _viewedPosts = {};
  
  /// SharedPreferences key for persisting viewed posts
  static const _storageKey = 'viewed_posts_session';
  
  /// Load viewed posts from SharedPreferences (survives hot reload)
  Future<void> _loadFromStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final storedList = prefs.getStringList(_storageKey);
      if (storedList != null && storedList.isNotEmpty) {
        _viewedPosts.addAll(storedList);
        print('👁️ [ViewTracker] Loaded ${storedList.length} viewed posts from storage');
      }
    } catch (e) {
      print('⚠️ [ViewTracker] Failed to load from storage: $e');
    }
  }
  
  /// Save viewed posts to SharedPreferences
  Future<void> _saveToStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_storageKey, _viewedPosts.toList());
    } catch (e) {
      print('⚠️ [ViewTracker] Failed to save to storage: $e');
    }
  }
  
  /// Check if a post should record a view (first time this session)
  /// Returns true if this is a NEW view, false if already recorded
  bool shouldRecordView(String postId) {
    if (_viewedPosts.contains(postId)) {
      print('👁️ [ViewTracker] Post ${postId.substring(0, 8)}... already viewed this session');
      return false;
    }
    _viewedPosts.add(postId);
    _saveToStorage();  // Persist async
    print('👁️ [ViewTracker] Registering view for post ${postId.substring(0, 8)}...');
    return true;
  }
  
  /// Mark a post as viewed (if calling API separately)
  void markAsViewed(String postId) {
    _viewedPosts.add(postId);
    _saveToStorage();
  }
  
  /// Check if a post has been viewed without marking it
  bool hasBeenViewed(String postId) => _viewedPosts.contains(postId);
  
  /// Clear all tracked views (call on logout or after 24h)
  Future<void> clear() async {
    _viewedPosts.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
    print('👁️ [ViewTracker] Session cleared');
  }
  
  /// Clear all tracked views and start fresh session
  /// Call this on app cold start if you want fresh session per launch
  static Future<void> resetSession() async {
    await instance.clear();
  }
  
  /// Debug: Get count of viewed posts
  int get viewedCount => _viewedPosts.length;
}
