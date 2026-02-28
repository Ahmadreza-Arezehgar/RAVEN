import 'package:flutter/material.dart';
import '../theme/ios_design_system.dart';

enum SearchPrivacy { public, private, none }

/// Privacy Settings Page
class PrivacySettingsPage extends StatefulWidget {
  const PrivacySettingsPage({super.key});

  @override
  State<PrivacySettingsPage> createState() => _PrivacySettingsPageState();
}

class _PrivacySettingsPageState extends State<PrivacySettingsPage> {
  SearchPrivacy _selectedPrivacy = SearchPrivacy.public;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: iOSDesignSystem.baseBackground,
      appBar: AppBar(
        title: const Text('Search Privacy'),
        backgroundColor: iOSDesignSystem.baseBackground,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Who can find you in search?',
            style: iOSDesignSystem.textTheme.titleLarge,
          ),
          const SizedBox(height: 20),
          _buildPrivacyOption(
            SearchPrivacy.public,
            'Public',
            'Anyone can find and add you',
            Icons.public,
          ),
          const SizedBox(height: 12),
          _buildPrivacyOption(
            SearchPrivacy.private,
            'Private',
            'Only friends can find you',
            Icons.lock_outline,
          ),
          const SizedBox(height: 12),
          _buildPrivacyOption(
            SearchPrivacy.none,
            'None',
            'Hidden from all searches',
            Icons.visibility_off_outlined,
          ),
        ],
      ),
    );
  }

  Widget _buildPrivacyOption(
    SearchPrivacy value,
    String title,
    String description,
    IconData icon,
  ) {
    final isSelected = _selectedPrivacy == value;
    
    return GestureDetector(
      onTap: () => setState(() => _selectedPrivacy = value),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected
              ? iOSDesignSystem.accentBlue.withOpacity(0.1)
              : iOSDesignSystem.surfaceCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? iOSDesignSystem.accentBlue
                : iOSDesignSystem.glassBorderMedium,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: isSelected
                  ? iOSDesignSystem.accentBlue
                  : iOSDesignSystem.textSecondary,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: iOSDesignSystem.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    description,
                    style: iOSDesignSystem.textTheme.bodySmall?.copyWith(
                      color: iOSDesignSystem.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              const Icon(
                Icons.check_circle,
                color: iOSDesignSystem.accentBlue,
              ),
          ],
        ),
      ),
    );
  }
}
