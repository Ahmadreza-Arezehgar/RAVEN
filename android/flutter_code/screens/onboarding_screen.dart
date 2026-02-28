import 'dart:ui';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/ios_design_system.dart';

/// Onboarding data model
class OnboardingSlide {
  final String title;
  final String description;
  final IconData icon;
  final Color accentColor;
  final Widget Function(Animation<double> animation) animationBuilder;

  const OnboardingSlide({
    required this.title,
    required this.description,
    required this.icon,
    required this.accentColor,
    required this.animationBuilder,
  });
}

/// Professional Onboarding Screen with 4 feature slides
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with TickerProviderStateMixin {
  late PageController _pageController;
  late AnimationController _iconAnimationController;
  int _currentPage = 0;

  final List<OnboardingSlide> _slides = [
    OnboardingSlide(
      title: 'Offline Messaging',
      description:
          'Send messages even without internet. Raven stores them securely and delivers automatically when connection returns.',
      icon: Icons.wifi_off_rounded,
      accentColor: const Color(0xFF0A84FF),
      animationBuilder: (animation) => _OfflineAnimation(animation: animation),
    ),
    OnboardingSlide(
      title: 'Secure & Private',
      description:
          'End-to-end encryption, device-level protection, and privacy controls designed for real life.',
      icon: Icons.lock_rounded,
      accentColor: const Color(0xFF34C759),
      animationBuilder: (animation) => _SecureAnimation(animation: animation),
    ),
    OnboardingSlide(
      title: 'Fast & Simple',
      description:
          'Clean UI, easy navigation, and everything where you expect it — no complexity.',
      icon: Icons.flash_on_rounded,
      accentColor: const Color(0xFFFF9500),
      animationBuilder: (animation) => _SimpleAnimation(animation: animation),
    ),
    OnboardingSlide(
      title: 'Mesh Mode',
      description:
          'Connect to nearby people via Bluetooth mesh when the network is down — and switch automatically between offline and online.',
      icon: Icons.hub_rounded,
      accentColor: const Color(0xFFAF52DE),
      animationBuilder: (animation) => _MeshAnimation(animation: animation),
    ),
  ];

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _iconAnimationController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _iconAnimationController.dispose();
    super.dispose();
  }

  Future<void> _completeOnboarding() async {
    HapticFeedback.mediumImpact();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('hasSeenOnboarding', true);
    if (mounted) {
      Navigator.of(context).pushReplacementNamed('/welcome');
    }
  }

  void _nextPage() {
    HapticFeedback.lightImpact();
    if (_currentPage < _slides.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeOutCubic,
      );
    } else {
      _completeOnboarding();
    }
  }

  void _skipOnboarding() {
    HapticFeedback.lightImpact();
    _completeOnboarding();
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      backgroundColor: iOSDesignSystem.baseBackground,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF0D0D12),
              Color(0xFF1A1A2E),
              Color(0xFF0D0D12),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Skip button
              Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextButton(
                    onPressed: _skipOnboarding,
                    child: Text(
                      'Skip',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.6),
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),

              // Page content
              Expanded(
                child: PageView.builder(
                  controller: _pageController,
                  onPageChanged: (index) {
                    setState(() => _currentPage = index);
                    HapticFeedback.selectionClick();
                  },
                  itemCount: _slides.length,
                  itemBuilder: (context, index) {
                    return _OnboardingPage(
                      slide: _slides[index],
                      animation: _iconAnimationController,
                    );
                  },
                ),
              ),

              // Bottom section
              Padding(
                padding: EdgeInsets.fromLTRB(24, 16, 24, bottomPadding + 24),
                child: Column(
                  children: [
                    // Page indicators
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(
                        _slides.length,
                        (index) => AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          width: _currentPage == index ? 24 : 8,
                          height: 8,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            color: _currentPage == index
                                ? _slides[_currentPage].accentColor
                                : Colors.white.withOpacity(0.3),
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 32),

                    // Continue / Get Started button
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: _LiquidGlassButton(
                        onPressed: _nextPage,
                        accentColor: _slides[_currentPage].accentColor,
                        child: Text(
                          _currentPage == _slides.length - 1
                              ? 'Get Started'
                              : 'Continue',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
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

/// Single onboarding page
class _OnboardingPage extends StatelessWidget {
  final OnboardingSlide slide;
  final Animation<double> animation;

  const _OnboardingPage({
    required this.slide,
    required this.animation,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Animated icon container
          Container(
            width: 200,
            height: 200,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(40),
              boxShadow: [
                BoxShadow(
                  color: slide.accentColor.withOpacity(0.3),
                  blurRadius: 60,
                  spreadRadius: 10,
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(40),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(40),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.15),
                      width: 1,
                    ),
                  ),
                  child: slide.animationBuilder(animation),
                ),
              ),
            ),
          ),

          const SizedBox(height: 48),

          // Title
          Text(
            slide.title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              letterSpacing: -0.5,
            ),
          ),

          const SizedBox(height: 16),

          // Description
          Text(
            slide.description,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w400,
              color: Colors.white.withOpacity(0.7),
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Liquid Glass Button
class _LiquidGlassButton extends StatelessWidget {
  final VoidCallback onPressed;
  final Color accentColor;
  final Widget child;

  const _LiquidGlassButton({
    required this.onPressed,
    required this.accentColor,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              accentColor,
              accentColor.withOpacity(0.8),
            ],
          ),
          boxShadow: [
            BoxShadow(
              color: accentColor.withOpacity(0.4),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: Colors.white.withOpacity(0.2),
                  width: 1,
                ),
                borderRadius: BorderRadius.circular(28),
              ),
              alignment: Alignment.center,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// CUSTOM ANIMATIONS FOR EACH SLIDE
// ============================================================

/// Slide 1: Offline Animation - Radar waves
class _OfflineAnimation extends StatelessWidget {
  final Animation<double> animation;

  const _OfflineAnimation({required this.animation});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        return Stack(
          alignment: Alignment.center,
          children: [
            // Radar waves
            for (int i = 0; i < 3; i++)
              Opacity(
                opacity: ((1 - ((animation.value + i * 0.33) % 1)) * 0.5),
                child: Transform.scale(
                  scale: 0.3 + ((animation.value + i * 0.33) % 1) * 0.7,
                  child: Container(
                    width: 160,
                    height: 160,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(0xFF0A84FF),
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ),
            // Center icon
            Icon(
              Icons.wifi_off_rounded,
              size: 60,
              color: Colors.white.withOpacity(0.9),
            ),
          ],
        );
      },
    );
  }
}

/// Slide 2: Secure Animation - Lock pulse
class _SecureAnimation extends StatelessWidget {
  final Animation<double> animation;

  const _SecureAnimation({required this.animation});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final pulse = math.sin(animation.value * 2 * math.pi) * 0.1 + 1;
        return Stack(
          alignment: Alignment.center,
          children: [
            // Shield glow
            Opacity(
              opacity: 0.3 + math.sin(animation.value * 2 * math.pi) * 0.2,
              child: Container(
                width: 140,
                height: 140,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      const Color(0xFF34C759).withOpacity(0.5),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            // Lock icon with pulse
            Transform.scale(
              scale: pulse,
              child: Icon(
                Icons.shield_rounded,
                size: 80,
                color: Colors.white.withOpacity(0.9),
              ),
            ),
            // Small lock overlay
            Transform.translate(
              offset: const Offset(0, 5),
              child: Icon(
                Icons.lock_rounded,
                size: 32,
                color: const Color(0xFF34C759),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Slide 3: Simple Animation - Floating cards
class _SimpleAnimation extends StatelessWidget {
  final Animation<double> animation;

  const _SimpleAnimation({required this.animation});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        return Stack(
          alignment: Alignment.center,
          children: [
            // Floating cards
            for (int i = 0; i < 3; i++)
              Transform.translate(
                offset: Offset(
                  math.sin(animation.value * 2 * math.pi + i * 2) * 10,
                  math.cos(animation.value * 2 * math.pi + i * 2) * 8 -
                      (i * 15),
                ),
                child: Transform.rotate(
                  angle: (i - 1) * 0.1,
                  child: Container(
                    width: 100 - i * 10,
                    height: 60 - i * 5,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.15 - i * 0.03),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.1),
                        width: 1,
                      ),
                    ),
                  ),
                ),
              ),
            // Flash icon
            Icon(
              Icons.flash_on_rounded,
              size: 50,
              color: const Color(0xFFFF9500),
            ),
          ],
        );
      },
    );
  }
}

/// Slide 4: Mesh Animation - Connected nodes
class _MeshAnimation extends StatelessWidget {
  final Animation<double> animation;

  const _MeshAnimation({required this.animation});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final nodes = [
          Offset(0, -50),
          Offset(-50, 20),
          Offset(50, 20),
          Offset(-25, 50),
          Offset(25, 50),
        ];

        return CustomPaint(
          painter: _MeshPainter(
            nodes: nodes,
            animation: animation.value,
            color: const Color(0xFFAF52DE),
          ),
          child: Center(
            child: Icon(
              Icons.hub_rounded,
              size: 50,
              color: Colors.white.withOpacity(0.9),
            ),
          ),
        );
      },
    );
  }
}

class _MeshPainter extends CustomPainter {
  final List<Offset> nodes;
  final double animation;
  final Color color;

  _MeshPainter({
    required this.nodes,
    required this.animation,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..color = color.withOpacity(0.6)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final nodePaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    // Draw connections with animation
    for (int i = 0; i < nodes.length; i++) {
      final nodePos = center + nodes[i];
      for (int j = i + 1; j < nodes.length; j++) {
        final otherPos = center + nodes[j];
        final progress = ((animation * 2 + i * 0.2) % 1);
        paint.color = color.withOpacity(0.3 + progress * 0.3);
        canvas.drawLine(nodePos, otherPos, paint);
      }
    }

    // Draw nodes
    for (int i = 0; i < nodes.length; i++) {
      final nodePos = center + nodes[i];
      final pulse = math.sin(animation * 2 * math.pi + i) * 2 + 8;
      canvas.drawCircle(nodePos, pulse, nodePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _MeshPainter oldDelegate) => true;
}
