import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/backup_service.dart';
import '../services/toast_service.dart';
import '../widgets/liquid_glass_card.dart';
import '../theme/ios_design_system.dart';

/// Backup Settings Page - WhatsApp style with Liquid Glass
class BackupSettingsPage extends StatefulWidget {
  const BackupSettingsPage({super.key});

  @override
  State<BackupSettingsPage> createState() => _BackupSettingsPageState();
}

class _BackupSettingsPageState extends State<BackupSettingsPage> {
  BackupInfo? _lastBackup;
  bool _isLoading = true;
  bool _isBackingUp = false;
  double _backupProgress = 0;
  
  String _autoBackup = 'off';
  bool _includeVideos = true;
  bool _encrypted = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    setState(() => _isLoading = true);
    
    final backup = await BackupService.getLatestBackup();
    final autoBackup = await BackupService.getAutoBackupSetting();
    final includeVideos = await BackupService.getIncludeVideosSetting();
    
    if (mounted) {
      setState(() {
        _lastBackup = backup;
        _autoBackup = autoBackup;
        _includeVideos = includeVideos;
        _isLoading = false;
      });
    }
  }

  Future<void> _performBackup() async {
    HapticFeedback.mediumImpact();
    
    setState(() {
      _isBackingUp = true;
      _backupProgress = 0;
    });
    
    final success = await BackupService.performBackup(
      encrypted: _encrypted,
      onProgress: (progress) {
        if (mounted) {
          setState(() => _backupProgress = progress);
        }
      },
    );
    
    if (mounted) {
      setState(() => _isBackingUp = false);
      
      if (success) {
        _loadSettings(); // Refresh backup info
        ToastService.showSuccess('Backup completed successfully');
      } else {
        ToastService.showError('Backup failed');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Chat Backup',
          style: TextStyle(
            color: Colors.white.withOpacity(0.9),
            fontWeight: FontWeight.w600,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : SingleChildScrollView(
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + kToolbarHeight + 16,
                left: 16,
                right: 16,
                bottom: 32,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Backup Status Card
                  _buildBackupStatusCard(),
                  
                  const SizedBox(height: 24),
                  
                  // Back up now button
                  _buildBackupButton(),
                  
                  const SizedBox(height: 32),
                  
                  // Settings Section
                  _buildSettingsSection(),
                ],
              ),
            ),
    );
  }

  Widget _buildBackupStatusCard() {
    final hasBackup = _lastBackup != null;
    
    return LiquidGlassCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          // Cloud icon with animation
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [
                  iOSDesignSystem.accentBlue.withOpacity(0.3),
                  iOSDesignSystem.accentBlue.withOpacity(0.1),
                ],
              ),
            ),
            child: Icon(
              hasBackup ? Icons.cloud_done : Icons.cloud_off,
              color: hasBackup ? iOSDesignSystem.accentBlue : Colors.white54,
              size: 28,
            ),
          ),
          
          const SizedBox(height: 16),
          
          // Last backup info
          Text(
            hasBackup
                ? 'Last backup: ${_formatDate(_lastBackup!.createdAt)}'
                : 'No backup yet',
            style: TextStyle(
              color: Colors.white.withOpacity(0.9),
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          
          if (hasBackup) ...[
            const SizedBox(height: 8),
            Text(
              'Size: ${_lastBackup!.formattedSize}',
              style: TextStyle(
                color: Colors.white.withOpacity(0.5),
                fontSize: 14,
              ),
            ),
            Text(
              '${_lastBackup!.messageCount} messages • ${_lastBackup!.mediaCount} media',
              style: TextStyle(
                color: Colors.white.withOpacity(0.5),
                fontSize: 14,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBackupButton() {
    return GestureDetector(
      onTap: _isBackingUp ? null : _performBackup,
      child: LiquidGlassCard(
        radius: 16,
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: _isBackingUp
              ? Column(
                  children: [
                    SizedBox(
                      width: 120,
                      child: LinearProgressIndicator(
                        value: _backupProgress,
                        backgroundColor: Colors.white.withOpacity(0.2),
                        color: iOSDesignSystem.accentBlue,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Backing up... ${(_backupProgress * 100).toInt()}%',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.7),
                        fontSize: 14,
                      ),
                    ),
                  ],
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.backup, color: iOSDesignSystem.accentGreen, size: 22),
                    const SizedBox(width: 10),
                    Text(
                      'Back up now',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.9),
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildSettingsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 12),
          child: Text(
            'SETTINGS',
            style: TextStyle(
              color: Colors.white.withOpacity(0.5),
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
        ),
        
        LiquidGlassCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              // Auto backup
              _buildSettingRow(
                icon: Icons.schedule,
                title: 'Auto backup',
                trailing: _buildDropdown(),
              ),
              
              _buildDivider(),
              
              // Include videos
              _buildSettingRow(
                icon: Icons.videocam,
                title: 'Include videos',
                trailing: Switch(
                  value: _includeVideos,
                  onChanged: (value) async {
                    HapticFeedback.selectionClick();
                    setState(() => _includeVideos = value);
                    await BackupService.setIncludeVideosSetting(value);
                  },
                  activeColor: iOSDesignSystem.accentGreen,
                ),
              ),
              
              _buildDivider(),
              
              // End-to-end encryption
              _buildSettingRow(
                icon: Icons.lock_outline,
                title: 'End-to-end encryption',
                trailing: Switch(
                  value: _encrypted,
                  onChanged: (value) {
                    HapticFeedback.selectionClick();
                    setState(() => _encrypted = value);
                    if (value) {
                      _showEncryptionInfo();
                    }
                  },
                  activeColor: iOSDesignSystem.accentGreen,
                ),
              ),
            ],
          ),
        ),
        
        const SizedBox(height: 12),
        
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'End-to-end encrypted backups can only be restored with your password or key.',
            style: TextStyle(
              color: Colors.white.withOpacity(0.4),
              fontSize: 12,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSettingRow({
    required IconData icon,
    required String title,
    required Widget trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(icon, color: Colors.white.withOpacity(0.6), size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                color: Colors.white.withOpacity(0.9),
                fontSize: 15,
              ),
            ),
          ),
          trailing,
        ],
      ),
    );
  }

  Widget _buildDivider() {
    return Divider(
      height: 1,
      color: Colors.white.withOpacity(0.1),
      indent: 50,
    );
  }

  Widget _buildDropdown() {
    return DropdownButton<String>(
      value: _autoBackup,
      dropdownColor: const Color(0xFF2C2C2E),
      style: TextStyle(color: Colors.white.withOpacity(0.7)),
      underline: const SizedBox(),
      items: const [
        DropdownMenuItem(value: 'off', child: Text('Off')),
        DropdownMenuItem(value: 'daily', child: Text('Daily')),
        DropdownMenuItem(value: 'weekly', child: Text('Weekly')),
        DropdownMenuItem(value: 'monthly', child: Text('Monthly')),
      ],
      onChanged: (value) async {
        if (value != null) {
          HapticFeedback.selectionClick();
          setState(() => _autoBackup = value);
          await BackupService.setAutoBackupSetting(value);
        }
      },
    );
  }

  void _showEncryptionInfo() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2E),
        title: const Text(
          'End-to-End Encryption',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          'When enabled, your backups will be encrypted with a key that only you know. '
          'This means we cannot recover your backups if you lose your password.',
          style: TextStyle(color: Colors.white.withOpacity(0.7)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dateDay = DateTime(date.year, date.month, date.day);
    
    if (dateDay == today) {
      return 'Today, ${_formatTime(date)}';
    } else if (dateDay == today.subtract(const Duration(days: 1))) {
      return 'Yesterday, ${_formatTime(date)}';
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }

  String _formatTime(DateTime date) {
    return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }
}
