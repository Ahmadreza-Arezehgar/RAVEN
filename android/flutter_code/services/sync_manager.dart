import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:hybrid_messenger/models/message_model.dart';
import 'package:hybrid_messenger/services/api_service.dart';
import 'package:hybrid_messenger/services/database_helper.dart';

/// SyncManager - Handles automatic sync when internet becomes available
/// 
/// Flow:
/// 1. Listen to connectivity changes
/// 2. When online: upload pending media → sync pending messages → purge local files
/// 3. Update syncState for each item
class SyncManager {
  static final SyncManager _instance = SyncManager._internal();
  factory SyncManager() => _instance;
  SyncManager._internal();
  
  final DatabaseHelper _db = DatabaseHelper.instance;
  StreamSubscription? _connectivitySub;
  bool _isSyncing = false;
  
  /// Callback when sync state changes
  Function(String status)? onSyncStatusChanged;
  
  /// Initialize and start listening to connectivity
  void init() {
    print('🔄 [SyncManager] Initializing...');
    
    _connectivitySub = Connectivity().onConnectivityChanged.listen((result) {
      print('📶 [SyncManager] Connectivity changed: $result');
      
      if (result != ConnectivityResult.none) {
        // Internet available - trigger sync (fire-and-forget to prevent UI freeze)
        // ignore: unawaited_futures
        syncAll().catchError((e) {
          print('⚠️ [SyncManager] Sync error (non-blocking): $e');
        });
      }
    });
  }
  
  /// Dispose listeners
  void dispose() {
    _connectivitySub?.cancel();
  }
  
  /// Get count of pending items
  Future<int> getPendingCount() async {
    final db = await _db.database;
    final result = await db.rawQuery('''
      SELECT COUNT(*) as count FROM messages 
      WHERE syncState != ${SyncState.synced.index}
    ''');
    return result.first['count'] as int? ?? 0;
  }
  
  /// Main sync function - called when internet becomes available
  Future<void> syncAll() async {
    if (_isSyncing) {
      print('⏳ [SyncManager] Already syncing, skipping...');
      return;
    }
    
    _isSyncing = true;
    onSyncStatusChanged?.call('Syncing...');
    print('🔄 [SyncManager] Starting full sync...');
    
    try {
      // Step 1: Upload pending media files
      await _uploadPendingMedia();
      
      // Step 2: Sync pending messages
      await _syncPendingMessages();
      
      // Step 3: Purge local files that have been synced
      await _purgeLocalFiles();
      
      onSyncStatusChanged?.call('Synced');
      print('✅ [SyncManager] Full sync complete!');
    } catch (e) {
      print('❌ [SyncManager] Sync failed: $e');
      onSyncStatusChanged?.call('Sync failed');
    } finally {
      _isSyncing = false;
    }
  }
  
  /// Upload media files that have localPath but no remoteUrl
  Future<void> _uploadPendingMedia() async {
    print('📤 [SyncManager] Uploading pending media...');
    
    final db = await _db.database;
    
    // Find messages with localPath but no audioUrl (not yet uploaded)
    final pending = await db.query(
      'messages',
      where: 'localPath IS NOT NULL AND audioUrl IS NULL',
    );
    
    print('📤 [SyncManager] Found ${pending.length} media files to upload');
    
    for (final row in pending) {
      final messageId = row['id'] as String;
      final localPath = row['localPath'] as String;
      
      // Update sync state to uploading
      await db.update(
        'messages',
        {'syncState': SyncState.uploading.index},
        where: 'id = ?',
        whereArgs: [messageId],
      );
      
      try {
        final file = File(localPath);
        if (await file.exists()) {
          // Upload to server
          final remoteUrl = await ApiService.uploadVoice(file);
          
          if (remoteUrl != null) {
            // Update message with remote URL
            await db.update(
              'messages',
              {
                'audioUrl': remoteUrl,
                'syncState': SyncState.queued.index, // Ready for message sync
              },
              where: 'id = ?',
              whereArgs: [messageId],
            );
            print('✅ [SyncManager] Uploaded: $messageId');
          } else {
            // Upload failed
            await _markFailed(messageId, 'Upload returned null');
          }
        } else {
          await _markFailed(messageId, 'Local file not found');
        }
      } catch (e) {
        await _markFailed(messageId, e.toString());
      }
    }
  }
  
