// integration_test/test_helpers.dart
// Common test utilities and mock setup for integration tests

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// Extension methods for common test actions
extension WidgetTesterExtensions on WidgetTester {
  /// Pump and settle with a reasonable timeout
  Future<void> pumpAndSettleSafe({
    Duration duration = const Duration(seconds: 5),
  }) async {
    await pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      duration,
    );
  }

  /// Navigate to a specific tab in the bottom navigation
  Future<void> navigateToTab(IconData icon) async {
    final tabFinder = find.byIcon(icon);
    if (tabFinder.evaluate().isNotEmpty) {
      await tap(tabFinder.first);
      await pumpAndSettleSafe();
    }
  }

  /// Safely enter text into a TextField
  Future<void> safeEnterText(Finder finder, String text) async {
    await tap(finder);
    await pump(const Duration(milliseconds: 100));
    await enterText(finder, text);
    await pump(const Duration(milliseconds: 100));
  }

  /// Assert no overflow errors occurred
  void assertNoOverflow() {
    expect(takeException(), isNull);
  }
}

/// Test configuration constants
class TestConfig {
  static const Duration defaultTimeout = Duration(seconds: 10);
  static const Duration animationDuration = Duration(milliseconds: 300);
  static const Duration keyboardDelay = Duration(milliseconds: 500);
  
  // Test user credentials
  static const String testUserId = 'test-user-001';
  static const String testUsername = 'testuser';
  static const String testRecipientId = 'test-recipient-001';
  static const String testRecipientUsername = 'alice';
}

/// Mock notification payload builder
class MockNotificationPayload {
  static String message(String userId, String username) {
    return 'message:$userId:$username';
  }
  
  static String friendRequest(String requesterId, String requesterUsername) {
    return 'friend_request:$requesterId:$requesterUsername';
  }
}
