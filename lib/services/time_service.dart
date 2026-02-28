import 'package:hybrid_messenger/services/api_service.dart';

/// Singleton service for unified UTC time management
/// 
/// This ensures all timestamps in the app are consistent regardless of
/// the device's local time settings.
/// 
/// Usage:
/// - `TimeService.instance.appNowUtc()` instead of `DateTime.now()`
/// - Call `syncWithServer()` on app startup
class TimeService {
  static final TimeService instance = TimeService._();
  TimeService._();
  
  /// Offset between server time and device time
  /// Positive = server is ahead, Negative = server is behind
  Duration _serverOffset = Duration.zero;
  
  /// Whether we've successfully synced with server
  bool _isSynced = false;
  bool get isSynced => _isSynced;
  
  /// Get the current UTC time, adjusted for server offset
  /// This is the SINGLE SOURCE OF TRUTH for time in the app
  DateTime appNowUtc() => DateTime.now().toUtc().add(_serverOffset);
  
  /// Get offset in human-readable format (for debugging)
  String get offsetString {
    final secs = _serverOffset.inSeconds;
    if (secs == 0) return '0s';
    return '${secs > 0 ? '+' : ''}${secs}s';
  }
  
  /// Sync with server time
  /// Call this on app startup and periodically (e.g., every hour)
  Future<void> syncWithServer() async {
    try {
      final beforeRequest = DateTime.now().toUtc();
      final serverTime = await ApiService.getServerTime();
      final afterRequest = DateTime.now().toUtc();
      
      // Estimate network latency (round trip / 2)
      final latency = afterRequest.difference(beforeRequest) ~/ 2;
      
      // Calculate offset (server - device) accounting for latency
      _serverOffset = serverTime.difference(beforeRequest.add(latency));
      _isSynced = true;
      
      print('⏰ [TimeService] Synced with server. Offset: $offsetString');
    } catch (e) {
      print('⚠️ [TimeService] Failed to sync: $e (using device time)');
      // Keep using device time if sync fails
      _serverOffset = Duration.zero;
    }
  }
  
  /// Convert a UTC timestamp to local time for display
  static DateTime toLocal(DateTime utc) => utc.toLocal();
  
  /// Format a timestamp as "X minutes ago" using server-synced time
  String timeAgo(DateTime timestamp) {
    final now = appNowUtc();
    final diff = now.difference(timestamp);
    
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    if (diff.inDays < 30) return '${diff.inDays ~/ 7}w ago';
    return '${diff.inDays ~/ 30}mo ago';
  }
  
  /// Format timestamp for display (e.g., "10:30 AM" or "Jan 25")
  String formatTime(DateTime timestamp, {bool showDate = false}) {
    final local = timestamp.toLocal();
    final now = appNowUtc().toLocal();
    final today = DateTime(now.year, now.month, now.day);
    final msgDate = DateTime(local.year, local.month, local.day);
    
    if (msgDate == today && !showDate) {
      // Today: show time only
      final hour = local.hour > 12 ? local.hour - 12 : (local.hour == 0 ? 12 : local.hour);
      final ampm = local.hour >= 12 ? 'PM' : 'AM';
      return '${hour}:${local.minute.toString().padLeft(2, '0')} $ampm';
    } else {
      // Other days: show date
      final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 
                      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      return '${months[local.month - 1]} ${local.day}';
    }
  }
}
