import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/user_model.dart';
import '../main.dart';
import '../services/api_service.dart';
import '../services/toast_service.dart';
import '../gen_l10n/app_localizations.dart';
import '../theme/ios_design_system.dart';
import '../screens/change_password_page.dart';
import '../screens/edit_bio_screen.dart';
import '../screens/proxy_settings_screen.dart';
import '../screens/privacy_security_page.dart';
import '../screens/privacy_settings_page.dart';
import '../screens/privacy_policy_page.dart';
import '../screens/faq_page.dart';
import '../screens/language_selector_page.dart';
import '../screens/news_interests_page.dart';
import '../screens/font_size_settings_page.dart';
import '../screens/screenshot_notifications_page.dart';
import '../widgets/backup_widgets.dart';
import '../services/profile_picture_service.dart';
import '../widgets/glass_header.dart';
import '../services/device_optimization_service.dart';

/// Account Settings Page - Liquid Glass Design
class AccountSettingsPage extends StatefulWidget {
  const AccountSettingsPage({super.key});

  @override
  State<AccountSettingsPage> createState() => _AccountSettingsPageState();
}

class _AccountSettingsPageState extends State<AccountSettingsPage> {
  bool _isUpdatingPicture = false;
  final _secureStorage = const FlutterSecureStorage();

