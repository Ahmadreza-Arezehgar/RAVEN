import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';

/// Apple Liquid Glass Animation Utilities
/// 
/// Provides premium animation components inspired by iOS 18 design language:
/// - Staggered list animations
/// - Glassmorphism with animated gradients
/// - Spring physics animations
/// - Particle mesh effects
/// - Shimmer loading states
/// - Glow pulse effects

// ═══════════════════════════════════════════════════════════════════════════
// SPRING CURVES
// ═══════════════════════════════════════════════════════════════════════════

/// Apple-style spring curve with configurable damping
class AppleSpringCurve extends Curve {
  final double damping;
  final double stiffness;
  
  const AppleSpringCurve({
    this.damping = 0.7,
    this.stiffness = 300,
  });

  @override
  double transformInternal(double t) {
    final omega = sqrt(stiffness);
    final zeta = damping;
    final decay = exp(-zeta * omega * t);
    return 1 - decay * cos(omega * sqrt(1 - zeta * zeta) * t);
  }
}

/// Predefined spring curves
class AppleCurves {
  static const bouncy = AppleSpringCurve(damping: 0.6, stiffness: 400);
  static const smooth = AppleSpringCurve(damping: 0.8, stiffness: 300);
  static const snappy = AppleSpringCurve(damping: 0.9, stiffness: 500);
  static const gentle = AppleSpringCurve(damping: 0.85, stiffness: 200);
}

// ═══════════════════════════════════════════════════════════════════════════
// STAGGERED LIST ANIMATION
// ═══════════════════════════════════════════════════════════════════════════

/// Animates list items with staggered entrance
class StaggeredListItem extends StatefulWidget {
  final Widget child;
  final int index;
  final Duration delay;
  final Duration duration;
  final Curve curve;
  final Offset slideOffset;
  
  const StaggeredListItem({
    super.key,
    required this.child,
    required this.index,
    this.delay = const Duration(milliseconds: 50),
    this.duration = const Duration(milliseconds: 400),
    this.curve = Curves.easeOutCubic,
    this.slideOffset = const Offset(0, 30),
  });

  @override
  State<StaggeredListItem> createState() => _StaggeredListItemState();
}

