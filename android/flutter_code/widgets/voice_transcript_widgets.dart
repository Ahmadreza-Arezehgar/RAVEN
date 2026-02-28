import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ═══════════════════════════════════════════════════════════════════════════
// TRANSCRIPT STATE ENUM
// ═══════════════════════════════════════════════════════════════════════════
enum TranscriptState { 
  idle,      // No transcript yet
  loading,   // Generating transcript
  ready,     // Transcript available
  error,     // Transcription failed
}

// ═══════════════════════════════════════════════════════════════════════════
// TRANSCRIPT BUTTON (Liquid Glass CC Button)
// ═══════════════════════════════════════════════════════════════════════════
class TranscriptButton extends StatelessWidget {
  final TranscriptState state;
  final bool isExpanded;
  final VoidCallback onTap;

  const TranscriptButton({
    super.key,
    required this.state,
    this.isExpanded = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    Widget icon;
    Color? iconColor;
    
    switch (state) {
      case TranscriptState.idle:
        icon = Icon(
          Icons.subtitles_rounded, 
          color: Colors.white.withOpacity(0.85), 
          size: 16,
        );
        break;
      case TranscriptState.loading:
        icon = SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: Colors.white.withOpacity(0.8),
          ),
        );
        break;
      case TranscriptState.ready:
        iconColor = isExpanded 
            ? const Color(0xFF0A84FF)  // Active blue when showing
            : Colors.white.withOpacity(0.85);
        icon = Icon(
          Icons.closed_caption_rounded, 
          color: iconColor, 
          size: 16,
        );
        break;
      case TranscriptState.error:
        icon = Icon(
          Icons.error_outline_rounded, 
          color: Colors.orange.withOpacity(0.9), 
          size: 16,
        );
        break;
    }

    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isExpanded 
                  ? const Color(0xFF0A84FF).withOpacity(0.15)
                  : const Color(0xFF1C1C1E).withOpacity(0.35),
              border: Border.all(
                color: isExpanded 
                    ? const Color(0xFF0A84FF).withOpacity(0.3)
                    : Colors.white.withOpacity(0.10), 
                width: 0.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.20),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Center(child: icon),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// TRANSCRIPT BUBBLE (Subtitle display below voice message)
// ═══════════════════════════════════════════════════════════════════════════
class TranscriptBubble extends StatefulWidget {
  final String text;
  final String? language;
  final bool isVisible;
  final bool isMe;
  final VoidCallback? onClose;

  const TranscriptBubble({
    super.key, 
    required this.text, 
    this.language,
    required this.isVisible,
    this.isMe = true,
    this.onClose,
  });

