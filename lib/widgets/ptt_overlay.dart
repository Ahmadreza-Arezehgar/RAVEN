import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/mesh/ptt_controller.dart';
import '../services/toast_service.dart';
import 'liquid_glass_animations.dart';

/// PTT Overlay - Premium walkie-talkie style voice recording
/// 
/// Apple Liquid Glass design with:
/// - Glowing microphone with pulse animation
/// - Multi-layer waveform visualization
/// - Particle burst on press
/// - Spring physics interactions
/// - Animated gradient rings
class PttOverlay extends StatefulWidget {
  final VoidCallback? onClose;
  final bool fullScreen;
  
  const PttOverlay({
    super.key,
    this.onClose,
    this.fullScreen = false,
  });
  
  /// Show PTT overlay as a modal
  static Future<void> show(BuildContext context) async {
    HapticFeedback.mediumImpact();
    
    await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'PTT',
      barrierColor: Colors.black.withOpacity(0.8),
      transitionDuration: const Duration(milliseconds: 400),
      pageBuilder: (_, __, ___) => const PttOverlay(fullScreen: true),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curvedAnimation = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutBack,
        );
        
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.85, end: 1.0).animate(curvedAnimation),
            child: child,
          ),
        );
      },
    );
  }

  @override
  State<PttOverlay> createState() => _PttOverlayState();
}

