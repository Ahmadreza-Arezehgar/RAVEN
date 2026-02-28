import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../mesh_bridge.dart';
import '../services/mesh/mesh_event_dispatcher.dart';
import '../services/toast_service.dart';
import '../screens/mesh_status_screen.dart';
import '../screens/deaddrop_list_screen.dart';
import '../screens/knowledge_home.dart';
import 'nearby_people_portal.dart';
import 'ptt_overlay.dart';

/// ══════════════════════════════════════════════════════════════════════════
/// MESH ACTION SHEET - Apple Liquid Glass Design
/// ══════════════════════════════════════════════════════════════════════════
/// 
/// 6 Mesh-focused actions with premium glass styling:
/// 1. Check-in Nearby - Mesh Presence
/// 2. People Around - Nearby devices
/// 3. Dead Drops - Location messages
/// 4. Push-to-Talk - Voice Mesh
/// 5. Local Knowledge - Collective knowledge
/// 6. Mesh Status - Network status
/// 
/// Design specs:
/// - Blur: 25 sigmaX/Y
/// - Glass tint: rgba(28,28,30, 0.65)
/// - Border: 1px white @ 10%
/// - Card radius: 20
/// - Spring animation for open
/// - NO underlines anywhere
/// ══════════════════════════════════════════════════════════════════════════

void showMeshActionSheet(BuildContext context) {
  HapticFeedback.lightImpact();
  
  showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Mesh Actions',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 380),
    pageBuilder: (_, __, ___) => const _MeshActionSheet(),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      // Spring curve: smooth with minimal bounce
      final curve = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutBack,
      );
      
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.15),
          end: Offset.zero,
        ).animate(curve),
        child: FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.95, end: 1.0).animate(curve),
            child: child,
          ),
        ),
      );
    },
  );
}

class _MeshActionSheet extends StatefulWidget {
  const _MeshActionSheet();

  @override
  State<_MeshActionSheet> createState() => _MeshActionSheetState();
}

class _MeshActionSheetState extends State<_MeshActionSheet> {
  int? _pressedIndex;

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.of(context).padding.bottom;

