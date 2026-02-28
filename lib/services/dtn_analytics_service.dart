import 'dart:async';
import 'dart:convert';
import '../models/message_model.dart';

/// DTN Analytics Service
/// Track و نمایش metrics برای performance monitoring
class DTNAnalyticsService {
  static final DTNAnalyticsService instance = DTNAnalyticsService._();
  DTNAnalyticsService._();

  // Metrics storage
  final _deliveryTimes = <String, Duration>{}; // messageId -> delivery time
  final _hopCounts = <String, int>{}; // messageId -> hop count
  final _routeMethods = <String, String>{}; // messageId -> 'wifi', 'bluetooth', 'relay'
  
  int _totalMessagesSent = 0;
  int _messagesDelivered = 0;
  int _messagesFailed = 0;
  int _messagesRelayed = 0;
  int _bluetoothBroadcasts = 0;
  
  DateTime? _sessionStart;
  
  // Battery tracking
  DateTime? _lastBatteryCheck;
  double _estimatedBatteryImpact = 0.0; // percentage per hour

  /// Initialize analytics
  void initialize() {
    _sessionStart = DateTime.now();
    print('📊 [Analytics] Session started');
  }

  /// Track message sent
  void trackMessageSent(ChatMessage msg, String method) {
    _totalMessagesSent++;
    _routeMethods[msg.id] = method;
    
    print('📤 [Analytics] Message sent via $method: ${msg.id}');
  }

  /// Track message delivered
  void trackMessageDelivered(ChatMessage msg) {
    _messagesDelivered++;
    
    // Calculate delivery time
    final deliveryTime = DateTime.now().difference(msg.timestamp);
    _deliveryTimes[msg.id] = deliveryTime;
    _hopCounts[msg.id] = msg.hopCount;
    
    print('✅ [Analytics] Message delivered:');
    print('   ID: ${msg.id}');
    print('   Delivery time: ${deliveryTime.inSeconds}s');
    print('   Hop count: ${msg.hopCount}');
    print('   Via: ${_routeMethods[msg.id] ?? 'unknown'}');
  }

  /// Track message failed
  void trackMessageFailed(String messageId, String reason) {
    _messagesFailed++;
    print('❌ [Analytics] Message failed: $messageId - $reason');
  }

  /// Track relay event
  void trackRelay(String messageId, int currentHop) {
    _messagesRelayed++;
    print('🔄 [Analytics] Relayed message $messageId (hop $currentHop)');
  }

  /// Track Bluetooth broadcast
  void trackBluetoothBroadcast(String messageId) {
    _bluetoothBroadcasts++;
    print('📡 [Analytics] Bluetooth broadcast: $messageId');
  }

  /// Get delivery statistics
  DTNStats getStats() {
    return DTNStats(
      totalSent: _totalMessagesSent,
      delivered: _messagesDelivered,
      failed: _messagesFailed,
      relayed: _messagesRelayed,
      bluetoothBroadcasts: _bluetoothBroadcasts,
      averageDeliveryTime: _calculateAverageDeliveryTime(),
      averageHopCount: _calculateAverageHopCount(),
      successRate: _calculateSuccessRate(),
      sessionDuration: _getSessionDuration(),
      estimatedBatteryImpact: _estimatedBatteryImpact,
    );
  }

  Duration _calculateAverageDeliveryTime() {
    if (_deliveryTimes.isEmpty) return Duration.zero;
    
    final totalMs = _deliveryTimes.values
        .map((d) => d.inMilliseconds)
        .reduce((a, b) => a + b);
    
    return Duration(milliseconds: totalMs ~/ _deliveryTimes.length);
  }

  double _calculateAverageHopCount() {
    if (_hopCounts.isEmpty) return 0.0;
    
    final total = _hopCounts.values.reduce((a, b) => a + b);
    return total / _hopCounts.length;
  }

  double _calculateSuccessRate() {
    if (_totalMessagesSent == 0) return 0.0;
    return (_messagesDelivered / _totalMessagesSent) * 100;
  }

  Duration _getSessionDuration() {
    if (_sessionStart == null) return Duration.zero;
    return DateTime.now().difference(_sessionStart!);
  }

