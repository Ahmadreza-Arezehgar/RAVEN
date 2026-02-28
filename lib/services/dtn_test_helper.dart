import 'package:flutter/material.dart';
import '../services/dtn_router_service.dart';
import '../services/bluetooth_mesh_service.dart';
import '../services/toast_service.dart';
import '../models/message_model.dart';

/// DTN Test Helper
/// برای تست سریع قابلیت mesh networking
class DTNTestHelper {
  static final DTNTestHelper instance = DTNTestHelper._();
  DTNTestHelper._();

  bool _isInitialized = false;

  /// Initialize DTN services for testing
  Future<void> initialize(String userId, String deviceId) async {
    if (_isInitialized) return;

    print('🧪 [DTN Test] Initializing...');

    // 1. Initialize DTN Router
    DTNRouterService.instance.initialize(
      userId: userId,
      deviceId: deviceId,
      sharedSecret: 'test-shared-secret-12345', // برای تست
    );

    // 2. Setup callbacks
    DTNRouterService.instance.onMessageDelivered = (msg) {
      print('✅ [DTN Test] Message delivered: ${msg.id}');
      print('   From: ${msg.senderName}');
      print('   Text: ${msg.text}');
      print('   Hops: ${msg.hopCount}');
    };

    DTNRouterService.instance.onBluetoothBroadcast = (msg) {
      print('📡 [DTN Test] Broadcasting message: ${msg.id}');
      BluetoothMeshService.instance.broadcast(msg);
    };

    DTNRouterService.instance.onServerUpload = (msgId) {
      print('🌐 [DTN Test] Message uploaded to server: $msgId');
    };

    // 3. Initialize Bluetooth Mesh
    await BluetoothMeshService.instance.initialize();

    _isInitialized = true;
    print('✅ [DTN Test] Initialized successfully!');
  }

  /// Send a test message
  Future<void> sendTestMessage({
    required String senderId,
    required String senderName,
    required String recipientId,
    required String text,
  }) async {
    if (!_isInitialized) {
      print('❌ [DTN Test] Not initialized! Call initialize() first');
      return;
    }

    final testMsg = ChatMessage(
      id: 'test-${DateTime.now().millisecondsSinceEpoch}',
      roomId: 'test-room',
      senderId: senderId,
      senderName: senderName,
      recipientId: recipientId,
      text: text,
      timestamp: DateTime.now(),
    );

    print('📤 [DTN Test] Sending test message...');
    await DTNRouterService.instance.sendMessage(testMsg);
  }

  /// Get status info
  String getStatus() {
    final peers = BluetoothMeshService.instance.connectedPeerCount;
    return '''
🔵 DTN Status:
  - Initialized: $_isInitialized
  - Connected Peers: $peers
  - Bluetooth: ${peers > 0 ? 'Active' : 'Waiting for peers'}
''';
  }

  /// Show test dialog
  static void showTestDialog(BuildContext context, String userId, String deviceId) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('🧪 DTN Mesh Test'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Test mesh networking:'),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () async {
                await instance.initialize(userId, deviceId);
                ToastService.showSuccess('DTN Initialized');
              },
              child: const Text('Initialize DTN'),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () async {
                await instance.sendTestMessage(
                  senderId: userId,
                  senderName: 'Test User',
                  recipientId: 'test-recipient',
                  text: 'Hello from mesh network! 👋',
                );
                ToastService.showSuccess('Test message sent');
              },
              child: const Text('Send Test Message'),
            ),
            const SizedBox(height: 16),
            Text(
              instance.getStatus(),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