  /// Sync pending messages to server
  Future<void> _syncPendingMessages() async {
    print('📤 [SyncManager] Syncing pending messages...');
    
    final db = await _db.database;
    
    // Find messages that are queued (not synced yet)
    final pending = await db.query(
      'messages',
      where: 'syncState IN (?, ?)',
      whereArgs: [SyncState.localOnly.index, SyncState.queued.index],
    );
    
    print('📤 [SyncManager] Found ${pending.length} messages to sync');
    
    for (final row in pending) {
      final message = ChatMessage.fromJson(row);
      
      try {
        // Send to server with idempotency key (message.id)
        final success = await ApiService.sendMessage(
          recipientId: message.recipientId,
          content: message.text,
          messageId: message.id, // Idempotency key
          audioUrl: message.audioUrl,
        );
        
        if (success) {
          // Mark as synced
          await db.update(
            'messages',
            {'syncState': SyncState.synced.index},
            where: 'id = ?',
            whereArgs: [message.id],
          );
          print('✅ [SyncManager] Synced message: ${message.id}');
        } else {
          await _markFailed(message.id, 'Server returned false');
        }
      } catch (e) {
        await _markFailed(message.id, e.toString());
      }
    }
  }
  
  /// Delete local files that have been successfully synced
  Future<void> _purgeLocalFiles() async {
    print('🗑️ [SyncManager] Purging synced local files...');
    
    final db = await _db.database;
    
    // Find synced messages with local files
    final synced = await db.query(
      'messages',
      where: 'syncState = ? AND localPath IS NOT NULL AND audioUrl IS NOT NULL',
      whereArgs: [SyncState.synced.index],
    );
    
    print('🗑️ [SyncManager] Found ${synced.length} files to purge');
    
    for (final row in synced) {
      final localPath = row['localPath'] as String?;
      final messageId = row['id'] as String;
      
      if (localPath != null) {
        try {
          final file = File(localPath);
          if (await file.exists()) {
            await file.delete();
            print('🗑️ [SyncManager] Deleted: $localPath');
          }
          
          // Clear localPath from database
          await db.update(
            'messages',
            {'localPath': null},
            where: 'id = ?',
            whereArgs: [messageId],
          );
        } catch (e) {
          print('⚠️ [SyncManager] Failed to delete file: $e');
        }
      }
    }
  }
  
  /// Mark message as failed with error
  Future<void> _markFailed(String messageId, String error) async {
    final db = await _db.database;
    
    // Get current retry count
    final result = await db.query(
      'messages',
      columns: ['retryCount'],
      where: 'id = ?',
      whereArgs: [messageId],
    );
    
    final currentRetry = result.isNotEmpty 
        ? (result.first['retryCount'] as int? ?? 0) 
        : 0;
    
    await db.update(
      'messages',
      {
        'syncState': SyncState.failed.index,
        'retryCount': currentRetry + 1,
        'lastError': error,
      },
      where: 'id = ?',
      whereArgs: [messageId],
    );
    
    print('❌ [SyncManager] Failed: $messageId - $error (retry: ${currentRetry + 1})');
  }
  
  /// Retry failed messages
  Future<void> retryFailed() async {
    print('🔄 [SyncManager] Retrying failed messages...');
    
    final db = await _db.database;
    
    // Reset failed to queued
    await db.update(
      'messages',
      {'syncState': SyncState.queued.index},
      where: 'syncState = ? AND retryCount < 5',
      whereArgs: [SyncState.failed.index],
    );
    
    // Trigger sync
    await syncAll();
  }
}
