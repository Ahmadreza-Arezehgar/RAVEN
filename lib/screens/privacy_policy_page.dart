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
                  content: '''RAVEN ("we", "our", or "us") wants to be completely honest with you about your data. This Privacy Policy explains exactly what we collect, what we do with it, and what we can't do.

**Let's be real:** We're a small team building a messenger. We're not perfect, but we're trying to be transparent.''',
                ),

                // Data We Collect
                _buildSection(
                  title: '1. What We Actually Collect',
                  content: '''Here's everything we collect - no hidden stuff:

**Account Info:**
• Username & email (to log you in)
• Password (hashed with bcrypt - we can't see it)
• Profile pic & bio (if you add them)
• Birth year (for age verification only)

**Messages:**
• Your messages ARE end-to-end encrypted
• BUT: We store encrypted messages on our server until delivered
• We CAN see metadata: who messaged who, when, message size
• We CANNOT read the actual message content

**Posts & Social:**
• Everything you post publicly - it's public!
• Likes, comments, who you follow
• This is visible to other users

**Device Stuff:**
• Push notification tokens
• Your public key for mesh networking
• Basic device info (iOS version, app version)

**Location (only if you enable it):**
• For local posts feature
• We don't track you continuously
• You can disable this anytime''',
                ),

                // What We Actually Do
                _buildSection(
                  title: '2. What We Actually Do With It',
                  content: '''**Local Storage (your phone):**
• Messages in encrypted SQLite database
• Keys in iOS Keychain (Apple's secure storage)
• We use standard iOS security - not custom crypto

**Our Servers:**
• Hosted on standard cloud infrastructure
• TLS encryption for data in transit
• Passwords hashed with bcrypt
• Messages deleted after delivery confirmation (usually)

**Honest note about encryption:**
• We use AES-256-GCM for messages
• Keys are generated on your device
• We genuinely cannot read your messages
• BUT: Metadata (who, when, size) is visible to us''',
                ),

                // Third Parties - Being Honest
                _buildSection(
                  title: '3. Third-Party Services (Important!)',
                  content: '''We use some external services. Here's what they get:

**Google Gemini AI (@ask feature):**
• When you use @ask, that text goes to Google
• Google's privacy policy applies to that data
• We have no control over what Google does with it
• Disable in Settings if you're concerned

**Push Notifications:**
• Apple Push Notification service
• They see that you got a notification
• Not the content

**We do NOT use:**
• Analytics SDKs (no Firebase Analytics, etc.)
• Ad networks
• Data brokers

**We do NOT sell your data. Period.**''',
                ),

                // Mesh Networking - Real Talk
                _buildSection(
                  title: '4. Mesh Networking - How It Really Works',
                  content: '''When you send messages via Bluetooth mesh:

**What other devices see:**
• Encrypted blob of data
• Sender & recipient IDs (hashed)
• Hop count and routing info

**What they CAN'T see:**
• Your actual message (it's encrypted)
• Your email or real identity
• Your exact location

**Honest limitations:**
• Mesh works best when many people use RAVEN nearby
• Range is limited by Bluetooth (~10-30 meters)
• Messages may take time to relay
• It's not magic - it's just passing encrypted data around''',
                ),

                // Your Rights
                _buildSection(
                  title: '5. Your Rights',
                  content: '''You can:

**See your data:** Settings → Account
**Delete everything:** Settings → Delete Account
**Turn off features:**
• Mesh networking: Settings → SOS Mode
• AI features: Don't use @ask
• Location: iOS Settings → RAVEN → Location

**Export data:** Not available yet (we're working on it)

Questions? Email: info@raven-messenger.com''',
                ),

                // Account Deletion
                _buildSection(
                  title: '6. When You Delete Your Account',
                  content: '''**Gone immediately:**
• Your profile
• Your posts
• Your friend list
• Local data on your phone

**Gone within 30 days:**
• Server message copies
• Backup data

**We might keep:**
• If someone reported you for abuse - that record stays
• Legal compliance stuff if required by law

**Honest note:** Once messages are delivered to others, we can't delete them from their devices.''',
                ),

                // Age Requirements
                _buildSection(
                  title: '7. Age Requirements',
                  content: '''We're not for kids under 13. Seriously.

If you're under 18:
• Be careful what you share
• Don't share personal info with strangers

If you find a child using RAVEN inappropriately, tell us: info@raven-messenger.com''',
                ),

                // Security - Being Real
                _buildSection(
                  title: '8. Security - Being Honest',
                  content: '''What we do:
• End-to-end encryption for messages ✓
• TLS for server communication ✓
• Secure key storage ✓

What we don't (yet):
• We haven't had an external security audit
• We don't have a bug bounty program (yet)
• We're a small team - we do our best

If you find a security issue:
• Please email: info@raven-messenger.com
• We'll take it seriously and fix it''',
                ),

                // Changes
                _buildSection(
                  title: '9. Policy Changes',
                  content: '''If we change this policy:
• We'll notify you in the app
• We'll update the date at the top
• Big changes = we'll ask you to review

You can always find the latest version in the app.''',
                ),

                // Contact
                _buildSection(
                  title: '10. Contact',
                  content: '''Questions? Concerns? Complaints?

**Email:** info@raven-messenger.com

We're real humans and we'll respond within a few days.

Thanks for trusting us with your data. We take that seriously.''',
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