  /// Update battery impact estimate
  /// Call this periodically with battery level changes
  void updateBatteryImpact(double percentageDrop, Duration duration) {
    if (duration.inHours > 0) {
      _estimatedBatteryImpact = percentageDrop / duration.inHours;
      print('🔋 [Analytics] Battery impact: ${_estimatedBatteryImpact.toStringAsFixed(2)}%/hour');
    }
  }

  /// Print detailed report
  void printReport() {
    final stats = getStats();
    
    print('\n═══════════════════════════════════════');
    print('📊 DTN ANALYTICS REPORT');
    print('═══════════════════════════════════════');
    print('Session Duration: ${_formatDuration(stats.sessionDuration)}');
    print('');
    print('📤 MESSAGES:');
    print('   Total Sent: ${stats.totalSent}');
    print('   Delivered: ${stats.delivered}');
    print('   Failed: ${stats.failed}');
    print('   Success Rate: ${stats.successRate.toStringAsFixed(1)}%');
    print('');
    print('🔄 RELAY:');
    print('   Messages Relayed: ${stats.relayed}');
    print('   Bluetooth Broadcasts: ${stats.bluetoothBroadcasts}');
    print('');
    print('⚡ PERFORMANCE:');
    print('   Avg Delivery Time: ${_formatDuration(stats.averageDeliveryTime)}');
    print('   Avg Hop Count: ${stats.averageHopCount.toStringAsFixed(2)}');
    print('');
    print('🔋 BATTERY:');
    print('   Estimated Impact: ${stats.estimatedBatteryImpact.toStringAsFixed(2)}%/hour');
    print('═══════════════════════════════════════\n');
  }

  /// Export stats as JSON
  Map<String, dynamic> exportJson() {
    final stats = getStats();
    return {
      'session_duration_seconds': stats.sessionDuration.inSeconds,
      'messages': {
        'total_sent': stats.totalSent,
        'delivered': stats.delivered,
        'failed': stats.failed,
        'success_rate': stats.successRate,
      },
      'relay': {
        'messages_relayed': stats.relayed,
        'bluetooth_broadcasts': stats.bluetoothBroadcasts,
      },
      'performance': {
        'avg_delivery_time_seconds': stats.averageDeliveryTime.inSeconds,
        'avg_hop_count': stats.averageHopCount,
      },
      'battery': {
        'estimated_impact_per_hour': stats.estimatedBatteryImpact,
      },
      'detailed_deliveries': _deliveryTimes.entries.map((e) => {
        'message_id': e.key,
        'delivery_time_seconds': e.value.inSeconds,
        'hop_count': _hopCounts[e.key] ?? 0,
        'method': _routeMethods[e.key] ?? 'unknown',
      }).toList(),
    };
  }

  String _formatDuration(Duration d) {
    if (d.inHours > 0) {
      return '${d.inHours}h ${d.inMinutes % 60}m';
    } else if (d.inMinutes > 0) {
      return '${d.inMinutes}m ${d.inSeconds % 60}s';
    } else {
      return '${d.inSeconds}s';
    }
  }

  /// Reset all metrics
  void reset() {
    _deliveryTimes.clear();
    _hopCounts.clear();
    _routeMethods.clear();
    _totalMessagesSent = 0;
    _messagesDelivered = 0;
    _messagesFailed = 0;
    _messagesRelayed = 0;
    _bluetoothBroadcasts = 0;
    _sessionStart = DateTime.now();
    _estimatedBatteryImpact = 0.0;
    print('🔄 [Analytics] Metrics reset');
  }
}

/// DTN Statistics Model
class DTNStats {
  final int totalSent;
  final int delivered;
  final int failed;
  final int relayed;
  final int bluetoothBroadcasts;
  final Duration averageDeliveryTime;
  final double averageHopCount;
  final double successRate;
  final Duration sessionDuration;
  final double estimatedBatteryImpact;

  DTNStats({
    required this.totalSent,
    required this.delivered,
    required this.failed,
    required this.relayed,
    required this.bluetoothBroadcasts,
    required this.averageDeliveryTime,
    required this.averageHopCount,
    required this.successRate,
    required this.sessionDuration,
    required this.estimatedBatteryImpact,
  });
}
