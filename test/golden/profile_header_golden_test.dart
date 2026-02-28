// test/golden/profile_header_golden_test.dart
// Golden test for profile header capsule + glass layout

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Profile Header Golden Tests', () {
    testWidgets('Profile header expanded state matches golden', (tester) async {
      // Build a standalone version of the profile header for golden comparison
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Container(
              color: Colors.black,
              child: SafeArea(
                child: _MockProfileHeader(isExpanded: true),
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      await expectLater(
        find.byType(_MockProfileHeader),
        matchesGoldenFile('ios/dark/profile_header_expanded.png'),
      );
    });

    testWidgets('Profile header collapsed state matches golden', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Container(
              color: Colors.black,
              child: SafeArea(
                child: _MockProfileHeader(isExpanded: false),
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      await expectLater(
        find.byType(_MockProfileHeader),
        matchesGoldenFile('ios/dark/profile_header_collapsed.png'),
      );
    });
  });
}

/// Mock profile header widget for golden testing
/// Mirrors the structure of _CollapsibleProfileHeader from account_settings_page.dart
class _MockProfileHeader extends StatelessWidget {
  final bool isExpanded;

  const _MockProfileHeader({required this.isExpanded});

  @override
  Widget build(BuildContext context) {
    final avatarSize = isExpanded ? 80.0 : 40.0;
    
    return Container(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Avatar
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: avatarSize,
            height: avatarSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.grey[700],
              border: Border.all(color: Colors.white24, width: 2),
            ),
            child: Center(
              child: Text(
                'JD',
                style: TextStyle(
                  fontSize: avatarSize * 0.35,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          // Info section
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'John Doe',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const Text(
                  '@johndoe',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white60,
                  ),
                ),
                if (isExpanded) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'Flutter developer & privacy advocate',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.white70,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Tags as capsule chips
                  Wrap(
                    spacing: 8,
                    children: [
                      _buildTag('iOS'),
                      _buildTag('Flutter'),
                      _buildTag('Privacy'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Joined January 2024',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white38,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTag(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 12,
          color: Colors.white70,
        ),
      ),
    );
  }
}
