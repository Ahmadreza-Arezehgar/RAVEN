import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../main.dart';
import '../theme/ios_design_system.dart';
import '../gen_l10n/app_localizations.dart';
import '../services/database_helper.dart';
import '../screens/blocked_users_page.dart';
import '../screens/passcode_setup_page.dart';
import '../screens/two_step_verification_page.dart';
import '../screens/auto_delete_messages_page.dart';

/// Privacy & Security Settings - Main hub
class PrivacySecurityPage extends StatefulWidget {
  const PrivacySecurityPage({super.key});

  @override
  State<PrivacySecurityPage> createState() => _PrivacySecurityPageState();
}

class _PrivacySecurityPageState extends State<PrivacySecurityPage> {
  int _blockedUsersCount = 0;

  @override
  void initState() {
    super.initState();
    _loadBlockedUsersCount();
  }

  Future<void> _loadBlockedUsersCount() async {
    final blockedUsers = await DatabaseHelper.instance.getBlockedUsers();
    if (mounted) {
      setState(() {
        _blockedUsersCount = blockedUsers.length;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: iOSDesignSystem.baseBackground,
      appBar: AppBar(
        title: Text(l10n.privacyAndSecurity),
        backgroundColor: iOSDesignSystem.baseBackground,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _buildSettingsTile(
            context,
            icon: Icons.block_outlined,
            title: l10n.blockedUsers,
            subtitle: _blockedUsersCount > 0
                ? '$_blockedUsersCount ${l10n.blocked}'
                : l10n.noBlockedUsers,
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const BlockedUsersPage(),
                ),
              );
              // Refresh count when returning
              _loadBlockedUsersCount();
            },
          ),
          const SizedBox(height: 12),
          _buildSettingsTile(
            context,
            icon: Icons.lock_outline,
            title: l10n.passcodeAndFaceId,
            subtitle: l10n.setupPasscode,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const PasscodeSetupPage(),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _buildSettingsTile(
            context,
            icon: Icons.verified_user_outlined,
            title: l10n.twoStepVerification,
            subtitle: l10n.addExtraSecurity,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const TwoStepVerificationPage(),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _buildSettingsTile(
            context,
            icon: Icons.auto_delete_outlined,
            title: l10n.autoDeleteMessages,
            subtitle: l10n.automaticallyDeleteOldMessages,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const AutoDeleteMessagesPage(),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _buildSettingsTile(
            context,
            icon: Icons.architecture_outlined,
            title: l10n.technicalOverviewTitle,
            subtitle: l10n.technicalOverviewSubtitle,
            onTap: () => _openTechnicalOverview(),
          ),
        ],
      ),
    );
  }

  void _openTechnicalOverview() {
    // Open technology whitepaper in browser
    launchUrl(Uri.parse('https://raven-messager.com/technology.html'));
  }

  Widget _buildSettingsTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: iOSDesignSystem.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: iOSDesignSystem.glassBorderMedium,
          width: iOSDesignSystem.glassBorderWidth,
        ),
      ),
      child: ListTile(
        leading: Icon(icon, color: iOSDesignSystem.accentBlue),
        title: Text(
          title,
          style: iOSDesignSystem.textTheme.bodyLarge,
        ),
        subtitle: Text(
          subtitle,
          style: iOSDesignSystem.textTheme.bodySmall?.copyWith(
            color: iOSDesignSystem.textSecondary,
          ),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