  Future<void> _updateProfilePicture(BuildContext context) async {
    final model = context.read<AppModel>();
    final currentUser = model.currentUser;
    if (currentUser == null) return;

    final source = await ProfilePictureService.showImageSourceDialog(context);
    if (source == null) return;

    setState(() => _isUpdatingPicture = true);

    try {
      // Read token from secure storage (was hardcoded as empty string!)
      final token = await _secureStorage.read(key: 'jwt_token') ?? '';
      
      final updatedUser = await ProfilePictureService.updateProfilePicture(
        context: context,
        currentUser: currentUser,
        token: token,
        source: source,
      );

      if (updatedUser != null && mounted) {
        model.currentUser = updatedUser;
        ToastService.showSuccess('Profile picture updated!');
      }
    } finally {
      if (mounted) setState(() => _isUpdatingPicture = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = context.watch<AppModel>();
    final user = model.currentUser;
    final l10n = AppLocalizations.of(context)!;
    final bottomSafe = MediaQuery.of(context).padding.bottom;
    final dockH = DeviceOptimizationService.getDockHeight(context);
    final statusBarHeight = MediaQuery.of(context).padding.top;

    // Parse hobbies from user if available
    List<String> hobbies = [];
    // hobbies would come from user profile - for now empty

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusScope.of(context).unfocus(),
        child: CustomScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          physics: const BouncingScrollPhysics(),
          slivers: [
          // ═══════════════════════════════════════════════════════════
          // COLLAPSIBLE PROFILE HEADER
          // ═══════════════════════════════════════════════════════════
          SliverAppBar(
            pinned: true,
            expandedHeight: 220,
            backgroundColor: Colors.transparent,
            elevation: 0,
            automaticallyImplyLeading: false,
            flexibleSpace: LayoutBuilder(
              builder: (context, constraints) {
                final maxH = 220.0;
                final minH = kToolbarHeight + statusBarHeight;
                final t = ((constraints.maxHeight - minH) / (maxH - minH))
                    .clamp(0.0, 1.0);

                return _CollapsibleProfileHeader(
                  t: t,
                  user: user,
                  isUpdatingPicture: _isUpdatingPicture,
                  onAvatarTap: () => _updateProfilePicture(context),
                  hobbies: hobbies,
                  l10n: l10n,
                );
              },
            ),
          ),

          // ═══════════════════════════════════════════════════════════
          // SCROLLABLE CONTENT
          // ═══════════════════════════════════════════════════════════
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: dockH + bottomSafe + 24,
              ),
              child: Column(
                children: [
                  // ═══════════════════════════════════════════════════════
                  // ACCOUNT SECTION
                  // ═══════════════════════════════════════════════════════
                  _GlassSection(
                    title: l10n.account,
                    children: [
                      _GlassRow(
                        icon: Icons.lock_outline,
                        iconColor: const Color(0xFF8E8E93), // Gray
                        title: l10n.changePassword,
                        onTap: () => _navigateTo(context, const ChangePasswordPage()),
                      ),
                      _GlassRow(
                        icon: Icons.edit_outlined,
                        iconColor: const Color(0xFFFF9500), // Orange
                        title: l10n.editBio,
                        subtitle: 'Bio, Hobbies, Spotify preview',
                        onTap: () => _navigateTo(context, const EditBioScreen()),
                      ),
                      _GlassRow(
                        icon: Icons.shield_outlined,
                        iconColor: const Color(0xFF34C759), // Green
                        title: l10n.privacyAndSecurity,
                        subtitle: l10n.manageBlockedUsersAndSecurity,
                        onTap: () => _navigateTo(context, PrivacySecurityPage()),
                      ),
                      _GlassRow(
                        icon: Icons.camera_alt_outlined,
                        iconColor: const Color(0xFFFF9500), // Orange (changed from red - red reserved for Privacy Policy)
                        title: 'Screenshot Alerts',
                        onTap: () => _navigateTo(context, const ScreenshotNotificationsPage()),
                      ),
                      _GlassRow(
                        icon: Icons.visibility_outlined,
                        iconColor: const Color(0xFFAF52DE), // Purple
                        title: l10n.searchPrivacy,
                        subtitle: l10n.public,
                        onTap: () => _navigateTo(context, const PrivacySettingsPage()),
                      ),
                    ],
                  ),

                  const SizedBox(height: 20),

                  // ═══════════════════════════════════════════════════════
                  // GENERAL SECTION
                  // ═══════════════════════════════════════════════════════
                  _GlassSection(
                    title: l10n.general,
                    children: [
                      _GlassRow(
                        icon: Icons.help_outline,
                        iconColor: const Color(0xFF5856D6), // Indigo
                        title: l10n.faq,
                        onTap: () => _navigateTo(context, const FAQPage()),
                      ),
                      _GlassRow(
                        icon: Icons.newspaper_outlined,
                        iconColor: const Color(0xFFFF2D55), // Pink
                        title: l10n.newsInterests,
                        subtitle: '${l10n.technology}, ${l10n.business}',
                        onTap: () => _navigateTo(context, const NewsInterestsPage()),
                      ),
                      _GlassRow(
                        icon: Icons.language_outlined,
                        iconColor: const Color(0xFF007AFF), // Blue
                        title: l10n.language,
                        subtitle: _getLanguageName(model.locale.languageCode, l10n),
                        onTap: () => _navigateTo(context, const LanguageSelectorPage()),
                      ),
                      _GlassRow(
                        icon: Icons.vpn_key_outlined,
                        iconColor: const Color(0xFF5AC8FA), // Teal
                        title: 'Proxy',
                        subtitle: 'Route app traffic through proxy',
                        onTap: () => _navigateTo(context, const ProxySettingsScreen()),
                      ),
                      _GlassRow(
                        icon: Icons.text_fields_outlined,
                        iconColor: const Color(0xFFFFCC00), // Yellow
                        title: l10n.fontSize,
                        subtitle: _getFontSizeLabel(model.fontScale),
                        onTap: () => _navigateTo(context, const FontSizeSettingsPage()),
                      ),
                      _GlassRow(
                        icon: Icons.privacy_tip_outlined,
                        iconColor: const Color(0xFFFF3B30), // Red - distinctive for policy/legal
                        title: 'Privacy Policy',
                        onTap: () => _navigateTo(context, const PrivacyPolicyPage()),
                      ),
                    ],
                  ),

                  const SizedBox(height: 20),

                  // ═══════════════════════════════════════════════════════
                  // AI ASSISTANT
                  // ═══════════════════════════════════════════════════════
                  _GlassSection(
                    title: 'AI Assistant',
                    children: [
                      _GlassToggleRow(
                        icon: Icons.travel_explore_outlined,
                        iconColor: const Color(0xFF30B0C7), // Cyan
                        title: 'Internet Search',
                        subtitle: 'Allow AI to search web for fact-checking',
                        value: model.aiSearchEnabled,
                        onChanged: (val) => model.setAiSearchEnabled(val),
                      ),
                    ],
                  ),

                  const SizedBox(height: 20),

                  // ═══════════════════════════════════════════════════════
                  // BACKUP SECTION
                  // ═══════════════════════════════════════════════════════
                  const BackupSettingsSection(),
                ],
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }

  void _navigateTo(BuildContext context, Widget page) {
    HapticFeedback.selectionClick();
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }

  String _getFontSizeLabel(double fontScale) {
    if (fontScale <= 0.85) return 'Small';
    if (fontScale <= 1.0) return 'Medium';
    if (fontScale <= 1.15) return 'Large';
    return 'Extra Large';
  }

  String _getLanguageName(String code, AppLocalizations l10n) {
    switch (code) {
      case 'en': return l10n.english;
      case 'es': return l10n.spanish;
      case 'fa': return l10n.persian;
      case 'zh': return l10n.chinese;
      case 'de': return l10n.german;
      default: return l10n.english;
    }
  }
}

// ══════════════════════════════════════════════════════════════════════════
// COLLAPSIBLE PROFILE HEADER - LIQUID GLASS DESIGN
// ══════════════════════════════════════════════════════════════════════════
class _CollapsibleProfileHeader extends StatefulWidget {
  final double t; // 0 = collapsed, 1 = expanded
  final User? user;
  final bool isUpdatingPicture;
  final VoidCallback onAvatarTap;
  final List<String> hobbies;
  final AppLocalizations l10n;

  const _CollapsibleProfileHeader({
    required this.t,
    required this.user,
    required this.isUpdatingPicture,
    required this.onAvatarTap,
    required this.hobbies,
    required this.l10n,
  });

  @override
  State<_CollapsibleProfileHeader> createState() => _CollapsibleProfileHeaderState();
}

class _CollapsibleProfileHeaderState extends State<_CollapsibleProfileHeader>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _avatarAnim;
  late Animation<double> _nameAnim;
  late Animation<double> _usernameAnim;
  late Animation<double> _bioAnim;
  late Animation<double> _tagsAnim;
  late Animation<double> _joinAnim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );

    // Staggered animations (Avatar → Name → Username → Bio → Tags → JoinDate)
    _avatarAnim = Tween<double>(begin: 0.95, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: const Interval(0.0, 0.3, curve: Curves.easeOut)),
    );
    _nameAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: const Interval(0.1, 0.4, curve: Curves.easeOut)),
    );
    _usernameAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: const Interval(0.2, 0.5, curve: Curves.easeOut)),
    );
    _bioAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: const Interval(0.3, 0.6, curve: Curves.easeOut)),
    );
    _tagsAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: const Interval(0.4, 0.7, curve: Curves.easeOut)),
    );
    _joinAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: const Interval(0.6, 1.0, curve: Curves.easeOut)),
    );

    _animController.forward();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final statusBarHeight = MediaQuery.of(context).padding.top;
    final user = widget.user;
    final t = widget.t;

    // Interpolated values - Avatar from 44px (collapsed) to 84px (expanded)
    final avatarSize = lerpDouble(44, 84, t)!;
    final avatarLeft = 20.0;
    final avatarTop = lerpDouble(statusBarHeight + 6, statusBarHeight + 32, t)!;
    final nameFontSize = lerpDouble(17, 22, t)!;
    // Gap between avatar and text: 16px
    final infoLeft = avatarLeft + avatarSize + 16;

    return AnimatedBuilder(
      animation: _animController,
      builder: (context, child) {
        return Stack(
          children: [
            // ═══════════════════════════════════════════════════════════
            // GLASS BACKGROUND
            // ═══════════════════════════════════════════════════════════
            Positioned.fill(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(28),
                ),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
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
                          color: Color(0x20FFFFFF),
                          width: 0.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // ═══════════════════════════════════════════════════════════
            // 🟩 AVATAR (Left side)
            // ═══════════════════════════════════════════════════════════
            Positioned(
              left: avatarLeft,
              top: avatarTop,
              child: Transform.scale(
                scale: _avatarAnim.value,
                child: GestureDetector(
                  onTap: widget.onAvatarTap,
                  child: Stack(
                    children: [
                      // Avatar circle with glass effect
                      Container(
                        width: avatarSize,
                        height: avatarSize,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              const Color(0xFF0A84FF).withOpacity(0.4),
                              const Color(0xFF5E5CE6).withOpacity(0.3),
                            ],
                          ),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.3),
                            width: 2.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF0A84FF).withOpacity(0.25),
                              blurRadius: 16,
                              offset: const Offset(0, 6),
                            ),
                            BoxShadow(
                              color: Colors.black.withOpacity(0.15),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: ClipOval(
                          child: user?.avatarPath != null && user!.avatarPath!.isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: user!.avatarPath!.startsWith('http')
                                      ? user!.avatarPath!
                                      : '${ApiService.baseUrl}${user!.avatarPath}',
                                  fit: BoxFit.cover,
                                  placeholder: (_, __) => _buildInitial(avatarSize),
                                  errorWidget: (_, __, ___) => _buildInitial(avatarSize),
                                )
                              : _buildInitial(avatarSize),
                        ),
                      ),
                      // Camera edit icon (only when expanded)
                      if (t > 0.5 && !widget.isUpdatingPicture)
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: Opacity(
                            opacity: ((t - 0.5) / 0.5).clamp(0.0, 1.0),
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: const Color(0xFF0A84FF),
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.black, width: 2.5),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFF0A84FF).withOpacity(0.4),
                                    blurRadius: 8,
                                  ),
                                ],
                              ),
                              child: Icon(
                                Icons.camera_alt,
                                size: avatarSize * 0.18,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      // Loading spinner
                      if (widget.isUpdatingPicture)
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.black.withOpacity(0.5),
                            ),
                            child: const Center(
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),

            // ═══════════════════════════════════════════════════════════
            // PROFILE INFO (Right side)
            // Order: Name → Username → Bio → Tags → JoinDate
            // ═══════════════════════════════════════════════════════════
            Positioned(
              left: infoLeft,
              right: 20,
              top: avatarTop,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 🟦 FULL NAME (First + Last, bold)
                  Opacity(
                    opacity: _nameAnim.value,
                    child: Transform.translate(
                      offset: Offset(8 * (1 - _nameAnim.value), 0),
                      child: Text(
                        _getFullName(user),
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: nameFontSize,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.4,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),

                  // ⬛ USERNAME (@username, smaller, gray)
                  if (user?.username != null)
                    Opacity(
                      opacity: _usernameAnim.value,
                      child: Transform.translate(
                        offset: Offset(8 * (1 - _usernameAnim.value), 0),
                        child: Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Text(
                            '@${user!.username}',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.55),
                              fontSize: 14,
                              fontWeight: FontWeight.w400,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),

                  // 🟨 BIO (max 2 lines, fades on collapse)
                  if (t > 0.25)
                    Opacity(
                      opacity: _bioAnim.value * ((t - 0.25) / 0.75).clamp(0.0, 1.0),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 7),
                        child: Text(
                          user?.bio?.isNotEmpty == true
                              ? user!.bio!
                              : 'No bio yet',
                          style: TextStyle(
                            color: user?.bio?.isNotEmpty == true
                                ? Colors.white.withOpacity(0.75)
                                : Colors.white.withOpacity(0.35),
                            fontSize: 13,
                            height: 1.35,
                            fontStyle: user?.bio?.isNotEmpty == true
                                ? FontStyle.normal
                                : FontStyle.italic,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),

                  // 🟨 TAGS (capsule chips, horizontal scroll)
                  if (t > 0.35 && widget.hobbies.isNotEmpty)
                    Opacity(
                      opacity: _tagsAnim.value * ((t - 0.35) / 0.65).clamp(0.0, 1.0),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          physics: const BouncingScrollPhysics(),
                          child: Row(
                            children: widget.hobbies.take(5).map((tag) {
                              return Container(
                                margin: const EdgeInsets.only(right: 8),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.12),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: Colors.white.withOpacity(0.18),
                                    width: 0.5,
                                  ),
                                ),
                                child: Text(
                                  tag,
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.9),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ),
                    ),

                  // 🟥 JOIN DATE (minimal, last)
                  if (t > 0.5 && user != null)
                    Opacity(
                      opacity: _joinAnim.value * ((t - 0.5) / 0.5).clamp(0.0, 1.0),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          'Joined ${_formatJoinDate(user!.createdAt)}',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.35),
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// Get full name (First + Last) or fallback to username
  String _getFullName(User? user) {
    if (user == null) return widget.l10n.user;
    
    final firstName = user.firstName?.trim() ?? '';
    final lastName = user.lastName?.trim() ?? '';
    final fullName = '$firstName $lastName'.trim();
    
    return fullName.isNotEmpty ? fullName : user.username;
  }

  Widget _buildInitial(double size) {
    final username = widget.user?.username ?? '';
    final firstName = widget.user?.firstName ?? '';
    final initial = firstName.isNotEmpty
        ? firstName[0].toUpperCase()
        : (username.isNotEmpty ? username[0].toUpperCase() : '?');
    return Center(
      child: Text(
        initial,
        style: TextStyle(
          fontSize: size * 0.42,
          fontWeight: FontWeight.bold,
          color: const Color(0xFF0A84FF),
        ),
      ),
    );
  }

  String _formatJoinDate(DateTime date) {
    const months = ['January', 'February', 'March', 'April', 'May', 'June',
                    'July', 'August', 'September', 'October', 'November', 'December'];
    return '${months[date.month - 1]} ${date.year}';
  }
}

// ══════════════════════════════════════════════════════════════════════════
// GLASS CARD (Base container with blur)
// ══════════════════════════════════════════════════════════════════════════
class _GlassCard extends StatelessWidget {
  final Widget child;
  final double borderRadius;

  const _GlassCard({
    required this.child,
    this.borderRadius = 24,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withOpacity(0.10),
                Colors.white.withOpacity(0.05),
              ],
            ),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              color: Colors.white.withOpacity(0.12),
              width: 0.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.25),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// GLASS SECTION (Title + Card with rows)
// ══════════════════════════════════════════════════════════════════════════
class _GlassSection extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _GlassSection({
    required this.title,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 10),
          child: Text(
            title,
            style: TextStyle(
              color: Colors.white.withOpacity(0.6),
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
        ),
        _GlassCard(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              children: children.asMap().entries.map((entry) {
                return Column(
                  children: [
                    entry.value,
                    if (entry.key < children.length - 1)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Divider(
                          height: 1,
                          color: Colors.white.withOpacity(0.06),
                        ),
                      ),
                  ],
                );
              }).toList(),
            ),
          ),
        ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// GLASS ROW (Settings item with icon, title, subtitle, chevron)
// ══════════════════════════════════════════════════════════════════════════
class _GlassRow extends StatefulWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  const _GlassRow({
    required this.icon,
    this.iconColor = const Color(0xFF0A84FF),
    required this.title,
    this.subtitle,
    required this.onTap,
  });

  @override
  State<_GlassRow> createState() => _GlassRowState();
}

class _GlassRowState extends State<_GlassRow> {
  bool _isPressed = false;

  void _handleTapDown(TapDownDetails details) {
    HapticFeedback.lightImpact();
    setState(() => _isPressed = true);
  }

  void _handleTapUp(TapUpDetails details) {
    setState(() => _isPressed = false);
    widget.onTap();
  }

  void _handleTapCancel() {
    setState(() => _isPressed = false);
  }

  @override
  Widget build(BuildContext context) {
    final hasSubtitle = widget.subtitle != null;

    return GestureDetector(
      onTapDown: _handleTapDown,
      onTapUp: _handleTapUp,
      onTapCancel: _handleTapCancel,
      child: AnimatedScale(
        scale: _isPressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: Container(
          height: hasSubtitle ? 66 : 56,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: _isPressed
                ? Colors.white.withOpacity(0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              // Icon container (colorful rounded square)
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: widget.iconColor,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: widget.iconColor.withOpacity(0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Icon(
                  widget.icon,
                  size: 20,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 14),
              // Titles
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (hasSubtitle)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          widget.subtitle!,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.5),
                            fontSize: 13,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
              // Chevron
              Icon(
                Icons.chevron_right,
                size: 20,
                color: Colors.white.withOpacity(0.3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// GLASS TOGGLE ROW (Settings item with switch instead of chevron)
// ══════════════════════════════════════════════════════════════════════════
class _GlassToggleRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _GlassToggleRow({
    required this.icon,
    this.iconColor = const Color(0xFF0A84FF),
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final hasSubtitle = subtitle != null;

    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onChanged(!value);
      },
      child: Container(
        height: hasSubtitle ? 66 : 56,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            // Icon container (colorful rounded square)
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: iconColor,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: iconColor.withOpacity(0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Icon(
                icon,
                size: 20,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 14),
            // Titles
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (hasSubtitle)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle!,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.5),
                          fontSize: 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
            // iOS-style Toggle
            Transform.scale(
              scale: 0.85,
              child: Switch.adaptive(
                value: value,
                onChanged: (val) {
                  HapticFeedback.lightImpact();
                  onChanged(val);
                },
                activeColor: const Color(0xFF34C759),  // iOS green
                activeTrackColor: const Color(0xFF34C759),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
