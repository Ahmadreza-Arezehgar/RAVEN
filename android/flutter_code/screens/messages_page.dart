import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:uuid/uuid.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../theme/ios_design_system.dart';
import '../screens/chat_page.dart';
import '../screens/contact_picker_page.dart';
import '../screens/group_setup_page.dart';
import '../services/database_helper.dart';
import '../services/api_service.dart';
import '../services/toast_service.dart';
import '../services/peek_pop_controller.dart';
import '../services/nickname_service.dart';
import '../models/contact_model.dart';
import '../widgets/nickname_dialog.dart';
import '../widgets/liquid_glass_dialog.dart';

/// Messages Page - List of all conversations
class MessagesPage extends StatefulWidget {
  const MessagesPage({super.key});

  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  // ══════════════════════════════════════════════════════════════
  // UNIFIED REFRESH SYSTEM
  // ══════════════════════════════════════════════════════════════
  Timer? _autoTimer;
  bool _refreshInFlight = false;
  DateTime _lastRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  
  // ✅ Segmented Control: 0 = Individuals, 1 = Groups
  int _selectedSegment = 0;

  // ══════════════════════════════════════════════════════════════
  // AVATAR HELPER - Builds full URL from relative paths
  // ══════════════════════════════════════════════════════════════
  ImageProvider? _getAvatarImage(String? avatarUrl) {
    if (avatarUrl == null || avatarUrl.isEmpty) return null;
    
    // Already full URL
    if (avatarUrl.startsWith('http://') || avatarUrl.startsWith('https://')) {
      return NetworkImage(avatarUrl);
    }
    
    // Relative path - prepend base URL
    if (avatarUrl.startsWith('/uploads/') || avatarUrl.startsWith('/static/')) {
      return NetworkImage('${ApiService.baseUrl}$avatarUrl');
    }
    
    // Unknown format - still try with base URL
    return NetworkImage('${ApiService.baseUrl}$avatarUrl');
  }

