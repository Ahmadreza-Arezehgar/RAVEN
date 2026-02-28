import 'dart:io';
import 'dart:async';
import 'dart:ui';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../main.dart';
import '../models/contact_model.dart';
import '../models/post_model.dart';
import '../models/message_model.dart';
import '../services/api_service.dart';
import '../services/toast_service.dart';
import '../theme/ios_design_system.dart';
import '../widgets/post_composer.dart';
import '../widgets/ios_post_card.dart';
import '../widgets/ios_navigation.dart';
import '../widgets/glass_header.dart';
import '../widgets/glass_header_components.dart';
import '../widgets/notification_item.dart';
import '../models/notification_model.dart';
import '../services/network_mode_service.dart';
import '../services/feed_algorithm.dart';
import '../widgets/system_components.dart' hide EmptyState, ToastType;
import '../services/device_optimization_service.dart';
import '../widgets/action_components.dart';
import '../widgets/empty_state.dart';
import '../widgets/repost_sheet.dart';  // Legacy: kept for compatibility
import '../widgets/forward_sheet.dart';  // NEW: In-app forward sheet
import '../widgets/post_owner_actions_sheet.dart';  // NEW: Edit/Delete sheet
import '../screens/chat_page.dart';
import '../services/database_helper.dart';
import '../widgets/profile_components.dart';
import '../models/user_model.dart';
import '../screens/qr_screen.dart';
import '../widgets/liquid_glass_menu.dart';
import '../widgets/skeleton_loading.dart';
import '../widgets/comments_sheet.dart';
import '../screens/user_profile_page.dart';  // For notification deep links

// Home Tab - Twitter/X Style Feed
class HomeTab extends StatefulWidget {
  final int currentTab;
  
  const HomeTab({super.key, required this.currentTab});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  int _feedMode = 0; // 0=Local, 1=Friends
  int _sendMethodFilter = 0; // 0=All, 1=WiFi, 2=Bluetooth
  Timer? _refreshTimer;
  
  // ══════════════════════════════════════════════════════════════
  // SMOOTH REFRESH SYSTEM - No flicker
  // ══════════════════════════════════════════════════════════════
  bool _refreshInFlight = false;
  DateTime _lastRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  
  // Cached posts (no more FutureBuilder key change)
  List<Post> _cachedPosts = [];
  bool _isLoading = true;
  
  // Buffer for new posts (shown via pill)
  List<Post> _bufferedNewPosts = [];
  bool _hasNewPosts = false;
  
  // Scroll controller to detect if user is at top
  final ScrollController _scrollController = ScrollController();
  
  // ✅ Listener for AppModel changes (properly disposed)
  AppModel? _appModel;
  
