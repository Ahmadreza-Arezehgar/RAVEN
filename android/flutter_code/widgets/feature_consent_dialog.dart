import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// FeatureConsentDialog - Apple Liquid Glass style consent dialog
/// 
/// Used for first-time consent prompts for:
/// - Mesh Networking (BLE data sharing)
/// - Gemini AI (third-party AI access)
/// 
/// Features:
/// - Capsule-shaped Liquid Glass design
/// - Animated fade-in with scale
/// - Clear Allow/Don't Allow buttons
/// - Feature icon and description
class FeatureConsentDialog extends StatefulWidget {
  final String title;
  final String description;
  final IconData icon;
  final Color iconColor;
  final String allowText;
  final String denyText;
  final List<String>? bulletPoints;

  const FeatureConsentDialog({
    super.key,
    required this.title,
    required this.description,
    required this.icon,
    this.iconColor = const Color(0xFF0A84FF),
    this.allowText = 'Allow',
    this.denyText = "Don't Allow",
    this.bulletPoints,
  });

  @override
  State<FeatureConsentDialog> createState() => _FeatureConsentDialogState();
}

class _FeatureConsentDialogState extends State<FeatureConsentDialog>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 350),
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    _scaleAnimation = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleResponse(bool allowed) {
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop(allowed);
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: ScaleTransition(
        scale: _scaleAnimation,
        child: Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 340),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E).withOpacity(0.85),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.12),
                    width: 0.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.35),
                      blurRadius: 32,
                      offset: const Offset(0, 16),
                    ),
                  ],
                ),
                child: Stack(
                  children: [
                    // Sheen highlight
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(28),
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Colors.white.withOpacity(0.08),
                                Colors.transparent,
                                Colors.black.withOpacity(0.05),
                              ],
                              stops: const [0.0, 0.5, 1.0],
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Content
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Icon with glow
                          Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  widget.iconColor.withOpacity(0.35),
                                  widget.iconColor.withOpacity(0.15),
                                ],
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: widget.iconColor.withOpacity(0.3),
                                  blurRadius: 20,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                            ),
                            child: Icon(
                              widget.icon,
                              size: 32,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 20),

                          // Title
                          Text(
                            widget.title,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              letterSpacing: -0.4,
                            ),
                          ),
                          const SizedBox(height: 12),

                          // Description
                          Text(
                            widget.description,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.75),
                              fontSize: 15,
                              height: 1.4,
                            ),
                          ),

                          // Bullet points (optional)
                          if (widget.bulletPoints != null) ...[
                            const SizedBox(height: 16),
                            Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.06),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: widget.bulletPoints!.map((point) {
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 3),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Container(
                                          margin: const EdgeInsets.only(top: 7),
                                          width: 5,
                                          height: 5,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: widget.iconColor,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            point,
                                            style: TextStyle(
                                              color: Colors.white.withOpacity(0.7),
                                              fontSize: 13,
                                              height: 1.35,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                          ],

                          const SizedBox(height: 24),

                          // Buttons
                          Column(
                            children: [
                              // Allow button (primary)
                              SizedBox(
                                width: double.infinity,
                                height: 50,
                                child: ElevatedButton(
                                  onPressed: () => _handleResponse(true),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: widget.iconColor,
                                    foregroundColor: Colors.white,
                                    elevation: 0,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                  ),
                                  child: Text(
                                    widget.allowText,
                                    style: const TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),

                              // Don't Allow button (secondary)
                              SizedBox(
                                width: double.infinity,
                                height: 50,
                                child: TextButton(
                                  onPressed: () => _handleResponse(false),
                                  style: TextButton.styleFrom(
                                    foregroundColor: Colors.white.withOpacity(0.9),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    backgroundColor: Colors.white.withOpacity(0.08),
                                  ),
                                  child: Text(
                                    widget.denyText,
                                    style: const TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// HELPER FUNCTIONS
// ═══════════════════════════════════════════════════════════════════════════════

/// Show Mesh Networking consent dialog
Future<bool?> showMeshConsentDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black.withOpacity(0.6),
    builder: (context) => const FeatureConsentDialog(
      title: 'Mesh Networking',
      description:
          'RAVEN uses Bluetooth to send messages when you\'re offline. Messages are encrypted and relayed through nearby devices.',
      icon: Icons.wifi_tethering,
      iconColor: Color(0xFF30D158), // Green
      bulletPoints: [
        'Messages are end-to-end encrypted',
        'Only metadata is shared for routing',
        'Works without internet connection',
        'You can disable this anytime in Settings',
      ],
    ),
  );
}

/// Show Gemini AI consent dialog
Future<bool?> showGeminiConsentDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black.withOpacity(0.6),
    builder: (context) => const FeatureConsentDialog(
      title: 'AI Assistant',
      description:
          'RAVEN can use Google Gemini AI to help answer your questions when you mention @time_ask.',
      icon: Icons.auto_awesome,
      iconColor: Color(0xFF5E5CE6), // Purple
      bulletPoints: [
        'Your message content is sent to Google Gemini',
        'Responses are generated by AI',
        'Google may store data per their privacy policy',
        'You can disable this anytime in Settings',
      ],
    ),
  );
}
