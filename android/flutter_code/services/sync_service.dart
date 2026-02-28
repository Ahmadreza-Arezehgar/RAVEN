import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'database_helper.dart';
import '../models/message_model.dart';

/// Cloud Sync Service - Syncs local data with server API
/// Handles: Messages, Media (voice/images), Friends
class SyncService extends ChangeNotifier {
  static final SyncService instance = SyncService._init();
  SyncService._init();
  
  Timer? _syncTimer;
  bool _isSyncing = false;
  DateTime? _lastSyncTime;
  
  // Sync status
  int _pendingUploadCount = 0;
  int get pendingUploadCount => _pendingUploadCount;
  
  bool get isSyncing => _isSyncing;
  DateTime? get lastSyncTime => _lastSyncTime;
  
  // ═══════════════════════════════════════════════════════════════════════════
  // LIFECYCLE
  // ═══════════════════════════════════════════════════════════════════════════
  
  /// Start automatic sync (every 10 seconds)
  void startAutoSync() {
    stopAutoSync(); // Cancel any existing timer
    
    print('🔄 [SyncService] Starting auto-sync (10s interval)');
    
    // Initial sync
    syncAll();
    
    // Periodic sync every 10 seconds for near-realtime updates
    _syncTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      syncAll();
    });
  }
  
  /// Stop automatic sync
  void stopAutoSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
    print('⏹️ [SyncService] Auto-sync stopped');
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // MAIN SYNC
  // ═══════════════════════════════════════════════════════════════════════════
  
  /// Sync all data types
  Future<void> syncAll() async {
    if (_isSyncing) {
      print('⏳ [SyncService] Already syncing, skipping...');
      return;
    }
    
    _isSyncing = true;
    notifyListeners();
    
    print('🔄 [SyncService] Starting full sync...');
    
    try {
      // 1. Upload pending messages
      await uploadPendingMessages();
      
      // 2. Download new messages
      await downloadNewMessages();
      
      // 3. Sync friends
      await syncFriends();
      
      // 4. Sync groups (NEW - ensures groups appear on all devices)
      await syncGroups();
      
      // 5. Update last sync time
      _lastSyncTime = DateTime.now();
      await _saveLastSyncTime();
      
      print('✅ [SyncService] Full sync complete');
    } catch (e) {
      print('❌ [SyncService] Sync failed: $e');
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // MESSAGE SYNC
  // ═══════════════════════════════════════════════════════════════════════════
  
  /// Upload messages that haven't been synced to server
  Future<void> uploadPendingMessages() async {
    try {
      final messages = await DatabaseHelper.instance.getUnsyncedMessages();
      _pendingUploadCount = messages.length;
      notifyListeners();
      
      if (messages.isEmpty) {
        print('📤 [SyncService] No pending messages to upload');
        return;
      }
      
      print('📤 [SyncService] Uploading ${messages.length} pending messages...');
      
      for (final msg in messages) {
        try {
          // Upload media first if voice message
          String? mediaUrl;
          if (msg.type == MessageType.voice && msg.audioUrl != null) {
            final file = File(msg.audioUrl!);
            if (await file.exists()) {
              mediaUrl = await ApiService.uploadVoice(file);
              print('📤 [SyncService] Voice uploaded: $mediaUrl');
            }
          }
          
          // Upload message to server
          final success = await ApiService.sendMessage(
            recipientId: msg.recipientId,
            content: msg.text,
            messageId: msg.id, // For idempotency
          );
          
          if (success) {
            // Mark as synced
            await DatabaseHelper.instance.markMessageSynced(msg.id);
            _pendingUploadCount--;
            notifyListeners();
            print('✅ [SyncService] Message ${msg.id.substring(0, 8)} synced');
          }
        } catch (e) {
          print('❌ [SyncService] Failed to sync message ${msg.id}: $e');
        }
      }
    } catch (e) {
      print('❌ [SyncService] uploadPendingMessages failed: $e');
    }
  }
  
  /// Download new messages from server
  Future<void> downloadNewMessages() async {
    try {
      final lastSync = await _getLastSyncTime();
      final since = lastSync?.toIso8601String();
      
      print('📥 [SyncService] Checking for new messages since $since');
      
      // Fetch inbox messages from server
      final serverMessages = await ApiService.getInbox(since: since);
      
      if (serverMessages.isEmpty) {
        print('📥 [SyncService] No new messages');
        return;
      }
      
      print('📥 [SyncService] Got ${serverMessages.length} new messages');
      
      int newCount = 0;
      for (final msgJson in serverMessages) {
        try {
          // Parse message type from server
          final serverType = msgJson['message_type'] ?? 'text';
          MessageType msgType = MessageType.text;
          if (serverType == 'voice') msgType = MessageType.voice;
          else if (serverType == 'image') msgType = MessageType.image;
          else if (serverType == 'file') msgType = MessageType.file;  // ✅ Added file type
          
          // Create ChatMessage from server data
          final msg = ChatMessage(
            id: msgJson['id'] ?? '',
            senderId: msgJson['sender_id'] ?? '',
            recipientId: msgJson['recipient_id'] ?? '',
            senderName: msgJson['sender_name'] ?? msgJson['sender_username'] ?? 'Unknown',
            roomId: _getRoomId(msgJson['sender_id'] ?? '', msgJson['recipient_id'] ?? ''),
            text: msgJson['content'] ?? '',
            timestamp: DateTime.tryParse(msgJson['timestamp'] ?? '') ?? DateTime.now(),
            status: MessageStatus.delivered,
            type: msgType,
            via: 'wifi',
            audioUrl: msgJson['audio_url'],
            fileName: msgJson['file_name'],      // ✅ Parse filename for media display
            mimeType: msgJson['mime_type'],      // ✅ Parse MIME type for proper handling
          );
          
          // Check if message already exists in local DB
          final exists = await DatabaseHelper.instance.messageExists(msg.id);
          if (exists) {
            continue; // Skip duplicate
          }
          
          // Insert to local DB
          await DatabaseHelper.instance.insertMessage(msg);
          newCount++;
          
          // ✅ Update conversation list with unread count
          await DatabaseHelper.instance.touchConversation(
            otherUserId: msg.senderId,
            otherUsername: msg.senderName,
            // ✅ No emoji in DB - UI adds emoji when displaying
            preview: msg.text.isNotEmpty ? msg.text : (msg.type == MessageType.voice ? 'Voice message' : 'Photo'),
            time: msg.timestamp,
            incoming: true,  // This increments unreadCount!
          );
          
          // Trigger notification callback
          if (_onNewMessage != null) {
            print('🔔 [SyncService] Triggering notification callback for ${msg.senderName}');
            _onNewMessage!(msg);
          } else {
            print('⚠️ [SyncService] No notification callback set!');
          }
          
          print('📥 [SyncService] Saved new message from ${msg.senderName}');
        } catch (e) {
          print('⚠️ [SyncService] Error parsing message: $e');
        }
      }
      
      print('✅ [SyncService] Downloaded $newCount new messages');
      
      // ✅ Trigger inbox refresh for MessagesPage (always, to keep stream fresh)
      if (_onInboxUpdate != null) {
        print('📬 [SyncService] Triggering inbox refresh callback (newCount=$newCount)');
        _onInboxUpdate!();
      } else {
        print('⚠️ [SyncService] No inbox update callback registered!');
      }

      
    } catch (e) {
      print('❌ [SyncService] downloadNewMessages failed: $e');
    }
  }
  
  // Callback for new message notifications
  Function(ChatMessage)? _onNewMessage;
  void setOnNewMessageCallback(Function(ChatMessage) callback) {
    _onNewMessage = callback;
  }
  
  // ✅ Callback for inbox refresh (triggers MessagesPage update)
  Function()? _onInboxUpdate;
  void setOnInboxUpdateCallback(Function() callback) {
    _onInboxUpdate = callback;
  }

  
  // Helper to generate room ID
  String _getRoomId(String a, String b) {
    final sorted = [a, b]..sort();
    return '${sorted[0]}_${sorted[1]}';
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // FRIENDS SYNC
  // ═══════════════════════════════════════════════════════════════════════════
  
  /// Sync friends list with server
  Future<void> syncFriends() async {
    try {
      print('👥 [SyncService] Syncing friends...');
      
      final serverFriends = await ApiService.getFriends();
      if (serverFriends.isEmpty) {
        print('📭 [SyncService] No friends from server');
        return;
      }

      // 1) Save to SharedPreferences for offline access
      final prefs = await SharedPreferences.getInstance();
      final friendsJson = serverFriends.map((f) => 
        '{"id":"${f['id']}","username":"${f['username']}","avatar_path":"${f['avatar_path'] ?? ''}"}'
      ).toList();
      await prefs.setStringList('friends_list', friendsJson);

      // 2) ✅ CRITICAL: Also update SQLite contacts table
      final myId = await ApiService.getCurrentUserId();
      if (myId == null) {
        print('⚠️ [SyncService] myId missing, cannot update DB contacts');
        return;
      }

      for (final f in serverFriends) {
        final friendId = (f['id'] ?? '').toString();
        final username = (f['username'] ?? 'User').toString();
        // Handle avatar key inconsistency: avatar_path or friend_avatar or avatar_url
        final avatar = (f['avatar_path'] ?? f['friend_avatar'] ?? f['avatar_url'] ?? '').toString();

        if (friendId.isEmpty) continue;

        await DatabaseHelper.instance.updateFriendStatus(
          myId,
          friendId,
          1, // FriendStatus.accepted
          username: username,
          avatarPath: avatar.isNotEmpty ? avatar : null,
        );
      }

      print('✅ [SyncService] Synced ${serverFriends.length} friends to SharedPreferences + SQLite');
    } catch (e) {
      print('❌ [SyncService] syncFriends failed: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP SYNC
  // ═══════════════════════════════════════════════════════════════════════════

  /// Sync groups from server to local database
  /// This ensures groups created on one device appear on all devices
  Future<void> syncGroups() async {
    try {
      print('👥 [SyncService] Syncing groups...');
      
      // Fetch groups from server
      final serverGroups = await ApiService.getMyGroups();
      
      if (serverGroups.isEmpty) {
        print('👥 [SyncService] No groups from server');
        return;
      }
      
      // Store each group in local DB
      for (final group in serverGroups) {
        final groupId = group['id'] as String;
        final groupName = group['name'] as String;
        final avatarUrl = group['avatar_url'] as String?;
        
        // Get member list if available (may need separate API call)
        List<String> memberIds = [];
        if (group['members'] != null) {
          final members = group['members'] as List<dynamic>;
          memberIds = members.map((m) => (m['user_id'] ?? m['id']) as String).toList();
        }
        
        // Create/update group in local DB
        await DatabaseHelper.instance.createGroupConversation(
          roomId: groupId,
          title: groupName,
          memberIds: memberIds,
          avatarUrl: avatarUrl,
        );
      }
      
      print('✅ [SyncService] Synced ${serverGroups.length} groups to local DB');
    } catch (e) {
      print('❌ [SyncService] syncGroups failed: $e');
    }
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // MEDIA UPLOAD HELPERS
  // ═══════════════════════════════════════════════════════════════════════════
  
  /// Upload voice file and return server URL
  Future<String?> uploadVoiceFile(String localPath) async {
    try {
      final file = File(localPath);
      if (!await file.exists()) {
        print('❌ [SyncService] Voice file not found: $localPath');
        return null;
      }
      
      print('🎤 [SyncService] Uploading voice: $localPath');
      return await ApiService.uploadVoice(file);
    } catch (e) {
      print('❌ [SyncService] uploadVoiceFile failed: $e');
      return null;
    }
  }
  
  /// Upload image file and return server URL
  Future<String?> uploadImageFile(String localPath) async {
    try {
      final file = File(localPath);
      if (!await file.exists()) {
        print('❌ [SyncService] Image file not found: $localPath');
        return null;
      }
      
      print('🖼️ [SyncService] Uploading image: $localPath');
      return await ApiService.uploadImage(file);
    } catch (e) {
      print('❌ [SyncService] uploadImageFile failed: $e');
      return null;
    }
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // PERSISTENCE
  // ═══════════════════════════════════════════════════════════════════════════
  
  Future<void> _saveLastSyncTime() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_sync_time', _lastSyncTime!.toIso8601String());
  }
  
  Future<DateTime?> _getLastSyncTime() async {
    final prefs = await SharedPreferences.getInstance();
    final str = prefs.getString('last_sync_time');
    if (str != null) {
      return DateTime.tryParse(str);
    }
    return null;
  }
}
