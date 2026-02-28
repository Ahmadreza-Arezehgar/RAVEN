import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../services/device_optimization_service.dart';
import '../services/network_mode_service.dart';
import '../services/badge_state.dart';
import '../services/toast_service.dart';
import '../services/account_service.dart';
import '../screens/account_settings_page.dart';
import '../screens/privacy_security_page.dart';
import '../screens/news_interests_page.dart';
import '../screens/chat_page.dart';
import '../screens/my_qr_screen.dart';
import '../screens/scan_qr_screen.dart';
import 'raven_context_menu.dart';


/// Connection status for the status dot
enum ConnectionStatus { online, local, offline }

/// Adaptive Navigation Dock with Haptics, Animations, Status Indicator
/// and Telegram-style long-press context menus with REAL navigation
class FloatingGlassDock extends StatelessWidget {
  final int selectedIndex;
  final Function(int) onTap;
  final int unreadCount;
  
  // Global keys for getting anchor positions
  static final _homeKey = GlobalKey();
  static final _messagesKey = GlobalKey();
  static final _searchKey = GlobalKey();
  static final _profileKey = GlobalKey();
  
  const FloatingGlassDock({
    super.key,
    required this.selectedIndex,
    required this.onTap,
    this.unreadCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final dockHeight = DeviceOptimizationService.getDockHeight(context);
    final iconSize = DeviceOptimizationService.getNavIconSize(context);
    final connectionStatus = _getConnectionStatus(context);
    final badge = context.watch<BadgeState>();
    
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Main dock content
        SizedBox(
          height: dockHeight,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Home
              _DockItemButton(
                globalKey: _homeKey,
                icon: Icons.home_outlined,
                activeIcon: Icons.home,
                isActive: selectedIndex == 0,
                onTap: () => onTap(0),
                onLongPress: () => _showHomeMenu(context),
                size: iconSize,
                badgeCount: badge.home,
              ),
              // Messages
              _DockItemButton(
                globalKey: _messagesKey,
                icon: Icons.message_outlined,
                activeIcon: Icons.message,
                isActive: selectedIndex == 1,
                onTap: () => onTap(1),
                onLongPress: () => _showMessagesMenu(context),
                size: iconSize,
                badgeCount: badge.messages,
              ),
              // Search
              _DockItemButton(
                globalKey: _searchKey,
                icon: Icons.search,
                activeIcon: Icons.search,
                isActive: selectedIndex == 2,
                onTap: () => onTap(2),
                onLongPress: () => _showSearchMenu(context),
                size: iconSize,
              ),
              // Profile
              _DockItemButton(
                globalKey: _profileKey,
                icon: Icons.person_outline,
                activeIcon: Icons.person,
                isActive: selectedIndex == 3,
                onTap: () => onTap(3),
                onLongPress: () => _showAccountMenu(context),
                onDoubleTap: () => _switchToNextAccount(context), // ✅ Quick account switch
                size: iconSize,
                badgeCount: badge.account,
              ),

            ],
          ),
        ),
        
