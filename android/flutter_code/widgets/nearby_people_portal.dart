import 'dart:ui';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../screens/chat_page.dart';
import '../services/toast_service.dart';
import '../mesh_bridge.dart';

/// Show Nearby People Portal - Liquid Glass floating panel
void showNearbyPeoplePortal(BuildContext context) {
  showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Nearby People',
    barrierColor: Colors.black.withOpacity(0.3),
    transitionDuration: const Duration(milliseconds: 280),
    pageBuilder: (_, __, ___) => const _NearbyPeoplePortal(),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      return FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        ),
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.92, end: 1.0).animate(
            CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
            ),
          ),
          child: child,
        ),
      );
    },
  );
}

/// Nearby People Portal - Liquid Glass Design
class _NearbyPeoplePortal extends StatefulWidget {
  const _NearbyPeoplePortal();

  @override
  State<_NearbyPeoplePortal> createState() => _NearbyPeoplePortalState();
}

class _NearbyPeoplePortalState extends State<_NearbyPeoplePortal> 
    with SingleTickerProviderStateMixin {
  
  bool _isScanning = true;
  List<NearbyPerson> _nearbyPeople = [];
  late AnimationController _scanController;
  
  // ✅ Real MeshBridge subscription
  StreamSubscription<String>? _meshSubscription;
  
  @override
  void initState() {
    super.initState();
    _scanController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    
    // ✅ Subscribe to real mesh events
    _meshSubscription = MeshBridge.messages().listen(_handleMeshEvent);
    
    _startDiscovery();
  }
  
  @override
  void dispose() {
    _meshSubscription?.cancel();
    _scanController.dispose();
    super.dispose();
  }
  
  /// ✅ Handle real mesh events from iOS MultipeerConnectivity
  void _handleMeshEvent(String jsonStr) {
    try {
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      final type = data['type'] as String?;
      
      // ✅ Handle discovered_peers event (complete list from iOS)
      if (type == 'discovered_peers') {
        final peers = data['peers'] as List? ?? [];
        debugPrint('🟩 NEARBY: Received ${peers.length} discovered peers');
        
        if (!mounted) return;
        
        // Check friends
        final model = context.read<AppModel>();
        final friends = model.friends;
        final friendFingerprints = friends
            .map((f) => f['fingerprint'] as String?)
            .whereType<String>()
            .toSet();
        
        setState(() {
          _nearbyPeople = peers.map((p) {
            final peerMap = p as Map<String, dynamic>;
            final fingerprint = peerMap['fingerprint'] as String? ?? '';
            final displayName = peerMap['displayName'] as String? ?? 'Unknown';
            
            return NearbyPerson(
              userId: fingerprint.length > 8 ? fingerprint.substring(0, 8) : fingerprint,
              username: displayName,
              deviceId: fingerprint,
              isFriend: friendFingerprints.contains(fingerprint),
              signalStrength: 1.0,
              lastSeen: DateTime.now(),
            );
          }).toList();
          _isScanning = false;
        });
      }
      // Also handle pairing_request for backward compatibility
      else if (type == 'pairing_request') {
        final fingerprint = data['fingerprint'] as String? ?? '';
        final peerName = data['peerName'] as String? ?? 'Unknown';
        
        debugPrint('🟩 NEARBY from pairing_request: $peerName / ${fingerprint.length > 8 ? fingerprint.substring(0, 8) : fingerprint}...');
        
        if (!mounted) return;
        
        // Check if already in list
        if (_nearbyPeople.any((p) => p.deviceId == fingerprint)) return;
        
        final model = context.read<AppModel>();
        final friends = model.friends;
        final friendFingerprints = friends
            .map((f) => f['fingerprint'] as String?)
            .whereType<String>()
            .toSet();
        
        setState(() {
          _nearbyPeople.add(NearbyPerson(
            userId: fingerprint.length > 8 ? fingerprint.substring(0, 8) : fingerprint,
            username: peerName,
            deviceId: fingerprint,
            isFriend: friendFingerprints.contains(fingerprint),
            signalStrength: 1.0,
            lastSeen: DateTime.now(),
          ));
          _isScanning = false;
        });
      }
    } catch (e) {
      debugPrint('⚠️ [NearbyPortal] Error parsing mesh event: $e');
    }
  }
  
  Future<void> _startDiscovery() async {
    setState(() => _isScanning = true);
    
    // Wait a bit for mesh events to arrive
    await Future.delayed(const Duration(seconds: 3));
    
    if (!mounted) return;
    
    // If no peers found after timeout, stop scanning animation
    if (_nearbyPeople.isEmpty) {
      setState(() => _isScanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final safeTop = MediaQuery.of(context).padding.top;
    
    return Stack(
      children: [
        // Positioned panel
        Positioned(
          top: safeTop + 60,
          left: 16,
          right: 16,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
              child: Container(
                constraints: BoxConstraints(
                  maxHeight: size.height * 0.6,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.45),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.1),
                    width: 0.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 30,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Header
                    _buildHeader(),
                    
                    // Content
                    if (_isScanning)
                      _buildScanningIndicator()
                    else if (_nearbyPeople.isEmpty)
                      _buildEmptyState()
                    else
                      _buildPeopleList(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
  
  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Colors.white.withOpacity(0.08),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          // Close button
          GestureDetector(
            onTap: () {
              HapticFeedback.lightImpact();
              Navigator.of(context).pop();
            },
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.close,
                color: Colors.white70,
                size: 18,
              ),
            ),
          ),
          const SizedBox(width: 12),
          
          // Title
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Nearby People',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.none,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(
                      Icons.bluetooth,
                      color: Colors.blue.withOpacity(0.8),
                      size: 12,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Bluetooth Mesh',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.5),
                        fontSize: 12,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          
          // Refresh button
          GestureDetector(
            onTap: () {
              HapticFeedback.lightImpact();
              setState(() => _isScanning = true);
              _startDiscovery();
            },
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _isScanning ? Icons.sync : Icons.refresh,
                color: Colors.white70,
                size: 18,
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildScanningIndicator() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 60),
      child: Column(
        children: [
          RotationTransition(
            turns: _scanController,
            child: Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.blue.withOpacity(0.5),
                  width: 2,
                ),
              ),
              child: Icon(
                Icons.wifi_tethering,
                color: Colors.blue.withOpacity(0.8),
                size: 30,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Scanning nearby...',
            style: TextStyle(
              color: Colors.white.withOpacity(0.6),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildEmptyState() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 60),
      child: Column(
        children: [
          Icon(
            Icons.person_off,
            color: Colors.white.withOpacity(0.3),
            size: 48,
          ),
          const SizedBox(height: 16),
          Text(
            'No one nearby',
            style: TextStyle(
              color: Colors.white.withOpacity(0.5),
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Make sure Bluetooth is enabled',
            style: TextStyle(
              color: Colors.white.withOpacity(0.3),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildPeopleList() {
    return ListView.builder(
      shrinkWrap: true,
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: _nearbyPeople.length,
      itemBuilder: (context, index) {
        return _NearbyPersonTile(
          person: _nearbyPeople[index],
          delay: Duration(milliseconds: 30 * index),
          onChat: () => _handleChat(_nearbyPeople[index]),
          onRequest: () => _handleRequest(_nearbyPeople[index]),
        );
      },
    );
  }
  
  void _handleChat(NearbyPerson person) {
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop();
    
    // Start chat with this person
    final model = context.read<AppModel>();
    model.startChatWith(person.userId, person.username);
    
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ChatPage()),
    );
  }
  
  void _handleRequest(NearbyPerson person) {
    HapticFeedback.mediumImpact();
    
    // TODO: Send mesh_chat_request via MessageRouter
    // final requestId = Uuid().v4();
    // router.sendMeshChatRequest(person.userId, requestId);
    
    ToastService.showSuccess('Request sent to @${person.username}');
    
    // Update UI
    setState(() {
      final index = _nearbyPeople.indexWhere((p) => p.userId == person.userId);
      if (index >= 0) {
        _nearbyPeople[index] = person.copyWith(requestSent: true);
      }
    });
  }
}

/// Individual person tile
class _NearbyPersonTile extends StatefulWidget {
  final NearbyPerson person;
  final Duration delay;
  final VoidCallback onChat;
  final VoidCallback onRequest;
  
  const _NearbyPersonTile({
    required this.person,
    required this.delay,
    required this.onChat,
    required this.onRequest,
  });

  @override
  State<_NearbyPersonTile> createState() => _NearbyPersonTileState();
}

class _NearbyPersonTileState extends State<_NearbyPersonTile> 
    with SingleTickerProviderStateMixin {
  
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;
  
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    
    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    
    Future.delayed(widget.delay, () {
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
    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(
        position: _slideAnimation,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Colors.white.withOpacity(0.05),
              width: 0.5,
            ),
          ),
          child: Row(
            children: [
              // Avatar
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.blue.withOpacity(0.6),
                      Colors.purple.withOpacity(0.6),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    widget.person.username[0].toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              
              // Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '@${widget.person.username}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        decoration: TextDecoration.none,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        // Friend status
                        Icon(
                          widget.person.isFriend 
                              ? Icons.check_circle 
                              : Icons.person_outline,
                          color: widget.person.isFriend 
                              ? Colors.green 
                              : Colors.white38,
                          size: 12,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          widget.person.isFriend ? 'Friend' : 'Not Friend',
                          style: TextStyle(
                            color: widget.person.isFriend 
                                ? Colors.green.withOpacity(0.8) 
                                : Colors.white38,
                            fontSize: 12,
                            decoration: TextDecoration.none,
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Signal
                        Icon(
                          _getSignalIcon(widget.person.signalStrength),
                          color: Colors.blue.withOpacity(0.6),
                          size: 12,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              
              // Action button
              _buildActionButton(),
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _buildActionButton() {
    if (widget.person.isFriend) {
      // Chat button
      return GestureDetector(
        onTap: widget.onChat,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.blue.withOpacity(0.2),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Colors.blue.withOpacity(0.3),
              width: 0.5,
            ),
          ),
          child: const Text(
            'Chat',
            style: TextStyle(
              color: Colors.blue,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      );
    } else if (widget.person.requestSent) {
      // Pending state
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.orange.withOpacity(0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          'Pending',
          style: TextStyle(
            color: Colors.orange.withOpacity(0.8),
            fontSize: 13,
            fontWeight: FontWeight.w500,
            decoration: TextDecoration.none,
          ),
        ),
      );
    } else {
      // Request button
      return GestureDetector(
        onTap: widget.onRequest,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Colors.white.withOpacity(0.15),
              width: 0.5,
            ),
          ),
          child: const Text(
            'Request',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 13,
              fontWeight: FontWeight.w500,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      );
    }
  }
  
  IconData _getSignalIcon(double strength) {
    if (strength > 0.7) return Icons.signal_cellular_4_bar;
    if (strength > 0.4) return Icons.signal_cellular_alt;
    return Icons.signal_cellular_alt_1_bar;
  }
}

/// Model for nearby person
class NearbyPerson {
  final String userId;
  final String username;
  final String deviceId;
  final bool isFriend;
  final double signalStrength;
  final bool requestSent;
  final DateTime? lastSeen; // ✅ For recency indicator
  
  const NearbyPerson({
    required this.userId,
    required this.username,
    required this.deviceId,
    this.isFriend = false,
    this.signalStrength = 1.0,
    this.requestSent = false,
    this.lastSeen,
  });
  
  NearbyPerson copyWith({
    String? userId,
    String? username,
    String? deviceId,
    bool? isFriend,
    double? signalStrength,
    bool? requestSent,
    DateTime? lastSeen,
  }) {
    return NearbyPerson(
      userId: userId ?? this.userId,
      username: username ?? this.username,
      deviceId: deviceId ?? this.deviceId,
      isFriend: isFriend ?? this.isFriend,
      signalStrength: signalStrength ?? this.signalStrength,
      requestSent: requestSent ?? this.requestSent,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }
}
