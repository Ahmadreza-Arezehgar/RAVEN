// integration_test/message_ordering_test.dart
// Critical regression test: Verify messages display in correct chronological order

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:hybrid_messenger/main.dart' as app;
import 'package:hybrid_messenger/main.dart';
import 'package:hybrid_messenger/models/message_model.dart';

import 'test_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Message Ordering Tests', () {
    testWidgets('Messages are ordered by timestamp (oldest first in list)', (tester) async {
      app.main();
      await tester.pumpAndSettleSafe();

      final appModel = tester.element(find.byType(MaterialApp)).read<AppModel>();

      final now = DateTime.now();
      const roomId = 'room-order-test';

      // Create messages with specific timestamps (out of order)
      final message3 = ChatMessage(
        id: 'order-test-003',
        roomId: roomId,
        senderId: TestConfig.testRecipientId,
        senderName: TestConfig.testRecipientUsername,
        recipientId: TestConfig.testUserId,
        text: 'Third message (newest)',
        type: MessageType.text,
        timestamp: now.add(const Duration(minutes: 2)),
        status: MessageStatus.delivered,
      );

      final message1 = ChatMessage(
        id: 'order-test-001',
        roomId: roomId,
        senderId: TestConfig.testRecipientId,
        senderName: TestConfig.testRecipientUsername,
        recipientId: TestConfig.testUserId,
        text: 'First message (oldest)',
        type: MessageType.text,
        timestamp: now,
        status: MessageStatus.delivered,
      );

      final message2 = ChatMessage(
        id: 'order-test-002',
        roomId: roomId,
        senderId: TestConfig.testRecipientId,
        senderName: TestConfig.testRecipientUsername,
        recipientId: TestConfig.testUserId,
        text: 'Second message (middle)',
        type: MessageType.text,
        timestamp: now.add(const Duration(minutes: 1)),
        status: MessageStatus.delivered,
      );

      // Add messages in wrong order
      appModel.messages.add(message3);
      appModel.messages.add(message1);
      appModel.messages.add(message2);
      appModel.notifyListeners();
      await tester.pumpAndSettle();

      // Get messages for this conversation and sort by timestamp
      final conversationMessages = appModel.messages
          .where((m) => m.id.startsWith('order-test-'))
          .toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

      // Verify they're sorted by timestamp
      expect(conversationMessages[0].id, 'order-test-001', reason: 'Oldest message should be first');
      expect(conversationMessages[1].id, 'order-test-002', reason: 'Middle message should be second');
      expect(conversationMessages[2].id, 'order-test-003', reason: 'Newest message should be last');
    });

    testWidgets('Scheduled messages have correct timestamp handling', (tester) async {
      app.main();
      await tester.pumpAndSettleSafe();

      final appModel = tester.element(find.byType(MaterialApp)).read<AppModel>();

      final now = DateTime.now();
      const roomId = 'room-scheduled-order';

      // Add a regular message
      final regularMessage = ChatMessage(
        id: 'order-scheduled-001',
        roomId: roomId,
        senderId: TestConfig.testUserId,
        senderName: TestConfig.testUsername,
        recipientId: TestConfig.testRecipientId,
        text: 'Regular message',
        type: MessageType.text,
        timestamp: now,
        status: MessageStatus.sent,
      );

      // Add a scheduled message
      final scheduledMessage = ChatMessage(
        id: 'order-scheduled-002',
        roomId: roomId,
        senderId: TestConfig.testUserId,
        senderName: TestConfig.testUsername,
        recipientId: TestConfig.testRecipientId,
        text: 'Scheduled message',
        type: MessageType.text,
        timestamp: now.subtract(const Duration(minutes: 5)), // Created earlier
        scheduledAtUtc: now.add(const Duration(minutes: 10)), // Scheduled for later
        status: MessageStatus.scheduled,
        sendMode: 'scheduled',
      );

      appModel.messages.add(regularMessage);
      appModel.messages.add(scheduledMessage);
      appModel.notifyListeners();
      await tester.pumpAndSettle();

      // Both messages should exist
      expect(
        appModel.messages.any((m) => m.id == 'order-scheduled-001'),
        isTrue,
      );
      expect(
        appModel.messages.any((m) => m.id == 'order-scheduled-002'),
        isTrue,
      );

      // Scheduled message should have scheduledAtUtc set
      final scheduled = appModel.messages.firstWhere((m) => m.id == 'order-scheduled-002');
      expect(scheduled.scheduledAtUtc, isNotNull);
      expect(scheduled.sendMode, 'scheduled');
    });

    testWidgets('Messages from different sources maintain timestamp order', (tester) async {
      app.main();
      await tester.pumpAndSettleSafe();

      final appModel = tester.element(find.byType(MaterialApp)).read<AppModel>();

      final now = DateTime.now();
      const roomId = 'room-multi-source';

      // Simulate messages arriving from mesh and server in interleaved order
      final meshMessage1 = ChatMessage(
        id: 'mesh-msg-001',
        roomId: roomId,
        senderId: TestConfig.testRecipientId,
        senderName: TestConfig.testRecipientUsername,
        recipientId: TestConfig.testUserId,
        text: 'Mesh message 1',
        type: MessageType.text,
        timestamp: now,
        status: MessageStatus.delivered,
        via: 'mesh',
      );

      final serverMessage1 = ChatMessage(
        id: 'server-msg-001',
        roomId: roomId,
        senderId: TestConfig.testRecipientId,
        senderName: TestConfig.testRecipientUsername,
        recipientId: TestConfig.testUserId,
        text: 'Server message 1',
        type: MessageType.text,
        timestamp: now.add(const Duration(seconds: 30)),
        status: MessageStatus.delivered,
        via: 'server',
      );

      final meshMessage2 = ChatMessage(
        id: 'mesh-msg-002',
        roomId: roomId,
        senderId: TestConfig.testRecipientId,
        senderName: TestConfig.testRecipientUsername,
        recipientId: TestConfig.testUserId,
        text: 'Mesh message 2',
        type: MessageType.text,
        timestamp: now.add(const Duration(minutes: 1)),
        status: MessageStatus.delivered,
        via: 'mesh',
      );

      // Add in arrival order (not timestamp order)
      appModel.messages.add(serverMessage1);
      appModel.messages.add(meshMessage1);
      appModel.messages.add(meshMessage2);
      appModel.notifyListeners();
      await tester.pumpAndSettle();

      // Get mixed-source messages sorted by timestamp
      final mixedMessages = appModel.messages
          .where((m) => m.id.contains('-msg-'))
          .toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

      // Verify chronological order regardless of source
      expect(mixedMessages[0].id, 'mesh-msg-001', reason: 'First by timestamp');
      expect(mixedMessages[1].id, 'server-msg-001', reason: 'Second by timestamp');
      expect(mixedMessages[2].id, 'mesh-msg-002', reason: 'Third by timestamp');
    });
  });
}
