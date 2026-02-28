// integration_test/app_test.dart
// Main integration test entry point - runs all critical tests

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'search_keyboard_overflow_test.dart' as search_tests;
import 'scheduled_message_test.dart' as scheduled_tests;
import 'notification_deep_link_test.dart' as notification_tests;
import 'message_deduplication_test.dart' as dedup_tests;
import 'message_ordering_test.dart' as ordering_tests;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('RAVEN Integration Tests', () {
    // Run all test groups
    search_tests.main();
    scheduled_tests.main();
    notification_tests.main();
    
    // Critical regression tests
    dedup_tests.main();
    ordering_tests.main();
  });
}
