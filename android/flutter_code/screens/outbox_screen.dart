import 'package:flutter/material.dart';
import '../models/message_model.dart';
import '../services/dtn_router_service.dart';
import '../services/bluetooth_mesh_service.dart';
import '../services/toast_service.dart';

/// Outbox Screen - نمایش پیام‌های pending
/// 
/// پیام‌هایی که منتظر ارسال هستند:
/// - بدون اینترنت
/// - بدون Bluetooth peer نزدیک
/// - در صف relay
class OutboxScreen extends StatefulWidget {
  const OutboxScreen({Key? key}) : super(key: key);

  @override
  State<OutboxScreen> createState() => _OutboxScreenState();
}

class _OutboxScreenState extends State<OutboxScreen> {
  final _dtnRouter = DTNRouterService.instance;
  final _bluetoothMesh = BluetoothMeshService.instance;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('📤 Outbox'),
        subtitle: const Text('پیام‌های در انتظار ارسال'),
      ),
      body: Column(
        children: [
          _buildStatusCard(),
          const SizedBox(height: 16),
          Expanded(
            child: _buildPendingMessages(),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard() {
    final peerCount = _bluetoothMesh.connectedPeerCount;
    final queueSize = _dtnRouter.relayQueueSize;

    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  peerCount > 0 ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                  color: peerCount > 0 ? Colors.blue : Colors.grey,
                ),
                const SizedBox(width: 8),
                Text(
                  '$peerCount Bluetooth Peers',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('$queueSize پیام در صف'),
            const Divider(),
            const Text(
              '💡 وقتی اینترنت برگرده یا device دیگه‌ای نزدیک شه، '
              'پیام‌ها خودکار ارسال می‌شن',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPendingMessages() {
    // از DTN router صف رو بگیریم
    final messages = _dtnRouter.getPendingMessages();

    if (messages.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle_outline, size: 64, color: Colors.green),
            SizedBox(height: 16),
            Text(
              'همه پیام‌ها ارسال شدن! ✅',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final msg = messages[index];
        return _buildMessageCard(msg);
      },
    );
  }

  Widget _buildMessageCard(ChatMessage msg) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: ListTile(
        leading: CircleAvatar(
          child: Text(_getStatusIcon(msg)),
        ),
        title: Text(msg.senderName),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              msg.text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              _getStatusText(msg),
              style: const TextStyle(fontSize: 11, color: Colors.orange),
            ),
          ],
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _formatTime(msg.timestamp),
              style: const TextStyle(fontSize: 11),
            ),
            const SizedBox(height: 4),
            _buildRetryButton(msg),
          ],
        ),
      ),
    );
  }

  String _getStatusIcon(ChatMessage msg) {
    if (msg.status == MessageStatus.forwarding) return '🔄';
    if (msg.status == MessageStatus.pending) return '⏳';
    return '📤';
  }

  String _getStatusText(ChatMessage msg) {
    if (msg.hopCount > 0) {
      return 'در حال relay (${msg.hopCount} hop) - ${msg.sprayCounter} کپی باقی';
    }
    return 'منتظر شبکه...';
  }

  Widget _buildRetryButton(ChatMessage msg) {
    return IconButton(
      icon: const Icon(Icons.refresh, size: 16),
      onPressed: () async {
        // تلاش مجدد برای ارسال
        await _dtnRouter.processRelayQueue();
        setState(() {});
        ToastService.showInfo('Retrying...');
      },
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inMinutes < 1) return 'الان';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

/// Widget برای نمایش badge تعداد pending messages
class OutboxBadge extends StatelessWidget {
  const OutboxBadge({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final queueSize = DTNRouterService.instance.relayQueueSize;

    if (queueSize == 0) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.orange,
        borderRadius: BorderRadius.circular(12),
      ),
      constraints: const BoxConstraints(
        minWidth: 20,
        minHeight: 20,
      ),
      child: Text(
        '$queueSize',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}
