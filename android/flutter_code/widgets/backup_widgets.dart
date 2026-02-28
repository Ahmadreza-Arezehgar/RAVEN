import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/icloud_backup_service.dart';
import '../services/database_helper.dart';
import '../services/toast_service.dart';
import '../models/backup_metadata.dart';
import '../main.dart';
import 'package:uuid/uuid.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Dialog showing backup/restore progress
class BackupProgressDialog extends StatefulWidget {
  final bool isBackup; // true for backup, false for restore
  final Future<dynamic> Function() operation;

  const BackupProgressDialog({
    super.key,
    required this.isBackup,
    required this.operation,
  });

  @override
  State<BackupProgressDialog> createState() => _BackupProgressDialogState();
}

class _BackupProgressDialogState extends State<BackupProgressDialog> {
  String _status = '';
  bool _isComplete = false;
  String? _errorMessage;
  dynamic _result;

  @override
  void initState() {
    super.initState();
    _performOperation();
  }

  Future<void> _performOperation() async {
    setState(() {
      _status = widget.isBackup ? 'Preparing backup...' : 'Downloading from iCloud...';
    });

    try {
      final result = await widget.operation();
      setState(() {
        _result = result;
        _isComplete = true;
        _status = widget.isBackup ? 'Backup completed!' : 'Restore completed!';
      });
    } catch (e) {
      setState(() {
        _isComplete = true;
        _errorMessage = e.toString();
        _status = widget.isBackup ? 'Backup failed' : 'Restore failed';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isBackup ? 'Creating Backup' : 'Restoring from Backup'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_isComplete)
            const CircularProgressIndicator()
          else if (_errorMessage != null)
            const Icon(Icons.error, color: Colors.red, size: 48)
          else
            const Icon(Icons.check_circle, color: Colors.green, size: 48),
          const SizedBox(height: 16),
          Text(_status),
          if (_errorMessage != null) ...[
            const SizedBox(height: 8),
            Text(
              _errorMessage!,
              style: const TextStyle(color: Colors.red, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
          if (_isComplete && widget.isBackup && _result is BackupResult) ...[
            const SizedBox(height: 8),
            Text(
              'Size: ${(_result as BackupResult).size != null ? _formatBytes((_result as BackupResult).size!) : "Unknown"}',
              style: const TextStyle(fontSize: 12),
            ),
          ],
          if (_isComplete && !widget.isBackup && _result is RestoreResult) ...[
            const SizedBox(height: 8),
            Text(
              'Messages restored: ${(_result as RestoreResult).messagesRestored}',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ],
      ),
      actions: [
        if (_isComplete)
          TextButton(
            onPressed: () => Navigator.of(context).pop(_result),
            child: const Text('OK'),
          ),
      ],
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// iCloud Backup UI - DISABLED (removed from Settings per user request)
// Kept for future roadmap implementation
// ═══════════════════════════════════════════════════════════════════════════════

/* COMMENTED OUT - iCloud Backup UI removed from Settings
/// Widget for managing iCloud backups in Settings
class BackupSettingsSection extends StatefulWidget {
  const BackupSettingsSection({super.key});

  @override
  State<BackupSettingsSection> createState() => _BackupSettingsSectionState();
}
*/

// Placeholder widget that renders nothing (for backwards compatibility)
class BackupSettingsSection extends StatelessWidget {
  const BackupSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    // iCloud backup UI removed - render nothing
    return const SizedBox.shrink();
  }
}

/* COMMENTED OUT - iCloud Backup State Class removed from Settings
class _BackupSettingsSectionState extends State<BackupSettingsSection> {
  final ICloudBackupService _backupService = ICloudBackupService();
  bool _iCloudAvailable = false;
  bool _isLoading = true;
  List<BackupFile> _backups = [];
  DateTime? _lastBackupTime;

  @override
  void initState() {
    super.initState();
    _checkICloudAndLoadBackups();
  }

  Future<void> _checkICloudAndLoadBackups() async {
    setState(() => _isLoading = true);

    final available = await _backupService.isICloudAvailable();
    setState(() => _iCloudAvailable = available);

    if (available) {
      await _loadBackups();
    }

    setState(() => _isLoading = false);
  }

  Future<void> _loadBackups() async {
    final backups = await _backupService.listBackups();
    setState(() {
      _backups = backups;
      if (backups.isNotEmpty) {
        _lastBackupTime = backups.first.timestamp;
      }
    });
  }

  Future<void> _createBackup() async {
    final appModel = context.read<AppModel>();
    final currentUser = appModel.currentUser;

    if (currentUser == null) {
      _showError('No user logged in');
      return;
    }

    // Show progress dialog
    final result = await showDialog<BackupResult>(
      context: context,
      barrierDismissible: false,
      builder: (context) => BackupProgressDialog(
        isBackup: true,
        operation: () async {
          // Export all messages
          final db = DatabaseHelper.instance;
          final messages = await db.exportAllMessages();

          // Get app version
          final packageInfo = await PackageInfo.fromPlatform();

          // Create backup metadata
          final metadata = BackupMetadata(
            backupId: const Uuid().v4(),
            timestamp: DateTime.now(),
            messageCount: messages.length,
            appVersion: packageInfo.version,
            userId: currentUser.id,
          );

          // Create backup data
          final backupData = BackupData(
            metadata: metadata,
            messages: messages,
          );

          // Upload to iCloud
          return await _backupService.createBackup(backupData.toJsonString());
        },
      ),
    );

    if (result != null && result.success) {
      await _loadBackups();
      if (mounted) {
        ToastService.showSuccess('Backup created successfully');
      }
    } else if (result != null && result.error != null) {
      _showError(result.error!);
    }
  }

  Future<void> _restoreBackup(BackupFile backup) async {
    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore from Backup?'),
        content: Text(
          'This will restore messages from ${DateFormat('MMM d, y h:mm a').format(backup.timestamp)}.\n\n'
          'Existing messages will not be deleted. Any duplicate messages will be skipped.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // Show progress dialog
    final result = await showDialog<RestoreResult>(
      context: context,
      barrierDismissible: false,
      builder: (context) => BackupProgressDialog(
        isBackup: false,
        operation: () async {
          // Download from iCloud
          final jsonData = await _backupService.restoreBackup(backup.filename);

          if (jsonData == null) {
            throw Exception('Failed to download backup from iCloud');
          }

          // Parse backup data
          final backupData = BackupData.fromJsonString(jsonData);

          // Import messages
          final db = DatabaseHelper.instance;
          final importedCount = await db.importMessages(backupData.messages);

          return RestoreResult(
            success: true,
            messagesRestored: importedCount,
          );
        },
      ),
    );

    if (result != null && result.success) {
      if (mounted) {
        ToastService.showSuccess('Restored ${result.messagesRestored} messages');
      }
    } else if (result != null && result.error != null) {
      _showError(result.error!);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ToastService.showError(message);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!_iCloudAvailable) {
      return GestureDetector(
        onTap: () async {
          // Open iOS Settings for app settings (not notification settings!)
          // Using 'app-settings:' opens the app's main settings page
          // LaunchMode.externalApplication ensures iOS handles it properly
          final url = Uri.parse('app-settings:');
          try {
            await launchUrl(
              url,
              mode: LaunchMode.externalApplication,  // ✅ Force iOS to handle correctly
            );
          } catch (e) {
            print('❌ Failed to open settings: $e');
          }
        },
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.cloud_off, color: Colors.grey),
                    SizedBox(width: 8),
                    Text(
                      'iCloud Backup',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'iCloud is not available. Please sign in to iCloud in Settings to enable backup.',
                  style: TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(Icons.settings, size: 16, color: Colors.blue[400]),
                    const SizedBox(width: 6),
                    Text(
                      'Open Settings',
                      style: TextStyle(
                        color: Colors.blue[400],
                        fontWeight: FontWeight.w500,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.arrow_forward_ios, size: 12, color: Colors.blue[400]),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.cloud, color: Colors.blue),
                const SizedBox(width: 8),
                const Text(
                  'iCloud Backup',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _loadBackups,
                  tooltip: 'Refresh',
                ),
              ],
            ),
            const SizedBox(height: 16),
            
            // Last backup info
            if (_lastBackupTime != null) ...[
              Text(
                'Last backup: ${DateFormat('MMM d, y h:mm a').format(_lastBackupTime!)}',
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
              const SizedBox(height: 8),
            ],

            // Backup button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _createBackup,
                icon: const Icon(Icons.backup),
                label: const Text('Create Backup Now'),
              ),
            ),

            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),

            // Available backups
            Text(
              'Available Backups (${_backups.length})',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),

            if (_backups.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Center(
                  child: Text(
                    'No backups found',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              )
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _backups.length,
                itemBuilder: (context, index) {
                  final backup = _backups[index];
                  return ListTile(
                    leading: const Icon(Icons.folder),
                    title: Text(
                      DateFormat('MMM d, y h:mm a').format(backup.timestamp),
                    ),
                    subtitle: Text(backup.formattedSize),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.restore),
                          onPressed: () => _restoreBackup(backup),
                          tooltip: 'Restore',
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete, color: Colors.red),
                          onPressed: () async {
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('Delete Backup?'),
                                content: const Text('This cannot be undone.'),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(context, false),
                                    child: const Text('Cancel'),
                                  ),
                                  TextButton(
                                    onPressed: () => Navigator.pop(context, true),
                                    child: const Text('Delete'),
                                  ),
                                ],
                              ),
                            );

                            if (confirmed == true) {
                              await _backupService.deleteBackup(backup.filename);
                              await _loadBackups();
                            }
                          },
                          tooltip: 'Delete',
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
END OF COMMENTED OUT iCloud Backup State Class */