        // Status indicator dot
        Positioned(
          right: 16,
          top: -4,
          child: _StatusDot(status: connectionStatus),
        ),
      ],
    );
  }

  ConnectionStatus _getConnectionStatus(BuildContext context) {
    try {
      final networkMode = context.watch<NetworkModeService>();
      if (networkMode.isWiFiMode) {
        return ConnectionStatus.online;
      } else if (networkMode.isBluetoothMode) {
        return ConnectionStatus.local;
      }
      return ConnectionStatus.offline;
    } catch (e) {
      return ConnectionStatus.offline;
    }
  }

  // ══════════════════════════════════════════════════════════════
  // ACCOUNT SWITCH (Double-tap on Profile icon)
  // ══════════════════════════════════════════════════════════════
  void _switchToNextAccount(BuildContext context) async {
    HapticFeedback.mediumImpact();
    
    final model = context.read<AppModel>();
    final result = await model.switchToNextAccount();
    
    if (result != null && result['success'] == true) {
      final username = result['username'] as String? ?? 'User';
      
      // ✅ Show welcome toast via notification overlay
      model.showAccountSwitchToast(username);
    }
  }

  // ══════════════════════════════════════════════════════════════
  // HOME MENU → Original 3 options: Local / Friends / Refresh
  // ══════════════════════════════════════════════════════════════

  void _showHomeMenu(BuildContext context) {
    final rect = getGlobalRect(_homeKey);
    RavenContextMenu.show(
      context: context,
      anchorRect: rect,
      actions: [
        RavenMenuAction(
          title: 'Local Feed',
          icon: Icons.location_on,
          onTap: () {
            onTap(0); // Go to Home
            context.read<AppModel>().setHomeFeedMode(0); // 0 = Local
          },
        ),
        RavenMenuAction(
          title: 'Friends Feed',
          icon: Icons.people,
          onTap: () {
            onTap(0); // Go to Home
            context.read<AppModel>().setHomeFeedMode(1); // 1 = Friends
          },
        ),
        RavenMenuAction(
          title: 'Refresh',
          icon: Icons.refresh,
          onTap: () async {
            onTap(0); // Go to Home
            await context.read<AppModel>().getPosts();
            ToastService.showSuccess('Feed refreshed');
          },
        ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════
  // MESSAGES MENU
  // ══════════════════════════════════════════════════════════════
  void _showMessagesMenu(BuildContext context) {
    final rect = getGlobalRect(_messagesKey);
    RavenContextMenu.show(
      context: context,
      anchorRect: rect,
      actions: [
        RavenMenuAction(
          title: 'New Message',
          icon: Icons.edit, // pencil
          onTap: () {
            // ✅ Navigate to Messages + Open new message sheet
            onTap(1);
            _showNewMessageSheet(context);
          },
        ),
        RavenMenuAction(
          title: 'New Group',
          icon: Icons.group_add, // new group
          onTap: () {
            // ✅ Navigate to Messages + Open new group sheet
            onTap(1);
            _showNewGroupSheet(context);
          },
        ),
        RavenMenuAction(
          title: 'Mark All Read',
          icon: Icons.done_all, // mark read
          onTap: () async {
            // ✅ Navigate to Messages + Clear all unread counts
            onTap(1);
            await context.read<AppModel>().markAllMessagesRead();
            ToastService.showSuccess('All messages marked as read');
          },
        ),
      ],
    );
  }


  // ══════════════════════════════════════════════════════════════
  // SEARCH MENU
  // ══════════════════════════════════════════════════════════════
  void _showSearchMenu(BuildContext context) {
    final rect = getGlobalRect(_searchKey);
    RavenContextMenu.show(
      context: context,
      anchorRect: rect,
      actions: [
        RavenMenuAction(
          title: 'Go to News',
          icon: Icons.article, // newspaper
          onTap: () {
            // ✅ Navigate to Search tab + Open News page
            onTap(2);
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const NewsInterestsPage()),
            );
          },
        ),
        RavenMenuAction(
          title: 'Search Users',
          icon: Icons.search, // magnifyingglass
          onTap: () {
            // ✅ Navigate to Search tab + Focus search field + Show keyboard
            onTap(2);
            context.read<AppModel>().triggerSearchFieldFocus();
          },
        ),
        RavenMenuAction(
          title: 'Scan QR Code',
          icon: Icons.qr_code_scanner,
          onTap: () {
            // ✅ Open QR scanner to add friends
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ScanQrScreen()),
            );
          },
        ),
        RavenMenuAction(
          title: 'My QR Code',
          icon: Icons.qr_code,
          onTap: () {
            // ✅ Show my QR code for others to scan
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const MyQrScreen()),
            );
          },
        ),
      ],
    );
  }



  // ══════════════════════════════════════════════════════════════
  // ACCOUNT MENU
  // ══════════════════════════════════════════════════════════════
  void _showAccountMenu(BuildContext context) {
    final rect = getGlobalRect(_profileKey);
    RavenContextMenu.show(
      context: context,
      anchorRect: rect,
      actions: [
        RavenMenuAction(
          title: 'Settings',
          icon: Icons.settings, // settings
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AccountSettingsPage()),
            );
          },
        ),
        RavenMenuAction(
          title: 'Privacy & Security',
          icon: Icons.lock, // lock
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PrivacySecurityPage()),
            );
          },
        ),
        RavenMenuAction(
          title: 'Notification Settings',
          icon: Icons.notifications, // bell
          onTap: () {
            _showNotificationSettingsSheet(context);
          },
        ),
        RavenMenuAction(
          title: 'Add New Account',
          icon: Icons.person_add, // person.add
          onTap: () {
            // Navigate to welcome screen for Sign in / Sign up / Google auth
            Navigator.pushNamed(context, '/welcome');
          },
        ),
        RavenMenuAction(
          title: 'Logout',
          icon: Icons.logout, // logout
          destructive: true,
          onTap: () {
            _showLogoutConfirmation(context);
          },
        ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════
  // HELPER SHEETS
  // ══════════════════════════════════════════════════════════════

  void _showNewMessageSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ContactSelectionSheet(
        title: 'New Message',
        onSelect: (userId, username) {
          Navigator.pop(ctx);
          context.read<AppModel>().startChatWith(userId, username);
          Navigator.push(context, MaterialPageRoute(builder: (_) => const ChatPage()));
        },
      ),
    );
  }

  void _showNewGroupSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _NewGroupSheet(),
    );
  }

  void _showNotificationSettingsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _NotificationSettingsSheet(),
    );
  }

  void _showLogoutConfirmation(BuildContext context) {
    final model = context.read<AppModel>();
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Logout',
      barrierColor: Colors.black.withOpacity(0.5),
      transitionDuration: const Duration(milliseconds: 240),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.15),
            end: Offset.zero,
          ).animate(CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          )),
          child: FadeTransition(
            opacity: animation,
            child: child,
          ),
        );
      },
      pageBuilder: (context, animation, secondaryAnimation) {
        return _LiquidGlassLogoutDialog(
          onCancel: () => Navigator.pop(context),
          onLogout: () async {
            // AccountService handles everything
            await AccountService.instance.fullLogout(context, model);
          },
        );
      },
    );
  }
}

