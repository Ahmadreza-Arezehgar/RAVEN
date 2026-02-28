import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../theme/modern_theme.dart';

/// Network Mode Toast - Shows when switching between WiFi and Mesh
class NetworkModeToast extends StatefulWidget {
  final Widget child;
  
  const NetworkModeToast({super.key, required this.child});
  
  @override
  State<NetworkModeToast> createState() => _NetworkModeToastState();
}

class _NetworkModeToastState extends State<NetworkModeToast> 
    with SingleTickerProviderStateMixin {
  
  StreamSubscription<dynamic>? _subscription;
  bool _isWiFi = true;
  bool _showToast = false;
  String _toastTitle = '';
  String _toastSubtitle = '';
  IconData _toastIcon = Icons.wifi;
  
  late AnimationController _animController;
  late Animation<Offset> _slideAnim;
  late Animation<double> _fadeAnim;
  
  @override
  void initState() {
    super.initState();
    
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 1.5),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOutCubic,
    ));
    
    _fadeAnim = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOut,
    ));
    
    _checkInitial();
    _startListening();
  }
  
  Future<void> _checkInitial() async {
    final result = await Connectivity().checkConnectivity();
    _updateState(result, showToast: false);
  }
  
  void _startListening() {
    _subscription = Connectivity().onConnectivityChanged.listen((result) {
      _updateState(result, showToast: true);
    });
  }
  
  void _updateState(dynamic result, {bool showToast = true}) {
    bool hasWiFi;
    
    if (result is List) {
      hasWiFi = (result as List<ConnectivityResult>).any((r) => 
        r == ConnectivityResult.wifi || 
        r == ConnectivityResult.mobile ||
        r == ConnectivityResult.ethernet
      );
    } else {
      final r = result as ConnectivityResult;
      hasWiFi = r == ConnectivityResult.wifi || 
                r == ConnectivityResult.mobile ||
                r == ConnectivityResult.ethernet;
    }
    
    if (hasWiFi != _isWiFi && showToast) {
      if (!mounted) return;  // ✅ Fix
      setState(() {
        _isWiFi = hasWiFi;
        _showToast = true;
        
        if (hasWiFi) {
          _toastTitle = 'Back Online! 🌐';
          _toastSubtitle = 'Messages via Internet';
          _toastIcon = Icons.wifi;
        } else {
          _toastTitle = 'Offline Mode Active 📡';
          _toastSubtitle = 'Switched to Mesh (Bluetooth). Messages will sync when online.';
          _toastIcon = Icons.bluetooth;
        }
      });
      
      _showAndDismiss();
    } else {
      _isWiFi = hasWiFi;
    }
  }
  
  void _showAndDismiss() async {
    await _animController.forward();
    await Future.delayed(const Duration(seconds: 3));
    if (mounted) {
      await _animController.reverse();
      setState(() => _showToast = false);
    }
  }
  
  @override
  void dispose() {
    _subscription?.cancel();
    _animController.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        
        // Network Mode Toast
        if (_showToast)
          Positioned(
            left: 16,
            right: 16,
            bottom: MediaQuery.of(context).padding.bottom + 80,
            child: SlideTransition(
              position: _slideAnim,
              child: FadeTransition(
                opacity: _fadeAnim,
                child: _buildToastCapsule(),
              ),
            ),
          ),
      ],
    );
  }
  
  Widget _buildToastCapsule() {
    return Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: _isWiFi 
                  ? ModernTheme.success.withOpacity(0.15)
                  : Colors.blue.withOpacity(0.15),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                color: Colors.white.withOpacity(0.1),
                width: 0.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: (_isWiFi ? ModernTheme.success : Colors.blue)
                      .withOpacity(0.2),
                  blurRadius: 20,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Icon with glow
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: (_isWiFi ? ModernTheme.success : Colors.blue)
                        .withOpacity(0.2),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _toastIcon,
                    color: _isWiFi ? ModernTheme.success : Colors.blue,
                    size: 22,
                  ),
                ),
                
                const SizedBox(width: 14),
                
                // Text
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _toastTitle,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _toastSubtitle,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.6),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
