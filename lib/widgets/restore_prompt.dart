import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/backup_service.dart';
import '../services/toast_service.dart';
import '../widgets/liquid_glass_card.dart';
import '../theme/ios_design_system.dart';

/// Restore Prompt - Shows after login if backup available
class RestorePrompt extends StatefulWidget {
  final VoidCallback? onSkip;
  final VoidCallback? onRestoreComplete;
  
  const RestorePrompt({
    super.key,
    this.onSkip,
    this.onRestoreComplete,
  });

  @override
  State<RestorePrompt> createState() => _RestorePromptState();
}

class _RestorePromptState extends State<RestorePrompt> 
    with SingleTickerProviderStateMixin {
  BackupInfo? _backup;
  bool _isLoading = true;
  bool _isRestoring = false;
  double _restoreProgress = 0;
  
  late AnimationController _animController;
  late Animation<double> _scaleAnim;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    
    _animController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    
    _scaleAnim = Tween<double>(begin: 0.9, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
    );
    
    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
    );
    
    _checkBackup();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  Future<void> _checkBackup() async {
    final backup = await BackupService.getLatestBackup();
    
    if (mounted) {
      setState(() {
        _backup = backup;
        _isLoading = false;
      });
      
      if (backup != null) {
        _animController.forward();
      } else {
        // No backup, skip immediately
        widget.onSkip?.call();
      }
    }
  }

  Future<void> _performRestore() async {
    HapticFeedback.mediumImpact();
    
    setState(() {
      _isRestoring = true;
      _restoreProgress = 0;
    });
    
    final success = await BackupService.restoreFromBackup(
      onProgress: (progress) {
        if (mounted) {
          setState(() => _restoreProgress = progress);
        }
      },
    );
    
    if (mounted) {
      setState(() => _isRestoring = false);
      
      if (success) {
        widget.onRestoreComplete?.call();
      } else {
        ToastService.showError('Restore failed. Please try again.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    
    if (_backup == null) {
      return const SizedBox.shrink();
    }
    
    return FadeTransition(
      opacity: _fadeAnim,
      child: ScaleTransition(
        scale: _scaleAnim,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: LiquidGlassCard(
              radius: 24,
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Cloud icon
                  Container(
                    width: 70,
                    height: 70,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [
                          iOSDesignSystem.accentBlue.withOpacity(0.3),
                          iOSDesignSystem.accentBlue.withOpacity(0.1),
                        ],
                      ),
                    ),
                    child: const Icon(
                      Icons.cloud_download,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                  
                  const SizedBox(height: 20),
                  
                  // Title
                  Text(
                    'Backup Found',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.95),
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  
                  const SizedBox(height: 12),
                  
                  // Info
                  Text(
                    '${_backup!.formattedSize} • ${_backup!.messageCount} messages',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.6),
                      fontSize: 15,
                    ),
                  ),
                  
                  Text(
                    _formatDate(_backup!.createdAt),
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.5),
                      fontSize: 14,
                    ),
                  ),
                  
                  const SizedBox(height: 28),
                  
                  // Restore button
                  if (_isRestoring)
                    Column(
                      children: [
                        SizedBox(
                          width: 150,
                          child: LinearProgressIndicator(
                            value: _restoreProgress,
                            backgroundColor: Colors.white.withOpacity(0.2),
                            color: iOSDesignSystem.accentGreen,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Restoring... ${(_restoreProgress * 100).toInt()}%',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.7),
                            fontSize: 14,
                          ),
                        ),
                      ],
                    )
                  else
                    Column(
                      children: [
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _performRestore,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: iOSDesignSystem.accentGreen,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: const Text(
                              'Restore',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        
                        const SizedBox(height: 12),
                        
                        TextButton(
                          onPressed: () {
                            HapticFeedback.selectionClick();
                            widget.onSkip?.call();
                          },
                          child: Text(
                            'Skip',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.5),
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dateDay = DateTime(date.year, date.month, date.day);
    
    if (dateDay == today) {
      return 'From today at ${_formatTime(date)}';
    } else if (dateDay == today.subtract(const Duration(days: 1))) {
      return 'From yesterday at ${_formatTime(date)}';
    } else {
      return 'From ${date.day}/${date.month}/${date.year}';
    }
  }

  String _formatTime(DateTime date) {
    return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }
}
