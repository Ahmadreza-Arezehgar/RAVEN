import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../services/qr_friend_service.dart';

/// Scan QR Code Screen - Camera-based QR scanning for friend pairing
/// Verifies signature and initiates Bluetooth mesh handshake
class ScanQrScreen extends StatefulWidget {
  const ScanQrScreen({super.key});

  @override
  State<ScanQrScreen> createState() => _ScanQrScreenState();
}

class _ScanQrScreenState extends State<ScanQrScreen> with SingleTickerProviderStateMixin {
  final MobileScannerController _cameraController = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
    torchEnabled: false,
  );

  bool _isProcessing = false;
  String? _statusMessage;
  bool _isSuccess = false;
  bool _isError = false;
  
  late AnimationController _animController;
  late Animation<double> _scanLineAnimation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    
    _scanLineAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _cameraController.dispose();
    _animController.dispose();
    super.dispose();
  }

  Future<void> _onQrDetected(BarcodeCapture capture) async {
    if (_isProcessing) return;

    for (final barcode in capture.barcodes) {
      final rawValue = barcode.rawValue;
      if (rawValue == null || rawValue.isEmpty) continue;

      setState(() {
        _isProcessing = true;
        _statusMessage = 'Verifying QR code...';
        _isError = false;
        _isSuccess = false;
      });

      HapticFeedback.mediumImpact();

      try {
        // Parse and verify QR payload
        final qrService = QrFriendService.instance;
        final payload = await qrService.parseAndVerifyQrPayload(rawValue);

        setState(() {
          _statusMessage = 'Connecting to @${payload.username}...';
        });

        // Get current user
        final model = context.read<AppModel>();
        final currentUser = model.currentUser;
        
        if (currentUser == null) {
          throw Exception('Not logged in');
        }

        // Check if this is ourselves
        if (payload.userId == currentUser.id) {
          throw QrValidationException("You can't add yourself as a friend");
        }

        setState(() {
          _statusMessage = 'Connecting via Bluetooth...';
        });

        // Send friend pair request via Bluetooth mesh
        // This now handles: addTrustedPeer → restart → wait for connection → send
        final sent = await qrService.sendFriendPairRequest(
          myUserId: currentUser.id,
          myUsername: currentUser.username,
          targetPayload: payload,
        );

        if (!sent) {
          throw Exception('Could not connect. Make sure both devices have Bluetooth enabled and are nearby.');
        }

        setState(() {
          _statusMessage = 'Request sent to @${payload.username}!\nWaiting for acceptance...';
          _isSuccess = true;
        });

        HapticFeedback.heavyImpact();

        // Wait a moment then pop back
        await Future.delayed(const Duration(seconds: 2));
        
        if (mounted) {
          Navigator.pop(context, {
            'success': true,
            'payload': payload,
          });
        }
      } on QrValidationException catch (e) {
        print('❌ [ScanQrScreen] Validation error: ${e.message}');
        HapticFeedback.heavyImpact();
        
        setState(() {
          _statusMessage = e.message;
          _isError = true;
          _isProcessing = false;
        });

        // Reset after delay to allow retry
        await Future.delayed(const Duration(seconds: 3));
        if (mounted) {
          setState(() {
            _statusMessage = null;
            _isError = false;
          });
        }
      } catch (e) {
        print('❌ [ScanQrScreen] Error: $e');
        HapticFeedback.heavyImpact();
        
        setState(() {
          _statusMessage = 'Failed: $e';
          _isError = true;
          _isProcessing = false;
        });

        await Future.delayed(const Duration(seconds: 3));
        if (mounted) {
          setState(() {
            _statusMessage = null;
            _isError = false;
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final scanAreaSize = size.width * 0.7;

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Scan QR Code',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: true,
        actions: [
          // Torch toggle
          IconButton(
            icon: ValueListenableBuilder(
              valueListenable: _cameraController,
              builder: (context, state, child) {
                return Icon(
                  state.torchState == TorchState.on
                      ? Icons.flash_on
                      : Icons.flash_off,
                  color: Colors.white,
                );
              },
            ),
            onPressed: () => _cameraController.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        children: [
          // Camera preview
          MobileScanner(
            controller: _cameraController,
            onDetect: _onQrDetected,
          ),
          
          // Scan overlay
          _buildScanOverlay(scanAreaSize),
          
          // Status message
          if (_statusMessage != null)
            Positioned(
              bottom: 120,
              left: 24,
              right: 24,
              child: _buildStatusBanner(),
            ),
          
          // Bottom instructions
          Positioned(
            bottom: 48,
            left: 24,
            right: 24,
            child: _buildInstructions(),
          ),
        ],
      ),
    );
  }

  Widget _buildScanOverlay(double scanAreaSize) {
    return Stack(
      children: [
        // Dark overlay with cutout
        ColorFiltered(
          colorFilter: ColorFilter.mode(
            Colors.black.withOpacity(0.6),
            BlendMode.srcOut,
          ),
          child: Stack(
            children: [
              Container(
                decoration: const BoxDecoration(
                  color: Colors.transparent,
                  backgroundBlendMode: BlendMode.dstOut,
                ),
              ),
              Center(
                child: Container(
                  width: scanAreaSize,
                  height: scanAreaSize,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
              ),
            ],
          ),
        ),
        
        // Scan area border
        Center(
          child: Container(
            width: scanAreaSize,
            height: scanAreaSize,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: _isSuccess
                    ? const Color(0xFF30D158)
                    : _isError
                        ? const Color(0xFFFF3B30)
                        : Colors.white.withOpacity(0.5),
                width: 2,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: Stack(
                children: [
                  // Animated scan line
                  if (!_isProcessing || (!_isSuccess && !_isError))
                    AnimatedBuilder(
                      animation: _scanLineAnimation,
                      builder: (context, child) {
                        return Positioned(
                          top: _scanLineAnimation.value * scanAreaSize,
                          left: 0,
                          right: 0,
                          child: Container(
                            height: 2,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  Colors.transparent,
                                  const Color(0xFF0A84FF).withOpacity(0.8),
                                  Colors.transparent,
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
        ),
        
        // Corner markers
        Center(
          child: SizedBox(
            width: scanAreaSize,
            height: scanAreaSize,
            child: CustomPaint(
              painter: _CornerPainter(
                color: _isSuccess
                    ? const Color(0xFF30D158)
                    : _isError
                        ? const Color(0xFFFF3B30)
                        : const Color(0xFF0A84FF),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusBanner() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: _isSuccess
                ? const Color(0xFF30D158).withOpacity(0.2)
                : _isError
                    ? const Color(0xFFFF3B30).withOpacity(0.2)
                    : Colors.white.withOpacity(0.15),
            border: Border.all(
              color: _isSuccess
                  ? const Color(0xFF30D158).withOpacity(0.3)
                  : _isError
                      ? const Color(0xFFFF3B30).withOpacity(0.3)
                      : Colors.white.withOpacity(0.2),
            ),
          ),
          child: Row(
            children: [
              if (_isSuccess)
                const Icon(Icons.check_circle, color: Color(0xFF30D158), size: 24)
              else if (_isError)
                const Icon(Icons.error_outline, color: Color(0xFFFF3B30), size: 24)
              else
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white.withOpacity(0.8),
                  ),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _statusMessage ?? '',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.9),
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInstructions() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.qr_code_scanner,
          color: Colors.white.withOpacity(0.5),
          size: 24,
        ),
        const SizedBox(height: 8),
        Text(
          'Point camera at a friend\'s QR code',
          style: TextStyle(
            color: Colors.white.withOpacity(0.7),
            fontSize: 15,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Text(
          'Connection happens via Bluetooth',
          style: TextStyle(
            color: Colors.white.withOpacity(0.4),
            fontSize: 12,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// Custom painter for corner markers
class _CornerPainter extends CustomPainter {
  final Color color;
  
  _CornerPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    const cornerLength = 30.0;
    const radius = 24.0;

    // Top-left
    canvas.drawPath(
      Path()
        ..moveTo(0, cornerLength)
        ..lineTo(0, radius)
        ..quadraticBezierTo(0, 0, radius, 0)
        ..lineTo(cornerLength, 0),
      paint,
    );

    // Top-right
    canvas.drawPath(
      Path()
        ..moveTo(size.width - cornerLength, 0)
        ..lineTo(size.width - radius, 0)
        ..quadraticBezierTo(size.width, 0, size.width, radius)
        ..lineTo(size.width, cornerLength),
      paint,
    );

    // Bottom-left
    canvas.drawPath(
      Path()
        ..moveTo(0, size.height - cornerLength)
        ..lineTo(0, size.height - radius)
        ..quadraticBezierTo(0, size.height, radius, size.height)
        ..lineTo(cornerLength, size.height),
      paint,
    );

    // Bottom-right
    canvas.drawPath(
      Path()
        ..moveTo(size.width - cornerLength, size.height)
        ..lineTo(size.width - radius, size.height)
        ..quadraticBezierTo(size.width, size.height, size.width, size.height - radius)
        ..lineTo(size.width, size.height - cornerLength),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
