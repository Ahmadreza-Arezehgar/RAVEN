import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Mesh Notification Service - Push notifications for mesh events
/// 
/// Sends local push notifications when mesh events occur:
/// - Dead drop discovered nearby
/// - PTT voice message received
/// - Presence check-in from friend
/// - Knowledge item shared
/// - New message received (with deep-link to chat)
class MeshNotificationService {
  static final MeshNotificationService _instance = MeshNotificationService._();
  static MeshNotificationService get instance => _instance;
  MeshNotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  // ✅ Navigation callback - set from main.dart to enable deep-linking
  // Called with (userId, username) when user taps a message notification
  static void Function(String userId, String username)? onOpenChat;

  // Notification channels (Android)
  static const String _meshChannelId = 'mesh_channel';
  static const String _meshChannelName = 'Mesh Notifications';
  static const String _meshChannelDesc = 'Notifications for mesh networking events';
  
  // ✅ Message channel (separate for message notifications)
  static const String _messageChannelId = 'message_channel';
  static const String _messageChannelName = 'Message Notifications';
  static const String _messageChannelDesc = 'Notifications for new messages';

  // Notification IDs - using distinct ranges for each type
  static const int _deadDropBaseId = 1000;
  static const int _pttBaseId = 2000;
  static const int _presenceBaseId = 3000;
  static const int _knowledgeBaseId = 4000;
  static const int _messageBaseId = 5000;  // ✅ New range for messages
  
  int _deadDropCounter = 0;
  int _pttCounter = 0;
  int _presenceCounter = 0;
  int _knowledgeCounter = 0;
  int _messageCounter = 0;

