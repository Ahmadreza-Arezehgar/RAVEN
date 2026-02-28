import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/toast_service.dart';
import '../services/voice_queue_controller.dart';

/// Voice Message Bubble with Liquid Glass capsule design
/// 
/// Modern Apple-style UI:
/// - Glass play/pause button with highlight
/// - Wave capsule progress (pseudo-waveform)
/// - Minimal duration display
/// - Proper position sync from player stream
class VoiceMessageBubble extends StatefulWidget {
  final String messageId;
  final String? audioUrl;
  final String? localPath;
  final int durationSeconds;
  final String? transcript;
  final bool isFromMe;
  final DateTime timestamp;
  final List<VoiceQueueItem> allVoicesInChat;
  
  const VoiceMessageBubble({
    super.key,
    required this.messageId,
    this.audioUrl,
    this.localPath,
    required this.durationSeconds,
    this.transcript,
    required this.isFromMe,
    required this.timestamp,
    this.allVoicesInChat = const [],
  });

  @override
  State<VoiceMessageBubble> createState() => _VoiceMessageBubbleState();
}

class _VoiceMessageBubbleState extends State<VoiceMessageBubble> 
    with SingleTickerProviderStateMixin {
  final VoiceQueueController _controller = VoiceQueueController.instance;
  
  bool _isPlaying = false;
  bool _isCurrent = false;
  bool _completed = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _showTranscript = false;
  bool _isLoading = false;
  
  StreamSubscription<String?>? _playingIdSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub; // ✅ Duration stream subscription
  
  // Activity ring animation
  late AnimationController _ringController;
  
  @override
  void initState() {
    super.initState();
    _duration = Duration(seconds: widget.durationSeconds);
    
    _ringController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    
    _playingIdSub = _controller.playingIdStream.listen((playingId) {
      if (!mounted) return;
      final nowCurrent = playingId == widget.messageId;
      final nowPlaying = nowCurrent && _controller.isPlaying(widget.messageId);
      
      if (_isCurrent != nowCurrent || _isPlaying != nowPlaying) {
        setState(() {
          _isCurrent = nowCurrent;
          _isPlaying = nowPlaying;
          if (!nowCurrent) {
            _position = Duration.zero;
            _completed = false;
          }
        });
        
        // Animate ring when playing
        if (nowPlaying) {
          _ringController.repeat();
        } else {
          _ringController.stop();
        }
      }
      
      // Check for completion (playingId becomes null when queue ends)
      if (playingId == null && _isCurrent) {
        setState(() {
          _completed = true;
          _position = _duration; // Force to end
          _isPlaying = false;
          _isCurrent = false;
        });
        _ringController.stop();
      }
    });
    
    _positionSub = _controller.positionStream.listen((pos) {
      if (!mounted) return;
      if (_isCurrent) {
        // Force to 100% when within 100ms of end
        if (_duration.inMilliseconds > 0 && 
            _duration.inMilliseconds - pos.inMilliseconds <= 100) {
          setState(() {
            _position = _duration;
            _completed = true;
          });
        } else {
          setState(() => _position = pos);
        }
      }
    });
    
    // ✅ Listen for accurate duration from player (fixes 0:00 display)
    _durationSub = _controller.durationStream.listen((d) {
      if (!mounted) return;
      if (_isCurrent && d.inSeconds > 0) {
        setState(() => _duration = d);
      }
    });
  }
  
  @override
  void dispose() {
    _playingIdSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel(); // ✅ Clean up duration subscription
    _ringController.dispose();
    super.dispose();
  }
  
  double get progress {
    if (_duration.inMilliseconds == 0) return 0;
    return (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
  }
  
  Future<void> _togglePlay() async {
    HapticFeedback.selectionClick();
    
    if (widget.audioUrl == null && widget.localPath == null) {
      if (widget.isFromMe) {
        ToastService.showError('Audio is still uploading...');
      } else {
        ToastService.showError('Audio not available yet');
      }
      return;
    }
    
    if (widget.localPath != null && widget.localPath!.isNotEmpty) {
      final file = File(widget.localPath!);
      if (!await file.exists() && widget.audioUrl == null) {
        ToastService.showError('Audio file not found');
        return;
      }
    }
    
    setState(() => _isLoading = true);
    
    try {
      // If completed, reset position
      if (_completed) {
        setState(() => _completed = false);
      }
      
      List<VoiceQueueItem> voices = widget.allVoicesInChat;
      if (voices.isEmpty) {
        voices = [
          VoiceQueueItem(
            id: widget.messageId,
            url: widget.audioUrl,
            localPath: widget.localPath,
          ),
        ];
      }
      
      await _controller.togglePlayPause(
        voiceId: widget.messageId,
        allVoices: voices,
      );
    } catch (e) {
      print('❌ [VoiceBubble] Toggle play error: $e');
      ToastService.showError('Cannot play audio');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }
  
  String _formatTime(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
  
  String get _timeDisplay {
    if (_isPlaying || _isCurrent) {
      // Show current / total while playing
      return '${_formatTime(_position)} / ${_formatTime(_duration)}';
    }
    // Show total duration when idle
    return _formatTime(_duration);
  }
  
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: widget.isFromMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        child: Column(
          crossAxisAlignment: widget.isFromMe 
              ? CrossAxisAlignment.end 
              : CrossAxisAlignment.start,
          children: [
            // Main Liquid Glass Capsule
            _buildVoiceCapsule(),
            
            // Transcript (collapsible)
            if (_showTranscript && widget.transcript != null)
              _buildTranscript(),
          ],
        ),
      ),
    );
  }
  
  Widget _buildVoiceCapsule() {
    final isSender = widget.isFromMe;
    
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isSender
                  ? [
                      const Color(0xFF0A84FF).withOpacity(0.9),
                      const Color(0xFF0066CC).withOpacity(0.85),
                    ]
                  : [
                      Colors.white.withOpacity(0.15),
                      Colors.white.withOpacity(0.08),
                    ],
            ),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: isSender 
                  ? Colors.white.withOpacity(0.2)
                  : Colors.white.withOpacity(0.12),
              width: 0.5,
            ),
            boxShadow: [
              BoxShadow(
                color: isSender 
                    ? const Color(0xFF0A84FF).withOpacity(0.3)
                    : Colors.black.withOpacity(0.2),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Glass Play/Pause Button
              _buildGlassPlayButton(),
              
              const SizedBox(width: 10),
              
              // Wave Progress Capsule
              Expanded(
                child: _buildWaveCapsule(),
              ),
              
              const SizedBox(width: 10),
              
              // Duration
              _buildTimeDisplay(),
              
              // Transcript toggle
              if (widget.transcript != null && widget.transcript!.isNotEmpty)
                _buildTranscriptToggle(),
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _buildGlassPlayButton() {
    final isSender = widget.isFromMe;
    final buttonSize = 40.0;
    
    return GestureDetector(
      onTap: _togglePlay,
      child: AnimatedBuilder(
        animation: _ringController,
        builder: (context, child) {
          return Container(
            width: buttonSize,
            height: buttonSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: isSender
                    ? [
                        Colors.white.withOpacity(0.3),
                        Colors.white.withOpacity(0.15),
                      ]
                    : [
                        const Color(0xFF0A84FF).withOpacity(0.35),
                        const Color(0xFF0A84FF).withOpacity(0.15),
                      ],
              ),
              border: Border.all(
                color: isSender 
                    ? Colors.white.withOpacity(0.4)
                    : const Color(0xFF0A84FF).withOpacity(0.4),
                width: 1.5,
              ),
              boxShadow: _isPlaying
                  ? [
                      BoxShadow(
                        color: isSender 
                            ? Colors.white.withOpacity(0.2)
                            : const Color(0xFF0A84FF).withOpacity(0.3),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: _buildButtonIcon(),
          );
        },
      ),
    );
  }
  
  Widget _buildButtonIcon() {
    final isSender = widget.isFromMe;
    final iconColor = isSender ? Colors.white : const Color(0xFF0A84FF);
    
    if (_isLoading) {
      return Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: iconColor,
          ),
        ),
      );
    }
    
    if (widget.audioUrl == null && !widget.isFromMe) {
      return Icon(Icons.cloud_download_outlined, color: iconColor.withOpacity(0.6), size: 22);
    }
    
    if (widget.audioUrl == null && widget.isFromMe) {
      return Icon(Icons.cloud_upload_outlined, color: iconColor.withOpacity(0.7), size: 22);
    }
    
    // Show replay icon when completed
    if (_completed) {
      return Icon(Icons.replay, color: iconColor, size: 22);
    }
    
    return Icon(
      _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
      color: iconColor,
      size: 24,
    );
  }
  
  Widget _buildWaveCapsule() {
    final isSender = widget.isFromMe;
    final activeColor = isSender ? Colors.white : const Color(0xFF0A84FF);
    final inactiveColor = isSender 
        ? Colors.white.withOpacity(0.3) 
        : Colors.white.withOpacity(0.2);
    
    // Pseudo-waveform heights
    const heights = [0.35, 0.6, 0.45, 0.9, 0.7, 0.5, 0.85, 0.4, 0.65, 0.5,
                     0.75, 0.55, 0.8, 0.4, 0.6, 0.95, 0.45, 0.7, 0.55, 0.35,
                     0.5, 0.7, 0.4, 0.8, 0.6];
    
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      decoration: BoxDecoration(
        color: isSender 
            ? Colors.white.withOpacity(0.1)
            : Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(
        children: List.generate(heights.length, (i) {
          final isPlayed = i / heights.length <= progress;
          final barHeight = 20 * heights[i];
          
          return Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              margin: const EdgeInsets.symmetric(horizontal: 0.5),
              height: barHeight,
              decoration: BoxDecoration(
                color: isPlayed ? activeColor : inactiveColor,
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
          );
        }),
      ),
    );
  }
  
  Widget _buildTimeDisplay() {
    final isSender = widget.isFromMe;
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: isSender 
            ? Colors.white.withOpacity(0.15)
            : Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        _timeDisplay,
        style: TextStyle(
          color: isSender ? Colors.white.withOpacity(0.9) : Colors.white.withOpacity(0.7),
          fontSize: 11,
          fontWeight: FontWeight.w500,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
  
  Widget _buildTranscriptToggle() {
    final isSender = widget.isFromMe;
    
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _showTranscript = !_showTranscript);
      },
      child: Container(
        padding: const EdgeInsets.all(6),
        margin: const EdgeInsets.only(left: 4),
        child: Icon(
          _showTranscript ? Icons.text_fields : Icons.closed_caption_outlined,
          color: isSender 
              ? Colors.white.withOpacity(0.7)
              : Colors.white.withOpacity(0.5),
          size: 18,
        ),
      ),
    );
  }
  
  Widget _buildTranscript() {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.text_snippet, size: 13, color: Colors.white.withOpacity(0.5)),
              const SizedBox(width: 6),
              Text(
                'Transcript',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.5),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: widget.transcript!));
                  HapticFeedback.lightImpact();
                  ToastService.showSuccess('Copied to clipboard');
                },
                child: Icon(Icons.copy, size: 14, color: Colors.white.withOpacity(0.5)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            widget.transcript!,
            style: TextStyle(
              color: Colors.white.withOpacity(0.85),
              fontSize: 14,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}
