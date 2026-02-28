import 'package:flutter/material.dart';

/// Message Status Indicator Widget
/// نمایش وضعیت ارسال پیام با آیکون‌های مختلف
class MessageStatusIndicator extends StatelessWidget {
  final String via;  // 'wifi', 'bluetooth', 'relay_queue', 'mesh'
  final bool isDelivered;
  final int? hopCount;

  const MessageStatusIndicator({
    Key? key,
    required this.via,
    this.isDelivered = false,
    this.hopCount,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          _getIcon(),
          size: 14,
          color: _getColor(),
        ),
        if (hopCount != null && hopCount! > 0) ...[
          const SizedBox(width: 4),
          Text(
            '$hopCount hop${hopCount! > 1 ? 's' : ''}',
            style: TextStyle(
              fontSize: 10,
              color: _getColor(),
            ),
          ),
        ],
      ],
    );
  }

  IconData _getIcon() {
    switch (via) {
      case 'wifi':
      case 'internet':
      case 'server':
        return Icons.wifi;
      case 'bluetooth':
      case 'mesh':
        return Icons.bluetooth;
      case 'relay_queue':
      case 'forwarding':
        return Icons.hourglass_empty;
      default:
        return Icons.send;
    }
  }

  Color _getColor() {
    if (isDelivered) return Colors.green;
    if (via == 'relay_queue' || via == 'forwarding') return Colors.orange;
    return Colors.blue;
  }
}

/// Outbox Floating Action Button
/// دکمه شناور برای دسترسی سریع به Outbox
class OutboxFAB extends StatefulWidget {
  const OutboxFAB({Key? key}) : super(key: key);

  @override
  State<OutboxFAB> createState() => _OutboxFABState();
}

class _OutboxFABState extends State<OutboxFAB> {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int>(
      stream: _getQueueSizeStream(),
      builder: (context, snapshot) {
        final queueSize = snapshot.data ?? 0;
        
        if (queueSize == 0) return const SizedBox.shrink();

        return FloatingActionButton.extended(
          onPressed: () {
            Navigator.pushNamed(context, '/outbox');
          },
          icon: const Icon(Icons.outbox),
          label: Text('$queueSize pending'),
          backgroundColor: Colors.orange,
        );
      },
    );
  }

  Stream<int> _getQueueSizeStream() {
    // این یک مثال ساده است - در پیاده‌سازی واقعی از StreamController استفاده کنید
    return Stream.periodic(
      const Duration(seconds: 2),
      (_) => 0, // اینجا از DTNRouterService.instance.relayQueueSize استفاده کنید
    );
  }
}

/// Network Status Banner
/// بنر برای نمایش وضعیت شبکه
class NetworkStatusBanner extends StatelessWidget {
  final bool hasInternet;
  final int bluetoothPeers;
  final int pendingMessages;

  const NetworkStatusBanner({
    Key? key,
    required this.hasInternet,
    required this.bluetoothPeers,
    required this.pendingMessages,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (hasInternet || bluetoothPeers > 0) {
      return const SizedBox.shrink(); // همه چیز خوب است
    }

    if (pendingMessages == 0) {
      return const SizedBox.shrink(); // پیام pending نداریم
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      color: Colors.orange.shade100,
      child: Row(
        children: [
          const Icon(Icons.warning_amber, color: Colors.orange),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$pendingMessages پیام در انتظار. '
              'برای ارسال به اینترنت یا Bluetooth دستگاه دیگری نیاز دارید.',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pushNamed(context, '/outbox');
            },
            child: const Text('مشاهده'),
          ),
        ],
      ),
    );
  }
}
