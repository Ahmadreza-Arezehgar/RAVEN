import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'database_helper.dart';

/// Backup info from server
class BackupInfo {
  final String id;
  final DateTime createdAt;
  final int sizeBytes;
  final int messageCount;
  final int mediaCount;
  final bool isEncrypted;
  final String status;

  BackupInfo({
    required this.id,
    required this.createdAt,
    required this.sizeBytes,
    required this.messageCount,
    required this.mediaCount,
    required this.isEncrypted,
    required this.status,
  });

  factory BackupInfo.fromJson(Map<String, dynamic> json) {
    return BackupInfo(
      id: json['id'] ?? '',
      createdAt: DateTime.parse(json['created_at']),
      sizeBytes: json['size_bytes'] ?? 0,
      messageCount: json['message_count'] ?? 0,
      mediaCount: json['media_count'] ?? 0,
      isEncrypted: json['is_encrypted'] ?? false,
      status: json['status'] ?? 'unknown',
    );
  }

  String get formattedSize {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    if (sizeBytes < 1024 * 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

/// BackupService - Handles cloud backup and restore operations
class BackupService {
  static const String _baseUrl = ApiService.baseUrl;
  static const int _chunkSize = 100; // Messages per chunk
  
  // ==================== BACKUP OPERATIONS ====================
  
  /// Get the latest backup info for current user
  static Future<BackupInfo?> getLatestBackup() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('auth_token');
      
      if (token == null) return null;
      
      final response = await http.get(
        Uri.parse('$_baseUrl/api/backup/latest'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data == null) return null;
        return BackupInfo.fromJson(data);
      }
      return null;
    } catch (e) {
      print('❌ Error getting latest backup: $e');
      return null;
    }
  }
  
  /// Start a new backup session
  static Future<String?> startBackup({bool encrypted = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('auth_token');
      
      if (token == null) return null;
      
      final response = await http.post(
        Uri.parse('$_baseUrl/api/backup/start'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'is_encrypted': encrypted,
        }),
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['backup_id'];
      }
      print('❌ Failed to start backup: ${response.statusCode}');
      return null;
    } catch (e) {
      print('❌ Error starting backup: $e');
      return null;
    }
  }
  
  /// Upload a chunk of backup data
  static Future<bool> uploadChunk(
    String backupId, 
    List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> media,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('auth_token');
      
      if (token == null) return false;
      
      final response = await http.put(
        Uri.parse('$_baseUrl/api/backup/chunk'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'backup_id': backupId,
          'messages': messages,
          'media': media,
        }),
      );
      
      return response.statusCode == 200;
    } catch (e) {
      print('❌ Error uploading chunk: $e');
      return false;
    }
  }
  
  /// Finish the backup
  static Future<bool> finishBackup(String backupId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('auth_token');
      
      if (token == null) return false;
      
      final response = await http.post(
        Uri.parse('$_baseUrl/api/backup/finish'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'backup_id': backupId,
        }),
      );
      
      if (response.statusCode == 200) {
        // Save last backup time
        await prefs.setString('last_backup_time', DateTime.now().toIso8601String());
        return true;
      }
      return false;
    } catch (e) {
      print('❌ Error finishing backup: $e');
      return false;
    }
  }
  
  /// Perform full backup of local messages
  static Future<bool> performBackup({
    Function(double progress)? onProgress,
    bool encrypted = false,
  }) async {
    try {
      print('📦 Starting backup...');
      
      // 1. Get all local messages via exportAllMessages
      final db = DatabaseHelper.instance;
      final messages = await db.exportAllMessages();
      
      if (messages.isEmpty) {
        print('📦 No messages to backup');
        return true;
      }
      
      // 2. Start backup session
      final backupId = await startBackup(encrypted: encrypted);
      if (backupId == null) {
        print('❌ Failed to start backup session');
        return false;
      }
      
      // 3. Upload in chunks
      final totalChunks = (messages.length / _chunkSize).ceil();
      for (var i = 0; i < totalChunks; i++) {
        final start = i * _chunkSize;
        final end = (start + _chunkSize).clamp(0, messages.length);
        final chunk = messages.sublist(start, end);
        
        // Messages are already Map<String, dynamic> from exportAllMessages
        final serialized = chunk.cast<Map<String, dynamic>>();
        
        // TODO: Get media for these messages
        final media = <Map<String, dynamic>>[];
        
        final success = await uploadChunk(backupId, serialized, media);
        if (!success) {
          print('❌ Failed to upload chunk $i');
          return false;
        }
        
        // Report progress
        onProgress?.call((i + 1) / totalChunks);
      }
      
      // 4. Finish backup
      final finished = await finishBackup(backupId);
      if (finished) {
        print('✅ Backup completed: ${messages.length} messages');
      }
      return finished;
    } catch (e) {
      print('❌ Backup failed: $e');
      return false;
    }
  }
  
  // ==================== RESTORE OPERATIONS ====================
  
  /// Check if restore is available
  static Future<bool> hasBackupAvailable() async {
    final backup = await getLatestBackup();
    return backup != null;
  }
  
  /// Restore from server backup
  static Future<bool> restoreFromBackup({
    String? backupId,
    Function(double progress)? onProgress,
  }) async {
    try {
      print('📥 Starting restore...');
      
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('auth_token');
      
      if (token == null) return false;
      
      // 1. Get restore data from server
      final uri = backupId != null
          ? Uri.parse('$_baseUrl/api/backup/restore?backup_id=$backupId')
          : Uri.parse('$_baseUrl/api/backup/restore');
      
      final response = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );
      
      if (response.statusCode != 200) {
        print('❌ Restore failed: ${response.statusCode}');
        return false;
      }
      
      final data = jsonDecode(response.body);
      final messages = data['messages'] as List<dynamic>;
      final mediaUrls = data['media_urls'] as List<dynamic>;
      
      print('📥 Restoring ${messages.length} messages, ${mediaUrls.length} media');
      
      // 2. Save messages to local DB
      final db = DatabaseHelper.instance;
      var count = 0;
      for (final msgData in messages) {
        try {
          // Import raw map data directly
          await db.importMessages([msgData as Map<String, dynamic>]);
          count++;
          onProgress?.call(count / messages.length);
        } catch (e) {
          print('⚠️ Failed to restore message: $e');
        }
      }
      
      // 3. Media will be downloaded on-demand when user views them
      // Store URLs for lazy loading
      await prefs.setString('pending_media_restore', jsonEncode(mediaUrls));
      
      print('✅ Restore completed: $count messages');
      return true;
    } catch (e) {
      print('❌ Restore failed: $e');
      return false;
    }
  }
  
  // ==================== SETTINGS ====================
  
  /// Get auto-backup setting
  static Future<String> getAutoBackupSetting() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('auto_backup') ?? 'off';
  }
  
  /// Set auto-backup setting
  static Future<void> setAutoBackupSetting(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('auto_backup', value);
  }
  
  /// Get include videos setting
  static Future<bool> getIncludeVideosSetting() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('backup_include_videos') ?? true;
  }
  
  /// Set include videos setting
  static Future<void> setIncludeVideosSetting(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('backup_include_videos', value);
  }
  
  /// Get last backup time
  static Future<DateTime?> getLastBackupTime() async {
    final prefs = await SharedPreferences.getInstance();
    final timeStr = prefs.getString('last_backup_time');
    if (timeStr == null) return null;
    return DateTime.tryParse(timeStr);
  }
}
