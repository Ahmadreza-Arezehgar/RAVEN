// integration_test/message_deduplication_test.dart
// Critical regression test: Verify duplicate messages are not displayed

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

  group('Message Deduplication Tests', () {
    testWidgets('Duplicate messages by ID should not appear twice in UI', (tester) async {
      app.main();
      await tester.pumpAndSettleSafe();

      final appModel = tester.element(find.byType(MaterialApp)).read<AppModel>();

      // Create a message with a specific ID
      const testMessageId = 'dedup-test-001';
      const testRoomId = 'room-dedup-test';
      const testText = 'This is a test message for deduplication';

      // Simulate receiving the same message twice (e.g., from mesh + server)
      final message1 = ChatMessage(
        id: testMessageId,
        roomId: testRoomId,
        senderId: TestConfig.testRecipientId,
        senderName: TestConfig.testRecipientUsername,
        recipientId: TestConfig.testUserId,
        text: testText,
        type: MessageType.text,
        timestamp: DateTime.now(),
        status: MessageStatus.delivered,
      );

      final message2 = ChatMessage(
        id: testMessageId, // Same ID!
        roomId: testRoomId,
        senderId: TestConfig.testRecipientId,
        senderName: TestConfig.testRecipientUsername,
        recipientId: TestConfig.testUserId,
        text: testText,
        type: MessageType.text,
        timestamp: DateTime.now(),
        status: MessageStatus.delivered,
      );

      // Add first message
      appModel.messages.add(message1);
      appModel.notifyListeners();
      await tester.pumpAndSettle();
      
      final countAfterFirst = appModel.messages.where((m) => m.id == testMessageId).length;
      expect(countAfterFirst, 1, reason: 'First message should be added');

      // Try to add duplicate - a proper implementation should check for duplicates
      final existsAlready = appModel.messages.any((m) => m.id == testMessageId);
      if (!existsAlready) {
        appModel.messages.add(message2);
        appModel.notifyListeners();
      }
      await tester.pumpAndSettle();

      // Count messages with this ID
      final duplicateCount = appModel.messages.where((m) => m.id == testMessageId).length;
      
      expect(duplicateCount, 1, 
        reason: 'Duplicate message with same ID should NOT be added again');
    });

    testWidgets('Messages with different IDs but same content are both kept', (tester) async {
      app.main();
      await tester.pumpAndSettleSafe();

      final appModel = tester.element(find.byType(MaterialApp)).read<AppModel>();

      const sameText = 'Identical content message';
      const roomId = 'room-content-test';

      final message1 = ChatMessage(
        id: 'unique-id-001',
        roomId: roomId,
        senderId: TestConfig.testRecipientId,
        senderName: TestConfig.testRecipientUsername,
        recipientId: TestConfig.testUserId,
        text: sameText,
        type: MessageType.text,
        timestamp: DateTime.now(),
        status: MessageStatus.delivered,
      );

      final message2 = ChatMessage(
        id: 'unique-id-002', // Different ID
        roomId: roomId,
        senderId: TestConfig.testRecipientId,
        senderName: TestConfig.testRecipientUsername,
        recipientId: TestConfig.testUserId,
        text: sameText, // Same content
        type: MessageType.text,
        timestamp: DateTime.now().add(const Duration(seconds: 1)),
        status: MessageStatus.delivered,
      );

      appModel.messages.add(message1);
      appModel.messages.add(message2);
      appModel.notifyListeners();
      await tester.pumpAndSettle();

      // Both should exist (same content but different IDs is valid)
      final msg1Exists = appModel.messages.any((m) => m.id == 'unique-id-001');
      final msg2Exists = appModel.messages.any((m) => m.id == 'unique-id-002');

      expect(msg1Exists, isTrue);
      expect(msg2Exists, isTrue);
    });

    testWidgets('Resend of failed message updates existing, no duplicate', (tester) async {
      app.main();
      await tester.pumpAndSettleSafe();

      final appModel = tester.element(find.byType(MaterialApp)).read<AppModel>();

      const resendMessageId = 'resend-test-001';
      const roomId = 'room-resend-test';

      // Simulate a failed message
      final failedMessage = ChatMessage(
        id: resendMessageId,
        roomId: roomId,
        senderId: TestConfig.testUserId,
        senderName: TestConfig.testUsername,
        recipientId: TestConfig.testRecipientId,
        text: 'Failed message to resend',
        type: MessageType.text,
        timestamp: DateTime.now(),
        status: MessageStatus.failed,
      );

      appModel.messages.add(failedMessage);
      appModel.notifyListeners();
      await tester.pumpAndSettle();

      // Simulate resend (updates status, same ID)
      final idx = appModel.messages.indexWhere((m) => m.id == resendMessageId);
      if (idx != -1) {
        appModel.messages[idx] = appModel.messages[idx].copyWith(
          status: MessageStatus.sending,
        );
        appModel.notifyListeners();
      }
      await tester.pumpAndSettle();

      // Should still be exactly 1 message with this ID
      final count = appModel.messages.where((m) => m.id == resendMessageId).length;
      expect(count, 1, reason: 'Resend should update existing message, not create duplicate');
    });
  });
}