class _StaggeredListItemState extends State<StaggeredListItem>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: widget.duration,
      vsync: this,
    );
    
    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: widget.curve),
    );
    
    _slideAnimation = Tween<Offset>(
      begin: widget.slideOffset,
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: widget.curve));
    
    _scaleAnimation = Tween<double>(begin: 0.95, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: widget.curve),
    );
    
    // Staggered delay based on index
    Future.delayed(widget.delay * widget.index, () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Transform.translate(
        offset: _slideAnimation.value,
        child: Transform.scale(
          scale: _scaleAnimation.value,
          child: Opacity(
            opacity: _fadeAnimation.value,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// LIQUID GLASS CONTAINER
// ═══════════════════════════════════════════════════════════════════════════

/// Premium glassmorphism container with animated gradient
class LiquidGlassContainer extends StatefulWidget {
  final Widget child;
  final double blur;
  final double borderRadius;
  final Color? tintColor;
  final bool animateGradient;
  final EdgeInsets padding;
  final bool hasBorder;
  final bool hasGlow;
  
  const LiquidGlassContainer({
    super.key,
    required this.child,
    this.blur = 20,
    this.borderRadius = 20,
    this.tintColor,
    this.animateGradient = false,
    this.padding = const EdgeInsets.all(16),
    this.hasBorder = true,
    this.hasGlow = false,
  });

  @override
  State<LiquidGlassContainer> createState() => _LiquidGlassContainerState();
}

class _LiquidGlassContainerState extends State<LiquidGlassContainer>
    with SingleTickerProviderStateMixin {
  late AnimationController _gradientController;
  
  @override
  void initState() {
    super.initState();
    _gradientController = AnimationController(
      duration: const Duration(seconds: 3),
      vsync: this,
    );
    
    if (widget.animateGradient) {
      _gradientController.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _gradientController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _gradientController,
      builder: (context, child) {
        final gradientOffset = widget.animateGradient 
            ? _gradientController.value * 0.3 
            : 0.0;
        
        return Container(
          decoration: widget.hasGlow ? BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            boxShadow: [
              BoxShadow(
                color: (widget.tintColor ?? const Color(0xFF0A84FF))
                    .withOpacity(0.15),
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ],
          ) : null,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: widget.blur,
                sigmaY: widget.blur,
              ),
              child: Container(
                padding: widget.padding,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(widget.borderRadius),
                  gradient: LinearGradient(
                    begin: Alignment(-1 + gradientOffset, -1),
                    end: Alignment(1 + gradientOffset, 1),
                    colors: [
                      (widget.tintColor ?? const Color(0xFF1C1C1E))
                          .withOpacity(0.7),
                      (widget.tintColor ?? const Color(0xFF1C1C1E))
                          .withOpacity(0.5),
                    ],
                  ),
                  border: widget.hasBorder ? Border.all(
                    color: Colors.white.withOpacity(0.12),
                    width: 0.5,
                  ) : null,
                ),
                child: widget.child,
              ),
            ),
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SHIMMER LOADING EFFECT
// ═══════════════════════════════════════════════════════════════════════════

/// Apple-style shimmer loading effect
class ShimmerLoading extends StatefulWidget {
  final double width;
  final double height;
  final double borderRadius;
  
  const ShimmerLoading({
    super.key,
    this.width = double.infinity,
    this.height = 60,
    this.borderRadius = 12,
  });

  @override
  State<ShimmerLoading> createState() => _ShimmerLoadingState();
}

class _ShimmerLoadingState extends State<ShimmerLoading>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            gradient: LinearGradient(
              begin: Alignment(-1 + _controller.value * 2, 0),
              end: Alignment(_controller.value * 2, 0),
              colors: [
                Colors.white.withOpacity(0.05),
                Colors.white.withOpacity(0.15),
                Colors.white.withOpacity(0.05),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// GLOW PULSE EFFECT
// ═══════════════════════════════════════════════════════════════════════════

/// Animated glow pulse for status indicators
class GlowPulse extends StatefulWidget {
  final Color color;
  final double size;
  final bool active;
  
  const GlowPulse({
    super.key,
    required this.color,
    this.size = 12,
    this.active = true,
  });

  @override
  State<GlowPulse> createState() => _GlowPulseState();
}

class _GlowPulseState extends State<GlowPulse>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _pulseAnimation;
  
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    
    _pulseAnimation = Tween<double>(begin: 0.4, end: 0.8).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
    
    if (widget.active) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(GlowPulse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (context, _) => Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
          boxShadow: widget.active ? [
            BoxShadow(
              color: widget.color.withOpacity(_pulseAnimation.value),
              blurRadius: 12,
              spreadRadius: 2,
            ),
          ] : null,
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// MESH PARTICLE BACKGROUND
// ═══════════════════════════════════════════════════════════════════════════

/// Animated mesh particle network background
class MeshParticleBackground extends StatefulWidget {
  final Color color;
  final int particleCount;
  
  const MeshParticleBackground({
    super.key,
    this.color = const Color(0xFF0A84FF),
    this.particleCount = 20,
  });

  @override
  State<MeshParticleBackground> createState() => _MeshParticleBackgroundState();
}

class _MeshParticleBackgroundState extends State<MeshParticleBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late List<_Particle> _particles;
  final Random _random = Random();
  
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 10),
      vsync: this,
    )..repeat();
    
    _particles = List.generate(widget.particleCount, (_) => _Particle(
      x: _random.nextDouble(),
      y: _random.nextDouble(),
      vx: (_random.nextDouble() - 0.5) * 0.002,
      vy: (_random.nextDouble() - 0.5) * 0.002,
      size: _random.nextDouble() * 3 + 1,
    ));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        // Update particle positions
        for (final p in _particles) {
          p.x += p.vx;
          p.y += p.vy;
          
          // Wrap around
          if (p.x < 0) p.x = 1;
          if (p.x > 1) p.x = 0;
          if (p.y < 0) p.y = 1;
          if (p.y > 1) p.y = 0;
        }
        
        return CustomPaint(
          painter: _MeshParticlePainter(
            particles: _particles,
            color: widget.color,
          ),
          size: Size.infinite,
        );
      },
    );
  }
}

class _Particle {
  double x, y, vx, vy, size;
  _Particle({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.size,
  });
}

class _MeshParticlePainter extends CustomPainter {
  final List<_Particle> particles;
  final Color color;
  
  _MeshParticlePainter({required this.particles, required this.color});
  
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withOpacity(0.6)
      ..strokeWidth = 0.5;
    
    final dotPaint = Paint()
      ..color = color.withOpacity(0.8);
    
    // Draw connections between nearby particles
    for (int i = 0; i < particles.length; i++) {
      final p1 = particles[i];
      
      // Draw particle
      canvas.drawCircle(
        Offset(p1.x * size.width, p1.y * size.height),
        p1.size,
        dotPaint,
      );
      
      // Draw connections
      for (int j = i + 1; j < particles.length; j++) {
        final p2 = particles[j];
        final dx = (p1.x - p2.x) * size.width;
        final dy = (p1.y - p2.y) * size.height;
        final distance = sqrt(dx * dx + dy * dy);
        
        if (distance < 100) {
          paint.color = color.withOpacity(0.3 * (1 - distance / 100));
          canvas.drawLine(
            Offset(p1.x * size.width, p1.y * size.height),
            Offset(p2.x * size.width, p2.y * size.height),
            paint,
          );
        }
      }
    }
  }
  
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// ═══════════════════════════════════════════════════════════════════════════
// SCALE TAP ANIMATION
// ═══════════════════════════════════════════════════════════════════════════

/// Widget that scales down on tap for tactile feedback
class ScaleTap extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double scaleDown;
  
  const ScaleTap({
    super.key,
    required this.child,
    this.onTap,
    this.scaleDown = 0.97,
  });

  @override
  State<ScaleTap> createState() => _ScaleTapState();
}

class _ScaleTapState extends State<ScaleTap>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 100),
      vsync: this,
    );
    
    _scaleAnimation = Tween<double>(begin: 1.0, end: widget.scaleDown).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
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
        widget.onTap?.call();
      },
      onTapCancel: () => _controller.reverse(),
      child: AnimatedBuilder(
        animation: _scaleAnimation,
        builder: (context, child) => Transform.scale(
          scale: _scaleAnimation.value,
          child: widget.child,
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// ANIMATED GRADIENT BORDER
// ═══════════════════════════════════════════════════════════════════════════

/// Container with animated gradient border
class AnimatedGradientBorder extends StatefulWidget {
  final Widget child;
  final double borderRadius;
  final double borderWidth;
  final List<Color> colors;
  
  const AnimatedGradientBorder({
    super.key,
    required this.child,
    this.borderRadius = 20,
    this.borderWidth = 2,
    this.colors = const [
      Color(0xFF0A84FF),
      Color(0xFFBF5AF2),
      Color(0xFFFF375F),
      Color(0xFFFF9F0A),
      Color(0xFF30D158),
      Color(0xFF0A84FF),
    ],
  });

  @override
  State<AnimatedGradientBorder> createState() => _AnimatedGradientBorderState();
}

class _AnimatedGradientBorderState extends State<AnimatedGradientBorder>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 3),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            gradient: SweepGradient(
              center: Alignment.center,
              startAngle: _controller.value * 2 * pi,
              endAngle: _controller.value * 2 * pi + 2 * pi,
              colors: widget.colors,
            ),
          ),
          child: Container(
            margin: EdgeInsets.all(widget.borderWidth),
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E),
              borderRadius: BorderRadius.circular(
                widget.borderRadius - widget.borderWidth,
              ),
            ),
            child: widget.child,
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// FLOATING ICON ANIMATION
// ═══════════════════════════════════════════════════════════════════════════

/// Icon that floats up and down
class FloatingIcon extends StatefulWidget {
  final IconData icon;
  final double size;
  final Color color;
  
  const FloatingIcon({
    super.key,
    required this.icon,
    this.size = 64,
    this.color = Colors.white,
  });

  @override
  State<FloatingIcon> createState() => _FloatingIconState();
}

class _FloatingIconState extends State<FloatingIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _floatAnimation;
  
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat(reverse: true);
    
    _floatAnimation = Tween<double>(begin: -5, end: 5).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _floatAnimation,
      builder: (context, _) => Transform.translate(
        offset: Offset(0, _floatAnimation.value),
        child: Icon(
          widget.icon,
          size: widget.size,
          color: widget.color,
        ),
      ),
    );
  }
}