  @override
  State<TranscriptBubble> createState() => _TranscriptBubbleState();
}

class _TranscriptBubbleState extends State<TranscriptBubble> 
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnim;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    
    _scaleAnim = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    
    if (widget.isVisible) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(TranscriptBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isVisible && !oldWidget.isVisible) {
      _controller.forward();
    } else if (!widget.isVisible && oldWidget.isVisible) {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _getLanguageLabel(String? lang) {
    if (lang == null) return '';
    switch (lang.toLowerCase()) {
      case 'en': return '🇬🇧';
      case 'fa': return '🇮🇷';
      case 'es': return '🇪🇸';
      case 'de': return '🇩🇪';
      case 'fr': return '🇫🇷';
      case 'ar': return '🇸🇦';
      case 'zh': return '🇨🇳';
      default: return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        if (_controller.value == 0 && !widget.isVisible) {
          return const SizedBox.shrink();
        }
        
        return Transform.scale(
          scale: _scaleAnim.value,
          alignment: widget.isMe ? Alignment.topRight : Alignment.topLeft,
          child: Opacity(
            opacity: _fadeAnim.value,
            child: child,
          ),
        );
      },
      child: Container(
        margin: EdgeInsets.only(
          top: 6,
          left: widget.isMe ? 40 : 0,
          right: widget.isMe ? 0 : 40,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF1C1C1E).withOpacity(0.35),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: Colors.white.withOpacity(0.08), 
                  width: 0.5,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Language indicator + Close button
                  if (widget.language != null || widget.onClose != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.language != null) ...[
                            Text(
                              _getLanguageLabel(widget.language),
                              style: const TextStyle(fontSize: 12),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Transcript',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.4),
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                          const Spacer(),
                          if (widget.onClose != null)
                            GestureDetector(
                              onTap: widget.onClose,
                              child: Icon(
                                Icons.close_rounded,
                                size: 14,
                                color: Colors.white.withOpacity(0.4),
                              ),
                            ),
                        ],
                      ),
                    ),
                  
                  // Transcript text
                  Text(
                    widget.text,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.85),
                      fontSize: 13,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// VOICE MESSAGE WITH TRANSCRIPT (Combined Widget)
// ═══════════════════════════════════════════════════════════════════════════
class VoiceMessageWithTranscript extends StatefulWidget {
  final String messageId;
  final String? audioUrl;
  final Duration duration;
  final bool isMe;
  final DateTime timestamp;
  
  // Transcript data
  final String? transcriptText;
  final String? transcriptLang;
  final TranscriptState transcriptState;
  
  // Callbacks
  final VoidCallback? onPlay;
  final Future<void> Function()? onRequestTranscript;

  const VoiceMessageWithTranscript({
    super.key,
    required this.messageId,
    this.audioUrl,
    required this.duration,
    required this.isMe,
    required this.timestamp,
    this.transcriptText,
    this.transcriptLang,
    this.transcriptState = TranscriptState.idle,
    this.onPlay,
    this.onRequestTranscript,
  });

  @override
  State<VoiceMessageWithTranscript> createState() => _VoiceMessageWithTranscriptState();
}

class _VoiceMessageWithTranscriptState extends State<VoiceMessageWithTranscript> {
  bool _showTranscript = false;
  TranscriptState _localState = TranscriptState.idle;

  @override
  void initState() {
    super.initState();
    _localState = widget.transcriptState;
    _showTranscript = widget.transcriptText != null && widget.transcriptText!.isNotEmpty;
  }

  @override
  void didUpdateWidget(VoiceMessageWithTranscript oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.transcriptState != oldWidget.transcriptState) {
      _localState = widget.transcriptState;
    }
  }

  Future<void> _handleTranscriptTap() async {
    if (_localState == TranscriptState.ready) {
      // Toggle visibility
      setState(() => _showTranscript = !_showTranscript);
      return;
    }
    
    if (_localState == TranscriptState.loading) return;
    
    // Request transcript from server
    setState(() => _localState = TranscriptState.loading);
    
    try {
      if (widget.onRequestTranscript != null) {
        await widget.onRequestTranscript!();
        setState(() {
          _localState = TranscriptState.ready;
          _showTranscript = true;
        });
      }
    } catch (e) {
      setState(() => _localState = TranscriptState.error);
    }
  }

  String _formatDuration(Duration d) {
    final mins = d.inMinutes;
    final secs = d.inSeconds % 60;
    return '${mins.toString().padLeft(1, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: widget.isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        // Voice message bubble with transcript button
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Transcript button (left side for others)
            if (!widget.isMe) ...[
              TranscriptButton(
                state: _localState,
                isExpanded: _showTranscript,
                onTap: _handleTranscriptTap,
              ),
              const SizedBox(width: 6),
            ],
            
            // Voice message bubble
            _buildVoiceBubble(),
            
            // Transcript button (right side for me)
            if (widget.isMe) ...[
              const SizedBox(width: 6),
              TranscriptButton(
                state: _localState,
                isExpanded: _showTranscript,
                onTap: _handleTranscriptTap,
              ),
            ],
          ],
        ),
        
        // Transcript bubble (below)
        if (widget.transcriptText != null && widget.transcriptText!.isNotEmpty)
          TranscriptBubble(
            text: widget.transcriptText!,
            language: widget.transcriptLang,
            isVisible: _showTranscript,
            isMe: widget.isMe,
            onClose: () => setState(() => _showTranscript = false),
          ),
      ],
    );
  }

  Widget _buildVoiceBubble() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          constraints: const BoxConstraints(maxWidth: 220),
          decoration: BoxDecoration(
            color: widget.isMe 
                ? const Color(0xFF0A84FF).withOpacity(0.25)
                : const Color(0xFF1C1C1E).withOpacity(0.45),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: widget.isMe 
                  ? const Color(0xFF0A84FF).withOpacity(0.3)
                  : Colors.white.withOpacity(0.08),
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Play button
              GestureDetector(
                onTap: widget.onPlay,
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.isMe 
                        ? const Color(0xFF0A84FF)
                        : Colors.white.withOpacity(0.15),
                  ),
                  child: Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              
              // Waveform placeholder
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Fake waveform
                    Row(
                      children: List.generate(12, (i) {
                        final height = 6.0 + (i % 3) * 4.0 + (i % 5) * 2.0;
                        return Container(
                          width: 3,
                          height: height,
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.4),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 4),
                    
                    // Duration
                    Text(
                      _formatDuration(widget.duration),
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.6),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
