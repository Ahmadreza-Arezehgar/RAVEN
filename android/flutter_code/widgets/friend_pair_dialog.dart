import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Friend Pair Dialog - Liquid Glass approval panel for incoming friend requests
/// Shows when someone scans our QR and sends a FRIEND_PAIR_REQUEST
class FriendPairDialog extends StatefulWidget {
  final String requesterUsername;
  final String requesterUserId;
  final String requesterFingerprint;
  final String? requesterAvatarUrl;
  final Function(bool accepted) onResponse;
  
  const FriendPairDialog({
    super.key,
    required this.requesterUsername,
    required this.requesterUserId,
    required this.requesterFingerprint,
    this.requesterAvatarUrl,
    required this.onResponse,
  });

  @override
  State<FriendPairDialog> createState() => _FriendPairDialogState();

  /// Show the dialog as an overlay
  static Future<bool?> show({
    required BuildContext context,
    required String requesterUsername,
    required String requesterUserId,
    required String requesterFingerprint,
    String? requesterAvatarUrl,
  }) async {
    return await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'Friend Request',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, anim1, anim2) {
        return FriendPairDialog(
          requesterUsername: requesterUsername,
          requesterUserId: requesterUserId,
          requesterFingerprint: requesterFingerprint,
          requesterAvatarUrl: requesterAvatarUrl,
          onResponse: (accepted) {
            Navigator.of(context).pop(accepted);
          },
        );
      },
      transitionBuilder: (context, anim1, anim2, child) {
        return ScaleTransition(
          scale: CurvedAnimation(
            parent: anim1,
            curve: Curves.easeOutBack,
          ),
          child: FadeTransition(
            opacity: anim1,
            child: child,
          ),
        );
      },
    );
  }
}

class _FriendPairDialogState extends State<FriendPairDialog> 
    with SingleTickerProviderStateMixin {
  Timer? _autoDeclineTimer;
  int _remainingSeconds = 30;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    
    // Auto-decline after 30 seconds
    _autoDeclineTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_remainingSeconds <= 1) {
        timer.cancel();
        HapticFeedback.mediumImpact();
        widget.onResponse(false);
      } else {
        setState(() => _remainingSeconds--);
      }
    });
    
    HapticFeedback.heavyImpact();
  }

  @override
  void dispose() {
    _autoDeclineTimer?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  void _handleAccept() {
    HapticFeedback.heavyImpact();
    _autoDeclineTimer?.cancel();
    widget.onResponse(true);
  }

  void _handleDecline() {
    HapticFeedback.mediumImpact();
    _autoDeclineTimer?.cancel();
    widget.onResponse(false);
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: ScaleTransition(
          scale: _pulseAnimation,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withOpacity(0.2),
                      Colors.white.withOpacity(0.08),
                    ],
                  ),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.25),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 30,
                      offset: const Offset(0, 15),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Header icon
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            const Color(0xFF30D158).withOpacity(0.3),
                            const Color(0xFF30D158).withOpacity(0.1),
                          ],
                        ),
                        border: Border.all(
                          color: const Color(0xFF30D158).withOpacity(0.4),
                          width: 2,
                        ),
                      ),
                      child: widget.requesterAvatarUrl != null
                          ? ClipOval(
                              child: Image.network(
                                widget.requesterAvatarUrl!,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => _buildDefaultAvatar(),
                              ),
                            )
                          : _buildDefaultAvatar(),
                    ),
                    
                    const SizedBox(height: 20),
                    
                    // Title
                    const Text(
                      'Friend Request',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    
                    const SizedBox(height: 12),
                    
                    // Message
                    RichText(
                      textAlign: TextAlign.center,
                      text: TextSpan(
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.8),
                          fontSize: 16,
                          height: 1.4,
                        ),
                        children: [
                          TextSpan(
                            text: '@${widget.requesterUsername}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF0A84FF),
                            ),
                          ),
                          const TextSpan(text: ' wants to add you as a friend'),
                        ],
                      ),
                    ),
                    
                    const SizedBox(height: 16),
                    
                    // Fingerprint badge
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.fingerprint,
                            color: Colors.white.withOpacity(0.6),
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            widget.requesterFingerprint.length > 8
                                ? widget.requesterFingerprint.substring(0, 8).toUpperCase()
                                : widget.requesterFingerprint.toUpperCase(),
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.6),
                              fontSize: 12,
                              fontFamily: 'monospace',
                              letterSpacing: 1,
                            ),
                          ),
                        ],
                      ),
                    ),
                    
                    const SizedBox(height: 8),
                    
                    // Timer
                    Text(
                      'Auto-decline in ${_remainingSeconds}s',
                      style: TextStyle(
                        color: _remainingSeconds <= 10
                            ? const Color(0xFFFF9500)
                            : Colors.white.withOpacity(0.4),
                        fontSize: 12,
                      ),
                    ),
                    
                    const SizedBox(height: 24),
                    
                    // Buttons
                    Row(
                      children: [
                        // Decline button
                        Expanded(
                          child: GestureDetector(
                            onTap: _handleDecline,
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFF3B30).withOpacity(0.15),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: const Color(0xFFFF3B30).withOpacity(0.3),
                                ),
                              ),
                              child: const Center(
                                child: Text(
                                  'Decline',
                                  style: TextStyle(
                                    color: Color(0xFFFF3B30),
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        
                        const SizedBox(width: 12),
                        
                        // Accept button
                        Expanded(
                          child: GestureDetector(
                            onTap: _handleAccept,
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [Color(0xFF30D158), Color(0xFF28B24C)],
                                ),
                                borderRadius: BorderRadius.circular(14),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFF30D158).withOpacity(0.3),
                                    blurRadius: 12,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: const Center(
                                child: Text(
                                  'Accept',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
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
      ),
    );
  }

  Widget _buildDefaultAvatar() {
    return Center(
      child: Text(
        widget.requesterUsername.isNotEmpty
            ? widget.requesterUsername[0].toUpperCase()
            : '?',
        style: const TextStyle(
          color: Color(0xFF30D158),
          fontSize: 28,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
