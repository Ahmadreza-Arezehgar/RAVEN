import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ═══════════════════════════════════════════════════════════════════════════
// NOTIFICATION TYPE ENUM
// ═══════════════════════════════════════════════════════════════════════════
enum OverlayNotificationType { 
  message, 
  friendRequest, 
  like,         // Someone liked your post
  comment,      // Someone commented on your post
  mention,      // Someone @mentioned you
  presence,     // ✅ Mesh: Someone checked in nearby
  deadDrop,     // ✅ Mesh: New dead drop discovered
  security,     // 🔐 Security events (login, password change)
  other 
}

// ═══════════════════════════════════════════════════════════════════════════
// OVERLAY NOTIFICATION MODEL  
// ═══════════════════════════════════════════════════════════════════════════
class OverlayNotification {
  final String id;
  final OverlayNotificationType type;
  final String title;
  final String body;
  final DateTime time;
  
  // Navigation payload (for messages)
  final String? roomId;
  final String? peerUserId;
  final String? peerUsername;
  final bool isGroup;
  
  // Friend request payload
  final String? requesterId;
  final String? requesterUsername;
  
  bool isRead;

  OverlayNotification({
    required this.id,
    this.type = OverlayNotificationType.other,
    required this.title,
    required this.body,
    required this.time,
    this.roomId,
    this.peerUserId,
    this.peerUsername,
    this.isGroup = false,
    this.requesterId,
    this.requesterUsername,
    this.isRead = false,
  });
  
  /// Factory for message notification
  factory OverlayNotification.message({
    required String id,
    required String senderName,
    required String messagePreview,
    required String roomId,
    required String peerUserId,
    bool isGroup = false,
  }) {
    return OverlayNotification(
      id: id,
      type: OverlayNotificationType.message,
      title: senderName,
      body: messagePreview,
      time: DateTime.now(),
      roomId: roomId,
      peerUserId: peerUserId,
      peerUsername: senderName,
      isGroup: isGroup,
    );
  }
  
  /// Factory for friend request notification
  factory OverlayNotification.friendRequest({
    required String id,
    required String requesterName,
    required String requesterId,
  }) {
    return OverlayNotification(
      id: id,
      type: OverlayNotificationType.friendRequest,
      title: 'Friend Request',
      body: '$requesterName wants to be your friend',
      time: DateTime.now(),
      requesterId: requesterId,
      requesterUsername: requesterName,
    );
  }
  
  /// Factory for presence check-in notification (Mesh)
  factory OverlayNotification.presence({
    required String id,
    required String nickname,
    String? note,
  }) {
    final timeAgo = 'just now';
    return OverlayNotification(
      id: id,
      type: OverlayNotificationType.presence,
      title: nickname,
      body: note != null && note.isNotEmpty 
          ? '$note • checked in nearby'
          : 'checked in nearby • $timeAgo',
      time: DateTime.now(),
    );
  }
  
