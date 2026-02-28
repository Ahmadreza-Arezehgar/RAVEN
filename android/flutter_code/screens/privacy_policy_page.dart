import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

/// PrivacyPolicyPage - Detailed privacy policy with accurate data handling info
/// 
/// Describes exactly how RAVEN handles user data:
/// - Data collection
/// - Data storage (encryption, keychain)
/// - Data sharing (servers, third-party)
/// - User rights (deletion, export)
class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // Header
          SliverAppBar(
            pinned: true,
            expandedHeight: 120,
            backgroundColor: Colors.transparent,
            leading: IconButton(
              icon: const Icon(CupertinoIcons.back, color: Colors.white),
              onPressed: () {
                HapticFeedback.selectionClick();
                Navigator.pop(context);
              },
            ),
            flexibleSpace: FlexibleSpaceBar(
              title: const Text(
                'Privacy Policy',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
              background: ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.white.withOpacity(0.08),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Content
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                // Last updated
                Text(
                  'Last updated: January 2026',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.5),
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 24),

                // Introduction
                _buildSection(
                  title: 'Introduction',
                  content: '''RAVEN ("we", "our", or "us") is committed to protecting your privacy. This Privacy Policy explains exactly how we collect, use, store, and share your information when you use our messaging application.

We believe in transparency and want you to understand exactly what happens with your data.''',
                ),

                // Data We Collect
                _buildSection(
                  title: '1. Data We Collect',
                  content: '''We collect the following types of data:

**Account Information:**
• Username (required)
• Email address (required for login)
• Password (stored as a cryptographic hash, never in plain text)
• Profile picture (optional)
• Bio (optional)

**Message Data:**
• Message content is end-to-end encrypted
• We store encrypted message content on our servers temporarily for delivery
• Message metadata: sender ID, recipient ID, timestamps

**Device Information:**
• Device identifier for push notifications
• Public key fingerprint for Mesh networking
• App version and OS version

**Usage Data:**
• Last seen timestamp
• Friend list (user IDs only)
• Post engagement (likes, reposts, views)''',
                ),

                // Data Storage
                _buildSection(
                  title: '2. How We Store Your Data',
                  content: '''**Local Storage (on your device):**
• Messages are stored in an encrypted SQLite database
• Private encryption keys are stored in iOS Keychain (the most secure storage on iOS)
• Sensitive data is NEVER stored in plain text

**Server Storage:**
• All server communication uses TLS 1.3 encryption
• Passwords are hashed using bcrypt with salt
• Messages are stored encrypted and deleted after delivery confirmation
• Server data is backed up with encryption at rest

**Encryption Methods:**
• AES-256-GCM for message content
• Ed25519 for message signing
• HMAC-SHA256 for message authentication
• X25519 for key exchange in Mesh networking''',
                ),

                // Data Sharing
                _buildSection(
                  title: '3. How We Share Your Data',
                  content: '''**We DO share:**
• Public profile info (username, avatar) with other RAVEN users
• Messages with your intended recipients
• Posts in the public feed (visible to all users)
• Device fingerprint with mesh peers (for routing only)

**Third-Party Services:**
• Google Gemini AI: If you use @time_ask, your message is sent to Google's AI services. You can disable this in Settings.
• News API: Your general location (country/region) is used to fetch relevant news.

**We NEVER share:**
• Your email address with other users
• Your private encryption keys with anyone
• Your message content with advertisers
• Your data for marketing purposes

**We NEVER sell your data to anyone.**''',
                ),

                // Mesh Networking
                _buildSection(
                  title: '4. Mesh Networking',
                  content: '''When using offline Mesh messaging:

**What is shared:**
• Encrypted message payload
• Sender and recipient identifiers (hashed)
• Message routing metadata (TTL, hop count)
• Your device's public key fingerprint

**What is NOT shared:**
• Your actual message content (encrypted end-to-end)
• Your email or personal details
• Your location

All mesh communications are encrypted and authenticated. Intermediate relay devices cannot read your messages.''',
                ),

                // Your Rights
                _buildSection(
                  title: '5. Your Rights',
                  content: '''You have the right to:

**Access:** View all data we have about you in Settings
**Export:** Download your chat history (coming soon)
**Delete:** Delete your account and all associated data
**Revoke:** Disable Mesh networking or AI features anytime
**Opt-out:** Disable analytics and data collection

To exercise these rights:
• Go to Settings → Privacy & Security
• Or email: privacy@raven-messager.com''',
                ),

                // Account Deletion
                _buildSection(
                  title: '6. Account Deletion',
                  content: '''When you delete your account:

**Immediately deleted:**
• Your profile information
• Your posts and comments
• Your friend connections
• Your local app data

**Deleted within 30 days:**
• Server-side message copies
• Backup data
• Analytics data

**Retained for legal compliance:**
• Transaction records (if any)
• Abuse reports involving your account

To delete your account: Settings → Delete Account''',
                ),

                // Children's Privacy
                _buildSection(
                  title: '7. Children\'s Privacy',
                  content: '''RAVEN is not intended for children under 13.

For users under 18:
• Content filtering is enabled by default
• Certain features may be restricted
• We comply with COPPA and GDPR requirements

If you believe a child under 13 is using RAVEN, please contact us at: info@raven-messager.com''',
                ),

                // Security
                _buildSection(
                  title: '8. Security',
                  content: '''We implement industry-standard security measures:

• End-to-end encryption for all messages
• TLS 1.3 for all server communications
• iOS Keychain for sensitive key storage
• Regular security audits
• Bug bounty program for security researchers

To report security issues: info@raven-messager.com''',
                ),

                // Changes
                _buildSection(
                  title: '9. Changes to This Policy',
                  content: '''We may update this Privacy Policy periodically. When we make significant changes:

• We will notify you in-app
• The "Last updated" date will change
• Major changes require your review

Continued use of RAVEN after changes constitutes acceptance of the updated policy.''',
                ),

                // Contact
                _buildSection(
                  title: '10. Contact Us',
                  content: '''For privacy-related questions:

**Email:** info@raven-messager.com

We aim to respond within 48 hours.''',
                ),

                const SizedBox(height: 40),

                // Footer
                Center(
                  child: Text(
                    '© 2026 RAVEN. All rights reserved.',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.4),
                      fontSize: 12,
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection({required String title, required String content}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFF0A84FF),
              fontSize: 18,
              fontWeight: FontWeight.bold,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 12),
          _buildFormattedText(content),
        ],
      ),
    );
  }

  Widget _buildFormattedText(String text) {
    // Parse markdown-like formatting
    final lines = text.split('\n');
    List<InlineSpan> spans = [];

    for (int i = 0; i < lines.length; i++) {
      String line = lines[i];
      
      // Bold text handling (simple **text** pattern)
      if (line.contains('**')) {
        final parts = line.split('**');
        for (int j = 0; j < parts.length; j++) {
          spans.add(TextSpan(
            text: parts[j],
            style: TextStyle(
              color: Colors.white.withOpacity(j % 2 == 1 ? 1.0 : 0.8),
              fontWeight: j % 2 == 1 ? FontWeight.bold : FontWeight.normal,
              fontSize: 14,
              height: 1.5,
            ),
          ));
        }
      } else {
        spans.add(TextSpan(
          text: line,
          style: TextStyle(
            color: Colors.white.withOpacity(0.8),
            fontSize: 14,
            height: 1.5,
          ),
        ));
      }
      
      if (i < lines.length - 1) {
        spans.add(const TextSpan(text: '\n'));
      }
    }

    return RichText(
      text: TextSpan(children: spans),
    );
  }
}
