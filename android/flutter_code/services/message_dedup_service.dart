import 'dart:async';
import 'dart:developer';
import 'package:shared_preferences/shared_preferences.dart';

/// Message Deduplication Service
/// 
/// Prevents duplicate message processing in mesh network.
/// Each node maintains a cache of seen message IDs with TTL.
/// If a message with the same ID arrives again → DROP.
/// 
/// ✅ Now persists across app restarts using SharedPreferences
class MessageDedupService {
  static final MessageDedupService _instance = MessageDedupService._internal();
  static MessageDedupService get instance => _instance;
  MessageDedupService._internal();

  // Cache of seen message IDs with their expiry times
  final Map<String, DateTime> _seenMessageIds = {};
  
  // Default TTL for cache entries (24 hours)
  static const Duration _defaultTtl = Duration(hours: 24);
  
  // Cleanup timer
  Timer? _cleanupTimer;
  
  // SharedPreferences keys
  static const String _seenIdsKey = 'message_dedup_seen_ids';
  static const String _expiryTimesKey = 'message_dedup_expiry_times';
  
  // Debounce save to avoid excessive writes
  Timer? _saveDebounceTimer;
  
  /// Initialize the service and start cleanup timer
  Future<void> init() async {
    // Load persisted data
    await _loadFromStorage();
    
    // Run cleanup every hour
    _cleanupTimer = Timer.periodic(const Duration(hours: 1), (_) {
      _cleanup();
    });
    log('✅ MessageDedupService initialized (${_seenMessageIds.length} cached entries)');
  }
  
  /// Load persisted seen IDs from SharedPreferences
  Future<void> _loadFromStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final seenIds = prefs.getStringList(_seenIdsKey);
      final expiryTimes = prefs.getStringList(_expiryTimesKey);
      
      if (seenIds != null && expiryTimes != null && seenIds.length == expiryTimes.length) {
        final now = DateTime.now();
        for (int i = 0; i < seenIds.length; i++) {
          final expiry = DateTime.tryParse(expiryTimes[i]);
          if (expiry != null && now.isBefore(expiry)) {
            // Only load non-expired entries
            _seenMessageIds[seenIds[i]] = expiry;
          }
        }
        log('📥 [MessageDedup] Loaded ${_seenMessageIds.length} seen IDs from storage');
      }
    } catch (e) {
      log('⚠️ [MessageDedup] Failed to load from storage: $e');
    }
  }
  
  /// Save seen IDs to SharedPreferences (debounced)
  void _saveToStorage() {
    // Debounce saves to avoid excessive writes
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(const Duration(seconds: 2), () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final ids = _seenMessageIds.keys.toList();
        final expiries = _seenMessageIds.values.map((e) => e.toIso8601String()).toList();
        await prefs.setStringList(_seenIdsKey, ids);
        await prefs.setStringList(_expiryTimesKey, expiries);
        log('💾 [MessageDedup] Saved ${ids.length} seen IDs to storage');
      } catch (e) {
        log('⚠️ [MessageDedup] Failed to save to storage: $e');
      }
    });
  }
  
  /// Dispose the service
  void dispose() {
    _cleanupTimer?.cancel();
    _saveDebounceTimer?.cancel();
    _seenMessageIds.clear();
  }
  
  /// Check if a message is a duplicate
  /// Returns true if this message ID has been seen before
  bool isDuplicate(String messageId) {
    if (_seenMessageIds.containsKey(messageId)) {
      final expiry = _seenMessageIds[messageId]!;
      if (DateTime.now().isBefore(expiry)) {
        log('⏭️ Duplicate message dropped: $messageId');
        return true;
      } else {
        // Expired, remove it
        _seenMessageIds.remove(messageId);
        _saveToStorage();
      }
    }
    return false;
  }
  
  /// Mark a message as seen (add to cache)
  /// Call this AFTER successfully processing a message
  void markAsSeen(String messageId, {Duration? ttl}) {
    final expiry = DateTime.now().add(ttl ?? _defaultTtl);
    _seenMessageIds[messageId] = expiry;
    log('📝 Message marked as seen: $messageId (expires: $expiry)');
    _saveToStorage();  // Persist
  }
  
  /// Check if message was already seen AND mark it if not
  /// Returns true if duplicate (should be dropped)
  /// Returns false if new (and marks it as seen)
  bool checkAndMark(String messageId, {Duration? ttl}) {
    if (isDuplicate(messageId)) {
      return true; // Duplicate
    }
    markAsSeen(messageId, ttl: ttl);
    return false; // New message
  }
  
  /// Check if message has been finalized (ACK received)
  /// Once finalized, no more forwarding should happen
  bool isFinalized(String messageId) {
    final finalizedKey = 'finalized:$messageId';
    return _seenMessageIds.containsKey(finalizedKey);
  }
  
  /// Mark message as finalized (ACK received)
  /// This stops all further forwarding
  /// ✅ Uses longer TTL to prevent re-forwarding
  void markAsFinalized(String messageId) {
    // Use a special prefix to distinguish finalized from just seen
    final finalizedKey = 'finalized:$messageId';
    // Finalized entries expire after 48 hours (longer than normal)
    _seenMessageIds[finalizedKey] = DateTime.now().add(const Duration(hours: 48));
    log('✅ Message finalized: $messageId');
    _saveToStorage();  // Persist
  }
  
  /// Check if message is finalized
  bool checkFinalized(String messageId) {
    final finalizedKey = 'finalized:$messageId';
    return _seenMessageIds.containsKey(finalizedKey);
  }
  
  /// Get current cache size (for debugging)
  int get cacheSize => _seenMessageIds.length;
  
  /// Cleanup expired entries
  void _cleanup() {
    final now = DateTime.now();
    final expiredKeys = <String>[];
    
    _seenMessageIds.forEach((key, expiry) {
      if (now.isAfter(expiry)) {
        expiredKeys.add(key);
      }
    });
    
    for (final key in expiredKeys) {
      _seenMessageIds.remove(key);
    }
    
    if (expiredKeys.isNotEmpty) {
      log('🧹 Cleaned up ${expiredKeys.length} expired message IDs');
      _saveToStorage();  // Persist cleanup
    }
  }
  
  /// Force cleanup (for testing)
  void forceCleanup() => _cleanup();
  
  /// Clear all entries (for testing/reset)
  Future<void> clear() async {
    _seenMessageIds.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_seenIdsKey);
    await prefs.remove(_expiryTimesKey);
    log('🗑️ MessageDedupService cache cleared');
  }
}