    return Stack(
      children: [
        // Tap outside to dismiss
        Positioned.fill(
          child: GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            behavior: HitTestBehavior.opaque,
            child: const SizedBox.expand(),
          ),
        ),

        // Liquid Glass Panel
        Positioned(
          left: 12,
          right: 12,
          bottom: safeBottom + 12,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
              child: Container(
                decoration: BoxDecoration(
                  // Glass tint - slightly more opaque for readability
                  color: const Color(0xFF1C1C1E).withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(24),
                  // Subtle white border
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.10),
                    width: 1,
                  ),
                  // Soft shadow
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 30,
                      offset: const Offset(0, 8),
                      spreadRadius: -5,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildHeader(),
                    // Very subtle divider
                    Container(
                      height: 0.5,
                      margin: const EdgeInsets.symmetric(horizontal: 20),
                      color: Colors.white.withValues(alpha: 0.06),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(14),
                      child: _buildActionGrid(),
                    ),
                    _buildCancelButton(),
                    const SizedBox(height: 10),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
      child: Row(
        children: [
          // Icon in glass circle
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF0A84FF).withValues(alpha: 0.22),
                  const Color(0xFF5856D6).withValues(alpha: 0.18),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.wifi_tethering,
              color: Color(0xFF0A84FF),
              size: 18,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title - NO underline
                const Text(
                  'Mesh Network',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.3,
                    decoration: TextDecoration.none, // ✅ NO UNDERLINE
                  ),
                ),
                const SizedBox(height: 2),
                // Subtitle with dot separator - NO underline
                Text(
                  'Bluetooth-first • Local-first',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    decoration: TextDecoration.none, // ✅ NO UNDERLINE
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionGrid() {
    final actions = _getMeshActions();
    
    return Column(
      children: [
        // Row 1
        Row(
          children: [
            Expanded(child: _buildActionCard(0, actions[0])),
            const SizedBox(width: 10),
            Expanded(child: _buildActionCard(1, actions[1])),
            const SizedBox(width: 10),
            Expanded(child: _buildActionCard(2, actions[2])),
          ],
        ),
        const SizedBox(height: 10),
        // Row 2
        Row(
          children: [
            Expanded(child: _buildActionCard(3, actions[3])),
            const SizedBox(width: 10),
            Expanded(child: _buildActionCard(4, actions[4])),
            const SizedBox(width: 10),
            Expanded(child: _buildActionCard(5, actions[5])),
          ],
        ),
      ],
    );
  }

  Widget _buildActionCard(int index, _MeshAction action) {
    final isPressed = _pressedIndex == index;

    return GestureDetector(
      onTapDown: (_) {
        HapticFeedback.selectionClick();
        setState(() => _pressedIndex = index);
      },
      onTapUp: (_) {
        setState(() => _pressedIndex = null);
        HapticFeedback.mediumImpact();
        Navigator.of(context).pop();
        action.onTap();
      },
      onTapCancel: () => setState(() => _pressedIndex = null),
      child: AnimatedScale(
        scale: isPressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          decoration: BoxDecoration(
            // Card glass effect
            color: isPressed
                ? action.color.withValues(alpha: 0.18)
                : Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(18), // ✅ Smoother radius
            border: Border.all(
              color: isPressed
                  ? action.color.withValues(alpha: 0.30)
                  : Colors.white.withValues(alpha: 0.08),
              width: 0.5,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Icon circle
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      action.color.withValues(alpha: 0.22),
                      action.color.withValues(alpha: 0.12),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  action.icon,
                  color: action.color,
                  size: 20,
                ),
              ),
              const SizedBox(height: 8),
              // Label - NO underline, smaller font
              Text(
                action.label,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.88),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.1,
                  decoration: TextDecoration.none, // ✅ NO UNDERLINE
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCancelButton() {
    return GestureDetector(
      onTapDown: (_) => HapticFeedback.lightImpact(),
      onTap: () {
        HapticFeedback.lightImpact();
        Navigator.of(context).pop();
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 14),
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          // Glass capsule button (not a link!)
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.06),
            width: 0.5,
          ),
        ),
        child: const Center(
          child: Text(
            'Cancel',
            style: TextStyle(
              color: Color(0xFF0A84FF),
              fontSize: 16,
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.none, // ✅ NO UNDERLINE
            ),
          ),
        ),
      ),
    );
  }

  List<_MeshAction> _getMeshActions() {
    return [
      // 1. Check-in Nearby - Green
      _MeshAction(
        icon: Icons.location_on_rounded,
        label: 'Check-in',
        color: const Color(0xFF30D158),
        onTap: () => _handleCheckIn(),
      ),
      // 2. People Around - Blue
      _MeshAction(
        icon: Icons.people_alt_rounded,
        label: 'People',
        color: const Color(0xFF0A84FF),
        onTap: () => showNearbyPeoplePortal(context),
      ),
      // 3. Dead Drops - Amber
      _MeshAction(
        icon: Icons.archive_rounded,
        label: 'Dead Drops',
        color: const Color(0xFFFF9F0A),
        onTap: () => _navigateTo(const DeadDropListScreen()),
      ),
      // 4. Push-to-Talk - Purple
      _MeshAction(
        icon: Icons.graphic_eq_rounded,
        label: 'PTT',
        color: const Color(0xFFBF5AF2),
        onTap: () => PttOverlay.show(context),
      ),
      // 5. Local Knowledge - Cyan
      _MeshAction(
        icon: Icons.auto_stories_rounded,
        label: 'Knowledge',
        color: const Color(0xFF64D2FF),
        onTap: () => _navigateTo(const KnowledgeHomePage()),
      ),
      // 6. Mesh Status - Gray
      _MeshAction(
        icon: Icons.cell_tower_rounded,
        label: 'Status',
        color: const Color(0xFF8E8E93),
        onTap: () => _navigateTo(const MeshStatusScreen()),
      ),
    ];
  }

  // ══════════════════════════════════════════════════════════════════════════
  // ACTION HANDLERS → All route through MeshRouter/MeshEventDispatcher
  // ══════════════════════════════════════════════════════════════════════════

  void _handleCheckIn() async {
    // ✅ Check if any peers are connected first
    final peers = await MeshBridge.getConnectedPeers();
    
    if (peers.isEmpty) {
      HapticFeedback.heavyImpact();
      ToastService.showError('No peers connected. Open Nearby People first.');
      return;
    }
    
    ToastService.showInfo('📍 Broadcasting to ${peers.length} peer(s)...');
    
    final success = await MeshEventDispatcher.instance.sendPresenceCheckIn();
    
    if (success) {
      ToastService.showSuccess("Sent to ${peers.length} nearby device(s) ✓");
    } else {
      HapticFeedback.heavyImpact();
      ToastService.showError('Send failed. Try restarting Bluetooth.');
    }
  }

  void _navigateTo(Widget screen) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => screen),
    );
  }
}

/// Mesh action model
class _MeshAction {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _MeshAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });
}
