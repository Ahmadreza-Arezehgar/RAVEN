import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';

/// Voice Recorder with elapsed time tracking
/// Returns both path and duration when recording completes
class VoiceRecorder extends StatefulWidget {
  /// Callback with (path, durationSeconds) when recording is complete
  final Function(String path, int durationSeconds) onRecordComplete;
  
  const VoiceRecorder({super.key, required this.onRecordComplete});

  @override
  State<VoiceRecorder> createState() => _VoiceRecorderState();
}

class _VoiceRecorderState extends State<VoiceRecorder> {
  final _recorder = AudioRecorder();
  bool _isRecording = false;
  String? _recordPath;
  
  // Track elapsed time
  Timer? _timer;
  int _elapsedSeconds = 0;
  DateTime? _startTime;

  @override
  void dispose() {
    _timer?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    if (await _recorder.hasPermission()) {
      final dir = await getApplicationDocumentsDirectory();
      _recordPath = '${dir.path}/${DateTime.now().millisecondsSinceEpoch}.m4a';
      
      await _recorder.start(const RecordConfig(), path: _recordPath!);
      
      _startTime = DateTime.now();
      _elapsedSeconds = 0;
      
      // Start timer to track elapsed time
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          setState(() => _elapsedSeconds++);
        }
      });
      
      setState(() => _isRecording = true);
      HapticFeedback.mediumImpact();
    }
  }

  Future<void> _stopRecording() async {
    _timer?.cancel();
    
    final path = await _recorder.stop();
    
    // Calculate actual duration from start time
    int durationSeconds = _elapsedSeconds;
    if (_startTime != null) {
      durationSeconds = DateTime.now().difference(_startTime!).inSeconds;
    }
    
    setState(() {
      _isRecording = false;
      _elapsedSeconds = 0;
    });
    
    HapticFeedback.lightImpact();
    
    if (path != null && durationSeconds > 0) {
      Navigator.pop(context);
      widget.onRecordComplete(path, durationSeconds);
    } else if (path != null) {
      Navigator.pop(context);
      widget.onRecordComplete(path, 1); // Minimum 1 second
    }
  }
  
  String _formatTime(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.85),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withOpacity(0.1)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Animated recording indicator
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: _isRecording ? 80 : 64,
              height: _isRecording ? 80 : 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _isRecording 
                    ? Colors.red.withOpacity(0.2) 
                    : Colors.white.withOpacity(0.1),
                border: Border.all(
                  color: _isRecording ? Colors.red : Colors.white.withOpacity(0.3),
                  width: 2,
                ),
              ),
              child: Icon(
                _isRecording ? Icons.mic : Icons.mic_none,
                size: _isRecording ? 40 : 32,
                color: _isRecording ? Colors.red : Colors.white,
              ),
            ),
            
            const SizedBox(height: 16),
            
            // Time display
            Text(
              _isRecording ? _formatTime(_elapsedSeconds) : 'Ready',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w600,
                color: _isRecording ? Colors.red : Colors.white.withOpacity(0.7),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            
            const SizedBox(height: 8),
            
            Text(
              _isRecording ? 'Recording...' : 'Tap to start',
              style: TextStyle(
                fontSize: 14,
                color: Colors.white.withOpacity(0.5),
              ),
            ),
            
            const SizedBox(height: 24),
            
            // Action buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                if (_isRecording) ...[
                  // Stop button
                  _ActionButton(
                    icon: Icons.stop_rounded,
                    label: 'Send',
                    color: Colors.red,
                    onTap: _stopRecording,
                  ),
                ] else ...[
                  // Record button
                  _ActionButton(
                    icon: Icons.fiber_manual_record,
                    label: 'Record',
                    color: const Color(0xFF0A84FF),
                    onTap: _startRecording,
                  ),
                ],
                // Cancel button
                _ActionButton(
                  icon: Icons.close,
                  label: 'Cancel',
                  color: Colors.white.withOpacity(0.6),
                  onTap: () {
                    if (_isRecording) {
                      _timer?.cancel();
                      _recorder.stop();
                    }
                    Navigator.pop(context);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });
  
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withOpacity(0.15),
              border: Border.all(color: color.withOpacity(0.4), width: 1.5),
            ),
            child: Icon(icon, color: color, size: 28),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
