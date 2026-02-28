import 'package:flutter/material.dart';
import '../services/dtn_analytics_service.dart';
import '../services/toast_service.dart';

/// Debug Panel برای نمایش DTN metrics
class DTNDebugPanel extends StatefulWidget {
  const DTNDebugPanel({Key? key}) : super(key: key);

  @override
  State<DTNDebugPanel> createState() => _DTNDebugPanelState();
}

class _DTNDebugPanelState extends State<DTNDebugPanel> {
  final _analytics = DTNAnalyticsService.instance;
  late Timer _refreshTimer;

  @override
  void initState() {
    super.initState();
    // Auto-refresh هر 2 ثانیه
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      setState(() {});
    });
  }

  @override
  void dispose() {
    _refreshTimer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stats = _analytics.getStats();

    return Scaffold(
      appBar: AppBar(
        title: const Text('📊 DTN Debug Panel'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() {}),
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () {
              _analytics.reset();
              setState(() {});
            },
          ),
          IconButton(
            icon: const Icon(Icons.print),
            onPressed: () {
              _analytics.printReport();
              ToastService.showSuccess('Report printed to console');
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildSessionCard(stats),
          const SizedBox(height: 16),
          _buildMessagesCard(stats),
          const SizedBox(height: 16),
          _buildRelayCard(stats),
          const SizedBox(height: 16),
          _buildPerformanceCard(stats),
          const SizedBox(height: 16),
          _buildBatteryCard(stats),
        ],
      ),
    );
  }

  Widget _buildSessionCard(DTNStats stats) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '⏱️ SESSION',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const Divider(),
            _buildMetric('Duration', _formatDuration(stats.sessionDuration)),
          ],
        ),
      ),
    );
  }

  Widget _buildMessagesCard(DTNStats stats) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '📤 MESSAGES',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const Divider(),
            _buildMetric('Total Sent', '${stats.totalSent}'),
            _buildMetric('Delivered', '${stats.delivered}', color: Colors.green),
            _buildMetric('Failed', '${stats.failed}', color: Colors.red),
            _buildMetric(
              'Success Rate',
              '${stats.successRate.toStringAsFixed(1)}%',
              color: stats.successRate > 80 ? Colors.green : Colors.orange,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRelayCard(DTNStats stats) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '🔄 RELAY',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const Divider(),
            _buildMetric('Messages Relayed', '${stats.relayed}'),
            _buildMetric('Bluetooth Broadcasts', '${stats.bluetoothBroadcasts}'),
          ],
        ),
      ),
    );
  }

  Widget _buildPerformanceCard(DTNStats stats) {
    final avgTime = stats.averageDeliveryTime;
    final timeColor = avgTime.inSeconds < 5
        ? Colors.green
        : avgTime.inSeconds < 15
            ? Colors.orange
            : Colors.red;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '⚡ PERFORMANCE',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const Divider(),
            _buildMetric(
              'Avg Delivery Time',
              _formatDuration(avgTime),
              color: timeColor,
            ),
            _buildMetric(
              'Avg Hop Count',
              stats.averageHopCount.toStringAsFixed(2),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBatteryCard(DTNStats stats) {
    final batteryColor = stats.estimatedBatteryImpact < 5
        ? Colors.green
        : stats.estimatedBatteryImpact < 10
            ? Colors.orange
            : Colors.red;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '🔋 BATTERY',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const Divider(),
            _buildMetric(
              'Estimated Impact',
              '${stats.estimatedBatteryImpact.toStringAsFixed(2)}%/hour',
              color: batteryColor,
            ),
            const SizedBox(height: 8),
            Text(
              'Lower is better. Target: < 5%/hour',
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetric(String label, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 14)),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
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
}

/// Floating Debug Button
class DTNDebugButton extends StatelessWidget {
  const DTNDebugButton({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton(
      mini: true,
      onPressed: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const DTNDebugPanel()),
        );
      },
      child: const Icon(Icons.analytics),
      backgroundColor: Colors.purple,
    );
  }
}
