import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../main.dart';
import '../services/api_service.dart';
import '../services/consent_service.dart';
import '../widgets/settings_components.dart';
import '../widgets/feature_consent_dialog.dart';
import '../gen_l10n/app_localizations.dart';

/// Settings Screen - Liquid Glass Design with Collapsible Profile Header
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final model = context.watch<AppModel>();
    final l10n = AppLocalizations.of(context)!;
    final user = model.currentUser;
    final statusBarHeight = MediaQuery.of(context).padding.top;
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // ═══════════════════════════════════════════════════════════════════
          // COLLAPSIBLE PROFILE HEADER
          // ═══════════════════════════════════════════════════════════════════
          SliverAppBar(
            pinned: true,
            expandedHeight: 160,
            backgroundColor: Colors.transparent,
            elevation: 0,
            automaticallyImplyLeading: false,
            flexibleSpace: LayoutBuilder(
              builder: (context, constraints) {
                final maxH = 160.0;
                final minH = kToolbarHeight + statusBarHeight;
                final t = ((constraints.maxHeight - minH) / (maxH - minH))
                    .clamp(0.0, 1.0);

                return _AnimatedProfileHeader(
                  t: t,
                  avatarUrl: user?.avatarPath != null && user!.avatarPath!.isNotEmpty
                      ? (user.avatarPath!.startsWith('http')
                          ? user.avatarPath!
                          : '${ApiService.baseUrl}${user.avatarPath}')
                      : null,
                  name: user?.username ?? l10n.settings,
                  subtitle: 'Change Profile Photo',
                  onTap: () {
                    HapticFeedback.selectionClick();
                    Navigator.pushNamed(context, '/profile-edit');
                  },
                );
              },
            ),
          ),

          // ═══════════════════════════════════════════════════════════════════
          // SETTINGS CONTENT
          // ═══════════════════════════════════════════════════════════════════
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: bottomPadding + 100,
              ),
              child: Column(
                children: [
                  // ═══════════════════════════════════════════════════════════
                  // PROFILE SECTION
                  // ═══════════════════════════════════════════════════════════
                  SettingsSectionCard(
                    children: [
                      SettingsRow(
                        icon: CupertinoIcons.person_fill,
                        iconColor: SettingsColors.red,
                        title: l10n.editProfile,
                        onTap: () => _navigateTo(context, '/profile-edit'),
                      ),
                      SettingsRow(
                        icon: CupertinoIcons.creditcard_fill,
                        iconColor: SettingsColors.blue,
                        title: 'Wallet',
                        badge: const NewBadge(),
                        onTap: () => _navigateTo(context, '/wallet'),
                      ),
                    ],
                  ),

                  const SizedBox(height: 18),

                  // ═══════════════════════════════════════════════════════════
                  // MESSAGES SECTION
                  // ═══════════════════════════════════════════════════════════
                  SettingsSectionCard(
                    children: [
                      SettingsRow(
                        icon: CupertinoIcons.bookmark_fill,
                        iconColor: SettingsColors.blue,
                        title: 'Saved Messages',
                        onTap: () => _navigateTo(context, '/saved-messages'),
                      ),
                      SettingsRow(
                        icon: CupertinoIcons.phone_fill,
                        iconColor: SettingsColors.green,
                        title: 'Recent Calls',
                        onTap: () => _navigateTo(context, '/recent-calls'),
                      ),
                    ],
                  ),

                  const SizedBox(height: 18),

                  // ═══════════════════════════════════════════════════════════
                  // PRIVACY SECTION
                  // ═══════════════════════════════════════════════════════════
                  SettingsSectionCard(
                    title: l10n.privacyAndSecurity.toUpperCase(),
                    children: [
                      SettingsToggleRow(
                        icon: CupertinoIcons.eye_fill,
                        iconColor: SettingsColors.purple,
                        title: l10n.showUsernameTitle,
                        subtitle: l10n.showUsernameSubtitle,
                        value: model.currentUser?.showUsername ?? true,
                        onChanged: (val) => model.togglePrivacy(val),
                      ),
                    ],
                  ),

                  const SizedBox(height: 18),

                  // ═══════════════════════════════════════════════════════════
                  // FEATURE CONSENTS SECTION
                  // ═══════════════════════════════════════════════════════════
                  _FeatureConsentsSection(),


                  const SizedBox(height: 18),

                  // ═══════════════════════════════════════════════════════════
                  // SOS MODE SECTION
                  // ═══════════════════════════════════════════════════════════
                  SettingsSectionCard(
                    title: l10n.sosModeTitle.toUpperCase(),
                    children: [
                      SettingsToggleRow(
                        icon: CupertinoIcons.antenna_radiowaves_left_right,
                        iconColor: SettingsColors.red,
                        title: l10n.enableRelayTitle,
                        subtitle: l10n.enableRelaySubtitle,
                        value: model.relayEnabled,
                        onChanged: (val) => model.setRelayEnabled(val),
                      ),
                      SettingsRow(
                        icon: Icons.route,
                        iconColor: SettingsColors.teal,
                        title: l10n.maxHops,
                        subtitle: l10n.hopsCount(model.maxHops),
                        showChevron: false,
                        onTap: () => _showHopsSelector(context, model, l10n),
                      ),
                    ],
                  ),

                  const SizedBox(height: 18),

                  // ═══════════════════════════════════════════════════════════
                  // MESH NETWORK SECTION
                  // ═══════════════════════════════════════════════════════════
                  SettingsSectionCard(
                    title: l10n.meshNetwork.toUpperCase(),
                    children: [
                      SettingsRow(
                        icon: CupertinoIcons.wifi,
                        iconColor: SettingsColors.green,
                        title: l10n.nearbyPeers(model.meshPeers.length),
                        subtitle: model.meshPeers.isNotEmpty
                            ? model.meshPeers.take(3).join(', ')
                            : 'No peers discovered',
                        showChevron: false,
                      ),
                    ],
                  ),

                  const SizedBox(height: 18),

                  // ═══════════════════════════════════════════════════════════
                  // DEBUG SECTION
                  // ═══════════════════════════════════════════════════════════
                  SettingsSectionCard(
                    children: [
                      SettingsRow(
                        icon: Icons.bug_report,
                        iconColor: SettingsColors.gray,
                        title: l10n.debugLogs,
                        onTap: () => _navigateTo(context, '/debug'),
                      ),
                      SettingsRow(
                        icon: Icons.delete_forever,
                        iconColor: SettingsColors.red,
                        title: l10n.clearAllDataTitle,
                        subtitle: l10n.clearAllDataSubtitle,
                        onTap: () => _showClearDataDialog(context, model, l10n),
                      ),
                    ],
                  ),

                  const SizedBox(height: 18),

                  // ═══════════════════════════════════════════════════════════
                  // ACCOUNT SECTION (Delete Account)
                  // ═══════════════════════════════════════════════════════════
                  SettingsSectionCard(
                    title: 'ACCOUNT',
                    children: [
                      SettingsRow(
                        icon: CupertinoIcons.doc_text_fill,
                        iconColor: SettingsColors.blue,
                        title: 'Privacy Policy',
                        subtitle: 'How we handle your data',
                        onTap: () => _navigateTo(context, '/privacy-policy'),
                      ),
                      SettingsRow(
                        icon: CupertinoIcons.person_badge_minus_fill,
                        iconColor: SettingsColors.red,
                        title: 'Delete Account',
                        subtitle: 'Permanently delete your account and data',
                        onTap: () => _showDeleteAccountDialog(context, model),
                      ),
                    ],
                  ),

                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _navigateTo(BuildContext context, String route) {
    HapticFeedback.selectionClick();
    Navigator.pushNamed(context, route);
  }

  void _showHopsSelector(BuildContext context, AppModel model, AppLocalizations l10n) {
    HapticFeedback.selectionClick();
    showCupertinoModalPopup(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(l10n.maxHops),
        actions: [3, 5, 10].map((value) {
          return CupertinoActionSheetAction(
            onPressed: () {
              model.setMaxHops(value);
              Navigator.pop(context);
            },
            child: Text(
              '$value hops',
              style: TextStyle(
                color: model.maxHops == value
                    ? CupertinoColors.activeBlue
                    : CupertinoColors.label,
                fontWeight: model.maxHops == value
                    ? FontWeight.bold
                    : FontWeight.normal,
              ),
            ),
          );
        }).toList(),
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
      ),
    );
  }

  Future<void> _showClearDataDialog(
    BuildContext context,
    AppModel model,
    AppLocalizations l10n,
  ) async {
    HapticFeedback.selectionClick();
    final confirm = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(l10n.clearAllDataDialogTitle),
        content: Text(l10n.clearAllDataDialogContent),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );

    if (confirm == true && context.mounted) {
      await model.clearAllData();
    }
  }

  /// Show Delete Account confirmation dialog
  Future<void> _showDeleteAccountDialog(
    BuildContext context,
    AppModel model,
  ) async {
    HapticFeedback.mediumImpact();
    final confirm = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(CupertinoIcons.exclamationmark_triangle_fill, color: CupertinoColors.destructiveRed, size: 22),
            SizedBox(width: 8),
            Text('Delete Account'),
          ],
        ),
        content: const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Text(
            'This will permanently delete your account, messages, posts, and all associated data. This action cannot be undone.',
            textAlign: TextAlign.center,
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete Forever'),
          ),
        ],
      ),
    );

    if (confirm == true && context.mounted) {
      // Show loading indicator
      showCupertinoDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(
          child: CupertinoActivityIndicator(radius: 20),
        ),
      );

      try {
        // Call delete account method
        await model.deleteAccount();
        
        if (context.mounted) {
          Navigator.of(context).pop(); // Dismiss loading
          // Navigate to login/splash
          Navigator.of(context).pushNamedAndRemoveUntil('/splash', (route) => false);
        }
      } catch (e) {
        if (context.mounted) {
          Navigator.of(context).pop(); // Dismiss loading
          showCupertinoDialog(
            context: context,
            builder: (context) => CupertinoAlertDialog(
              title: const Text('Error'),
              content: Text('Failed to delete account: $e'),
              actions: [
                CupertinoDialogAction(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('OK'),
                ),
              ],
            ),
          );
        }
      }
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// FEATURE CONSENTS SECTION
// ═══════════════════════════════════════════════════════════════════════════════

