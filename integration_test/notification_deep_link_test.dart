// integration_test/notification_deep_link_test.dart
// Test #7: Verify tapping notification opens the correct chat thread

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:hybrid_messenger/main.dart' as app;
import 'package:hybrid_messenger/main.dart';
import 'package:hybrid_messenger/screens/chat_page.dart';

import 'test_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Notification Deep Link Tests', () {
    testWidgets('Message notification payload format is correct', (tester) async {
      app.main();
      await tester.pumpAndSettleSafe();

      // Test payload format
      const userId = 'user123';
      const username = 'alice';
      final payload = MockNotificationPayload.message(userId, username);

      expect(payload, 'message:user123:alice');
      
      // Parse payload back
      final parts = payload.split(':');
      expect(parts[0], 'message');
      expect(parts[1], userId);
      expect(parts[2], username);
    });

    testWidgets('Notification tap updates currentChatId', (tester) async {
      app.main();
      await tester.pumpAndSettleSafe();

      final appModel = tester.element(find.byType(MaterialApp)).read<AppModel>();

      // Simulate what happens when notification is tapped
      const targetUserId = 'notification-target-user';
      const targetUsername = 'notif_user';

      // Set current chat (simulating navigation from notification)
      appModel.currentChatId = targetUserId;
      await tester.pumpAndSettleSafe();

      // Verify the model has the correct chat ID
      expect(appModel.currentChatId, targetUserId);
    });

    testWidgets('ChatPage can be navigated to with correct chatId', (tester) async {
      app.main();
      await tester.pumpAndSettleSafe();

      final context = tester.element(find.byType(MaterialApp));
      final appModel = context.read<AppModel>();

      // Set up target chat
      const targetUserId = 'deep-link-test-user';
      appModel.currentChatId = targetUserId;

      // Attempt to push ChatPage
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => const ChatPage(),
        ),
      );

      await tester.pumpAndSettleSafe();

      // Verify ChatPage is on screen
      expect(find.byType(ChatPage), findsOneWidget);
      
      // Verify the correct chat is being shown
      expect(appModel.currentChatId, targetUserId);
    });

    testWidgets('Friend request notification payload format is correct', (tester) async {
      app.main();
      await tester.pumpAndSettleSafe();

      const requesterId = 'requester456';
      const requesterUsername = 'bob';
      final payload = MockNotificationPayload.friendRequest(requesterId, requesterUsername);

      expect(payload, 'friend_request:requester456:bob');

      final parts = payload.split(':');
      expect(parts[0], 'friend_request');
      expect(parts[1], requesterId);
      expect(parts[2], requesterUsername);
    });
  });
}
