import 'dart:async';
import 'dart:ui';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';

/// 🧊 Apple Liquid Glass Message Composer
/// 
/// Features:
/// - Floating capsule design matching bottom bar
/// - Backdrop blur (systemUltraThinMaterialDark)
/// - Circular buttons with haptic feedback
/// - Smooth spring-based animations
/// - Voice recording with hold-to-record (REAL AUDIO)
/// - Multiline expansion with max height
class LiquidGlassComposer extends StatefulWidget {
  final Function(String) onSend;
  final VoidCallback? onAttach;
  final GlobalKey? attachButtonKey;  // For attachment picker anchor
  /// Called when voice recording is complete with (filePath, duration)
  final Function(String filePath, Duration duration)? onVoiceSend;
  
  /// Schedule props for showing schedule chip
  final DateTime? scheduledAtUtc;
  final VoidCallback? onModifySchedule;
  final VoidCallback? onCancelSchedule;
  
  const LiquidGlassComposer({
    super.key,
    required this.onSend,
    this.onAttach,
    this.attachButtonKey,
    this.onVoiceSend,
    this.scheduledAtUtc,
    this.onModifySchedule,
    this.onCancelSchedule,
  });

  @override
  State<LiquidGlassComposer> createState() => _LiquidGlassComposerState();
}