/// Widget to manage feature consent toggles (Mesh & Gemini AI)
class _FeatureConsentsSection extends StatefulWidget {
  @override
  State<_FeatureConsentsSection> createState() => _FeatureConsentsSectionState();
}

class _FeatureConsentsSectionState extends State<_FeatureConsentsSection> {
  bool _meshEnabled = false;
  bool _geminiEnabled = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadConsents();
  }

  Future<void> _loadConsents() async {
    final consent = ConsentService.instance;
    final mesh = await consent.hasMeshConsent();
    final gemini = await consent.hasGeminiConsent();
    if (mounted) {
      setState(() {
        _meshEnabled = mesh;
        _geminiEnabled = gemini;
        _loading = false;
      });
    }
  }

  Future<void> _toggleMesh(bool value) async {
    if (value && !_meshEnabled) {
      // Request consent if enabling
      final result = await showMeshConsentDialog(context);
      if (result == true) {
        await ConsentService.instance.setMeshConsent(true);
        setState(() => _meshEnabled = true);
      }
    } else if (!value) {
      // Allow disabling without dialog
      await ConsentService.instance.setMeshConsent(false);
      setState(() => _meshEnabled = false);
    }
  }

  Future<void> _toggleGemini(bool value) async {
    if (value && !_geminiEnabled) {
      // Request consent if enabling
      final result = await showGeminiConsentDialog(context);
      if (result == true) {
        await ConsentService.instance.setGeminiConsent(true);
        setState(() => _geminiEnabled = true);
      }
    } else if (!value) {
      // Allow disabling without dialog
      await ConsentService.instance.setGeminiConsent(false);
      setState(() => _geminiEnabled = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox.shrink();
    }

    return SettingsSectionCard(
      title: 'FEATURE CONSENT',
      children: [
        SettingsToggleRow(
          icon: Icons.wifi_tethering,
          iconColor: SettingsColors.green,
          title: 'Mesh Networking',
          subtitle: 'Allow offline message relay via Bluetooth',
          value: _meshEnabled,
          onChanged: _toggleMesh,
        ),
        SettingsToggleRow(
          icon: Icons.auto_awesome,
          iconColor: SettingsColors.purple,
          title: 'AI Assistant',
          subtitle: 'Allow @time_ask to use Google Gemini',
          value: _geminiEnabled,
          onChanged: _toggleGemini,
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// ANIMATED PROFILE HEADER
// ═══════════════════════════════════════════════════════════════════════════════

class _AnimatedProfileHeader extends StatelessWidget {
  final double t;
  final String? avatarUrl;
  final String name;
  final String? subtitle;
  final VoidCallback? onTap;

  const _AnimatedProfileHeader({
    required this.t,
    this.avatarUrl,
    required this.name,
    this.subtitle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final statusBarHeight = MediaQuery.of(context).padding.top;

    // Interpolate values based on t (0=collapsed, 1=expanded)
    final avatarSize = lerpDouble(36, 72, t)!;
    final left = lerpDouble(16, screenWidth / 2 - 36, t)!;
    final top = lerpDouble(statusBarHeight + 6, 70, t)!;
    final fontSize = lerpDouble(17, 24, t)!;

    return GestureDetector(
      onTap: onTap,
      child: Stack(
        children: [
          // Glass background
          Positioned.fill(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(24),
              ),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.white.withOpacity(0.14),
                        Colors.white.withOpacity(0.06),
                      ],
                    ),
                    border: const Border(
                      bottom: BorderSide(
                        color: Color(0x1AFFFFFF),
                        width: 0.5,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Avatar + Name
          Positioned(
            left: left,
            top: top,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Avatar
                Container(
                  width: avatarSize,
                  height: avatarSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        const Color(0xFF0A84FF).withOpacity(0.35),
                        const Color(0xFF5E5CE6).withOpacity(0.25),
                      ],
                    ),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.25),
                      width: 2.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF0A84FF).withOpacity(0.2),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ClipOval(
                    child: avatarUrl != null
                        ? CachedNetworkImage(
                            imageUrl: avatarUrl!,
                            fit: BoxFit.cover,
                            placeholder: (_, __) => _buildInitial(avatarSize),
                            errorWidget: (_, __, ___) => _buildInitial(avatarSize),
                          )
                        : _buildInitial(avatarSize),
                  ),
                ),
                const SizedBox(width: 14),

                // Name + subtitle
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: fontSize,
                        fontWeight: FontWeight.bold,
                        letterSpacing: -0.3,
                      ),
                    ),
                    if (subtitle != null && t > 0.35)
                      Opacity(
                        opacity: ((t - 0.35) / 0.65).clamp(0.0, 1.0),
                        child: Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            subtitle!,
                            style: TextStyle(
                              color: const Color(0xFF0A84FF),
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInitial(double size) {
    return Center(
      child: Text(
        name.isNotEmpty ? name[0].toUpperCase() : '?',
        style: TextStyle(
          fontSize: size * 0.4,
          fontWeight: FontWeight.bold,
          color: const Color(0xFF0A84FF),
        ),
      ),
    );
  }
}