  @override
  void initState() {
    super.initState();
    _loadInitialPosts();
    _startAutoRefresh();
    
    // ✅ Add listener after first frame to sync with Haptic Menu
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _appModel = context.read<AppModel>();
      _appModel?.addListener(_onAppModelChanged);
    });
  }
  
  /// ✅ Safe listener callback with mounted check
  void _onAppModelChanged() {
    if (!mounted || _appModel == null) return;
    
    // Sync feed mode with Haptic Menu
    if (_appModel!.homeFeedMode != _feedMode) {
      setState(() {
        _feedMode = _appModel!.homeFeedMode;
        _isLoading = true;
        _cachedPosts = [];
      });
      _loadInitialPosts();
    }
  }
  
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // ✅ FIX: Removed context.watch - using addListener pattern instead
    // context.watch in lifecycle methods causes assertion errors on dispose
  }
  
  @override
  void dispose() {
    // ✅ CRITICAL: Remove listener before disposal to prevent assertion error
    _appModel?.removeListener(_onAppModelChanged);
    _appModel = null;
    
    _refreshTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }
  
  Future<void> _loadInitialPosts() async {
    setState(() => _isLoading = true);
    try {
      final model = context.read<AppModel>();
      final posts = await model.getPosts(isLocal: _feedMode == 0);
      if (mounted) {
        setState(() {
          _cachedPosts = posts;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }
  
  // ✅ Reduced frequency - AppModel already refreshes posts every 30s
  // This timer is for UI-specific updates (new posts pill) only
  void _startAutoRefresh() {
    _refreshTimer = Timer.periodic(const Duration(seconds: 60), (timer) {
      if (mounted) _autoRefresh();
    });
  }

  /// Auto refresh - checks for new posts, shows pill if not at top
  Future<void> _autoRefresh() async {
    if (_refreshInFlight) return;
    
    final now = DateTime.now();
    if (now.difference(_lastRefresh) < const Duration(seconds: 5)) return;
    
    _refreshInFlight = true;
    _lastRefresh = now;
    
    try {
      final model = context.read<AppModel>();
      final newPosts = await model.getPosts(isLocal: _feedMode == 0);
      
      if (!mounted) return;
      
      // Find posts not in current list
      final currentIds = _cachedPosts.map((p) => p.id).toSet();
      final freshPosts = newPosts.where((p) => !currentIds.contains(p.id)).toList();
      
      if (freshPosts.isEmpty) {
        // No new posts - just update existing (likes, comments, etc.)
        _updateExistingPosts(newPosts);
        return;
      }
      
      // Check if user is near top
      if (_isNearTop()) {
        // User at top - merge immediately with animation
        setState(() {
          _cachedPosts = newPosts;
        });
      } else {
        // User scrolled down - buffer new posts, show pill
        setState(() {
          _bufferedNewPosts = freshPosts;
          _hasNewPosts = true;
        });
      }
    } finally {
      _refreshInFlight = false;
    }
  }
  
  /// Pull-to-refresh - always merge immediately
  Future<void> _pullRefresh() async {
    HapticFeedback.mediumImpact();
    
    final model = context.read<AppModel>();
    final newPosts = await model.getPosts(isLocal: _feedMode == 0);
    
    if (mounted) {
      setState(() {
        _cachedPosts = newPosts;
        _bufferedNewPosts = [];
        _hasNewPosts = false;
      });
    }
  }
  
  /// Update existing posts (likes/comments) without rebuilding list
  void _updateExistingPosts(List<Post> newPosts) {
    final newMap = {for (var p in newPosts) p.id: p};
    bool changed = false;
    
    for (int i = 0; i < _cachedPosts.length; i++) {
      final updated = newMap[_cachedPosts[i].id];
      if (updated != null && updated != _cachedPosts[i]) {
        _cachedPosts[i] = updated;
        changed = true;
      }
    }
    
    if (changed && mounted) setState(() {});
  }
  
  /// Check if user is near top of feed
  bool _isNearTop() {
    if (!_scrollController.hasClients) return true;
    return _scrollController.offset < 100;
  }
  
  /// Apply buffered new posts when user taps pill
  void _applyBufferedPosts() {
    if (_bufferedNewPosts.isEmpty) return;
    
    HapticFeedback.mediumImpact();
    
    setState(() {
      // Insert new posts at beginning
      _cachedPosts.insertAll(0, _bufferedNewPosts);
      _bufferedNewPosts = [];
      _hasNewPosts = false;
    });
    
    // Scroll to top smoothly
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }
  
  /// Change feed mode (Local/Friends)
  void _changeFeedMode(int mode) {
    if (_feedMode == mode) return;
    HapticFeedback.selectionClick();
    
    // ✅ Sync with AppModel for Haptic Menu (don't use read<> in build, use context.read in callbacks)
    context.read<AppModel>().setHomeFeedMode(mode);
    
    setState(() {
      _feedMode = mode;
      _isLoading = true;
      _cachedPosts = [];
      _bufferedNewPosts = [];
      _hasNewPosts = false;
    });
    _loadInitialPosts();
  }


  /// Opens a glass notification portal with friend requests
  void _openNotificationsPortal(BuildContext context) async {
    HapticFeedback.lightImpact();
    
    final model = context.read<AppModel>();
    await model.fetchNotifications();
    
    if (!context.mounted) return;
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.3),
      builder: (sheetContext) {
        return Consumer<AppModel>(
          builder: (context, model, child) {
            final notifications = model.notifications;
            
            return ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                child: Container(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.7,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.4),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                    border: Border(
                      top: BorderSide(color: Colors.white.withOpacity(0.15), width: 0.5),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Handle bar
                      Container(
                        margin: const EdgeInsets.only(top: 12),
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      
                      // Header
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            const Icon(Icons.notifications_outlined, color: Colors.white, size: 24),
                            const SizedBox(width: 12),
                            Text(
                              'Notifications',
                              style: iOSDesignSystem.textTheme.headlineMedium?.copyWith(
                                fontSize: 20,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Spacer(),
                            if (model.unreadNotificationCount > 0)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: iOSDesignSystem.accentBlue.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '${model.unreadNotificationCount}',
                                  style: const TextStyle(
                                    color: iOSDesignSystem.accentBlue,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      
                      Divider(color: Colors.white.withOpacity(0.1), height: 1),
                      
                      // Notifications List
                      if (notifications.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(40),
                          child: Column(
                            children: [
                              Icon(Icons.notifications_off_outlined, 
                                color: Colors.white.withOpacity(0.3), size: 48),
                              const SizedBox(height: 16),
                              Text(
                                'No notifications yet',
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.5),
                                  fontSize: 16,
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        Flexible(
                          child: ListView.separated(
                            shrinkWrap: true,
                            padding: EdgeInsets.only(
                              bottom: MediaQuery.of(context).padding.bottom + 16,
                            ),
                            itemCount: notifications.length > 10 ? 10 : notifications.length,
                            separatorBuilder: (_, __) => Divider(
                              color: Colors.white.withOpacity(0.08),
                              height: 1,
                              indent: 16,
                              endIndent: 16,
                            ),
                            itemBuilder: (context, index) {
                              final notification = notifications[index];
                              final friendRequestId = notification.data?['friend_request_id'];
                              final status = notification.data?['status'] ?? 'pending';
                              final senderName = notification.data?['sender_username'] ?? 'Someone';
                              
                              return Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                child: Row(
                                  children: [
                                    // Avatar
                                    CircleAvatar(
                                      radius: 22,
                                      backgroundColor: iOSDesignSystem.accentBlue.withOpacity(0.2),
                                      child: Text(
                                        senderName.isNotEmpty ? senderName[0].toUpperCase() : '?',
                                        style: const TextStyle(
                                          color: iOSDesignSystem.accentBlue,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    
                                    // Content
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            notification.title ?? 'Friend Request',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 15,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            notification.body ?? 'wants to connect',
                                            style: TextStyle(
                                              color: Colors.white.withOpacity(0.6),
                                              fontSize: 14,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ),
                                    ),
                                    
                                    // Action buttons
                                    if (status == 'pending' && friendRequestId != null) ...[
                                      const SizedBox(width: 8),
                                      // Decline
                                      GestureDetector(
                                        onTap: () async {
                                          HapticFeedback.lightImpact();
                                          await model.rejectFriendRequest(friendRequestId);
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                          decoration: BoxDecoration(
                                            color: Colors.white.withOpacity(0.1),
                                            borderRadius: BorderRadius.circular(16),
                                          ),
                                          child: const Text(
                                            'Decline',
                                            style: TextStyle(color: Colors.white70, fontSize: 13),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      // Accept
                                      GestureDetector(
                                        onTap: () async {
                                          HapticFeedback.mediumImpact();
                                          // Debug: show what ID we're using
                                          final requestId = friendRequestId ?? notification.id;
                                          print('🔵 [UI] Accept tapped:');
                                          print('   └── friendRequestId from data: $friendRequestId');
                                          print('   └── notification.id: ${notification.id}');
                                          print('   └── Using: $requestId');
                                          await model.acceptFriendRequest(requestId);
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                          decoration: BoxDecoration(
                                            color: iOSDesignSystem.accentBlue,
                                            borderRadius: BorderRadius.circular(16),
                                          ),
                                          child: const Text(
                                            'Accept',
                                            style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                                          ),
                                        ),
                                      ),
                                    ] else if (status == 'accepted')
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: iOSDesignSystem.success.withOpacity(0.2),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: const Text(
                                          'Accepted',
                                          style: TextStyle(color: iOSDesignSystem.success, fontSize: 12),
                                        ),
                                      ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// ✅ Simple Segmented Tabs (no glass, no shadow, clean underline)
  Widget _buildGlassSegmentedTabs() {
    return Container(
      height: 36,
      width: 180,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: Colors.white.withOpacity(0.06),
      ),
      child: Stack(
        children: [
          // Simple sliding indicator (no shadow)
          AnimatedAlign(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: _feedMode == 0 ? Alignment.centerLeft : Alignment.centerRight,
            child: Container(
              width: 88,
              height: 30,
              margin: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                color: Colors.white.withOpacity(0.12),
                // ✅ No shadow, no blur
              ),
            ),
          ),
          // Tab buttons
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => _changeFeedMode(0),
                  behavior: HitTestBehavior.opaque,
                  child: Center(
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 150),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: _feedMode == 0 ? FontWeight.w600 : FontWeight.w500,
                        color: _feedMode == 0 
                            ? Colors.white 
                            : Colors.white.withOpacity(0.5),
                      ),
                      child: const Text('Local'),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: GestureDetector(
                  onTap: () => _changeFeedMode(1),
                  behavior: HitTestBehavior.opaque,
                  child: Center(
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 150),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: _feedMode == 1 ? FontWeight.w600 : FontWeight.w500,
                        color: _feedMode == 1 
                            ? Colors.white 
                            : Colors.white.withOpacity(0.5),
                      ),
                      child: const Text('Friends'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
  
  // Legacy method - kept for compatibility
  Widget _buildInstagramTab(String title, bool isActive, VoidCallback onTap) {
    return GestureDetector(
      onTap: () {
        // Haptic feedback on tap
        HapticFeedback.lightImpact();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              style: TextStyle(
                fontSize: 18,
                fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                color: isActive ? Colors.white : Colors.grey.shade400,
                letterSpacing: isActive ? -0.6 : -0.5,
              ),
              child: Text(title),
            ),
            const SizedBox(height: 6),
            AnimatedContainer(
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOutCubic,  // Smooth dynamic curve
              height: 2.5,
              width: isActive ? 50 : 0,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(1.25),
                boxShadow: isActive ? [
                  BoxShadow(
                    color: Colors.white.withOpacity(0.4),
                    blurRadius: 6,
                    spreadRadius: 0,
                  ),
                ] : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showFilterSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: LiquidGlassPresets.modal.blur,
            sigmaY: LiquidGlassPresets.modal.blur,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: LiquidGlassPresets.modal.tint
                  .withOpacity(LiquidGlassPresets.modal.opacity),
              border: const Border(
                top: BorderSide(
                  color: iOSDesignSystem.glassBorderMedium,
                  width: iOSDesignSystem.glassBorderWidth,
                ),
              ),
            ),
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Filter',
                  style: iOSDesignSystem.textTheme.headlineMedium,
                ),
                const SizedBox(height: 16),
                _buildFilterOption('All Posts', 0, Icons.grid_view),
                _buildFilterOption('WiFi Only', 1, Icons.wifi),
                _buildFilterOption('Bluetooth Only', 2, Icons.bluetooth),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFilterOption(String title, int value, IconData icon) {
    return ListTile(
      leading: Icon(icon, color: _sendMethodFilter == value ? iOSDesignSystem.accentBlue : Colors.grey),
      title: Text(title),
      trailing: _sendMethodFilter == value ? const Icon(Icons.check, color: iOSDesignSystem.accentBlue) : null,
      onTap: () {
        setState(() => _sendMethodFilter = value);
        Navigator.pop(context);
      },
    );
  }

  void _showFriendSearchDialog(BuildContext context) {
    final searchController = TextEditingController();
    String? searchResult;
    
    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          backgroundColor: iOSDesignSystem.surfaceCard,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(
              color: iOSDesignSystem.glassBorderMedium,
              width: iOSDesignSystem.glassBorderWidth,
            ),
          ),
          title: Row(
            children: [
              const Icon(Icons.search, color: iOSDesignSystem.accentBlue),
              const SizedBox(width: 8),
              Text(
                'Search Friends',
                style: iOSDesignSystem.textTheme.headlineMedium,
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: searchController,
                style: iOSDesignSystem.textTheme.bodyLarge,
                decoration: InputDecoration(
                  hintText: 'Enter username',
                  hintStyle: TextStyle(
                    color: iOSDesignSystem.textTertiary,
                  ),
                  filled: true,
                  fillColor: iOSDesignSystem.surfaceElevated,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                      color: iOSDesignSystem.glassBorderLight,
                    ),
                  ),
                  prefixIcon: const Icon(
                    Icons.person_search,
                    color: iOSDesignSystem.textSecondary,
                  ),
                ),
                onChanged: (value) {
                  setState(() {
                    searchResult = null; // Reset on input change
                  });
                },
              ),
              if (searchResult != null) ...[
                const SizedBox(height: 16),
                Text(
                  searchResult!,
                  style: iOSDesignSystem.textTheme.bodyMedium?.copyWith(
                    color: searchResult!.contains('found')
                        ? iOSDesignSystem.success
                        : Colors.red, // Fixed: using Colors.red instead of .error
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(
                'Cancel',
                style: TextStyle(color: iOSDesignSystem.textSecondary),
              ),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: iOSDesignSystem.accentBlue,
              ),
              onPressed: () async {
                final username = searchController.text.trim();
                if (username.isEmpty) {
                  setState(() {
                    searchResult = 'Please enter a username';
                  });
                  return;
                }
                
                setState(() {
                  searchResult = 'Searching...';
                });
                
                final model = context.read<AppModel>();
                final currentUser = model.currentUser;
                
                if (currentUser == null) {
                  setState(() {
                    searchResult = 'Error: Not logged in';
                  });
                  return;
                }
                
                try {
                  // Search server for users
                  print('🔍 Searching for username: $username');
                  final users = await ApiService.searchUsers(username);
                  print('📋 Search results: ${users.length} users found');
                  
                  if (users.isEmpty) {
                    setState(() {
                      searchResult = 'No user found with username: $username';
                    });
                  } else {
                    // Show first result
                    final user = users.first;
                    final userId = user['id'] as String;
                    final foundUsername = user['username'] as String;
                    
                    print('👤 Found user: $foundUsername (ID: $userId)');
                    
                    setState(() {
                      searchResult = 'Found: $foundUsername';
                    });
                    
                    // Send friend request via API
                    print('📤 Sending friend request to: $userId');
                    final success = await ApiService.sendFriendRequest(userId);
                
                if (success) {
                  // Save sent request info for later (when it gets accepted)
                  final prefs = await SharedPreferences.getInstance();
                  final sentRequests = prefs.getStringList('sent_friend_requests') ?? [];
                  final requestInfo = jsonEncode({
                    'user_id': userId,
                    'username': username,
                    'sent_at': DateTime.now().toIso8601String(),
                  });
                  sentRequests.add(requestInfo);
                  await prefs.setStringList('sent_friend_requests', sentRequests);
                  
                  if (context.mounted) {
                    Navigator.pop(context);
                    ToastService.showSuccess('Friend request sent!');
                  }
                  print('✅ Friend request sent to $username ($userId)');
                } else {
                      setState(() {
                        searchResult = '❌ Failed to send';
                      });
                    }
                    
                    searchController.clear();
                  }
                } catch (e, stackTrace) {
                  print('❌ Search error: $e');
                  print('Stack trace: $stackTrace');
                  setState(() {
                    searchResult = 'Error: $e';
                  });
                }
              },
              child: const Text('Search'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // DynamicGlassHeader handles safe area internally - no wrapper needed
    return Column(
      children: [
          // Dynamic Header with Search
          DynamicGlassHeader(
            title: 'Home',
            currentTab: widget.currentTab,
            onAvatarTap: () {
              // TODO: Open Profile/Settings Sheet
            },
            onMessagesTap: () {
              // TODO: Navigate to Messages
            },
            onFriendsTap: () => _showFriendSearchDialog(context),
            onNotificationTap: () => _openNotificationsPortal(context),
            // ✅ CLEANED: Centered glass capsule tabs only (no filter button)
            customContent: Center(
              child: _buildGlassSegmentedTabs(),
            ),
          ),
          
          const SizedBox(height: 8),  // ✅ Reduced from 16 to move content higher
          
          // Twitter-style Feed
          Expanded(
            child: _buildTwitterFeed(isLocal: false),  // Always get from server
          ),
      ],
    );
  }

  Widget _buildTwitterFeed({required bool isLocal}) {
    final model = context.watch<AppModel>();
    final bottomSafe = MediaQuery.of(context).padding.bottom;
    final dockH = DeviceOptimizationService.getDockHeight(context);
    
    return Column(
      children: [
        // Composer
        iOSComposer(
          onTap: () {
            PostComposerSheet.show(context).then((_) {
              if (mounted) _pullRefresh();
            });
          },
          userAvatar: model.currentUser?.avatarPath,
          userName: model.currentUser?.username ?? 'User',
        ),
        
        // Feed with New Posts Pill
        Expanded(
          child: Stack(
            children: [
              // Main feed
              _isLoading
                  ? const FeedSkeleton()
                  : _cachedPosts.isEmpty
                      ? EmptyState(
                          icon: Icons.post_add_outlined,
                          title: _feedMode == 0 ? 'No local posts yet' : 'No posts from friends yet',
                          subtitle: _feedMode == 0 
                              ? 'Be the first to post something!' 
                              : 'Connect with friends to see their posts',
                          onAction: _feedMode == 0 ? () => PostComposerSheet.show(context) : null,
                          actionLabel: _feedMode == 0 ? 'Create Post' : null,
                        )
                      : RefreshIndicator(
                          onRefresh: _pullRefresh,
                          color: const Color(0xFF0A84FF),
                          backgroundColor: Colors.black.withOpacity(0.8),
                          child: ListView.builder(
                            key: const PageStorageKey('home_feed'),
                            controller: _scrollController,
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: EdgeInsets.only(
                              top: iOSDesignSystem.spacing8,
                              bottom: dockH + bottomSafe + 24,
                            ),
                            itemCount: _cachedPosts.length,
                            itemBuilder: (context, index) {
                              final post = _cachedPosts[index];
                              final effectiveIsLiked = model.isPostLiked(post.id, post.isLiked);
                              final effectiveIsReposted = model.isPostReposted(post.id, post.isReposted);
                              
                              return iOSPostCard(
                                post: post.copyWith(
                                  isLiked: effectiveIsLiked,
                                  isReposted: effectiveIsReposted,
                                ),
                                onTap: () {},
                                onLike: () async {
                                  await model.toggleLike(post.id, effectiveIsLiked);
                                },
                                onComment: () {
                                  HapticFeedback.selectionClick();
                                  CommentsSheet.show(context, post);
                                },
                                onForward: () {
                                  // Show in-app Forward sheet instead of repost
                                  HapticFeedback.lightImpact();
                                  ForwardSheet.show(
                                    context,
                                    post: post,
                                    onSend: (recipientIds) {
                                      // TODO: Send post_share messages to selected recipients
                                      print('📤 Forwarding post to: $recipientIds');
                                    },
                                  );
                                },
                                onLongPress: () async {
                                  // Owner-only: Edit/Delete actions
                                  final currentUserId = await ApiService.getCurrentUserId();
                                  if (currentUserId == post.authorId) {
                                    HapticFeedback.mediumImpact();
                                    PostOwnerActionsSheet.show(
                                      context,
                                      post: post,
                                      onEdit: () {
                                        // TODO: Open edit post screen
                                        print('✏️ Edit post: ${post.id}');
                                      },
                                      onDeleteConfirmed: () async {
                                        final success = await ApiService.deletePost(post.id);
                                        if (success && mounted) {
                                          _pullRefresh();
                                        }
                                        return success;
                                      },
                                    );
                                  }
                                },
                              );
                            },
                          ),
                        ),
              
              // ═══════════════════════════════════════════════════════════
              // NEW POSTS PILL (Telegram/Twitter style)
              // ═══════════════════════════════════════════════════════════
              if (_hasNewPosts && _bufferedNewPosts.isNotEmpty)
                Positioned(
                  top: 12,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: GestureDetector(
                      onTap: _applyBufferedPosts,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0A84FF).withOpacity(0.9),
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF0A84FF).withOpacity(0.4),
                                  blurRadius: 12,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.arrow_upward, color: Colors.white, size: 16),
                                const SizedBox(width: 6),
                                Text(
                                  '${_bufferedNewPosts.length} new post${_bufferedNewPosts.length > 1 ? 's' : ''}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
  
  Future<List<Post>> _getFilteredPosts(AppModel model, bool isLocal) async {
    PostSendMethod? sendMethodFilter;
    
    // Convert UI selection to PostSendMethod filter
    if (_sendMethodFilter == 1) {
      sendMethodFilter = PostSendMethod.wifi;
    } else if (_sendMethodFilter == 2) {
      sendMethodFilter = PostSendMethod.bluetooth;
    }
    // If _sendMethodFilter == 0, sendMethodFilter stays null (show all)
    
    return await model.getPosts(isLocal: isLocal, sendMethod: sendMethodFilter);
  }
}

// Nearby Tab
class NearbyTab extends StatelessWidget {
  final int currentTab;
  
  const NearbyTab({super.key, required this.currentTab});

  @override
  Widget build(BuildContext context) {
    final model = context.watch<AppModel>();
    final peers = model.meshPeers;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (peers.isEmpty) {
      return EmptyState(
        icon: Icons.bluetooth_disabled_outlined,
        title: 'No devices nearby',
        subtitle: 'Make sure WiFi and Bluetooth are enabled',
      );
    }

    final bottomSafe = MediaQuery.of(context).padding.bottom;
    final dockH = DeviceOptimizationService.getDockHeight(context);
    
    return ListView.builder(
      padding: EdgeInsets.only(
        top: iOSDesignSystem.spacing8,
        bottom: dockH + bottomSafe + 24,
      ),
      itemCount: peers.length,
      itemBuilder: (context, index) {
        final peerId = peers[index];
        final peerName = "Device ${peerId.substring(0, 4)}";
        
        return FutureBuilder<int>(
          future: DatabaseHelper.instance.getFriendStatus(model.currentUser?.id ?? '', peerId),
          builder: (context, snapshot) {
            final status = snapshot.data ?? 0;
            final isFriend = status == 1;
            final isRequestSent = status == 3;
            
            FollowStatus followStatus;
            if (isFriend) {
              followStatus = FollowStatus.following;
            } else if (isRequestSent) {
              followStatus = FollowStatus.pending;
            } else {
              followStatus = FollowStatus.notFollowing;
            }
            
            return Card(
              child: ListTile(
                leading: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      colors: [iOSDesignSystem.accentBlue, Color(0xFF0066CC)],
                    ),
                  ),
                  child: const Icon(Icons.bluetooth, color: Colors.white),
                ),
                title: Text(
                  peerName,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  isFriend ? 'Friend' : 'Nearby',
                  style: TextStyle(
                    color: isFriend 
                        ? iOSDesignSystem.success 
                    : iOSDesignSystem.textSecondary,
                  ),
                ),
                trailing: isFriend
                    ? IconButton(
                        icon: const Icon(Icons.chat_bubble_outline),
                        onPressed: () {
                          model.startChatWith(peerId, peerName);
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const ChatPage()),
                          );
                        },
                      )
                    : FollowButton(
                        status: followStatus,
                        compact: true,
                        onPressed: () {
                          model.sendFriendRequest(peerId, context);
                          ToastService.showSuccess('Request sent to $peerName');
                        },
                      ),
              ),
            );
          },
        );
      },
    );
  }
}


// Notifications Tab
class NotificationsTab extends StatefulWidget {
  final int currentTab;
  
  const NotificationsTab({super.key, required this.currentTab});

  @override
  State<NotificationsTab> createState() => _NotificationsTabState();
}

class _NotificationsTabState extends State<NotificationsTab> {
  @override
  void initState() {
    super.initState();
    // Fetch friend requests from server when tab loads
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final model = context.read<AppModel>();
      model.fetchNotifications();
    });
  }
  
  @override
  Widget build(BuildContext context) {
    final model = context.watch<AppModel>();
    final notifications = model.notifications;
    final unreadCount = model.unreadNotificationCount;
    
    return Column(
      children: [
        // Dynamic Header (handles top safe area internally)
          DynamicGlassHeader(
            title: 'Notifications',
            currentTab: widget.currentTab,
            onAvatarTap: () {},
            onMessagesTap: () {},
            onFriendsTap: () {},
          ),
          
          // Refresh button
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () {
                  model.fetchNotifications();
                },
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Refresh'),
                style: TextButton.styleFrom(
                  foregroundColor: iOSDesignSystem.accentBlue,
                ),
              ),
            ),
          ),
          
          // Notifications List
          Expanded(
            child: notifications.isEmpty
                ? EmptyState(
                    icon: Icons.notifications_none_outlined,
                    title: 'No notifications yet',
                    subtitle: 'We\'ll notify you when someone sends you a friend request',
                  )
                : ListView.builder(
                    padding: EdgeInsets.only(top: 8, bottom: DeviceOptimizationService.getDockHeight(context) + MediaQuery.of(context).padding.bottom + 24),
                    itemCount: notifications.length,
                    itemBuilder: (context, index) {
                      final notification = notifications[index];
                      final friendRequestId = notification.data?['friend_request_id'];
                      final status = notification.data?['status'] ?? 'pending';
                      
                      return NotificationItem(
                        notification: notification,
                        onDismiss: () {
                          // Remove from list
                        },
                        onAccept: (status == 'pending')
                            ? () async {
                                // Use notification.id as the request ID - this is the correct ID from server
                                final requestId = notification.id;
                                print('🔵 [NotificationItem] Accept tapped:');
                                print('   └── notification.id: ${notification.id}');
                                print('   └── data[friend_request_id]: $friendRequestId');
                                await model.acceptFriendRequest(requestId);
                              }
                            : null,
                        onDecline: (status == 'pending' && friendRequestId != null)
                            ? () async {
                                print('❌ Declining friend request: $friendRequestId');
                                await model.rejectFriendRequest(friendRequestId);
                              }
                            : null,
                        onTap: () async {
                          // ✅ Deep link based on notification type
                          HapticFeedback.selectionClick();
                          
                          switch (notification.type) {
                            case NotificationType.message:
                              // Navigate to chat with sender
                              final senderId = notification.data?['sender_id'] ?? notification.data?['user_id'];
                              final senderName = notification.data?['sender_name'] ?? notification.data?['username'] ?? 'User';
                              final chatId = notification.data?['chat_id'] ?? notification.data?['room_id'];
                              
                              if (senderId != null) {
                                final appModel = context.read<AppModel>();
                                
                                // Use chatId if available, otherwise derive from sender
                                if (chatId != null) {
                                  appModel.currentChatId = chatId;
                                  appModel.currentChatName = senderName;
                                } else {
                                  appModel.startChatWith(senderId, senderName);
                                }
                                
                                if (context.mounted) {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (_) => const ChatPage()),
                                  );
                                }
                              }
                              break;
                              
                            case NotificationType.like:
                            case NotificationType.comment:
                              // Navigate to post that was liked/commented
                              final postId = notification.data?['post_id'];
                              if (postId != null) {
                                // TODO: Navigate to post detail screen
                                print('📌 Navigate to post: $postId');
                              }
                              break;
                              
                            case NotificationType.friendRequest:
                            case NotificationType.friendRequestSent:
                              // Navigate to user profile
                              final userId = notification.data?['user_id'] ?? notification.data?['from_user_id'];
                              if (userId != null && context.mounted) {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => UserProfilePage(userId: userId),
                                  ),
                                );
                              }
                              break;
                              
                            case NotificationType.security:
                              // TODO: Navigate to security settings when screen is created
                              print('🔐 Security notification tapped');
                              break;
                              
                            default:
                              // Mark as read only
                              break;
                          }
                          
                          // Mark notification as read
                          // TODO: Add markNotificationRead to AppModel
                          // model.markNotificationRead(notification.id);
                        },
                      );
                    },
                  ),
          ),
        ],
      );
  }
}

// Contacts Tab  
class ContactsTab extends StatelessWidget {
  final int currentTab;
  
  const ContactsTab({super.key, required this.currentTab});

  @override
  Widget build(BuildContext context) {
    final model = context.watch<AppModel>();
    
    return FutureBuilder<List<Contact>>(
      future: model.getAllContacts(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        
        final contacts = snapshot.data!;
        if (contacts.isEmpty) {
          return const Center(child: Text('No contacts yet. Scan QR codes to add friends!'));
        }
        
        return ListView.builder(
          padding: EdgeInsets.only(top: 16, left: 16, right: 16, bottom: DeviceOptimizationService.getDockHeight(context) + MediaQuery.of(context).padding.bottom + 24),
          itemCount: contacts.length,
          itemBuilder: (context, index) {
            final contact = contacts[index];
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: iOSDesignSystem.spacing16,
                    vertical: iOSDesignSystem.spacing8,
                  ),
                  decoration: iOSDesignSystem.cardDecoration(),
                  child: ListTile(
                  leading: CircleAvatar(child: Text(contact.username[0].toUpperCase())),
                  title: Text(contact.username),
                  subtitle: Text(contact.status == 1 ? 'Friend' : 'Stranger'),
                  trailing: contact.status == 0
                      ? IconButton(
                          icon: const Icon(Icons.message),
                          onPressed: () {
                            model.startChatWith(contact.userId, contact.username);
                            Navigator.push(context, MaterialPageRoute(builder: (_) => const ChatPage()));
                          },
                        )
                      : null,
                  onTap: () {
                    model.startChatWith(contact.userId, contact.username);
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const ChatPage()));
                  },
                ),
              ),
            );
          },
        );
      },
    );
  }
}