class _LiquidGlassComposerState extends State<LiquidGlassComposer> 
    with SingleTickerProviderStateMixin {
  
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  
  // Audio recorder
  final AudioRecorder _audioRecorder = AudioRecorder();
  String? _recordingPath;
  
  bool _hasText = false;
  bool _isRecording = false;
  bool _isRecordingLocked = false;
  DateTime? _recordingStart;
  Timer? _recordingTimer;
  Duration _recordingDuration = Duration.zero;
  
  // Animation
  late AnimationController _animController;
  late Animation<double> _scaleAnim;
  
  // Constants
  static const double _baseHeight = 52.0;
  static const double _maxHeight = 140.0;
  static const double _buttonSize = 40.0;
  static const double _blurSigma = 25.0;
  static const _animDuration = Duration(milliseconds: 220);
  
  // Colors
  static const Color _blurColor = Color(0xFF1C1C1E);
  static const Color _accentBlue = Color(0xFF0A84FF);
  static const Color _recordRed = Color(0xFFFF3B30);
  
  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: 0.92).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
    );
  }
  
  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _animController.dispose();
    _recordingTimer?.cancel();
    super.dispose();
  }
  
  void _onTextChanged() {
    final hasText = _controller.text.trim().isNotEmpty;
    if (hasText != _hasText) {
      setState(() => _hasText = hasText);
    }
  }
  
  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    
    HapticFeedback.lightImpact();
    widget.onSend(text);
    _controller.clear();
    setState(() => _hasText = false);
  }
  
  Future<void> _startRecording() async {
    HapticFeedback.mediumImpact();
    
    try {
      // Check permission
      if (await _audioRecorder.hasPermission()) {
        // Get temp directory for recording
        final dir = await getTemporaryDirectory();
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        _recordingPath = '${dir.path}/voice_$timestamp.m4a';
        
        print('🎤 [Composer] Starting recording to: $_recordingPath');
        
        // Start recording
        await _audioRecorder.start(
          const RecordConfig(
            encoder: AudioEncoder.aacLc,
            bitRate: 128000,
            sampleRate: 44100,
          ),
          path: _recordingPath!,
        );
        
        setState(() {
          _isRecording = true;
          _recordingStart = DateTime.now();
          _recordingDuration = Duration.zero;
        });
        
        _recordingTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
          if (_recordingStart != null) {
            setState(() {
              _recordingDuration = DateTime.now().difference(_recordingStart!);
            });
          }
        });
        
        print('✅ [Composer] Recording started');
      } else {
        print('❌ [Composer] No microphone permission');
        HapticFeedback.heavyImpact();
      }
    } catch (e) {
      print('❌ [Composer] Recording error: $e');
    }
  }
  
  Future<void> _stopRecording({bool send = true}) async {
    _recordingTimer?.cancel();
    
    try {
      if (await _audioRecorder.isRecording()) {
        final path = await _audioRecorder.stop();
        print('🎤 [Composer] Recording stopped: $path');
        
        if (send && _recordingDuration.inSeconds >= 1 && path != null) {
          HapticFeedback.lightImpact();
          
          // Verify file exists
          final file = File(path);
          if (await file.exists()) {
            final size = await file.length();
            print('✅ [Composer] Audio file: ${size} bytes');
            widget.onVoiceSend?.call(path, _recordingDuration);
          } else {
            print('❌ [Composer] Audio file not found');
          }
        }
      }
    } catch (e) {
      print('❌ [Composer] Stop recording error: $e');
    }
    
    setState(() {
      _isRecording = false;
      _isRecordingLocked = false;
      _recordingDuration = Duration.zero;
      _recordingPath = null;
    });
  }
  
  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final hasSchedule = widget.scheduledAtUtc != null;
    
    return AnimatedContainer(
      duration: _animDuration,
      curve: Curves.easeOutCubic,
      margin: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: bottomPadding + 12,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ✅ SCHEDULE CHIP (above the composer)
          if (hasSchedule) _buildScheduleChip(),
          
          // Main Composer Capsule
          ClipRRect(
            borderRadius: BorderRadius.circular(_baseHeight / 2),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: _blurSigma, sigmaY: _blurSigma),
              child: AnimatedContainer(
                duration: _animDuration,
                curve: Curves.easeOutCubic,
                constraints: BoxConstraints(
                  minHeight: _baseHeight,
                  maxHeight: _maxHeight,
                ),
                decoration: BoxDecoration(
                  // ✅ Very low opacity for TRUE glass effect
                  color: _blurColor.withOpacity(0.28),
                  borderRadius: BorderRadius.circular(_baseHeight / 2),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.12),
                    width: 0.6,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.25),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Stack(
                  children: [
                    // ✨ Highlight sheen (key to liquid glass look)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(_baseHeight / 2),
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Colors.white.withOpacity(0.12),
                                Colors.transparent,
                                Colors.black.withOpacity(0.08),
                              ],
                              stops: const [0.0, 0.5, 1.0],
                            ),
                          ),
                        ),
                      ),
                    ),
                    
                    // Content
                    _isRecording ? _buildRecordingUI() : _buildComposerUI(),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  /// 🗓️ Schedule Chip - Liquid Glass Capsule above composer
  Widget _buildScheduleChip() {
    final dt = widget.scheduledAtUtc!.toLocal();
    final now = DateTime.now();
    
    // Format: Today/Tomorrow + time
    String formattedTime;
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      formattedTime = 'Today ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } else if (dt.year == now.year && dt.month == now.month && dt.day == now.day + 1) {
      formattedTime = 'Tomorrow ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } else {
      formattedTime = '${dt.day}/${dt.month} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF32D74B).withOpacity(0.15),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: const Color(0xFF32D74B).withOpacity(0.3),
                width: 0.5,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.schedule_rounded,
                  color: Color(0xFF32D74B),
                  size: 16,
                ),
                const SizedBox(width: 8),
                Text(
                  'Scheduled • $formattedTime',
                  style: const TextStyle(
                    color: Color(0xFF32D74B),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 12),
                // Modify button
                GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    widget.onModifySchedule?.call();
                  },
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(
                      Icons.edit_rounded,
                      color: Colors.white70,
                      size: 14,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // Cancel button
                GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    widget.onCancelSchedule?.call();
                  },
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(
                      Icons.close_rounded,
                      color: Colors.white70,
                      size: 14,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
  
  Widget _buildComposerUI() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // ✅ Attach Button (Circle)
          _CircleButton(
            key: widget.attachButtonKey,
            icon: Icons.add,
            size: _buttonSize,
            onTap: () {
              HapticFeedback.selectionClick();
              widget.onAttach?.call();
            },
          ),
          
          const SizedBox(width: 8),
          
          // ✅ Text Input (no box, just text in capsule)
          Expanded(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: _maxHeight - 16,
              ),
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                maxLines: null,
                textCapitalization: TextCapitalization.sentences,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  height: 1.3,
                ),
                decoration: InputDecoration(
                  hintText: 'Message...',
                  hintStyle: TextStyle(
                    color: Colors.white.withOpacity(0.45),
                    fontSize: 16,
                  ),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  filled: false,  // ✅ NO FILL
                  fillColor: Colors.transparent,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 10,
                  ),
                  isDense: true,
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
          ),
          
          const SizedBox(width: 8),
          
          // ✅ Voice / Send Button (Animated switch)
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (child, anim) => ScaleTransition(
              scale: anim,
              child: child,
            ),
            child: _hasText 
                ? _SendButton(
                    key: const ValueKey('send'),
                    size: _buttonSize,
                    onTap: _send,
                  )
                : _VoiceButton(
                    key: const ValueKey('voice'),
                    size: _buttonSize,
                    onLongPressStart: _startRecording,
                    onLongPressEnd: () => _stopRecording(send: true),
                  ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildRecordingUI() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          // Cancel
          _CircleButton(
            icon: Icons.close,
            size: _buttonSize,
            color: Colors.white.withOpacity(0.6),
            onTap: () {
              HapticFeedback.lightImpact();
              _stopRecording(send: false);
            },
          ),
          
          const SizedBox(width: 16),
          
          // Recording indicator
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: _recordRed,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: _recordRed.withOpacity(0.5),
                  blurRadius: 8,
                ),
              ],
            ),
          ),
          
          const SizedBox(width: 12),
          
          // Duration
          Text(
            _formatDuration(_recordingDuration),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w500,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          
          const Spacer(),
          
          // Slide to cancel hint
          Text(
            '< Slide to cancel',
            style: TextStyle(
              color: Colors.white.withOpacity(0.4),
              fontSize: 14,
            ),
          ),
          
          const Spacer(),
          
          // Send voice
          _SendButton(
            size: _buttonSize,
            onTap: () => _stopRecording(send: true),
            isVoice: true,
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// CIRCLE BUTTON (Attach, etc)
// ═══════════════════════════════════════════════════════════════════
class _CircleButton extends StatelessWidget {
  final IconData icon;
  final double size;
  final VoidCallback? onTap;
  final Color? color;
  
  const _CircleButton({
    super.key,  // ✅ Allow passing key for anchor positioning
    required this.icon,
    required this.size,
    this.onTap,
    this.color,
  });
  
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          // ✅ TRANSPARENT - no dark background!
          color: Colors.transparent,
        ),
        child: Icon(
          icon,
          color: color ?? const Color(0xFF0A84FF),
          size: size * 0.55,
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// SEND BUTTON (Blue gradient circle with arrow)
// ═══════════════════════════════════════════════════════════════════
class _SendButton extends StatefulWidget {
  final double size;
  final VoidCallback onTap;
  final bool isVoice;
  
  const _SendButton({
    super.key,
    required this.size,
    required this.onTap,
    this.isVoice = false,
  });
  
  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton> 
    with SingleTickerProviderStateMixin {
  
  late AnimationController _controller;
  late Animation<double> _scale;
  
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
    _scale = Tween<double>(begin: 1.0, end: 0.9).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
  }
  
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _controller.forward(),
      onTapUp: (_) {
        _controller.reverse();
        HapticFeedback.lightImpact();
        widget.onTap();
      },
      onTapCancel: () => _controller.reverse(),
      child: AnimatedBuilder(
        animation: _scale,
        builder: (context, child) => Transform.scale(
          scale: _scale.value,
          child: child,
        ),
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF0A84FF), Color(0xFF0066CC)],
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF0A84FF).withOpacity(0.4),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Icon(
            widget.isVoice ? Icons.send_rounded : Icons.arrow_upward_rounded,
            color: Colors.white,
            size: widget.size * 0.55,
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// VOICE BUTTON (Hold to record)
// ═══════════════════════════════════════════════════════════════════
class _VoiceButton extends StatefulWidget {
  final double size;
  final VoidCallback onLongPressStart;
  final VoidCallback onLongPressEnd;
  
  const _VoiceButton({
    super.key,
    required this.size,
    required this.onLongPressStart,
    required this.onLongPressEnd,
  });
  
  @override
  State<_VoiceButton> createState() => _VoiceButtonState();
}

class _VoiceButtonState extends State<_VoiceButton> 
    with SingleTickerProviderStateMixin {
  
  late AnimationController _controller;
  late Animation<double> _scale;
  bool _isPressed = false;
  
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _scale = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
  }
  
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPressStart: (_) {
        setState(() => _isPressed = true);
        _controller.forward();
        widget.onLongPressStart();
      },
      onLongPressEnd: (_) {
        setState(() => _isPressed = false);
        _controller.reverse();
        widget.onLongPressEnd();
      },
      onLongPressCancel: () {
        setState(() => _isPressed = false);
        _controller.reverse();
      },
      child: AnimatedBuilder(
        animation: _scale,
        builder: (context, child) => Transform.scale(
          scale: _scale.value,
          child: child,
        ),
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _isPressed 
                ? const Color(0xFFFF3B30).withOpacity(0.2) 
                : Colors.white.withOpacity(0.08),
          ),
          child: Icon(
            Icons.mic_rounded,
            color: _isPressed 
                ? const Color(0xFFFF3B30) 
                : Colors.white.withOpacity(0.7),
            size: widget.size * 0.55,
          ),
        ),
      ),
    );
  }
}
