import 'dart:async';
import 'dart:ui';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/ios_design_system.dart';
import '../services/mesh_router.dart';
import '../services/device_identity_service.dart';
import '../mesh_bridge.dart';
import '../widgets/liquid_glass_animations.dart';

/// Mesh Status Screen - Shows mesh network status with premium animations
/// 
/// Apple Liquid Glass design with:
/// - Animated mesh particle background
/// - Staggered card entrance animations
/// - Pulsing status indicators
/// - Spring physics interactions
class MeshStatusScreen extends StatefulWidget {
  const MeshStatusScreen({super.key});

  @override
  State<MeshStatusScreen> createState() => _MeshStatusScreenState();
}

class _MeshStatusScreenState extends State<MeshStatusScreen> 
    with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late AnimationController _headerController;
  late Animation<double> _pulseAnimation;
  late Animation<double> _headerFadeAnimation;
  late Animation<Offset> _headerSlideAnimation;
  Timer? _refreshTimer;
  
  // Mesh stats
  String _fingerprint = '';
  String _shortFingerprint = '';
  bool _isMeshRunning = false;
  int _peerCount = 0;
  int _messagesSent = 0;
  int _messagesReceived = 0;
  List<String> _connectedPeers = [];
  String _networkMode = 'Unknown';
  DateTime? _lastActivity;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    
    // Pulse animation for status indicator
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat(reverse: true);
    
    _pulseAnimation = Tween<double>(begin: 0.4, end: 0.8).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    
    // Header entrance animation
    _headerController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    
    _headerFadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _headerController, 
        curve: const Interval(0, 0.6, curve: Curves.easeOut),
      ),
    );
    
    _headerSlideAnimation = Tween<Offset>(
      begin: const Offset(0, -20),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _headerController,
      curve: const Interval(0, 0.6, curve: Curves.easeOutCubic),
    ));
    
    _headerController.forward();
    _loadStatus();
    
    // Auto-refresh every 2 seconds
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _loadStatus();
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _headerController.dispose();
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadStatus() async {
    try {
      final deviceIdentity = DeviceIdentityService.instance;
      final fingerprint = await deviceIdentity.getDeviceFingerprint();
      final shortFp = deviceIdentity.getShortFingerprint(fingerprint);
      
      // Get mesh status from MeshBridge
      final isRunning = await MeshBridge.isRunning();
      final peers = await MeshBridge.getConnectedPeers();
      
      // Get network mode
      final meshRouter = MeshRouter.instance;
      String mode = 'Offline';
      if (meshRouter.isWiFiMode) {
        mode = 'WiFi (Online)';
      } else if (meshRouter.isBluetoothMode) {
        mode = 'Bluetooth (Mesh)';
      }
      
      if (mounted) {
        setState(() {
          _fingerprint = fingerprint;
          _shortFingerprint = shortFp;
          _isMeshRunning = isRunning;
          _connectedPeers = peers;
          _peerCount = peers.length;
          _networkMode = mode;
          _lastActivity = DateTime.now();
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: iOSDesignSystem.baseBackground,
      body: Stack(
        children: [
          // Animated mesh particle background
          const Positioned.fill(
            child: MeshParticleBackground(
              color: Color(0xFF0A84FF),
              particleCount: 25,
            ),
          ),
          
          // Main content
          CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              // Animated header
              _buildHeader(),
              
              // Content
              SliverPadding(
                padding: const EdgeInsets.all(16),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    // Status Card
                    StaggeredListItem(
                      index: 0,
                      child: _buildStatusCard(),
                    ),
                    const SizedBox(height: 16),
                    
                    // Identity Card
                    StaggeredListItem(
                      index: 1,
                      child: _buildIdentityCard(),
                    ),
                    const SizedBox(height: 16),
                    
                    // Connected Peers
                    StaggeredListItem(
                      index: 2,
                      child: _buildPeersCard(),
                    ),
                    const SizedBox(height: 16),
                    
                    // Stats Card
                    StaggeredListItem(
                      index: 3,
                      child: _buildStatsCard(),
                    ),
                    const SizedBox(height: 32),
                    
                    // Actions
                    StaggeredListItem(
                      index: 4,
                      child: _buildActions(),
                    ),
                    const SizedBox(height: 100),
                  ]),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return SliverAppBar(
      expandedHeight: 140,
      floating: false,
      pinned: true,
      backgroundColor: Colors.transparent,
      flexibleSpace: ClipRRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: FlexibleSpaceBar(
            title: AnimatedBuilder(
              animation: _headerController,
              builder: (context, child) => Transform.translate(
                offset: _headerSlideAnimation.value,
                child: Opacity(
                  opacity: _headerFadeAnimation.value,
                  child: const Text(
                    'Mesh Status',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 20,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            ),
            background: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    const Color(0xFF0A84FF).withOpacity(0.4),
                    const Color(0xFF5856D6).withOpacity(0.3),
                    const Color(0xFFBF5AF2).withOpacity(0.2),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      leading: ScaleTap(
        onTap: () => Navigator.pop(context),
        child: const Padding(
          padding: EdgeInsets.all(8),
          child: Icon(Icons.arrow_back_ios, color: Colors.white),
        ),
      ),
      actions: [
        ScaleTap(
          onTap: () {
            HapticFeedback.lightImpact();
            _loadStatus();
          },
          child: const Padding(
            padding: EdgeInsets.all(12),
            child: Icon(Icons.refresh, color: Colors.white),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusCard() {
    final statusColor = _isMeshRunning 
        ? const Color(0xFF30D158) 
        : const Color(0xFFFF453A);
    final statusText = _isMeshRunning ? 'Active' : 'Inactive';
    
    return LiquidGlassContainer(
      hasGlow: _isMeshRunning,
      tintColor: _isMeshRunning ? const Color(0xFF30D158) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Animated status indicator
              GlowPulse(
                color: statusColor,
                size: 12,
                active: _isMeshRunning,
              ),
              const SizedBox(width: 12),
              Text(
                'Mesh Network',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.9),
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.8, end: 1.0),
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutBack,
                builder: (context, value, child) => Transform.scale(
                  scale: value,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: statusColor.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: statusColor.withOpacity(0.5),
                        width: 0.5,
                      ),
                    ),
                    child: Text(
                      statusText,
                      style: TextStyle(
                        color: statusColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          
          // Network mode
          _AnimatedStatusRow(
            icon: Icons.wifi,
            label: 'Network Mode',
            value: _networkMode,
            valueColor: _networkMode.contains('WiFi') 
                ? const Color(0xFF30D158) 
                : const Color(0xFF0A84FF),
            delay: 0,
          ),
          const SizedBox(height: 14),
          
          // Peer count
          _AnimatedStatusRow(
            icon: Icons.devices,
            label: 'Connected Peers',
            value: '$_peerCount',
            delay: 1,
          ),
          const SizedBox(height: 14),
          
          // Last activity
          _AnimatedStatusRow(
            icon: Icons.access_time,
            label: 'Last Activity',
            value: _lastActivity != null 
                ? _formatTime(_lastActivity!) 
                : 'Never',
            delay: 2,
          ),
        ],
      ),
    );
  }

  Widget _buildIdentityCard() {
    return LiquidGlassContainer(
      animateGradient: true,
      tintColor: const Color(0xFF5856D6).withOpacity(0.3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFF5856D6).withOpacity(0.4),
                      const Color(0xFFAF52DE).withOpacity(0.4),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFAF52DE).withOpacity(0.3),
                      blurRadius: 12,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.fingerprint,
                  color: Color(0xFFAF52DE),
                  size: 24,
                ),
              ),
              const SizedBox(width: 14),
              Text(
                'Device Identity',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.9),
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          
          // Short fingerprint
          _AnimatedStatusRow(
            icon: Icons.tag,
            label: 'Display ID',
            value: _shortFingerprint.isNotEmpty ? _shortFingerprint : '...',
            delay: 0,
          ),
          const SizedBox(height: 14),
          
          // Full fingerprint (truncated)
          ScaleTap(
            onTap: () {
              HapticFeedback.lightImpact();
              Clipboard.setData(ClipboardData(text: _fingerprint));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text('Fingerprint copied'),
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  duration: const Duration(seconds: 2),
                ),
              );
            },
            child: _AnimatedStatusRow(
              icon: Icons.content_copy,
              label: 'Full Fingerprint',
              value: _fingerprint.isNotEmpty 
                  ? '${_fingerprint.substring(0, 16)}...' 
                  : '...',
              delay: 1,
              trailing: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0xFF0A84FF).withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.copy,
                  color: Color(0xFF0A84FF),
                  size: 14,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPeersCard() {
    return LiquidGlassContainer(
      tintColor: const Color(0xFF64D2FF).withOpacity(0.2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFF0A84FF).withOpacity(0.4),
                      const Color(0xFF64D2FF).withOpacity(0.4),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF64D2FF).withOpacity(0.3),
                      blurRadius: 12,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.devices_other,
                  color: Color(0xFF64D2FF),
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Text(
                'Connected Peers',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.9),
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: _connectedPeers.length.toDouble()),
                duration: const Duration(milliseconds: 600),
                curve: Curves.easeOutCubic,
                builder: (context, value, _) => Text(
                  '${value.toInt()}',
                  style: const TextStyle(
                    color: Color(0xFF64D2FF),
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          
          if (_connectedPeers.isEmpty) ...[
            const SizedBox(height: 24),
            Center(
              child: Column(
                children: [
                  FloatingIcon(
                    icon: Icons.wifi_off,
                    size: 44,
                    color: Colors.white.withOpacity(0.3),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'No peers connected',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.5),
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
            ),
          ] else ...[
            const SizedBox(height: 20),
            ...List.generate(
              _connectedPeers.length.clamp(0, 5), 
              (index) => _buildPeerItem(_connectedPeers[index], index),
            ),
            if (_connectedPeers.length > 5)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '+ ${_connectedPeers.length - 5} more',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.5),
                    fontSize: 13,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildPeerItem(String peer, int index) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 300 + index * 100),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) => Transform.translate(
        offset: Offset((1 - value) * 30, 0),
        child: Opacity(
          opacity: value,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                GlowPulse(
                  color: const Color(0xFF30D158),
                  size: 8,
                  active: true,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    peer.length > 24 ? '${peer.substring(0, 24)}...' : peer,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.8),
                      fontSize: 14,
                      fontFamily: 'monospace',
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

  Widget _buildStatsCard() {
    return LiquidGlassContainer(
      tintColor: const Color(0xFFFF9F0A).withOpacity(0.2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFFFF9F0A).withOpacity(0.4),
                      const Color(0xFFFFD60A).withOpacity(0.4),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFFFD60A).withOpacity(0.3),
                      blurRadius: 12,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.analytics_outlined,
                  color: Color(0xFFFFD60A),
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Text(
                'Statistics',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.9),
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          
          Row(
            children: [
              Expanded(
                child: _AnimatedStatBox(
                  label: 'Sent',
                  value: _messagesSent,
                  icon: Icons.arrow_upward_rounded,
                  color: const Color(0xFF30D158),
                  delay: 0,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _AnimatedStatBox(
                  label: 'Received',
                  value: _messagesReceived,
                  icon: Icons.arrow_downward_rounded,
                  color: const Color(0xFF0A84FF),
                  delay: 1,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActions() {
    return Column(
      children: [
        ScaleTap(
          onTap: () async {
            HapticFeedback.mediumImpact();
            await MeshBridge.restart();
            _loadStatus();
          },
          child: _ActionButton(
            icon: Icons.restart_alt,
            label: 'Restart Mesh',
            color: const Color(0xFFFF9F0A),
          ),
        ),
        const SizedBox(height: 12),
        ScaleTap(
          onTap: () {
            HapticFeedback.lightImpact();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Debug log export coming soon')),
            );
          },
          child: _ActionButton(
            icon: Icons.bug_report_outlined,
            label: 'Export Debug Log',
            color: const Color(0xFF8E8E93),
          ),
        ),
      ],
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    
    if (diff.inSeconds < 10) return 'Just now';
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return '${diff.inHours}h ago';
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// HELPER WIDGETS
// ═══════════════════════════════════════════════════════════════════════════

class _AnimatedStatusRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;
  final Widget? trailing;
  final int delay;

  const _AnimatedStatusRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
    this.trailing,
    this.delay = 0,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 400 + delay * 100),
      curve: Curves.easeOutCubic,
      builder: (context, anim, child) => Transform.translate(
        offset: Offset((1 - anim) * 20, 0),
        child: Opacity(
          opacity: anim,
          child: Row(
            children: [
              Icon(icon, color: Colors.white.withOpacity(0.5), size: 18),
              const SizedBox(width: 10),
              Text(
                label,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.5),
                  fontSize: 14,
                ),
              ),
              const Spacer(),
              Text(
                value,
                style: TextStyle(
                  color: valueColor ?? Colors.white.withOpacity(0.9),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _AnimatedStatBox extends StatelessWidget {
  final String label;
  final int value;
  final IconData icon;
  final Color color;
  final int delay;

  const _AnimatedStatBox({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.delay = 0,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 500 + delay * 150),
      curve: Curves.easeOutBack,
      builder: (context, anim, _) => Transform.scale(
        scale: 0.8 + anim * 0.2,
        child: Opacity(
          opacity: anim,
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: color.withOpacity(0.2),
                width: 0.5,
              ),
            ),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.2),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: color, size: 22),
                ),
                const SizedBox(height: 12),
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: value.toDouble()),
                  duration: const Duration(milliseconds: 800),
                  curve: Curves.easeOutCubic,
                  builder: (context, val, _) => Text(
                    '${val.toInt()}',
                    style: TextStyle(
                      color: color,
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.6),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withOpacity(0.08),
          width: 0.5,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: color.withOpacity(0.2),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 16),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withOpacity(0.9),
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
          const Spacer(),
          Icon(
            Icons.chevron_right,
            color: Colors.white.withOpacity(0.3),
            size: 22,
          ),
        ],
      ),
    );
  }
}