class _PttOverlayState extends State<PttOverlay>
    with TickerProviderStateMixin {
  final PttController _pttController = PttController.instance;
  
  bool _isRecording = false;
  bool _isSending = false;
  Timer? _volumeTimer;
  
  late AnimationController _pulseController;
  late AnimationController _ringController;
  late AnimationController _waveController;
  late AnimationController _pressController;
  
  late Animation<double> _pulseAnimation;
  late Animation<double> _ringAnimation;
  late Animation<double> _pressScaleAnimation;
  
  final List<double> _waveformData = List.filled(40, 0.0);
  final List<double> _waveformData2 = List.filled(40, 0.0);
  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    
    // Pulse animation for idle state
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    )..repeat(reverse: true);
    
    _pulseAnimation = Tween<double>(begin: 0.2, end: 0.5).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    
    // Rotating ring animation
    _ringController = AnimationController(
      duration: const Duration(seconds: 8),
      vsync: this,
    )..repeat();
    
    _ringAnimation = Tween<double>(begin: 0, end: 2 * pi).animate(_ringController);
    
    // Wave animation
    _waveController = AnimationController(
      duration: const Duration(milliseconds: 50),
      vsync: this,
    );
    
    // Press scale animation
    _pressController = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    
    _pressScaleAnimation = Tween<double>(begin: 1.0, end: 0.92).animate(
      CurvedAnimation(parent: _pressController, curve: Curves.easeInOut),
    );
    
    // Listen to PTT state changes
    _pttController.onStateChange.listen((state) {
      if (mounted) {
        setState(() {
          _isRecording = state == PttState.recording;
          _isSending = state == PttState.sending;
        });
      }
    });
  }
  
  void _updateWaveform() {
    // Primary waveform
    for (int i = 0; i < _waveformData.length - 1; i++) {
      _waveformData[i] = _waveformData[i + 1];
    }
    _waveformData[_waveformData.length - 1] = 
        0.3 + _random.nextDouble() * 0.6;
    
    // Secondary waveform (slightly delayed and different)
    for (int i = 0; i < _waveformData2.length - 1; i++) {
      _waveformData2[i] = _waveformData2[i + 1] * 0.95;
    }
    _waveformData2[_waveformData2.length - 1] = 
        0.2 + _random.nextDouble() * 0.5;
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _ringController.dispose();
    _waveController.dispose();
    _pressController.dispose();
    _volumeTimer?.cancel();
    super.dispose();
  }

  void _startRecording() async {
    HapticFeedback.heavyImpact();
    _pressController.forward();
    
    try {
      final success = await _pttController.startRecording();
      if (success) {
        setState(() => _isRecording = true);
        
        // Faster waveform updates for snappy visuals
        _volumeTimer = Timer.periodic(const Duration(milliseconds: 40), (_) {
          if (mounted && _isRecording) {
            setState(() => _updateWaveform());
          }
        });
      } else {
        ToastService.showError('Failed to start recording');
        _pressController.reverse();
      }
    } catch (e) {
      ToastService.showError('Microphone error');
      _pressController.reverse();
    }
  }

  void _stopRecording() async {
    HapticFeedback.mediumImpact();
    _pressController.reverse();
    _volumeTimer?.cancel();
    
    setState(() {
      _isRecording = false;
      _isSending = true;
    });
    
    try {
      await _pttController.stopRecording();
      ToastService.showSuccess('🎙️ Voice sent');
    } catch (e) {
      ToastService.showError('Failed to send audio');
    }
    
    if (mounted) {
      setState(() {
        _isSending = false;
        // Fade out waveform
        for (int i = 0; i < _waveformData.length; i++) {
          _waveformData[i] = 0.0;
          _waveformData2[i] = 0.0;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.pop(context),
      behavior: HitTestBehavior.opaque,
      child: Stack(
        children: [
          // Particle background
          const Positioned.fill(
            child: MeshParticleBackground(
              color: Color(0xFFBF5AF2),
              particleCount: 15,
            ),
          ),
          
          // Main content
          Center(
            child: GestureDetector(
              onTap: () {}, // Prevent dismissal
              child: ClipRRect(
                borderRadius: BorderRadius.circular(32),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                  child: Container(
                    width: 340,
                    padding: const EdgeInsets.all(28),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          const Color(0xFF1C1C1E).withOpacity(0.85),
                          const Color(0xFF2C2C2E).withOpacity(0.75),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(32),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.15),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFBF5AF2).withOpacity(0.15),
                          blurRadius: 30,
                          spreadRadius: 5,
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Title with icon
                        _buildTitle(),
                        const SizedBox(height: 8),
                        _buildSubtitle(),
                        const SizedBox(height: 36),
                        
                        // Waveform visualization
                        _buildWaveformContainer(),
                        const SizedBox(height: 36),
                        
                        // PTT Button
                        _buildPttButton(),
                        const SizedBox(height: 24),
                        
                        // Status
                        _buildStatus(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTitle() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFBF5AF2), Color(0xFF9040C0)],
            ),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFBF5AF2).withOpacity(0.4),
                blurRadius: 12,
                spreadRadius: 1,
              ),
            ],
          ),
          child: const Icon(
            Icons.mic,
            color: Colors.white,
            size: 22,
          ),
        ),
        const SizedBox(width: 14),
        const Text(
          'Push to Talk',
          style: TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }

  Widget _buildSubtitle() {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 400),
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Text(
          _isRecording 
              ? 'Recording...' 
              : _isSending 
                  ? 'Sending...'
                  : 'Hold to record',
          style: TextStyle(
            color: _isRecording 
                ? const Color(0xFFBF5AF2) 
                : Colors.white.withOpacity(0.5),
            fontSize: 14,
            fontWeight: _isRecording ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  Widget _buildWaveformContainer() {
    return Container(
      height: 80,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _isRecording 
              ? const Color(0xFFBF5AF2).withOpacity(0.3)
              : Colors.white.withOpacity(0.08),
          width: 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            // Background waveform (subtle)
            CustomPaint(
              size: const Size(double.infinity, 80),
              painter: _WaveformPainter(
                waveformData: _waveformData2,
                color: _isRecording 
                    ? const Color(0xFFBF5AF2).withOpacity(0.2) 
                    : Colors.white.withOpacity(0.1),
                barWidth: 4,
              ),
            ),
            // Primary waveform
            CustomPaint(
              size: const Size(double.infinity, 80),
              painter: _WaveformPainter(
                waveformData: _waveformData,
                color: _isRecording 
                    ? const Color(0xFFBF5AF2) 
                    : Colors.white.withOpacity(0.25),
                barWidth: 3,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPttButton() {
    return GestureDetector(
      onTapDown: (_) => _startRecording(),
      onTapUp: (_) => _stopRecording(),
      onTapCancel: () => _stopRecording(),
      child: AnimatedBuilder(
        animation: Listenable.merge([_pulseAnimation, _pressScaleAnimation, _ringAnimation]),
        builder: (context, child) {
          return Transform.scale(
            scale: _pressScaleAnimation.value,
            child: SizedBox(
              width: 140,
              height: 140,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Outer rotating gradient ring
                  Transform.rotate(
                    angle: _ringAnimation.value,
                    child: Container(
                      width: 140,
                      height: 140,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: SweepGradient(
                          colors: [
                            _isRecording 
                                ? const Color(0xFFBF5AF2).withOpacity(0.4)
                                : Colors.white.withOpacity(0.1),
                            Colors.transparent,
                            _isRecording 
                                ? const Color(0xFFBF5AF2).withOpacity(0.4)
                                : Colors.white.withOpacity(0.1),
                          ],
                        ),
                      ),
                    ),
                  ),
                  
                  // Glow layer
                  if (_isRecording)
                    Container(
                      width: 130,
                      height: 130,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFBF5AF2)
                                .withOpacity(_pulseAnimation.value),
                            blurRadius: 40,
                            spreadRadius: 10,
                          ),
                        ],
                      ),
                    ),
                  
                  // Main button
                  Container(
                    width: 110,
                    height: 110,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: _isRecording
                            ? [
                                const Color(0xFFBF5AF2),
                                const Color(0xFF8040A0),
                              ]
                            : [
                                const Color(0xFF3A3A3C),
                                const Color(0xFF2C2C2E),
                              ],
                        center: const Alignment(-0.2, -0.3),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.3),
                          blurRadius: 15,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Icon(
                      _isRecording ? Icons.mic : Icons.mic_none_rounded,
                      color: Colors.white,
                      size: 48,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildStatus() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: Row(
        key: ValueKey(_isRecording),
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          GlowPulse(
            color: _isRecording 
                ? const Color(0xFFFF453A) 
                : const Color(0xFF30D158),
            size: 10,
            active: _isRecording,
          ),
          const SizedBox(width: 10),
          Text(
            _isRecording 
                ? 'REC' 
                : _isSending 
                    ? 'Sending...'
                    : 'Ready',
            style: TextStyle(
              color: _isRecording 
                  ? const Color(0xFFFF453A) 
                  : Colors.white.withOpacity(0.6),
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }
}

/// Custom painter for waveform visualization
class _WaveformPainter extends CustomPainter {
  final List<double> waveformData;
  final Color color;
  final double barWidth;

  _WaveformPainter({
    required this.waveformData,
    required this.color,
    this.barWidth = 3,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = barWidth
      ..strokeCap = StrokeCap.round;

    final gap = 2.0;
    final totalBars = waveformData.length;
    final barSpace = (size.width - (totalBars - 1) * gap) / totalBars;
    final centerY = size.height / 2;

    for (int i = 0; i < totalBars; i++) {
      final x = i * (barSpace + gap) + barSpace / 2;
      final amplitude = waveformData[i].clamp(0.0, 1.0);
      final barHeight = amplitude * (size.height * 0.75);
      
      // Add subtle gradient effect by varying opacity
      paint.color = color.withOpacity(0.5 + amplitude * 0.5);
      
      canvas.drawLine(
        Offset(x, centerY - barHeight / 2),
        Offset(x, centerY + barHeight / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) => true;
}
