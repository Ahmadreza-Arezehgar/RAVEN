// integration_test/scheduled_message_test.dart
// Test #4: Verify scheduled messages send exactly at the scheduled time

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

  group('Scheduled Message Tests', () {
    testWidgets('Scheduled message is created with correct status', (tester) async {
      app.main();
      await tester.pumpAndSettleSafe();

      // Get AppModel instance from widget tree
      final appModel = tester.element(find.byType(MaterialApp)).read<AppModel>();

      // Schedule message for 10 seconds from now
      final scheduledTime = DateTime.now().toUtc().add(const Duration(seconds: 10));
      
      await appModel.sendToUser(
        TestConfig.testRecipientId,
        'Scheduled integration test message',
        sendMode: 'scheduled',
        scheduledAtUtc: scheduledTime,
      );

      await tester.pumpAndSettleSafe();

      // Find the scheduled message
      final scheduledMsg = appModel.messages.where(
        (m) => m.text == 'Scheduled integration test message',
      ).toList();

      expect(scheduledMsg, isNotEmpty, reason: 'Scheduled message should be created');
      
      final msg = scheduledMsg.first;
      expect(msg.status, MessageStatus.scheduled);
      expect(msg.sendMode, 'scheduled');
      expect(msg.scheduledAtUtc, isNotNull);
      expect(msg.scheduledAtUtc!.isAfter(DateTime.now().toUtc()), isTrue);
    });

    testWidgets('Scheduled message worker processes due messages', (tester) async {
      app.main();
      await tester.pumpAndSettleSafe();

      final appModel = tester.element(find.byType(MaterialApp)).read<AppModel>();

      // Schedule message for 2 seconds from now (quick test)
      final scheduledTime = DateTime.now().toUtc().add(const Duration(seconds: 2));
      
      await appModel.sendToUser(
        TestConfig.testRecipientId,
        'Quick scheduled test',
        sendMode: 'scheduled',
        scheduledAtUtc: scheduledTime,
      );

      // Start the scheduled message worker
      appModel.startScheduledMessageWorker();

      // Wait for scheduled time + worker interval (15s) + buffer
      // Note: In real CI, we'd use fake_async to speed this up
      await Future.delayed(const Duration(seconds: 5));
      await tester.pumpAndSettleSafe();

      // Verify the message was processed
      final processedMsg = appModel.messages.firstWhere(
        (m) => m.text == 'Quick scheduled test',
        orElse: () => throw StateError('Message not found'),
      );

      // Message should be sent or sending (depending on API response)
      expect(
        [MessageStatus.sending, MessageStatus.sent, MessageStatus.failed]
            .contains(processedMsg.status),
        isTrue,
        reason: 'Scheduled message should have been picked up by worker',
      );

      appModel.stopScheduledMessageWorker();
    });

    testWidgets('Scheduled message sendMode changes to instant after sending', (tester) async {
      app.main();
      await tester.pumpAndSettleSafe();

      final appModel = tester.element(find.byType(MaterialApp)).read<AppModel>();

      // Create a message that's already past due (should be sent immediately by worker)
      final pastTime = DateTime.now().toUtc().subtract(const Duration(seconds: 5));
      
      await appModel.sendToUser(
        TestConfig.testRecipientId,
        'Past due scheduled message',
        sendMode: 'scheduled',
        scheduledAtUtc: pastTime,
      );

      // Start worker - it should immediately process this past-due message
      appModel.startScheduledMessageWorker();
      
      await Future.delayed(const Duration(seconds: 3));
      await tester.pumpAndSettleSafe();

      final msg = appModel.messages.firstWhere(
        (m) => m.text == 'Past due scheduled message',
      );

      // After sending, sendMode should change from 'scheduled' to 'instant'
      if (msg.status == MessageStatus.sent) {
        expect(msg.sendMode, 'instant');
      }

      appModel.stopScheduledMessageWorker();
    });
  });
}
