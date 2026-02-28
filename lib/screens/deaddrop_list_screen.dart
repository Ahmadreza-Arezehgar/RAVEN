import 'dart:ui';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/ios_design_system.dart';
import '../services/mesh/deaddrop_controller.dart';
import '../services/toast_service.dart';
import '../widgets/liquid_glass_animations.dart';

/// Dead Drop List Screen - Premium geo-cached messages browser
/// 
/// Apple Liquid Glass design with:
/// - Staggered card animations
/// - Shimmer loading states
/// - Animated floating action button
/// - Spring physics interactions
class DeadDropListScreen extends StatefulWidget {
  const DeadDropListScreen({super.key});

  @override
  State<DeadDropListScreen> createState() => _DeadDropListScreenState();
}

class _DeadDropListScreenState extends State<DeadDropListScreen>
    with TickerProviderStateMixin {
  late TabController _tabController;
  late AnimationController _fabController;
  late Animation<double> _fabScaleAnimation;
  late Animation<double> _fabRotationAnimation;
  
  final DeadDropController _controller = DeadDropController.instance;
  
  List<DeadDrop> _nearbyDrops = [];
  List<DeadDrop> _myDrops = [];
  bool _isLoading = true;
  String _currentCell = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    
    // FAB animation
    _fabController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    
    _fabScaleAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _fabController, curve: Curves.easeOutBack),
    );
    
    _fabRotationAnimation = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _fabController, curve: Curves.easeOutCubic),
    );
    
    _loadDrops();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _fabController.dispose();
    super.dispose();
  }

  Future<void> _loadDrops() async {
    setState(() => _isLoading = true);
    
    try {
      _currentCell = await _controller.getCurrentCell();
      _nearbyDrops = await _controller.getLocalDrops(_currentCell);
      _myDrops = await _controller.getMyDrops();
    } catch (e) {
      // Handle error
    }
    
    if (mounted) {
      setState(() => _isLoading = false);
      _fabController.forward();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: iOSDesignSystem.baseBackground,
      body: Stack(
        children: [
          // Subtle particle background
          Positioned.fill(
            child: Opacity(
              opacity: 0.3,
              child: MeshParticleBackground(
                color: const Color(0xFFFF9F0A),
                particleCount: 12,
              ),
            ),
          ),
          
          CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              _buildHeader(),
              
              // Tab bar
              SliverPersistentHeader(
                pinned: true,
                delegate: _AnimatedTabBarDelegate(
                  child: _buildTabBar(),
                ),
              ),
              
              // Content
              SliverFillRemaining(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _buildNearbyTab(),
                    _buildMyDropsTab(),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: _buildAnimatedFAB(),
    );
  }

  Widget _buildHeader() {
    return SliverAppBar(
      expandedHeight: 160,
      floating: false,
      pinned: true,
      backgroundColor: Colors.transparent,
      flexibleSpace: ClipRRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: FlexibleSpaceBar(
            title: const Text(
              'Dead Drops',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 20,
                letterSpacing: 0.5,
              ),
            ),
            background: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    const Color(0xFFFF9F0A).withOpacity(0.4),
                    const Color(0xFFFF6B35).withOpacity(0.3),
                    const Color(0xFFFF375F).withOpacity(0.2),
                    Colors.transparent,
                  ],
                ),
              ),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(60, 0, 16, 55),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFF9F0A).withOpacity(0.25),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: const Color(0xFFFF9F0A).withOpacity(0.5),
                                width: 0.5,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.location_on,
                                  size: 12,
                                  color: Color(0xFFFF9F0A),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _currentCell.isNotEmpty 
                                      ? _currentCell 
                                      : 'Loading...',
                                  style: const TextStyle(
                                    color: Color(0xFFFF9F0A),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ],
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
            _loadDrops();
          },
          child: const Padding(
            padding: EdgeInsets.all(12),
            child: Icon(Icons.refresh, color: Colors.white),
          ),
        ),
      ],
    );
  }

  Widget _buildTabBar() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E).withOpacity(0.95),
        border: Border(
          bottom: BorderSide(
            color: Colors.white.withOpacity(0.08),
            width: 0.5,
          ),
        ),
      ),
      child: TabBar(
        controller: _tabController,
        indicatorColor: const Color(0xFFFF9F0A),
        indicatorWeight: 2.5,
        indicatorSize: TabBarIndicatorSize.label,
        labelColor: Colors.white,
        unselectedLabelColor: Colors.white.withOpacity(0.4),
        labelStyle: const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
        tabs: const [
          Tab(text: 'Nearby'),
          Tab(text: 'My Drops'),
        ],
      ),
    );
  }

  Widget _buildNearbyTab() {
    if (_isLoading) {
      return _buildLoadingState();
    }

    if (_nearbyDrops.isEmpty) {
      return _buildEmptyState(
        icon: Icons.archive_outlined,
        title: 'No drops nearby',
        subtitle: 'Be the first to leave a message here!',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _nearbyDrops.length,
      itemBuilder: (context, index) {
        final drop = _nearbyDrops[index];
        return StaggeredListItem(
          index: index,
          delay: const Duration(milliseconds: 80),
          child: _DeadDropCard(
            drop: drop,
            onTap: () => _showDropDetails(drop),
          ),
        );
      },
    );
  }

  Widget _buildMyDropsTab() {
    if (_isLoading) {
      return _buildLoadingState();
    }

    if (_myDrops.isEmpty) {
      return _buildEmptyState(
        icon: Icons.edit_location_alt_outlined,
        title: 'No drops created',
        subtitle: 'Tap + to create your first dead drop',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _myDrops.length,
      itemBuilder: (context, index) {
        final drop = _myDrops[index];
        return StaggeredListItem(
          index: index,
          delay: const Duration(milliseconds: 80),
          child: _DeadDropCard(
            drop: drop,
            onTap: () => _showDropDetails(drop),
            showDelete: true,
            onDelete: () => _deleteDrop(drop),
          ),
        );
      },
    );
  }

  Widget _buildLoadingState() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: 4,
      itemBuilder: (context, index) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: ShimmerLoading(
          height: 100,
          borderRadius: 16,
        ),
      ),
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FloatingIcon(
            icon: icon,
            size: 64,
            color: Colors.white.withOpacity(0.25),
          ),
          const SizedBox(height: 20),
          Text(
            title,
            style: TextStyle(
              color: Colors.white.withOpacity(0.7),
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: TextStyle(
              color: Colors.white.withOpacity(0.4),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAnimatedFAB() {
    return AnimatedBuilder(
      animation: _fabController,
      builder: (context, child) => Transform.scale(
        scale: _fabScaleAnimation.value,
        child: Transform.rotate(
          angle: (1 - _fabRotationAnimation.value) * pi,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFFF9F0A).withOpacity(0.4),
                  blurRadius: 20,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: FloatingActionButton(
              backgroundColor: const Color(0xFFFF9F0A),
              onPressed: _showCreateDialog,
              child: const Icon(Icons.add, color: Colors.white, size: 28),
            ),
          ),
        ),
      ),
    );
  }

  void _showCreateDialog() {
    HapticFeedback.mediumImpact();
    
    final titleController = TextEditingController();
    final textController = TextEditingController();
    int ttlHours = 24;
    bool _isCreating = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          final bottomInset = MediaQuery.of(context).viewInsets.bottom;
          
          return GestureDetector(
            onTap: () => FocusScope.of(context).unfocus(),
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                child: Container(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.85,
                  ),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        const Color(0xFF2C2C2E).withOpacity(0.95),
                        const Color(0xFF1C1C1E).withOpacity(0.98),
                      ],
                    ),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.1),
                      width: 0.5,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Handle
                      Padding(
                        padding: const EdgeInsets.only(top: 12, bottom: 8),
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.25),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      
                      // ✅ Scrollable content
                      Flexible(
                        child: SingleChildScrollView(
                          padding: EdgeInsets.fromLTRB(24, 16, 24, bottomInset + 24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Title with icon
                              Row(
                                children: [
                                  Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      gradient: const LinearGradient(
                                        colors: [Color(0xFFFF9F0A), Color(0xFFFF6B35)],
                                      ),
                                      borderRadius: BorderRadius.circular(12),
                                      boxShadow: [
                                        BoxShadow(
                                          color: const Color(0xFFFF9F0A).withOpacity(0.4),
                                          blurRadius: 12,
                                          spreadRadius: 1,
                                        ),
                                      ],
                                    ),
                                    child: const Icon(
                                      Icons.archive,
                                      color: Colors.white,
                                      size: 22,
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          'Create Dead Drop',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 20,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          'Leave a note for whoever passes by',
                                          style: TextStyle(
                                            color: Colors.white.withOpacity(0.5),
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 24),
                              
                              // Title input
                              _buildTextField(
                                controller: titleController,
                                label: 'Title',
                                hint: 'Give it a name...',
                              ),
                              const SizedBox(height: 16),
                              
                              // Message input
                              _buildTextField(
                                controller: textController,
                                label: 'Message',
                                hint: 'Leave a message...',
                                maxLines: 4,
                              ),
                              const SizedBox(height: 20),
                              
                              // TTL selector
                              Text(
                                'Expires in',
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.6),
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 12),
                              
                              // ✅ Wrap instead of Row for chip overflow protection
                              Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                children: [
                                  _TTLChip(
                                    label: '6h',
                                    selected: ttlHours == 6,
                                    onTap: () => setSheetState(() => ttlHours = 6),
                                  ),
                                  _TTLChip(
                                    label: '24h',
                                    selected: ttlHours == 24,
                                    onTap: () => setSheetState(() => ttlHours = 24),
                                  ),
                                  _TTLChip(
                                    label: '72h',
                                    selected: ttlHours == 72,
                                    onTap: () => setSheetState(() => ttlHours = 72),
                                  ),
                                  _TTLChip(
                                    label: '7d',
                                    selected: ttlHours == 168,
                                    onTap: () => setSheetState(() => ttlHours = 168),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 28),
                              
                              // ✅ Create button with loading state
                              ScaleTap(
                                onTap: _isCreating ? null : () async {
                                  if (titleController.text.isEmpty || textController.text.isEmpty) {
                                    ToastService.showError('Please fill in all fields');
                                    return;
                                  }
                                  
                                  setSheetState(() => _isCreating = true);
                                  
                                  final success = await _controller.createDropSimplified(
                                    title: titleController.text,
                                    text: textController.text,
                                    cell: _currentCell,
                                    ttlSeconds: ttlHours * 3600,
                                  );
                                  
                                  if (!mounted) return;
                                  Navigator.pop(context);
                                  
                                  if (success) {
                                    ToastService.showSuccess('📦 Dead drop created!');
                                    _loadDrops();
                                  } else {
                                    ToastService.showError('Failed to create drop');
                                  }
                                },
                                child: Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(vertical: 16),
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      colors: [Color(0xFFFF9F0A), Color(0xFFFF6B35)],
                                    ),
                                    borderRadius: BorderRadius.circular(14),
                                    boxShadow: [
                                      BoxShadow(
                                        color: const Color(0xFFFF9F0A).withOpacity(0.35),
                                        blurRadius: 15,
                                        offset: const Offset(0, 5),
                                      ),
                                    ],
                                  ),
                                  child: Center(
                                    child: _isCreating
                                        ? const SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white,
                                            ),
                                          )
                                        : const Text(
                                            'Drop It',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 17,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    int maxLines = 1,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withOpacity(0.6),
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
          maxLines: maxLines,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
            filled: true,
            fillColor: Colors.white.withOpacity(0.08),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(
                color: Colors.white.withOpacity(0.1),
                width: 0.5,
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(
                color: Colors.white.withOpacity(0.1),
                width: 0.5,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(
                color: Color(0xFFFF9F0A),
                width: 1,
              ),
            ),
            contentPadding: const EdgeInsets.all(16),
          ),
        ),
      ],
    );
  }

  void _showDropDetails(DeadDrop drop) {
    HapticFeedback.lightImpact();
    
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
          child: Container(
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  const Color(0xFF2C2C2E).withOpacity(0.95),
                  const Color(0xFF1C1C1E).withOpacity(0.98),
                ],
              ),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Handle
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.25),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                
                // Title
                Text(
                  drop.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                
                // Metadata
                Row(
                  children: [
                    _MetadataChip(
                      icon: Icons.person_outline,
                      label: drop.fromNickname ?? 'Anonymous',
                    ),
                    const SizedBox(width: 12),
                    _MetadataChip(
                      icon: Icons.access_time,
                      label: _formatExpiry(drop.expiresAt),
                      color: drop.expiresAt.difference(DateTime.now()).inHours < 6
                          ? const Color(0xFFFF453A)
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                
                // Message
                LiquidGlassContainer(
                  blur: 10,
                  borderRadius: 16,
                  padding: const EdgeInsets.all(18),
                  child: Text(
                    drop.text,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.9),
                      fontSize: 16,
                      height: 1.6,
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                
                // Close button
                Center(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text(
                      'Close',
                      style: TextStyle(
                        color: Color(0xFF0A84FF),
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
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

  Future<void> _deleteDrop(DeadDrop drop) async {
    HapticFeedback.mediumImpact();
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete Drop?', style: TextStyle(color: Colors.white)),
        content: const Text(
          'This will remove the dead drop from your device.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Color(0xFFFF453A))),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _controller.deleteDrop(drop.id);
      _loadDrops();
      ToastService.showInfo('Drop deleted');
    }
  }

  String _formatExpiry(DateTime expiry) {
    final diff = expiry.difference(DateTime.now());
    if (diff.isNegative) return 'Expired';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m left';
    if (diff.inHours < 24) return '${diff.inHours}h left';
    return '${diff.inDays}d left';
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// HELPER WIDGETS
// ═══════════════════════════════════════════════════════════════════════════

class _AnimatedTabBarDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;
  _AnimatedTabBarDelegate({required this.child});

  @override
  Widget build(context, shrinkOffset, overlapsContent) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: child,
      ),
    );
  }

  @override
  double get maxExtent => 52;
  @override
  double get minExtent => 52;
  @override
  bool shouldRebuild(covariant SliverPersistentHeaderDelegate oldDelegate) => false;
}

class _DeadDropCard extends StatelessWidget {
  final DeadDrop drop;
  final VoidCallback onTap;
  final bool showDelete;
  final VoidCallback? onDelete;

  const _DeadDropCard({
    required this.drop,
    required this.onTap,
    this.showDelete = false,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return ScaleTap(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        child: LiquidGlassContainer(
          blur: 15,
          borderRadius: 18,
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          const Color(0xFFFF9F0A).withOpacity(0.4),
                          const Color(0xFFFF6B35).withOpacity(0.4),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.archive,
                      color: Color(0xFFFF9F0A),
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          drop.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          drop.fromNickname ?? 'Anonymous',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.5),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (showDelete && onDelete != null)
                    GestureDetector(
                      onTap: onDelete,
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF453A).withOpacity(0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.delete_outline,
                          color: Color(0xFFFF453A),
                          size: 18,
                        ),
                      ),
                    )
                  else
                    Icon(
                      Icons.chevron_right,
                      color: Colors.white.withOpacity(0.3),
                      size: 22,
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                drop.text,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.7),
                  fontSize: 14,
                  height: 1.4,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TTLChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _TTLChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ScaleTap(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          gradient: selected
              ? const LinearGradient(
                  colors: [Color(0xFFFF9F0A), Color(0xFFFF6B35)],
                )
              : null,
          color: selected ? null : Colors.white.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected 
                ? Colors.transparent
                : Colors.white.withOpacity(0.1),
            width: 0.5,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: const Color(0xFFFF9F0A).withOpacity(0.3),
                    blurRadius: 12,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            color: Colors.white.withOpacity(selected ? 1.0 : 0.6),
            fontSize: 14,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _MetadataChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;

  const _MetadataChip({
    required this.icon,
    required this.label,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final chipColor = color ?? Colors.white.withOpacity(0.5);
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: chipColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: chipColor),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: chipColor,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
