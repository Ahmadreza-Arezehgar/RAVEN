import 'package:flutter/material.dart';
import '../gen_l10n/app_localizations.dart';
import '../theme/ios_design_system.dart';

/// FAQ Page with comprehensive guides and feature tutorials
class FAQPage extends StatelessWidget {
  const FAQPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    return Scaffold(
      backgroundColor: iOSDesignSystem.baseBackground,
      appBar: AppBar(
        title: Text(l10n.faqTitle),
        backgroundColor: iOSDesignSystem.baseBackground,
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Quick Start Guide Section
          _buildSectionHeader(
            l10n.faqQuickStartTitle,
            l10n.faqQuickStartSubtitle,
          ),
          _buildGuideItem(
            l10n.faqSendMessageTitle,
            l10n.faqSendMessageQuestion,
            l10n.faqSendMessageSteps,
            Icons.send_rounded,
          ),
          _buildGuideItem(
            l10n.faqAddFriendTitle,
            l10n.faqAddFriendQuestion,
            l10n.faqAddFriendSteps,
            Icons.person_add_rounded,
          ),
          _buildGuideItem(
            l10n.faqCreatePostTitle,
            l10n.faqCreatePostQuestion,
            l10n.faqCreatePostSteps,
            Icons.post_add_rounded,
          ),
          _buildGuideItem(
            l10n.faqAiTitle,
            l10n.faqAiQuestion,
            l10n.faqAiSteps,
            Icons.auto_awesome,
          ),
          _buildGuideItem(
            l10n.faqVoiceTitle,
            l10n.faqVoiceQuestion,
            l10n.faqVoiceSteps,
            Icons.mic_rounded,
          ),
          _buildGuideItem(
            l10n.faqBackupTitle,
            l10n.faqBackupQuestion,
            l10n.faqBackupSteps,
            Icons.cloud_upload_rounded,
          ),

          const SizedBox(height: 24),

          // FAQ Section
          _buildSectionHeader(
            l10n.faqSectionTitle,
            l10n.faqSectionSubtitle,
          ),
          _buildFAQItem(
            l10n.faqWhatIsRaivenTitle,
            l10n.faqWhatIsRaivenAnswer,
          ),
          _buildFAQItem(
            l10n.faqOfflineTitle,
            l10n.faqOfflineAnswer,
          ),
          _buildFAQItem(
            l10n.faqSecurityTitle,
            l10n.faqSecurityAnswer,
          ),
          _buildFAQItem(
            l10n.faqStatusTitle,
            l10n.faqStatusAnswer,
          ),
          _buildFAQItem(
            l10n.faqBridgeTitle,
            l10n.faqBridgeAnswer,
          ),
          _buildFAQItem(
            l10n.faqInternetTitle,
            l10n.faqInternetAnswer,
          ),
          _buildFAQItem(
            l10n.faqDuplicateTitle,
            l10n.faqDuplicateAnswer,
          ),
          _buildFAQItem(
            l10n.faqDtnTitle,
            l10n.faqDtnAnswer,
          ),
          _buildFAQItem(
            l10n.faqLanguagesTitle,
            l10n.faqLanguagesAnswer,
          ),
          _buildFAQItem(
            l10n.faqWhitepaperTitle,
            l10n.faqWhitepaperAnswer,
          ),
          _buildFAQItem(
            l10n.faqLocalFeedTitle,
            l10n.faqLocalFeedAnswer,
          ),
          _buildFAQItem(
            l10n.faqSocialFeaturesTitle,
            l10n.faqSocialFeaturesAnswer,
          ),
          _buildFAQItem(
            l10n.faqHowMeshWorksTitle,
            l10n.faqHowMeshWorksAnswer,
          ),

          const SizedBox(height: 24),

          // Tips Section
          _buildSectionHeader(
            l10n.faqTipsTitle,
            l10n.faqTipsSubtitle,
          ),
          _buildTipItem(
            l10n.faqTipBluetooth,
            l10n.faqTipBluetoothDesc,
            Icons.bluetooth_rounded,
          ),
          _buildTipItem(
            l10n.faqTipBackup,
            l10n.faqTipBackupDesc,
            Icons.backup_rounded,
          ),
          _buildTipItem(
            l10n.faqTipQr,
            l10n.faqTipQrDesc,
            Icons.qr_code_rounded,
          ),
          _buildTipItem(
            l10n.faqTipNotifications,
            l10n.faqTipNotificationsDesc,
            Icons.notifications_rounded,
          ),

          const SizedBox(height: 32),

          // Contact Section
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: iOSDesignSystem.tertiaryBackground,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: iOSDesignSystem.opaqueSeparator,
              ),
            ),
            child: Column(
              children: [
                const Icon(
                  Icons.support_agent_rounded,
                  size: 48,
                  color: iOSDesignSystem.systemBlue,
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.faqContactTitle,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: iOSDesignSystem.primaryLabel,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.faqContactEmail,
                  style: TextStyle(
                    fontSize: 14,
                    color: iOSDesignSystem.systemBlue,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16, top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: iOSDesignSystem.primaryLabel,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 14,
              color: iOSDesignSystem.secondaryLabel,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGuideItem(
      String title, String question, String steps, IconData icon) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      color: iOSDesignSystem.tertiaryBackground,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: iOSDesignSystem.opaqueSeparator),
      ),
      child: ExpansionTile(
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: iOSDesignSystem.systemBlue.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            icon,
            color: iOSDesignSystem.systemBlue,
            size: 22,
          ),
        ),
        title: Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 15,
            color: iOSDesignSystem.primaryLabel,
          ),
        ),
        subtitle: Text(
          question,
          style: TextStyle(
            fontSize: 13,
            color: iOSDesignSystem.secondaryLabel,
          ),
        ),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: iOSDesignSystem.baseBackground,
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(12),
                bottomRight: Radius.circular(12),
              ),
            ),
            child: Text(
              steps,
              style: TextStyle(
                fontSize: 14,
                height: 1.6,
                color: iOSDesignSystem.primaryLabel,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFAQItem(String question, String answer) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      color: iOSDesignSystem.tertiaryBackground,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: iOSDesignSystem.opaqueSeparator),
      ),
      child: ExpansionTile(
        title: Text(
          question,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 15,
            color: iOSDesignSystem.primaryLabel,
          ),
        ),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: iOSDesignSystem.baseBackground,
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(12),
                bottomRight: Radius.circular(12),
              ),
            ),
            child: Text(
              answer,
              style: TextStyle(
                fontSize: 14,
                height: 1.6,
                color: iOSDesignSystem.primaryLabel,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTipItem(String title, String description, IconData icon) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: iOSDesignSystem.systemGreen.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: iOSDesignSystem.systemGreen.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: iOSDesignSystem.systemGreen.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              icon,
              color: iOSDesignSystem.systemGreen,
              size: 20,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: iOSDesignSystem.primaryLabel,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 13,
                    color: iOSDesignSystem.secondaryLabel,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