  /// Initialize the notification service
  Future<void> init() async {
    if (_initialized) return;

    // Android init settings
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');

    // iOS/macOS init settings
    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
      macOS: darwinSettings,
    );

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTap,
    );

    // Request permissions on iOS
    await _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>()?.requestPermissions(
      alert: true,
      badge: true,
      sound: true,
    );

    _initialized = true;
    debugPrint('🔔 [MeshNotifications] Initialized');
  }

  void _onNotificationTap(NotificationResponse response) {
    final payload = response.payload;
    debugPrint('🔔 [MeshNotifications] Tapped: $payload');
    
    if (payload == null || payload.isEmpty) return;
    
    // ✅ Handle message notification tap - navigate to chat
    // Payload format: "message:userId:username"
    if (payload.startsWith('message:')) {
      final parts = payload.split(':');
      if (parts.length >= 3) {
        final userId = parts[1];
        final username = parts.sublist(2).join(':'); // Handle usernames with colons
        
        debugPrint('🔔 [MeshNotifications] Opening chat with $username ($userId)');
        
        // Call the navigation callback if set
        if (onOpenChat != null) {
          onOpenChat!(userId, username);
        } else {
          debugPrint('⚠️ [MeshNotifications] onOpenChat callback not set!');
        }
      }
    }
    // TODO: Handle other payload types (deaddrop, ptt, presence, knowledge)
  }

  /// Get notification details
  NotificationDetails _getDetails({
    String? groupKey,
    bool playSound = true,
  }) {
    final android = AndroidNotificationDetails(
      _meshChannelId,
      _meshChannelName,
      channelDescription: _meshChannelDesc,
      importance: Importance.high,
      priority: Priority.high,
      playSound: playSound,
      groupKey: groupKey,
      icon: '@mipmap/ic_launcher',
    );

    const darwin = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    return NotificationDetails(android: android, iOS: darwin, macOS: darwin);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // DEAD DROP NOTIFICATIONS
  // ═══════════════════════════════════════════════════════════════════════════

  /// Notify about a new dead drop discovered nearby
  Future<void> notifyDeadDropDiscovered({
    required String title,
    required String previewText,
    required String dropId,
  }) async {
    if (!_initialized) await init();

    final id = _deadDropBaseId + (_deadDropCounter++ % 100);
    
    await _plugin.show(
      id,
      '📦 Dead Drop: $title',
      previewText.length > 50 ? '${previewText.substring(0, 47)}...' : previewText,
      _getDetails(groupKey: 'mesh_deaddrops'),
      payload: 'deaddrop:$dropId',
    );
    
    debugPrint('🔔 [MeshNotifications] Dead drop notification sent');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PTT NOTIFICATIONS
  // ═══════════════════════════════════════════════════════════════════════════

  /// Notify about incoming PTT voice message
  Future<void> notifyPttMessage({
    required String fromNickname,
    required String fromFingerprint,
    int durationSeconds = 0,
  }) async {
    if (!_initialized) await init();

    final id = _pttBaseId + (_pttCounter++ % 100);
    final duration = durationSeconds > 0 ? ' (${durationSeconds}s)' : '';
    
    await _plugin.show(
      id,
      '🎙️ Voice Message',
      '$fromNickname sent a voice message$duration',
      _getDetails(groupKey: 'mesh_ptt'),
      payload: 'ptt:$fromFingerprint',
    );
    
    debugPrint('🔔 [MeshNotifications] PTT notification sent');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PRESENCE NOTIFICATIONS
  // ═══════════════════════════════════════════════════════════════════════════

  /// Notify about nearby friend check-in
  Future<void> notifyPresenceCheckIn({
    required String nickname,
    required String fingerprint,
    String? note,
  }) async {
    if (!_initialized) await init();

    final id = _presenceBaseId + (_presenceCounter++ % 100);
    final body = note != null && note.isNotEmpty 
        ? '$nickname is nearby: "$note"'
        : '$nickname is nearby';
    
    await _plugin.show(
      id,
      '👋 Nearby Friend',
      body,
      _getDetails(groupKey: 'mesh_presence'),
      payload: 'presence:$fingerprint',
    );
    
    debugPrint('🔔 [MeshNotifications] Presence notification sent');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // KNOWLEDGE NOTIFICATIONS
  // ═══════════════════════════════════════════════════════════════════════════

  /// Notify about new knowledge item shared
  Future<void> notifyKnowledgeReceived({
    required String title,
    required String kind,
    required String hash,
  }) async {
    if (!_initialized) await init();

    final id = _knowledgeBaseId + (_knowledgeCounter++ % 100);
    final icon = kind == 'link' ? '🔗' : kind == 'note' ? '📝' : '📚';
    
    await _plugin.show(
      id,
      '$icon Knowledge Shared',
      title,
      _getDetails(groupKey: 'mesh_knowledge'),
      payload: 'knowledge:$hash',
    );
    
    debugPrint('🔔 [MeshNotifications] Knowledge notification sent');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MESSAGE NOTIFICATIONS (with deep-link to chat)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Notify about a new message received
  /// 
  /// When tapped, opens the chat with the sender.
  /// Payload format: "message:userId:username"
  Future<void> notifyNewMessage({
    required String fromUserId,
    required String fromUsername,
    required String messagePreview,
    bool isVoice = false,
  }) async {
    if (!_initialized) await init();

    final id = _messageBaseId + (_messageCounter++ % 100);
    final title = isVoice ? '🎙️ $fromUsername' : '💬 $fromUsername';
    final body = isVoice 
        ? 'Sent a voice message'
        : messagePreview.length > 80 
            ? '${messagePreview.substring(0, 77)}...' 
            : messagePreview;
    
    // ✅ Message notification details (separate channel for messages)
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _messageChannelId,
        _messageChannelName,
        channelDescription: _messageChannelDesc,
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
        groupKey: 'messages',
        icon: '@mipmap/ic_launcher',
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
      macOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );
    
    await _plugin.show(
      id,
      title,
      body,
      details,
      payload: 'message:$fromUserId:$fromUsername',  // ✅ Deep-link payload
    );
    
    debugPrint('🔔 [MeshNotifications] Message notification sent for $fromUsername');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // GENERAL MESH NOTIFICATION
  // ═══════════════════════════════════════════════════════════════════════════

  /// Send a generic mesh notification
  Future<void> notify({
    required String title,
    required String body,
    String? payload,
  }) async {
    if (!_initialized) await init();

    await _plugin.show(
      DateTime.now().millisecondsSinceEpoch % 10000,
      title,
      body,
      _getDetails(),
      payload: payload,
    );
  }

  /// Cancel all mesh notifications
  Future<void> cancelAll() async {
    await _plugin.cancelAll();
  }
}