// ══════════════════════════════════════════════════════════════
// LIQUID GLASS LOGOUT DIALOG
// ══════════════════════════════════════════════════════════════
class _LiquidGlassLogoutDialog extends StatefulWidget {
  final VoidCallback onCancel;
  final Future<void> Function() onLogout;

  const _LiquidGlassLogoutDialog({
    required this.onCancel,
    required this.onLogout,
  });

  @override
  State<_LiquidGlassLogoutDialog> createState() => _LiquidGlassLogoutDialogState();
}

class _LiquidGlassLogoutDialogState extends State<_LiquidGlassLogoutDialog> {
  bool _isLoading = false;

  void _handleLogout() {
    if (_isLoading) return; // Prevent double tap
    setState(() => _isLoading = true);
    // Don't await - fullLogout will navigate away, closing this dialog
    widget.onLogout();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.12),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: Colors.white.withOpacity(0.18),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.25),
                    blurRadius: 40,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Icon
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.logout_rounded,
                      color: Colors.red,
                      size: 28,
                    ),
                  ),
                  const SizedBox(height: 20),
                  
                  // Title
                  const Text(
                    'Log out',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  const SizedBox(height: 8),
                  
                  // Body
                  Text(
                    "You'll be signed out of this account on this device.",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.7),
                      fontSize: 15,
                      fontWeight: FontWeight.w400,
                      decoration: TextDecoration.none,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 28),
                  
                  // Buttons
                  Row(
                    children: [
                      // Cancel button (glass/neutral)
                      Expanded(
                        child: GestureDetector(
                          onTap: _isLoading ? null : widget.onCancel,
                          child: Container(
                            height: 48,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.15),
                                width: 1,
                              ),
                            ),
                            child: Center(
                              child: Text(
                                'Cancel',
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.9),
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  decoration: TextDecoration.none,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      
                      // Logout button (glass-red)
                      Expanded(
                        child: GestureDetector(
                          onTap: _isLoading ? null : _handleLogout,
                          child: Container(
                            height: 48,
                            decoration: BoxDecoration(
                              color: Colors.red.withOpacity(0.25),
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: Colors.red.withOpacity(0.4),
                                width: 1,
                              ),
                            ),
                            child: Center(
                              child: _isLoading
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                      ),
                                    )
                                  : const Text(
                                      'Log out',
                                      style: TextStyle(
                                        color: Colors.red,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        decoration: TextDecoration.none,
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// CONTACT SELECTION SHEET
// ══════════════════════════════════════════════════════════════
class _ContactSelectionSheet extends StatelessWidget {
  final String title;
  final Function(String userId, String username) onSelect;

  const _ContactSelectionSheet({
    required this.title,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final model = context.watch<AppModel>();
    
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: Colors.white30,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Title
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              title,
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
          // Contact list
          Flexible(
            child: FutureBuilder(
              future: model.getAllContacts(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final contacts = snapshot.data!;
                if (contacts.isEmpty) {
                  return const Center(
                    child: Text('No contacts yet', style: TextStyle(color: Colors.white54)),
                  );
                }
                return ListView.builder(
                  shrinkWrap: true,
                  itemCount: contacts.length,
                  itemBuilder: (ctx, i) {
                    final c = contacts[i];
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Colors.blue.withOpacity(0.2),
                        child: Text(c.username[0].toUpperCase(), style: const TextStyle(color: Colors.blue)),
                      ),
                      title: Text(c.username, style: const TextStyle(color: Colors.white)),
                      onTap: () => onSelect(c.userId, c.username),
                    );
                  },
                );
              },
            ),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// NEW GROUP SHEET
// ══════════════════════════════════════════════════════════════
class _NewGroupSheet extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: Colors.white30,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'New Group',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Group Name',
                hintStyle: TextStyle(color: Colors.white54),
                filled: true,
                fillColor: Colors.white.withOpacity(0.1),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Select members to add to the group',
              style: TextStyle(color: Colors.white54, fontSize: 14),
            ),
          ),
          const SizedBox(height: 100),
          Padding(
            padding: EdgeInsets.only(
              left: 16, right: 16, 
              bottom: MediaQuery.of(context).padding.bottom + 16,
            ),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
              onPressed: () {
                  Navigator.pop(context);
                  ToastService.showInfo('🚧 Group creation coming soon');
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0A84FF),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Create Group', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// NOTIFICATION SETTINGS SHEET
// ══════════════════════════════════════════════════════════════
class _NotificationSettingsSheet extends StatefulWidget {
  @override
  State<_NotificationSettingsSheet> createState() => _NotificationSettingsSheetState();
}

class _NotificationSettingsSheetState extends State<_NotificationSettingsSheet> {
  bool _newPosts = true;
  bool _friendRequests = true;
  bool _newMessages = true;
  bool _comments = true;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.6,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: Colors.white30,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Notification Settings',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
          _buildSwitch('New Posts', _newPosts, (v) => setState(() => _newPosts = v)),
          _buildSwitch('Friend Requests', _friendRequests, (v) => setState(() => _friendRequests = v)),
          _buildSwitch('New Messages', _newMessages, (v) => setState(() => _newMessages = v)),
          _buildSwitch('Comments & Replies', _comments, (v) => setState(() => _comments = v)),
          SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
        ],
      ),
    );
  }

  Widget _buildSwitch(String title, bool value, ValueChanged<bool> onChanged) {
    return ListTile(
      title: Text(title, style: const TextStyle(color: Colors.white)),
      trailing: CupertinoSwitch(
        value: value,
        onChanged: onChanged,
        activeColor: const Color(0xFF0A84FF),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// DOCK ITEM BUTTON
// ══════════════════════════════════════════════════════════════
class _DockItemButton extends StatefulWidget {
  final GlobalKey globalKey;
  final IconData icon;
  final IconData activeIcon;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onDoubleTap; // ✅ For account switch
  final double size;
  final int badgeCount;

  const _DockItemButton({
    required this.globalKey,
    required this.icon,
    required this.activeIcon,
    required this.isActive,
    required this.onTap,
    this.onLongPress,
    this.onDoubleTap,
    this.size = 26,
    this.badgeCount = 0,
  });

  @override
  State<_DockItemButton> createState() => _DockItemButtonState();
}

class _DockItemButtonState extends State<_DockItemButton> with SingleTickerProviderStateMixin {
  double _scale = 1.0;
  late AnimationController _badgeController;
  late Animation<double> _badgeAnimation;
  int _prevBadge = 0;

  @override
  void initState() {
    super.initState();
    _prevBadge = widget.badgeCount;
    _badgeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _badgeAnimation = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _badgeController, curve: Curves.elasticOut),
    );
    if (widget.badgeCount > 0) {
      _badgeController.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(covariant _DockItemButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.badgeCount != _prevBadge) {
      if (_prevBadge == 0 && widget.badgeCount > 0) {
        // 0 → N: scale-in
        _badgeController.forward(from: 0);
      } else if (_prevBadge > 0 && widget.badgeCount == 0) {
        // N → 0: scale-out
        _badgeController.reverse();
      } else if (widget.badgeCount > _prevBadge) {
        // N → M (increased): bump
        _badgeController.forward(from: 0.85);
      }
      _prevBadge = widget.badgeCount;
    }
  }

  @override
  void dispose() {
    _badgeController.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails details) {
    HapticFeedback.lightImpact();
    setState(() => _scale = 0.92);
  }

  void _onTapUp(TapUpDetails details) {
    setState(() => _scale = 1.0);
  }

  void _onTapCancel() {
    setState(() => _scale = 1.0);
  }

  String _formatBadge(int n) {
    if (n <= 0) return '';
    if (n > 9999) return '9999+';
    return '$n';
  }

  @override
  Widget build(BuildContext context) {
    final dockHeight = DeviceOptimizationService.getDockHeight(context);
    final badgeText = _formatBadge(widget.badgeCount);
    
    return GestureDetector(
      key: widget.globalKey,
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onDoubleTap: widget.onDoubleTap, // ✅ Account switch
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: widget.isActive ? 1.0 : 0.6,
          child: SizedBox(
            width: dockHeight,
            height: dockHeight,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                // Icon
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    widget.isActive ? widget.activeIcon : widget.icon,
                    key: ValueKey(widget.isActive),
                    size: widget.size,
                    color: Colors.white,
                  ),
                ),
                // Badge (positioned top-right of icon)
                if (badgeText.isNotEmpty)
                  Positioned(
                    top: dockHeight * 0.15,
                    right: dockHeight * 0.12,
                    child: ScaleTransition(
                      scale: _badgeAnimation,
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 18),
                        padding: EdgeInsets.symmetric(
                          horizontal: badgeText.length > 2 ? 5 : 4,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF3B30),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: Colors.black,
                            width: 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFFFF3B30).withOpacity(0.4),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Text(
                          badgeText,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            height: 1.0,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// STATUS DOT
// ══════════════════════════════════════════════════════════════
class _StatusDot extends StatelessWidget {
  final ConnectionStatus status;

  const _StatusDot({required this.status});

  @override
  Widget build(BuildContext context) {
    Color color;
    switch (status) {
      case ConnectionStatus.online:
        color = const Color(0xFF34C759);
        break;
      case ConnectionStatus.local:
        color = const Color(0xFF0A84FF);
        break;
      case ConnectionStatus.offline:
        color = const Color(0xFF8E8E93);
        break;
    }

    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.5),
            blurRadius: 6,
            spreadRadius: 1,
          ),
        ],
      ),
    );
  }
}
