// integration_test/search_keyboard_overflow_test.dart
// Test #1: Verify search screen handles keyboard without UI overflow

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hybrid_messenger/main.dart' as app;
import 'package:hybrid_messenger/screens/search_page.dart';

import 'test_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Search Screen Keyboard Tests', () {
    testWidgets('Search screen handles keyboard without overflow', (tester) async {
      // Launch the app
      app.main();
      await tester.pumpAndSettleSafe();

      // Navigate to Search tab
      await tester.navigateToTab(Icons.search);
      
      // Verify SearchPage is displayed
      expect(find.byType(SearchPage), findsOneWidget);

      // Find the search TextField
      final searchField = find.byType(TextField).first;
      expect(searchField, findsOneWidget);

      // Tap to focus (opens keyboard in test environment)
      await tester.tap(searchField);
      await tester.pump(TestConfig.keyboardDelay);

      // Enter search text
      await tester.enterText(searchField, 'test query');
      await tester.pumpAndSettleSafe();

      // Assert no RenderFlex overflow exception occurred
      tester.assertNoOverflow();

      // Verify UI is still visible and usable
      expect(find.byType(SearchPage), findsOneWidget);
      expect(find.text('test query'), findsOneWidget);
    });

    testWidgets('Search results visible when keyboard is open', (tester) async {
      app.main();
      await tester.pumpAndSettleSafe();

      await tester.navigateToTab(Icons.search);

      final searchField = find.byType(TextField).first;
      await tester.tap(searchField);
      await tester.pump(TestConfig.keyboardDelay);

      await tester.enterText(searchField, 'a');
      await tester.pumpAndSettleSafe();

      // Verify the explore/results content area is still accessible
      // (not pushed off screen by keyboard)
      tester.assertNoOverflow();
      
      // The search page should not have any overflow widgets
      final overflowWarning = find.textContaining('OVERFLOWED');
      expect(overflowWarning, findsNothing);
    });

    testWidgets('Keyboard dismissal restores layout', (tester) async {
      app.main();
      await tester.pumpAndSettleSafe();

      await tester.navigateToTab(Icons.search);

      final searchField = find.byType(TextField).first;
      
      // Open keyboard
      await tester.tap(searchField);
      await tester.pump(TestConfig.keyboardDelay);
      await tester.enterText(searchField, 'test');
      await tester.pumpAndSettleSafe();

      // Dismiss keyboard by tapping outside
      await tester.tapAt(const Offset(100, 100));
      await tester.pumpAndSettleSafe();

      // Layout should be restored without errors
      tester.assertNoOverflow();
      expect(find.byType(SearchPage), findsOneWidget);
    });
  });
}