  /// Factory for dead drop notification (Mesh)
  factory OverlayNotification.deadDrop({
    required String id,
    required String title,
    required String preview,
  }) {
    return OverlayNotification(
      id: id,
      type: OverlayNotificationType.deadDrop,
      title: 'New Dead Drop',
      body: '$title: ${preview.length > 40 ? '${preview.substring(0, 40)}...' : preview}',
      time: DateTime.now(),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// NOTIFICATION OVERLAY CONTROLLER
// ═══════════════════════════════════════════════════════════════════════════
class NotificationOverlayController extends ChangeNotifier {
  bool _isOpen = false;
  bool get isOpen => _isOpen;
  
  final List<OverlayNotification> items = [];
  int get unreadCount => items.where((n) => !n.isRead).length;
  
  // Bell position for anchoring
  Offset? _bellPosition;
  Size? _bellSize;
  Offset? get bellPosition => _bellPosition;
  Size? get bellSize => _bellSize;
  
  Rect? get bellRect {
    if (_bellPosition == null || _bellSize == null) return null;
    return _bellPosition! & _bellSize!;
  }
  
  // Toast state
  OverlayNotification? _currentToast;
  OverlayNotification? get currentToast => _currentToast;
  final List<OverlayNotification> _toastQueue = [];
  bool _isShowingToast = false;
  
  // Action callbacks (set from main.dart)
  Function(OverlayNotification)? onOpenChat;
  Function(String requesterId, bool accept)? onFriendRequestAction;
  
  void updateBellPosition(GlobalKey bellKey) {
    final context = bellKey.currentContext;
    if (context == null) return;
    
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    
    _bellPosition = box.localToGlobal(Offset.zero);
    _bellSize = box.size;
    notifyListeners();
  }
  
  void add(OverlayNotification n) {
    print('🔔 [NOTIF] add() called: type=${n.type.name} id=${n.id.substring(0, 8)} title=${n.title}');
    items.insert(0, n);
    notifyListeners();
    _enqueueToast(n);
  }
  
  void toggle() => _isOpen ? close() : open();
  
  void open() {
    HapticFeedback.mediumImpact();
    _isOpen = true;
    for (var n in items) {
      n.isRead = true;
    }
    notifyListeners();
  }
  
  void close() {
    HapticFeedback.lightImpact();
    _isOpen = false;
    notifyListeners();
  }
  
  void clearAll() {
    items.clear();
    notifyListeners();
  }
  
  void remove(String id) {
    items.removeWhere((n) => n.id == id);
    notifyListeners();
  }
  
  /// Handle toast tap based on notification type
  void handleToastTap(BuildContext context, OverlayNotification n) {
    // Dismiss toast immediately
    _currentToast = null;
    notifyListeners();
    
    if (n.type == OverlayNotificationType.message) {
      // Navigate to chat
      if (onOpenChat != null) {
        onOpenChat!(n);
      }
    } else if (n.type == OverlayNotificationType.friendRequest) {
      // Open panel to show actions
      open();
    }
  }
  
  /// Handle friend request accept/decline
  Future<void> handleFriendRequest(String notificationId, String requesterId, bool accept) async {
    HapticFeedback.mediumImpact();
    
    if (onFriendRequestAction != null) {
      await onFriendRequestAction!(requesterId, accept);
    }
    
    // Remove notification
    remove(notificationId);
  }
  
  Future<void> _enqueueToast(OverlayNotification n) async {
    print('🔔 [TOAST] _enqueueToast: id=${n.id.substring(0, 8)} isOpen=$_isOpen isShowing=$_isShowingToast queueLen=${_toastQueue.length}');
    
    if (_isOpen) {
      print('🔔 [TOAST] Skipping toast - panel is open');
      return;
    }
    
    _toastQueue.add(n);
    if (_isShowingToast) {
      print('🔔 [TOAST] Added to queue, already showing');
      return;
    }
    
    _isShowingToast = true;
    while (_toastQueue.isNotEmpty) {
      _currentToast = _toastQueue.first;
      print('🔔 [TOAST] Showing toast: ${_currentToast?.title}');
      notifyListeners();
      HapticFeedback.lightImpact();
      
      // Toast will auto-close via widget timer
      await Future.delayed(const Duration(milliseconds: 2500));
      
      _toastQueue.removeAt(0);
      _currentToast = null;
      notifyListeners();
      
      if (_toastQueue.isNotEmpty) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
    _isShowingToast = false;
    print('🔔 [TOAST] Queue empty, done');
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// CAPSULE TOAST (Pop from Bell → Hold 1s → Shrink Back)
// ═══════════════════════════════════════════════════════════════════════════
class NotificationToastWidget extends StatefulWidget {
  final OverlayNotification? toast;
  final Rect? bellRect;
  final VoidCallback? onTap;
  final Duration visibleFor;
  
  const NotificationToastWidget({
    super.key,
    this.toast,
    this.bellRect,
    this.onTap,
    this.visibleFor = const Duration(milliseconds: 1200),
  });

  @override
  State<NotificationToastWidget> createState() => _NotificationToastWidgetState();
}

class _NotificationToastWidgetState extends State<NotificationToastWidget> 
    with SingleTickerProviderStateMixin {
  
  late AnimationController _controller;
  late Animation<double> _scaleAnim;
  late Animation<double> _fadeAnim;
  Timer? _autoClose;
  
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    
    // ✅ Capsule popup animation (like haptic bottom bar)
    _scaleAnim = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
    );
    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
  }
  
  @override
  void didUpdateWidget(NotificationToastWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    if (widget.toast != null && oldWidget.toast == null) {
      // ✅ Pop in
      _autoClose?.cancel();
      _controller.forward(from: 0);
      
      // ✅ After 1s → shrink back
      _autoClose = Timer(widget.visibleFor, () async {
        if (!mounted) return;
        await _controller.reverse();
      });
    }
    
    if (widget.toast == null && oldWidget.toast != null) {
      _autoClose?.cancel();
      _controller.reverse();
    }
  }
  
  @override
  void dispose() {
    _autoClose?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.toast == null && _controller.value == 0) {
      return const SizedBox.shrink();
    }
    
    final safeTop = MediaQuery.of(context).padding.top;
    final screenWidth = MediaQuery.of(context).size.width;
    
    // ✅ Position from Bell
    final bellRect = widget.bellRect;
    final top = (bellRect?.bottom ?? (safeTop + 44)) + 10;
    final right = bellRect != null 
        ? (screenWidth - bellRect.right).clamp(12.0, 24.0)
        : 12.0;
    
    return Positioned(
      top: top,
      right: right,
      child: SizedBox(
        width: screenWidth * 0.82,
        child: IgnorePointer(
          ignoring: widget.toast == null,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) => Transform.scale(
              scale: _scaleAnim.value,
              alignment: Alignment.topRight, // ✅ Expand from Bell
              child: Opacity(
                opacity: _fadeAnim.value,
                child: child,
              ),
            ),
            child: GestureDetector(
              onTap: () {
                _autoClose?.cancel();
                widget.onTap?.call();
                _controller.reverse();
              },
              child: LiquidGlassCapsule(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: _ToastContent(notification: widget.toast),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Toast content with icon and text
class _ToastContent extends StatelessWidget {
  final OverlayNotification? notification;
  
  const _ToastContent({this.notification});

  IconData _getIcon() {
    switch (notification?.type) {
      case OverlayNotificationType.message:
        return Icons.chat_bubble_rounded;
      case OverlayNotificationType.friendRequest:
        return Icons.person_add_rounded;
      case OverlayNotificationType.like:
        return Icons.favorite_rounded;
      case OverlayNotificationType.comment:
        return Icons.mode_comment_rounded;
      case OverlayNotificationType.mention:
        return Icons.alternate_email_rounded;
      case OverlayNotificationType.presence:
        return Icons.location_on_rounded; // 📍 Presence check-in
      case OverlayNotificationType.deadDrop:
        return Icons.archive_rounded; // 📦 Dead drop
      case OverlayNotificationType.security:
        return Icons.security_rounded; // 🔐 Security events
      default:
        return Icons.notifications_rounded;
    }
  }
  
  Color _getIconColor() {
    switch (notification?.type) {
      case OverlayNotificationType.message:
        return const Color(0xFF0A84FF);
      case OverlayNotificationType.friendRequest:
        return const Color(0xFF30D158);
      case OverlayNotificationType.like:
        return const Color(0xFFFF3B30);  // ❤️ Red for likes
      case OverlayNotificationType.comment:
        return const Color(0xFFFF9500);  // 🟠 Orange for comments
      case OverlayNotificationType.mention:
        return const Color(0xFF5856D6);  // 💜 Purple for mentions
      case OverlayNotificationType.presence:
        return const Color(0xFF30D158);  // 📍 Green for presence
      case OverlayNotificationType.deadDrop:
        return const Color(0xFFFF9F0A);  // 📦 Amber for dead drops
      case OverlayNotificationType.security:
        return const Color(0xFFFF9500);  // 🔐 Orange for security
      default:
        return const Color(0xFF5856D6);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // Icon
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _getIconColor().withOpacity(0.15),
          ),
          child: Icon(
            _getIcon(),
            color: _getIconColor(),
            size: 20,
          ),
        ),
        const SizedBox(width: 12),
        
        // Content
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                notification?.title ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                notification?.body ?? '',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.65),
                  fontSize: 12,
                  height: 1.25,
                ),
              ),
            ],
          ),
        ),
        
        // Tap hint
        Icon(
          Icons.chevron_right_rounded,
          color: Colors.white.withOpacity(0.3),
          size: 20,
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// NOTIFICATION PANEL (Expand from Bell, scrollable)
// ═══════════════════════════════════════════════════════════════════════════
class NotificationPanelWidget extends StatefulWidget {
  final bool isOpen;
  final List<OverlayNotification> items;
  final Rect? bellRect;
  final VoidCallback onClose;
  final Function(OverlayNotification)? onItemTap;
  final VoidCallback? onClearAll;
  final Function(String notificationId, String requesterId, bool accept)? onFriendRequestAction;
  
  const NotificationPanelWidget({
    super.key,
    required this.isOpen,
    required this.items,
    this.bellRect,
    required this.onClose,
    this.onItemTap,
    this.onClearAll,
    this.onFriendRequestAction,
  });

  @override
  State<NotificationPanelWidget> createState() => _NotificationPanelWidgetState();
}

class _NotificationPanelWidgetState extends State<NotificationPanelWidget> 
    with SingleTickerProviderStateMixin {
  
  late AnimationController _controller;
  late Animation<double> _scaleAnim;
  late Animation<double> _fadeAnim;
  
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    
    _scaleAnim = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
    );
    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
  }
  
  @override
  void didUpdateWidget(NotificationPanelWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isOpen && !oldWidget.isOpen) {
      _controller.forward();
    } else if (!widget.isOpen && oldWidget.isOpen) {
      _controller.reverse();
    }
  }
  
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final safeTop = MediaQuery.of(context).padding.top;
    final screenWidth = MediaQuery.of(context).size.width;
    
    final bellRect = widget.bellRect;
    final top = (bellRect?.bottom ?? (safeTop + 44)) + 10;
    final right = bellRect != null 
        ? (screenWidth - bellRect.right).clamp(12.0, 24.0)
        : 12.0;
    
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        if (_controller.value == 0 && !widget.isOpen) {
          return const SizedBox.shrink();
        }
        
        return Stack(
          children: [
            // Backdrop
            GestureDetector(
              onTap: widget.onClose,
              child: Container(
                color: Colors.black.withOpacity(0.35 * _fadeAnim.value),
              ),
            ),
            
            // Panel
            Positioned(
              top: top,
              right: right,
              left: screenWidth * 0.06,
              child: Transform.scale(
                scale: _scaleAnim.value,
                alignment: Alignment.topRight,
                child: Opacity(
                  opacity: _fadeAnim.value,
                  child: GestureDetector(
                    onTap: () {},
                    child: LiquidGlassCapsule(
                      borderRadius: 20,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.of(context).size.height * 0.55,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Header
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
                              child: Row(
                                children: [
                                  const Text(
                                    'Notifications',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 17,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const Spacer(),
                                  if (widget.items.isNotEmpty)
                                    GestureDetector(
                                      onTap: widget.onClearAll,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withOpacity(0.08),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Text(
                                          'Clear All',
                                          style: TextStyle(
                                            color: Colors.white.withOpacity(0.5),
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            
                            Divider(height: 1, color: Colors.white.withOpacity(0.08)),
                            
                            // List
                            Flexible(
                              child: widget.items.isEmpty
                                  ? _buildEmptyState()
                                  : ListView.separated(
                                      shrinkWrap: true,
                                      padding: const EdgeInsets.symmetric(vertical: 6),
                                      itemCount: widget.items.length,
                                      separatorBuilder: (_, __) => Divider(
                                        height: 1,
                                        indent: 54,
                                        color: Colors.white.withOpacity(0.05),
                                      ),
                                      itemBuilder: (context, index) {
                                        final n = widget.items[index];
                                        return _NotificationItem(
                                          notification: n,
                                          onTap: () => widget.onItemTap?.call(n),
                                          onAccept: n.type == OverlayNotificationType.friendRequest 
                                              ? () {
                                                  print('🔵 [Overlay] Accept: n.id=${n.id} requesterId=${n.requesterId}');
                                                  // ✅ FIX: Use n.requesterId instead of n.id for the second param
                                                  widget.onFriendRequestAction?.call(n.id, n.requesterId ?? n.id, true);
                                                }
                                              : null,
                                          onDecline: n.type == OverlayNotificationType.friendRequest
                                              ? () {
                                                  print('🔴 [Overlay] Decline: n.id=${n.id} requesterId=${n.requesterId}');
                                                  // ✅ FIX: Use n.requesterId instead of n.id for the second param
                                                  widget.onFriendRequestAction?.call(n.id, n.requesterId ?? n.id, false);
                                                }
                                              : null,
                                        );
                                      },

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
        );
      },
    );
  }
  
  Widget _buildEmptyState() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.notifications_off_outlined,
            color: Colors.white.withOpacity(0.25),
            size: 40,
          ),
          const SizedBox(height: 10),
          Text(
            'No notifications',
            style: TextStyle(
              color: Colors.white.withOpacity(0.35),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// NOTIFICATION ITEM (with inline friend request actions)
// ═══════════════════════════════════════════════════════════════════════════
class _NotificationItem extends StatelessWidget {
  final OverlayNotification notification;
  final VoidCallback? onTap;
  final VoidCallback? onAccept;
  final VoidCallback? onDecline;
  
  const _NotificationItem({
    required this.notification,
    this.onTap,
    this.onAccept,
    this.onDecline,
  });

  String _formatTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    return '${diff.inDays}d';
  }
  
  IconData _getIcon() {
    switch (notification.type) {
      case OverlayNotificationType.message:
        return Icons.chat_bubble_rounded;
      case OverlayNotificationType.friendRequest:
        return Icons.person_add_rounded;
      default:
        return Icons.notifications_rounded;
    }
  }
  
  Color _getIconColor() {
    switch (notification.type) {
      case OverlayNotificationType.message:
        return const Color(0xFF0A84FF);
      case OverlayNotificationType.friendRequest:
        return const Color(0xFF30D158);
      default:
        return const Color(0xFF5856D6);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isFriendRequest = notification.type == OverlayNotificationType.friendRequest;
    
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Icon
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _getIconColor().withOpacity(0.15),
              ),
              child: Icon(
                _getIcon(),
                color: _getIconColor(),
                size: 18,
              ),
            ),
            const SizedBox(width: 10),
            
            // Content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          notification.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: notification.isRead ? FontWeight.w400 : FontWeight.w600,
                          ),
                        ),
                      ),
                      Text(
                        _formatTime(notification.time),
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.3),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    notification.body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.55),
                      fontSize: 12,
                      height: 1.2,
                    ),
                  ),
                  
                  // ✅ Inline actions for friend request
                  if (isFriendRequest && onAccept != null && onDecline != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _ActionButton(
                          label: 'Accept',
                          color: const Color(0xFF30D158),
                          onTap: onAccept!,
                        ),
                        const SizedBox(width: 8),
                        _ActionButton(
                          label: 'Decline',
                          color: Colors.white.withOpacity(0.2),
                          textColor: Colors.white.withOpacity(0.6),
                          onTap: onDecline!,
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            
            // Unread indicator
            if (!notification.isRead && !isFriendRequest)
              Container(
                margin: const EdgeInsets.only(left: 6, top: 3),
                width: 7,
                height: 7,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFF0A84FF),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Inline action button for friend requests
class _ActionButton extends StatelessWidget {
  final String label;
  final Color color;
  final Color? textColor;
  final VoidCallback onTap;
  
  const _ActionButton({
    required this.label,
    required this.color,
    this.textColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: textColor ?? Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// LIQUID GLASS CAPSULE (like haptic bottom bar)
// ═══════════════════════════════════════════════════════════════════════════
class LiquidGlassCapsule extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final double blur;
  final double opacity;
  
  const LiquidGlassCapsule({
    super.key,
    required this.child,
    this.borderRadius = 24,
    this.blur = 25,
    this.opacity = 0.45,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E).withOpacity(opacity),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              color: Colors.white.withOpacity(0.12),
              width: 0.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.25),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Stack(
            children: [
              // Sheen highlight (like bottom bar)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(borderRadius),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Colors.white.withOpacity(0.10),
                          Colors.transparent,
                          Colors.black.withOpacity(0.05),
                        ],
                        stops: const [0.0, 0.5, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// NOTIFICATION BELL BUTTON (StatefulWidget - updates position after render)
// ═══════════════════════════════════════════════════════════════════════════
class NotificationBellButton extends StatefulWidget {
  final GlobalKey bellKey;
  final VoidCallback onTap;
  final int unreadCount;
  final NotificationOverlayController controller;
  
  const NotificationBellButton({
    super.key,
    required this.bellKey,
    required this.onTap,
    required this.unreadCount,
    required this.controller,
  });

  @override
  State<NotificationBellButton> createState() => _NotificationBellButtonState();
}

class _NotificationBellButtonState extends State<NotificationBellButton> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.updateBellPosition(widget.bellKey);
    });
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.updateBellPosition(widget.bellKey);
    });

    return GestureDetector(
      key: widget.bellKey,
      onTap: () {
        HapticFeedback.lightImpact();
        widget.onTap();
      },
      child: SizedBox(
        width: 44,
        height: 44,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(
              Icons.notifications_none_rounded,
              color: Colors.white.withOpacity(0.9),
              size: 26,
            ),
            if (widget.unreadCount > 0)
              Positioned(
                top: 8,
                right: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF3B30),
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFFF3B30).withOpacity(0.4),
                        blurRadius: 5,
                      ),
                    ],
                  ),
                  child: Text(
                    widget.unreadCount > 99 ? '99+' : '${widget.unreadCount}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
