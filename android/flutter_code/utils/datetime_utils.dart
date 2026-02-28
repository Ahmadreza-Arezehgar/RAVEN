import 'package:intl/intl.dart';

/// DateTime utilities for formatting timestamps
class DateTimeUtils {
  /// Format timestamp with full date and time
  /// Example: "Jan 22, 2026 - 2:47 PM"
  static String formatFullTimestamp(DateTime dateTime) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final targetDate = DateTime(dateTime.year, dateTime.month, dateTime.day);
    
    final time = DateFormat('h:mm a').format(dateTime); // "2:47 PM"
    
    // Today
    if (targetDate == today) {
      return 'Today - $time';
    }
    
    // Yesterday
    if (targetDate == today.subtract(const Duration(days: 1))) {
      return 'Yesterday - $time';
    }
    
    // This week (last 7 days)
    if (now.difference(dateTime).inDays < 7) {
      final dayName = DateFormat('EEEE').format(dateTime); // "Monday"
      return '$dayName - $time';
    }
    
    // This year
    if (dateTime.year == now.year) {
      final date = DateFormat('MMM d').format(dateTime); // "Jan 22"
      return '$date - $time';
    }
    
    // Full date
    final date = DateFormat('MMM d, yyyy').format(dateTime); // "Jan 22, 2026"
    return '$date - $time';
  }
  
  /// Format just the date part
  /// Example: "Jan 22, 2026"
  static String formatDate(DateTime dateTime) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final targetDate = DateTime(dateTime.year, dateTime.month, dateTime.day);
    
    if (targetDate == today) {
      return 'Today';
    }
    
    if (targetDate == today.subtract(const Duration(days: 1))) {
      return 'Yesterday';
    }
    
    if (dateTime.year == now.year) {
      return DateFormat('MMM d').format(dateTime);
    }
    
    return DateFormat('MMM d, yyyy').format(dateTime);
  }
  
  /// Get relative time (for less than 24 hours)
  /// Example: "2h ago", "5m ago"
  static String getRelativeTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);
    
    if (difference.inSeconds < 60) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h ago';
    } else {
      // Use full timestamp for older posts
      return formatFullTimestamp(dateTime);
    }
  }
}
