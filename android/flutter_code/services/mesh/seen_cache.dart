import 'dart:async';

/// SeenCache - Message deduplication service for Mesh networking
/// 
/// Prevents reprocessing of messages that have already been handled,
/// which is critical for mesh networks where messages may be relayed
/// through multiple paths.
/// 
/// Features:
/// - In-memory Set of seen message IDs
/// - Automatic TTL-based expiration
/// - Thread-safe operations
class SeenCache {
  static final SeenCache _instance = SeenCache._();
  static SeenCache get instance => _instance;
  
  SeenCache._();

  /// Map of message ID -> expiration timestamp
  final Map<String, DateTime> _seenMessages = {};
  
  /// Timer for periodic cleanup
  Timer? _cleanupTimer;
  
  /// Initialize the cache with periodic cleanup
  void init() {
    // Clean up expired entries every 30 seconds
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _cleanup();
    });
  }
  
  /// Dispose cleanup timer
  void dispose() {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
  }

  /// Check if a message ID has been seen before
  /// Returns true if duplicate (already seen)
  bool isDuplicate(String messageId) {
    _cleanup(); // Clean expired entries first
    return _seenMessages.containsKey(messageId);
  }

  /// Mark a message as seen with TTL
  /// [messageId] - Unique message identifier
  /// [ttlSeconds] - How long to remember this message (default: 15 minutes)
  void markSeen(String messageId, {int ttlSeconds = 900}) {
    final expiresAt = DateTime.now().add(Duration(seconds: ttlSeconds));
    _seenMessages[messageId] = expiresAt;
  }

  /// Check if duplicate, and if not, mark as seen
  /// Returns true if this is a NEW message (not seen before)
  /// Returns false if this is a DUPLICATE (already seen)
  bool checkAndMark(String messageId, {int ttlSeconds = 900}) {
    if (isDuplicate(messageId)) {
      return false; // Duplicate
    }
    markSeen(messageId, ttlSeconds: ttlSeconds);
    return true; // New message
  }

  /// Get count of cached message IDs
  int get count => _seenMessages.length;

  /// Clear all cached entries
  void clear() {
    _seenMessages.clear();
  }

  /// Remove expired entries
  void _cleanup() {
    final now = DateTime.now();
    _seenMessages.removeWhere((_, expiresAt) => now.isAfter(expiresAt));
  }
}