  @override
  void initState() {
    super.initState();
    _startAutoRefresh();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshConversations(source: 'init');
      // ✅ Trigger initial inbox load for StreamBuilder
      context.read<AppModel>().refreshInbox();
    });
  }


  @override
  void dispose() {
    _autoTimer?.cancel();
    super.dispose();
  }

  // ✅ Removed auto-refresh timer - SyncService already syncs messages every 30s
  // This prevents duplicate sync operations that cause UI freezes
  void _startAutoRefresh({Duration interval = const Duration(seconds: 60)}) {
    _autoTimer?.cancel();
    // Only auto-refresh once per minute since SyncService handles messages
    _autoTimer = Timer.periodic(interval, (_) {
      if (mounted) {
        _refreshConversations(source: 'auto');
      }
    });
  }

  /// Unified refresh - prevents duplicate fetches
  Future<void> _refreshConversations({required String source}) async {
    if (_refreshInFlight) return;

    // Prevent spam refresh (min 5s between refreshes to reduce UI freezes)
    final now = DateTime.now();
    if (now.difference(_lastRefresh) < const Duration(seconds: 5)) return;

    _refreshInFlight = true;
    _lastRefresh = now;

    try {
      // ✅ Reduced delay to minimize perceived lag
      await Future.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      setState(() {}); // Trigger rebuild to refresh conversation list
    } finally {
      _refreshInFlight = false;
    }
  }

  // ══════════════════════════════════════════════════════════════
  // NEW MESSAGE - ContactPicker (single mode)
  // ══════════════════════════════════════════════════════════════
  void _openNewMessageSheet(BuildContext ctx) async {
    HapticFeedback.lightImpact();
    
    // Navigate to Contact Picker (single mode)
    final selectedUser = await Navigator.push<Map<String, dynamic>>(
      ctx,
      MaterialPageRoute(
        builder: (_) => const ContactPickerPage(mode: PickerMode.single),
      ),
    );

    // ✅ Safety check after await
    if (!mounted) return;
    if (selectedUser == null) return;
    
    final model = context.read<AppModel>();
    final userId = selectedUser['id'] as String? ?? '';
    final username = selectedUser['username'] as String? ?? 'Unknown';
    
    // Start chat and navigate
    model.startChatWith(userId, username);
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ChatPage()),
    );
  }

  // ══════════════════════════════════════════════════════════════
  // CREATE GROUP - ContactPicker (multi) → GroupSetup
  // ══════════════════════════════════════════════════════════════
  void _openNewGroupSheet(BuildContext ctx) async {
    HapticFeedback.mediumImpact();
    
    // Step 1: Select members
    final members = await Navigator.push<List<Map<String, dynamic>>>(
      ctx,
      MaterialPageRoute(
        builder: (_) => const ContactPickerPage(mode: PickerMode.multi),
      ),
    );

    // ✅ Safety check after await
    if (!mounted) return;
    if (members == null || members.isEmpty) return;

    // Step 2: Group setup (name, photo, bio)
    final groupData = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => GroupSetupPage(selectedMembers: members),
      ),
    );

    // ✅ Safety check after second await
    if (!mounted) return;
    if (groupData == null) return;

    // ═══════════════════════════════════════════════════════════
    // ✅ FIX: Actually create the group in the database!
    // ═══════════════════════════════════════════════════════════
    final groupName = groupData['name'] as String? ?? 'New Group';
    final memberIds = (groupData['memberIds'] as List<dynamic>?)
        ?.map((e) => e.toString())
        .toList() ?? [];
    final localImagePath = groupData['imagePath'] as String?;
    
    try {
      // ═══════════════════════════════════════════════════════════
      // ✅ FIX: Upload avatar first, then create group on SERVER
      // ═══════════════════════════════════════════════════════════
      
      String? serverAvatarUrl;
      
      // 0) Upload group avatar if provided (must be server URL, not local path)
      if (localImagePath != null && localImagePath.isNotEmpty) {
        try {
          final file = File(localImagePath);
          if (await file.exists()) {
            print('📷 [CreateGroup] Uploading avatar: $localImagePath');
            serverAvatarUrl = await ApiService.uploadImage(file);
            print('✅ [CreateGroup] Avatar uploaded: $serverAvatarUrl');
          }
        } catch (e) {
          print('⚠️ [CreateGroup] Avatar upload failed: $e');
          // Continue without avatar
        }
      }
      
      String groupRoomId;
      
      // 1) Try to create group on server
      try {
        final serverResponse = await ApiService.createGroup(
          name: groupName,
          memberIds: memberIds,
          avatarUrl: serverAvatarUrl,  // ✅ Use server URL, not local path
        );
        
        if (serverResponse != null) {
          // Use server-assigned group ID
          groupRoomId = serverResponse['id'] as String;
          // Use avatar URL from server response if available
          serverAvatarUrl = serverResponse['avatar_url'] as String? ?? serverAvatarUrl;
          print('✅ [CreateGroup] Server created group: $groupRoomId');
        } else {
          // Fallback to local UUID if server fails (offline mode)
          groupRoomId = 'group_${const Uuid().v4()}';
          print('⚠️ [CreateGroup] Server failed, using local ID: $groupRoomId');
        }
      } catch (e) {
        // Offline fallback: use local UUID
        groupRoomId = 'group_${const Uuid().v4()}';
        print('⚠️ [CreateGroup] Offline mode, using local ID: $groupRoomId');
      }
      
      // 2) Save group to local database with SERVER avatar URL
      await DatabaseHelper.instance.createGroupConversation(
        roomId: groupRoomId,
        title: groupName,
        memberIds: memberIds,
        avatarUrl: serverAvatarUrl,  // ✅ Server URL that works on all devices
      );
      print('✅ [CreateGroup] Saved group "$groupName" to local DB');
      
      // 3) Refresh UI to show the new group
      if (mounted) setState(() {});
      
      // 4) Show success message
      ToastService.showSuccess('Group "$groupName" created!');
    } catch (e) {
      print('❌ [CreateGroup] Failed to create group: $e');
      ToastService.showError('Failed to create group: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = context.watch<AppModel>();
    final safeTop = MediaQuery.of(context).padding.top;

    return Column(
      children: [
        // ═══════════════════════════════════════════════════════════
        // CUSTOM MESSAGES HEADER (No notification icon)
        // ═══════════════════════════════════════════════════════════
        ClipRRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: Container(
              padding: EdgeInsets.only(
                top: safeTop + 8,
                left: 16,
                right: 16,
                bottom: 12,
              ),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.3),
                border: Border(
                  bottom: BorderSide(
                    color: Colors.white.withOpacity(0.08),
                    width: 0.5,
                  ),
                ),
              ),
              child: Row(
                children: [
                  // LEFT: New Group button
                  _HeaderIconButton(
                    icon: Icons.group_add_outlined, // ✅ Material Icon
                    onTap: () => _openNewGroupSheet(context),
                    tooltip: 'New Group',
                  ),
                  
                  const Spacer(),
                  
                  // CENTER: Title
                  Text(
                    'Messages',
                    style: iOSDesignSystem.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  
                  const Spacer(),
                  
                  // RIGHT: New Message button
                  _HeaderIconButton(
                    icon: Icons.edit_outlined, // ✅ Material Icon (pencil)
                    onTap: () => _openNewMessageSheet(context),
                    tooltip: 'New Message',
                  ),
                ],
              ),
            ),
          ),
        ),

        // ═══════════════════════════════════════════════════════════
        // CONTENT: Two Sections (Groups + Messages)
        // ═══════════════════════════════════════════════════════════
        Expanded(
          child: StreamBuilder<List<Contact>>(
            stream: model.inboxStream,
            initialData: model.lastInboxData, // ✅ Show cached data immediately
            builder: (context, snap) {
              // Separate groups and individuals from the combined stream
              final all = snap.data ?? model.lastInboxData;
              final groups = all.where((c) => c.userId.startsWith('group_')).toList();
              final individuals = all.where((c) => !c.userId.startsWith('group_')).toList();
              
              return CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  // iOS-style Pull-to-Refresh
                  CupertinoSliverRefreshControl(
                    onRefresh: () => _refreshConversations(source: 'pull'),
                  ),

                  const SliverToBoxAdapter(child: SizedBox(height: 12)),

                  // ═══ GROUPS SECTION ═══
                  if (groups.isNotEmpty)
                    SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Section Header
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            child: Text(
                              'Groups',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.5),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                          // Group items
                          ...groups.map((c) => _buildConversationTile(context, model, c)),
                          const SizedBox(height: 16),
                        ],
                      ),
                    ),
                  
                  // ═══ MESSAGES (Individual) SECTION ═══
                  SliverToBoxAdapter(
                    child: snap.connectionState == ConnectionState.waiting && all.isEmpty
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.all(32),
                              child: CupertinoActivityIndicator(),
                            ),
                          )
                        : individuals.isEmpty && groups.isEmpty
                            ? _buildEmptyState()
                            : individuals.isEmpty
                                ? const SizedBox.shrink()
                                : Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      // Section Header
                                      Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                        child: Text(
                                          'Messages',
                                          style: TextStyle(
                                            color: Colors.white.withOpacity(0.5),
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                            letterSpacing: 0.5,
                                          ),
                                        ),
                                      ),
                                      // Individual chat items
                                      ...individuals.map((c) => _buildConversationTile(context, model, c)),
                                    ],
                                  ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  
  // ══════════════════════════════════════════════════════════════
  // EMPTY STATE
  // ══════════════════════════════════════════════════════════════
  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(48),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.chat_bubble_outline_rounded,
              size: 56,
              color: Colors.white.withOpacity(0.35),
            ),
            const SizedBox(height: 20),
            const Text(
              'No Messages Yet',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Start chatting with your friends',
              style: TextStyle(
                color: Colors.white.withOpacity(0.5),
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 28),
            GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                _openNewMessageSheet(context);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0A84FF),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF0A84FF).withOpacity(0.3),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.edit_outlined, color: Colors.white, size: 18),
                    SizedBox(width: 8),
                    Text(
                      'New Message',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  // ══════════════════════════════════════════════════════════════
  // CONVERSATION TILE
  // ══════════════════════════════════════════════════════════════
  Widget _buildConversationTile(BuildContext context, AppModel model, Contact c) {
    final unread = c.unreadCount ?? 0;
    final hasUnread = unread > 0;
    
    // Generate roomId for API calls
    final currentUserId = model.currentUser?.id ?? '';
    final roomId = currentUserId.compareTo(c.userId) < 0 
        ? '${currentUserId}_${c.userId}' 
        : '${c.userId}_$currentUserId';
    
    // Format timestamp
    String timeText = '';
    final dt = c.lastMessageTime;
    if (dt != null) {
      final now = DateTime.now();
      final diff = now.difference(dt);
      if (diff.inDays == 0) {
        timeText = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      } else if (diff.inDays == 1) {
        timeText = 'Yesterday';
      } else if (diff.inDays < 7) {
        const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
        timeText = days[dt.weekday - 1];
      } else {
        timeText = '${dt.day}/${dt.month}';
      }
    }
    
    return Slidable(
      key: ValueKey(c.userId),
      
      // ← Swipe LEFT = Delete
      endActionPane: ActionPane(
        motion: const BehindMotion(),
        extentRatio: 0.25,
        children: [
          SlidableAction(
            onPressed: (_) => _showDeleteConfirmation(context, model, c, roomId),
            backgroundColor: const Color(0xFFFF3B30),
            foregroundColor: Colors.white,
            icon: Icons.delete_outline_rounded,
            label: 'Delete',
            borderRadius: const BorderRadius.only(
              topRight: Radius.circular(16),
              bottomRight: Radius.circular(16),
            ),
          ),
        ],
      ),
      
      // → Swipe RIGHT = Mark as read
      startActionPane: ActionPane(
        motion: const BehindMotion(),
        extentRatio: 0.25,
        children: [
          SlidableAction(
            onPressed: (_) async {
              HapticFeedback.lightImpact();
              // Clear local unread
              await DatabaseHelper.instance.clearUnreadCountByUserId(c.userId);
              // Sync with server
              await ApiService.markRoomAsRead(roomId);
              ToastService.showSuccess('Marked as read');
              if (mounted) setState(() {});
            },
            backgroundColor: const Color(0xFF0A84FF),
            foregroundColor: Colors.white,
            icon: Icons.check_rounded,
            label: 'Read',
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              bottomLeft: Radius.circular(16),
            ),
          ),
        ],
      ),
      
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          // Clear unread and open chat
          DatabaseHelper.instance.clearUnreadCountByUserId(c.userId);
          model.startChatWith(c.userId, c.username);
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ChatPage()),
          ).then((_) {
            // Rebuild to update unread count
            if (mounted) setState(() {});
          });
        },
        onLongPressStart: (details) {
          // Show peek preview
          PeekPopController.instance.showPeek(
            context: context,
            anchor: details.globalPosition,
            onPop: () {
              // Pop to full chat
              model.startChatWith(c.userId, c.username);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ChatPage()),
              ).then((_) {
                if (mounted) setState(() {});
              });
            },
            child: MessagePeekCard(
              contactName: c.displayName,
              avatarUrl: c.avatarUrl,
              peerId: c.userId,
              username: c.username,
              onSetNickname: () async {
                PeekPopController.instance.hide();
                final changed = await showNicknameSheet(
                  context: context,
                  peerId: c.userId,
                  username: c.username,
                  avatarUrl: c.avatarUrl,
                  currentNickname: NicknameService.instance.getNickname(c.userId),
                );
                if (changed && mounted) setState(() {});
              },
              lastMessage: c.lastMessagePreview,
              lastMessageTime: c.lastMessageTime,
              unreadCount: unread,
              onMarkRead: () async {
                PeekPopController.instance.hide();
                await DatabaseHelper.instance.clearUnreadCountByUserId(c.userId);
                await ApiService.markRoomAsRead(roomId);
                ToastService.showSuccess('Marked as read');
                if (mounted) setState(() {});
              },
              onDelete: () {
                PeekPopController.instance.hide();
                _showDeleteConfirmation(context, model, c, roomId);
              },
            ),
          );
        },
        child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: hasUnread 
              ? Colors.white.withOpacity(0.08)
              : Colors.white.withOpacity(0.04),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Colors.white.withOpacity(hasUnread ? 0.15 : 0.08),
            width: 0.5,
          ),
        ),
        child: Row(
          children: [
            // Avatar - uses helper to build full URL from relative paths
            CircleAvatar(
              radius: 26,
              backgroundColor: const Color(0xFF0A84FF).withOpacity(0.2),
              backgroundImage: _getAvatarImage(c.avatarUrl),
              child: _getAvatarImage(c.avatarUrl) == null
                  ? Text(
                      c.displayName.isNotEmpty ? c.displayName[0].toUpperCase() : '?',
                      style: const TextStyle(
                        color: Color(0xFF0A84FF),
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            
            // Name and preview
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          c.displayName,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: hasUnread ? FontWeight.w700 : FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (timeText.isNotEmpty)
                        Text(
                          timeText,
                          style: TextStyle(
                            color: hasUnread 
                                ? const Color(0xFF0A84FF)
                                : Colors.white.withOpacity(0.4),
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          c.lastMessagePreview ?? 'No messages yet',
                          style: TextStyle(
                            color: hasUnread 
                                ? Colors.white.withOpacity(0.8)
                                : Colors.white.withOpacity(0.5),
                            fontSize: 14,
                            fontWeight: hasUnread ? FontWeight.w500 : FontWeight.normal,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (hasUnread)
                        Container(
                          margin: const EdgeInsets.only(left: 8),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0A84FF),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            unread > 99 ? '99+' : unread.toString(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
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
      ),
      ),
    );
  }
  
  // ══════════════════════════════════════════════════════════════
  // DELETE CONFIRMATION DIALOG (Liquid Glass)
  // ══════════════════════════════════════════════════════════════
  void _showDeleteConfirmation(BuildContext context, AppModel model, Contact c, String roomId) async {
    final confirmed = await LiquidGlassDialog.confirm(
      context: context,
      title: 'Delete Conversation?',
      message: 'This will delete the conversation with ${c.username}. Messages will be hidden for you only.',
      cancelText: 'Cancel',
      confirmText: 'Delete',
      isDestructive: true,
    );
    
    if (confirmed) {
      // Hide locally first
      await DatabaseHelper.instance.deleteContactByUserId(c.userId);
      
      // Sync with server
      await ApiService.hideRoom(roomId);
      
      ToastService.showSuccess('Conversation deleted');
      if (mounted) setState(() {});
    }
  }
}

// ══════════════════════════════════════════════════════════════════════════
// HEADER ICON BUTTON
// ══════════════════════════════════════════════════════════════════════════
class _HeaderIconButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  const _HeaderIconButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  @override
  State<_HeaderIconButton> createState() => _HeaderIconButtonState();
}

class _HeaderIconButtonState extends State<_HeaderIconButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) {
        HapticFeedback.selectionClick();
        setState(() => _pressed = true);
      },
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: Tooltip(
        message: widget.tooltip,
        child: AnimatedScale(
          scale: _pressed ? 0.9 : 1.0,
          duration: const Duration(milliseconds: 100),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Colors.white.withOpacity(0.1),
                width: 0.5,
              ),
            ),
            child: Icon(
              widget.icon,
              color: const Color(0xFF0A84FF),
              size: 20,
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// FRIENDS SELECTION SHEET (Map-based from AppModel.friends)
// ══════════════════════════════════════════════════════════════════════════
class _FriendsSelectionSheet extends StatelessWidget {
  final List<Map<String, dynamic>> friends;
  final String title;
  final void Function(String userId, String username) onSelect;

  const _FriendsSelectionSheet({
    required this.friends,
    required this.title,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.5),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(
              top: BorderSide(color: Colors.white.withOpacity(0.15), width: 0.5),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle
              Container(
                margin: const EdgeInsets.only(top: 12),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              
              // Title
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              
              const Divider(height: 1, color: Colors.white12),
              
              // Friends list
              Flexible(
                child: friends.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(32),
                        child: Text(
                          'No friends yet.\nAdd friends to start messaging!',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white70),
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: friends.length,
                        itemBuilder: (context, i) {
                          final f = friends[i];
                          final userId = f['id'] as String? ?? '';
                          final username = f['username'] as String? ?? 'Unknown';
                          
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: const Color(0xFF0A84FF).withOpacity(0.2),
                              child: Text(
                                username.isNotEmpty ? username[0].toUpperCase() : '?',
                                style: const TextStyle(color: Color(0xFF0A84FF)),
                              ),
                            ),
                            title: Text(
                              username,
                              style: const TextStyle(color: Colors.white),
                            ),
                            subtitle: Text(
                              '@$username',
                              style: TextStyle(color: Colors.white.withOpacity(0.5)),
                            ),
                            onTap: () => onSelect(userId, username),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// NEW GROUP SHEET (Map-based from AppModel.friends)
// ══════════════════════════════════════════════════════════════════════════
class _NewGroupSheet extends StatefulWidget {
  final List<Map<String, dynamic>> friends;

  const _NewGroupSheet({required this.friends});

  @override
  State<_NewGroupSheet> createState() => _NewGroupSheetState();
}

class _NewGroupSheetState extends State<_NewGroupSheet> {
  final TextEditingController _nameController = TextEditingController();
  final Set<String> _selectedIds = {};

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _createGroup() async {
    if (_nameController.text.isEmpty) {
      ToastService.showError('Please enter a group name');
      return;
    }
    if (_selectedIds.isEmpty) {
      ToastService.showError('Please select at least one member');
      return;
    }

    final groupName = _nameController.text.trim();
    final memberIds = _selectedIds.toList();
    
    try {
      String groupRoomId;
      
      // ✅ FIX: Create group on SERVER first so all members can see it!
      try {
        final serverResponse = await ApiService.createGroup(
          name: groupName,
          memberIds: memberIds,
        );
        
        if (serverResponse != null) {
          // Use server-assigned group ID
          groupRoomId = serverResponse['id'] as String;
          print('✅ [_NewGroupSheet] Server created group: $groupRoomId');
        } else {
          // Fallback to local UUID if server fails (offline mode)
          groupRoomId = 'group_${const Uuid().v4()}';
          print('⚠️ [_NewGroupSheet] Server failed, using local ID: $groupRoomId');
        }
      } catch (e) {
        // Offline fallback: use local UUID
        groupRoomId = 'group_${const Uuid().v4()}';
        print('⚠️ [_NewGroupSheet] Offline mode, using local ID: $groupRoomId');
      }
      
      // Save to local database
      await DatabaseHelper.instance.createGroupConversation(
        roomId: groupRoomId,
        title: groupName,
        memberIds: memberIds,
      );
      print('✅ [_NewGroupSheet] Saved group "$groupName" to local DB');
      
      Navigator.pop(context, true);  // Return true to signal refresh needed
      ToastService.showSuccess('Group "$groupName" created!');
    } catch (e) {
      print('❌ [_NewGroupSheet] Failed: $e');
      ToastService.showError('Failed to create group: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.8,
          ),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.5),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(
              top: BorderSide(color: Colors.white.withOpacity(0.15), width: 0.5),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle
              Container(
                margin: const EdgeInsets.only(top: 12),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              
              // Header with title and create button
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    const Spacer(),
                    const Text(
                      'New Group',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: _createGroup,
                      child: const Text('Create'),
                    ),
                  ],
                ),
              ),
              
              // Group name input
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: CupertinoTextField(
                  controller: _nameController,
                  placeholder: 'Group Name',
                  style: const TextStyle(color: Colors.white),
                  placeholderStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white.withOpacity(0.15)),
                  ),
                  padding: const EdgeInsets.all(16),
                ),
              ),
              
              const SizedBox(height: 16),
              
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Text(
                      'Members (${_selectedIds.length})',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.7),
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
              
              const SizedBox(height: 8),
              const Divider(height: 1, color: Colors.white12),
              
              // Friends list with checkboxes
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: widget.friends.length,
                  itemBuilder: (context, i) {
                    final f = widget.friends[i];
                    final userId = f['id'] as String? ?? '';
                    final username = f['username'] as String? ?? 'Unknown';
                    final selected = _selectedIds.contains(userId);
                    
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: selected 
                            ? const Color(0xFF34C759) 
                            : const Color(0xFF0A84FF).withOpacity(0.2),
                        child: selected
                            ? const Icon(CupertinoIcons.checkmark, color: Colors.white, size: 18)
                            : Text(
                                username.isNotEmpty ? username[0].toUpperCase() : '?',
                                style: const TextStyle(color: Color(0xFF0A84FF)),
                              ),
                      ),
                      title: Text(
                        username,
                        style: const TextStyle(color: Colors.white),
                      ),
                      trailing: selected
                          ? const Icon(CupertinoIcons.checkmark_circle_fill, color: Color(0xFF34C759))
                          : Icon(CupertinoIcons.circle, color: Colors.white.withOpacity(0.3)),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() {
                          if (selected) {
                            _selectedIds.remove(userId);
                          } else {
                            _selectedIds.add(userId);
                          }
                        });
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

