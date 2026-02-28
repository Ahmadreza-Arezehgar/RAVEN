import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import '../theme/ios_design_system.dart';

/// Telegram-style Voice Recording Button
/// 
/// Features:
/// - Press & hold to record
/// - Slide up to lock (hands-free mode)
/// - Waveform + timer display
/// - Send/Cancel buttons when locked
enum VoiceRecordState { idle, recording, locked, sending }

class VoiceHoldButton extends StatefulWidget {
  final Future<void> Function(String filePath, Duration duration) onSend;
  final VoidCallback? onCancel;
  
  const VoiceHoldButton({
    super.key,
    required this.onSend,
    this.onCancel,
  });

  @override
  State<VoiceHoldButton> createState() => _VoiceHoldButtonState();
}

class _VoiceHoldButtonState extends State<VoiceHoldButton> with SingleTickerProviderStateMixin {
  final AudioRecorder _recorder = AudioRecorder();
  VoiceRecordState _state = VoiceRecordState.idle;
  
  Offset _startPosition = Offset.zero;
  DateTime? _recordingStartTime;
  String? _recordingPath;
  Timer? _durationTimer;
  Duration _duration = Duration.zero;
  
  // Animation
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  
  static const double _lockThreshold = 80.0; // Pixels to swipe up
  
  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }
  
  @override
  void dispose() {
    _pulseController.dispose();
    _durationTimer?.cancel();
    _recorder.dispose();
    super.dispose();
  }
  
  Future<void> _startRecording() async {
    // Check permission
    if (!await _recorder.hasPermission()) {
      HapticFeedback.heavyImpact();
      return;
    }
    
    HapticFeedback.mediumImpact();
    
    // Generate path
    final dir = await getTemporaryDirectory();
    _recordingPath = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    
    // Start recording
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc),
      path: _recordingPath!,
    );
    
    _recordingStartTime = DateTime.now();
    _pulseController.repeat(reverse: true);
    
    // Start duration timer
    _durationTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_recordingStartTime != null) {
        setState(() {
          _duration = DateTime.now().difference(_recordingStartTime!);
        });
      }
    });
    
    setState(() => _state = VoiceRecordState.recording);
  }
  
  Future<void> _stopRecording({required bool send}) async {
    _durationTimer?.cancel();
    _pulseController.stop();
    _pulseController.reset();
    
    final path = await _recorder.stop();
    
    if (send && path != null && _duration.inMilliseconds > 500) {
      setState(() => _state = VoiceRecordState.sending);
      
      try {
        await widget.onSend(path, _duration);
      } finally {
        if (mounted) {
          setState(() {
            _state = VoiceRecordState.idle;
            _duration = Duration.zero;
          });
        }
      }
    } else {
      // Cancel - delete file
      if (_recordingPath != null) {
        try {
          await File(_recordingPath!).delete();
        } catch (_) {}
      }
      widget.onCancel?.call();
    }
    
    if (mounted) {
      setState(() {
        _state = VoiceRecordState.idle;
        _duration = Duration.zero;
        _recordingPath = null;
      });
    }
  }
  
  void _lock() {
    HapticFeedback.mediumImpact();
    setState(() => _state = VoiceRecordState.locked);
  }
  
  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
  
  @override
  Widget build(BuildContext context) {
    if (_state == VoiceRecordState.idle) {
      return _buildMicButton();
    }
    
    if (_state == VoiceRecordState.locked || _state == VoiceRecordState.sending) {
      return _buildLockedUI();
    }
    
    // Recording (not locked)
    return _buildRecordingUI();
  }
  
  Widget _buildMicButton() {
    return GestureDetector(
      onLongPressStart: (details) {
        _startPosition = details.globalPosition;
        _startRecording();
      },
      onLongPressMoveUpdate: (details) {
        if (_state != VoiceRecordState.recording) return;
        
        // Check for upward swipe to lock
        final dy = _startPosition.dy - details.globalPosition.dy;
        if (dy > _lockThreshold) {
          _lock();
        }
      },
      onLongPressEnd: (_) {
        if (_state == VoiceRecordState.recording) {
          // Release to send
          _stopRecording(send: true);
        }
      },
      onLongPressCancel: () {
        if (_state == VoiceRecordState.recording) {
          _stopRecording(send: false);
        }
      },
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.1),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withOpacity(0.2)),
        ),
        child: const Icon(Icons.mic, color: Colors.white, size: 24),
      ),
    );
  }
  
  Widget _buildRecordingUI() {
    return ScaleTransition(
      scale: _pulseAnimation,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.red.withOpacity(0.2),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.red.withOpacity(0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Recording dot
            Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                color: Colors.red,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              _formatDuration(_duration),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 16),
            // Swipe up hint
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.keyboard_arrow_up, color: Colors.white54, size: 16),
                Text(
                  'Slide to lock',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.6),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildLockedUI() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.12),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withOpacity(0.2)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Cancel button
              GestureDetector(
                onTap: () => _stopRecording(send: false),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close, color: Colors.red, size: 20),
                ),
              ),
              
              const SizedBox(width: 16),
              
              // Recording indicator
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.red.withOpacity(0.5),
                      blurRadius: 8,
                    ),
                  ],
                ),
              ),
              
              const SizedBox(width: 10),
              
              // Timer
              Text(
                _formatDuration(_duration),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              
              const SizedBox(width: 16),
              
              // Send button
              GestureDetector(
                onTap: _state == VoiceRecordState.sending 
                    ? null 
                    : () => _stopRecording(send: true),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A84FF),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF0A84FF).withOpacity(0.4),
                        blurRadius: 8,
                      ),
                    ],
                  ),
                  child: _state == VoiceRecordState.sending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.send, color: Colors.white, size: 16),
                            SizedBox(width: 6),
                            Text(
                              'Send',
                              style: TextStyle(
                                color: Colors.white,
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
      ),
    );
  }
}
