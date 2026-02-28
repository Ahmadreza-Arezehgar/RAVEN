import 'package:flutter/services.dart';

/// Result of a backup operation
class BackupResult {
  final bool success;
  final String? path;
  final int? size;
  final String? error;

  BackupResult({
    required this.success,
    this.path,
    this.size,
    this.error,
  });
}

/// Result of a restore operation
class RestoreResult {
  final bool success;
  final int messagesRestored;
  final String? error;

  RestoreResult({
    required this.success,
    this.messagesRestored = 0,
    this.error,
  });
}

/// Metadata about a backup file
class BackupFile {
  final String filename;
  final String path;
  final int size;
  final DateTime timestamp;

  BackupFile({
    required this.filename,
    required this.path,
    required this.size,
    required this.timestamp,
  });

  factory BackupFile.fromMap(Map<String, dynamic> map) {
    return BackupFile(
      filename: map['filename'] as String,
      path: map['path'] as String,
      size: map['size'] as int,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        ((map['timestamp'] as double) * 1000).toInt(),
      ),
    );
  }

  String get formattedSize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Service for managing iCloud backups of chat messages
class ICloudBackupService {
  static const MethodChannel _channel = MethodChannel('com.ahmd.hybridmessenger/icloud_backup');

  /// Check if iCloud is available on this device
  Future<bool> isICloudAvailable() async {
    try {
      final result = await _channel.invokeMethod<bool>('checkAvailability');
      return result ?? false;
    } catch (e) {
      print('Error checking iCloud availability: $e');
      return false;
    }
  }

  /// Create a backup of all messages
  /// 
  /// [messagesData] should be a JSON-encoded string of all messages
  /// NOTE: Encryption happens automatically in the iOS plugin (AES-GCM-256)
  /// Returns a [BackupResult] with success status and file info
  Future<BackupResult> createBackup(String messagesData) async {
    try {
      // Use .enc extension (iOS plugin adds this and encrypts the data)
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final filename = 'hybrid_messenger_backup_$timestamp';
      
      final result = await _channel.invokeMethod<Map<Object?, Object?>>('createBackup', {
        'data': messagesData,
        'filename': filename,
      });

      if (result == null) {
        return BackupResult(
          success: false,
          error: 'No response from platform',
        );
      }

      return BackupResult(
        success: result['success'] as bool? ?? false,
        path: result['path'] as String?,
        size: result['size'] as int?,
      );
    } on PlatformException catch (e) {
      return BackupResult(
        success: false,
        error: '${e.code}: ${e.message}',
      );
    } catch (e) {
      return BackupResult(
        success: false,
        error: e.toString(),
      );
    }
  }

  /// List all available backup files from iCloud
  Future<List<BackupFile>> listBackups() async {
    try {
      final result = await _channel.invokeMethod<List<Object?>>('listBackups');
      
      if (result == null) return [];

      return result
          .cast<Map<Object?, Object?>>()
          .map((map) => BackupFile.fromMap(Map<String, dynamic>.from(map)))
          .toList();
    } on PlatformException catch (e) {
      print('Error listing backups: ${e.code}: ${e.message}');
      return [];
    } catch (e) {
      print('Error listing backups: $e');
      return [];
    }
  }

  /// Restore messages from a specific backup file
  /// 
  /// Returns the JSON data from the backup file
  Future<String?> restoreBackup(String filename) async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>('restoreBackup', {
        'filename': filename,
      });

      if (result == null || result['success'] != true) {
        return null;
      }

      return result['data'] as String?;
    } on PlatformException catch (e) {
      print('Error restoring backup: ${e.code}: ${e.message}');
      return null;
    } catch (e) {
      print('Error restoring backup: $e');
      return null;
    }
  }

  /// Delete a backup file from iCloud
  Future<bool> deleteBackup(String filename) async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>('deleteBackup', {
        'filename': filename,
      });

      return result?['success'] as bool? ?? false;
    } on PlatformException catch (e) {
      print('Error deleting backup: ${e.code}: ${e.message}');
      return false;
    } catch (e) {
      print('Error deleting backup: $e');
      return false;
    }
  }
}
