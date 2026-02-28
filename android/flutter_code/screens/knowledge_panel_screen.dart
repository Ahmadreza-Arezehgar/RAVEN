import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/ios_design_system.dart';
import '../services/mesh/knowledge_controller.dart';
import '../services/toast_service.dart';
import '../widgets/liquid_glass_animations.dart';

/// Knowledge Panel Screen - Premium local knowledge cache browser
/// 
/// Apple Liquid Glass design with:
/// - Animated search bar
/// - Category filter pills with haptic feedback
/// - Staggered card animations
/// - Score-based visual hierarchy
/// - Smooth modal transitions
class KnowledgePanelScreen extends StatefulWidget {
  const KnowledgePanelScreen({super.key});

  @override
  State<KnowledgePanelScreen> createState() => _KnowledgePanelScreenState();
}

class _KnowledgePanelScreenState extends State<KnowledgePanelScreen>
    with TickerProviderStateMixin {
  final KnowledgeController _controller = KnowledgeController.instance;
  final TextEditingController _searchController = TextEditingController();
  
  late AnimationController _headerController;
  late AnimationController _fabController;
  late Animation<double> _headerAnimation;
  late Animation<double> _fabAnimation;
  
  List<KnowledgeItem> _items = [];
  bool _isLoading = true;
  String _searchQuery = '';
  String? _selectedCategory;

  final List<_CategoryData> _categories = [
    _CategoryData('All', Icons.apps, const Color(0xFF64D2FF)),
    _CategoryData('Text', Icons.text_snippet, const Color(0xFF64D2FF)),
    _CategoryData('File', Icons.insert_drive_file, const Color(0xFF30D158)),
    _CategoryData('Link', Icons.link, const Color(0xFF0A84FF)),
    _CategoryData('Note', Icons.note, const Color(0xFFFFD60A)),
  ];

  @override
  void initState() {
    super.initState();
    
    _headerController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    
    _headerAnimation = CurvedAnimation(
      parent: _headerController,
      curve: Curves.easeOutCubic,
    );
    
    _fabController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    
    _fabAnimation = CurvedAnimation(
      parent: _fabController,
      curve: Curves.easeOutBack,
    );
    
    _headerController.forward();
    _loadItems();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _headerController.dispose();
    _fabController.dispose();
    super.dispose();
  }

  Future<void> _loadItems() async {
    setState(() => _isLoading = true);
    
    try {
      if (_searchQuery.isNotEmpty) {
        _items = await _controller.searchByTitle(_searchQuery);
      } else {
        _items = await _controller.getAllItems();
      }
      
      if (_selectedCategory != null && _selectedCategory != 'All') {
        _items = _items.where((item) => 
            item.kind.toLowerCase() == _selectedCategory!.toLowerCase()
        ).toList();
      }
    } catch (e) {
      // Handle error
    }
    
    if (mounted) {
      setState(() => _isLoading = false);
      _fabController.forward();
    }
  }

  void _onSearch(String query) {
    _searchQuery = query;
    _loadItems();
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
              opacity: 0.25,
              child: MeshParticleBackground(
                color: const Color(0xFF64D2FF),
                particleCount: 15,
              ),
            ),
          ),
          
          CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              _buildHeader(),
              
              // Search bar
              SliverToBoxAdapter(
                child: _buildSearchBar(),
              ),
              
              // Category filters
              SliverToBoxAdapter(
                child: _buildCategoryFilters(),
              ),
              
              // Content
              _isLoading
                  ? SliverFillRemaining(child: _buildLoadingState())
                  : _items.isEmpty
                      ? SliverFillRemaining(child: _buildEmptyState())
                      : _buildItemsList(),
              
              // Bottom padding
              const SliverToBoxAdapter(
                child: SizedBox(height: 100),
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
      expandedHeight: 130,
      floating: false,
      pinned: true,
      backgroundColor: Colors.transparent,
      flexibleSpace: ClipRRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: FlexibleSpaceBar(
            title: AnimatedBuilder(
              animation: _headerAnimation,
              builder: (context, child) => Transform.translate(
                offset: Offset(0, (1 - _headerAnimation.value) * 10),
                child: Opacity(
                  opacity: _headerAnimation.value,
                  child: const Text(
                    'Knowledge',
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
                    const Color(0xFF64D2FF).withOpacity(0.4),
                    const Color(0xFF5AC8FA).withOpacity(0.3),
                    const Color(0xFF0A84FF).withOpacity(0.2),
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
            _loadItems();
          },
          child: const Padding(
            padding: EdgeInsets.all(12),
            child: Icon(Icons.refresh, color: Colors.white),
          ),
        ),
      ],
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
        builder: (context, value, child) => Transform.translate(
          offset: Offset(0, (1 - value) * 20),
          child: Opacity(
            opacity: value,
            child: LiquidGlassContainer(
              blur: 15,
              borderRadius: 16,
              padding: EdgeInsets.zero,
              child: TextField(
                controller: _searchController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Search knowledge...',
                  hintStyle: TextStyle(color: Colors.white.withOpacity(0.35)),
                  prefixIcon: Padding(
                    padding: const EdgeInsets.only(left: 16, right: 12),
                    child: Icon(
                      Icons.search,
                      color: Colors.white.withOpacity(0.5),
                      size: 22,
                    ),
                  ),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: 50,
                    minHeight: 50,
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 16,
                  ),
                ),
                onChanged: _onSearch,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryFilters() {
    return SizedBox(
      height: 56,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: _categories.length,
        itemBuilder: (context, index) {
          final category = _categories[index];
          final isSelected = _selectedCategory == category.name || 
              (category.name == 'All' && _selectedCategory == null);
          
          return TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: Duration(milliseconds: 300 + index * 50),
            curve: Curves.easeOutBack,
            builder: (context, value, child) => Transform.scale(
              scale: 0.8 + value * 0.2,
              child: Opacity(
                opacity: value,
                child: Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: ScaleTap(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      setState(() {
                        _selectedCategory = category.name == 'All' 
                            ? null 
                            : category.name;
                      });
                      _loadItems();
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        gradient: isSelected
                            ? LinearGradient(
                                colors: [
                                  category.color,
                                  category.color.withOpacity(0.7),
                                ],
                              )
                            : null,
                        color: isSelected 
                            ? null 
                            : Colors.white.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: isSelected
                            ? [
                                BoxShadow(
                                  color: category.color.withOpacity(0.3),
                                  blurRadius: 10,
                                  spreadRadius: 1,
                                ),
                              ]
                            : null,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            category.icon,
                            size: 16,
                            color: isSelected 
                                ? Colors.white
                                : Colors.white.withOpacity(0.6),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            category.name,
                            style: TextStyle(
                              color: isSelected 
                                  ? Colors.white
                                  : Colors.white.withOpacity(0.6),
                              fontSize: 14,
                              fontWeight: isSelected 
                                  ? FontWeight.w600 
                                  : FontWeight.w500,
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
        },
      ),
    );
  }

  Widget _buildLoadingState() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: 5,
      itemBuilder: (context, index) => StaggeredListItem(
        index: index,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: ShimmerLoading(
            height: 110,
            borderRadius: 18,
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FloatingIcon(
            icon: _searchQuery.isNotEmpty 
                ? Icons.search_off 
                : Icons.library_books_outlined,
            size: 64,
            color: Colors.white.withOpacity(0.25),
          ),
          const SizedBox(height: 20),
          Text(
            _searchQuery.isNotEmpty
                ? 'No results found'
                : 'No knowledge items',
            style: TextStyle(
              color: Colors.white.withOpacity(0.7),
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48),
            child: Text(
              _searchQuery.isNotEmpty
                  ? 'Try a different search term'
                  : 'Knowledge shared via mesh will appear here',
              style: TextStyle(
                color: Colors.white.withOpacity(0.4),
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildItemsList() {
    return SliverPadding(
      padding: const EdgeInsets.all(16),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final item = _items[index];
            return StaggeredListItem(
              index: index,
              delay: const Duration(milliseconds: 60),
              child: _KnowledgeCard(
                item: item,
                onTap: () => _showItemDetails(item),
              ),
            );
          },
          childCount: _items.length,
        ),
      ),
    );
  }

  Widget _buildAnimatedFAB() {
    return AnimatedBuilder(
      animation: _fabAnimation,
      builder: (context, child) => Transform.scale(
        scale: _fabAnimation.value,
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF64D2FF).withOpacity(0.4),
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ],
          ),
          child: FloatingActionButton(
            backgroundColor: const Color(0xFF64D2FF),
            onPressed: _showCreateDialog,
            child: const Icon(Icons.add, color: Colors.white, size: 28),
          ),
        ),
      ),
    );
  }

  void _showCreateDialog() {
    HapticFeedback.mediumImpact();
    
    final titleController = TextEditingController();
    final contentController = TextEditingController();
    String selectedKind = 'note';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
            child: Container(
              padding: EdgeInsets.fromLTRB(
                24,
                24,
                24,
                MediaQuery.of(context).viewInsets.bottom + 24,
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
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF64D2FF), Color(0xFF5AC8FA)],
                          ),
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF64D2FF).withOpacity(0.4),
                              blurRadius: 12,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.library_books,
                          color: Colors.white,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 14),
                      const Text(
                        'Share Knowledge',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  
                  // Kind selector
                  _buildLabel('Type'),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _KindChip(
                        icon: Icons.note,
                        label: 'Note',
                        selected: selectedKind == 'note',
                        color: const Color(0xFFFFD60A),
                        onTap: () => setSheetState(() => selectedKind = 'note'),
                      ),
                      const SizedBox(width: 10),
                      _KindChip(
                        icon: Icons.link,
                        label: 'Link',
                        selected: selectedKind == 'link',
                        color: const Color(0xFF0A84FF),
                        onTap: () => setSheetState(() => selectedKind = 'link'),
                      ),
                      const SizedBox(width: 10),
                      _KindChip(
                        icon: Icons.text_snippet,
                        label: 'Text',
                        selected: selectedKind == 'text',
                        color: const Color(0xFF64D2FF),
                        onTap: () => setSheetState(() => selectedKind = 'text'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  
                  // Title input
                  _buildLabel('Title'),
                  const SizedBox(height: 8),
                  _buildTextField(
                    controller: titleController,
                    hint: 'Enter a title...',
                  ),
                  const SizedBox(height: 16),
                  
                  // Content input
                  _buildLabel(selectedKind == 'link' ? 'URL' : 'Content'),
                  const SizedBox(height: 8),
                  _buildTextField(
                    controller: contentController,
                    hint: selectedKind == 'link' 
                        ? 'https://...'
                        : 'Enter content...',
                    maxLines: 4,
                  ),
                  const SizedBox(height: 28),
                  
                  // Share button
                  ScaleTap(
                    onTap: () async {
                      if (titleController.text.isEmpty || 
                          contentController.text.isEmpty) {
                        ToastService.showError('Please fill in all fields');
                        return;
                      }
                      
                      Navigator.pop(context);
                      
                      final success = await _controller.publishItem(
                        title: titleController.text,
                        kind: selectedKind,
                        content: contentController.text,
                      );
                      
                      if (success) {
                        ToastService.showSuccess('📚 Knowledge shared!');
                        _loadItems();
                      } else {
                        ToastService.showError('Failed to share');
                      }
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF64D2FF), Color(0xFF5AC8FA)],
                        ),
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF64D2FF).withOpacity(0.35),
                            blurRadius: 15,
                            offset: const Offset(0, 5),
                          ),
                        ],
                      ),
                      child: const Center(
                        child: Text(
                          'Share',
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
        ),
      ),
    );
  }

  Widget _buildLabel(String text) {
    return Text(
      text,
      style: TextStyle(
        color: Colors.white.withOpacity(0.6),
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hint,
    int maxLines = 1,
  }) {
    return TextField(
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
            color: Color(0xFF64D2FF),
            width: 1,
          ),
        ),
        contentPadding: const EdgeInsets.all(16),
      ),
    );
  }

  void _showItemDetails(KnowledgeItem item) {
    HapticFeedback.lightImpact();
    
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.65,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        builder: (context, scrollController) => ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
            child: Container(
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
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.all(28),
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
                  
                  // Type badge & score
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: _getKindColor(item.kind).withOpacity(0.2),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: _getKindColor(item.kind).withOpacity(0.3),
                            width: 0.5,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _getKindIcon(item.kind),
                              color: _getKindColor(item.kind),
                              size: 14,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              item.kind.toUpperCase(),
                              style: TextStyle(
                                color: _getKindColor(item.kind),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      _ScoreBadge(score: item.score),
                    ],
                  ),
                  const SizedBox(height: 20),
                  
                  // Title
                  Text(
                    item.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  
                  // Expiry
                  Row(
                    children: [
                      Icon(
                        Icons.access_time,
                        size: 14,
                        color: Colors.white.withOpacity(0.4),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Expires ${_formatExpiry(item.expiresAt)}',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.4),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  
                  // Content
                  LiquidGlassContainer(
                    blur: 10,
                    borderRadius: 16,
                    padding: const EdgeInsets.all(20),
                    child: SelectableText(
                      item.payloadText ?? 'No content',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.9),
                        fontSize: 16,
                        height: 1.65,
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  
                  // Actions
                  Row(
                    children: [
                      Expanded(
                        child: ScaleTap(
                          onTap: () {
                            Clipboard.setData(ClipboardData(
                              text: item.payloadText ?? '',
                            ));
                            ToastService.showSuccess('Copied to clipboard');
                          },
                          child: _ActionButton(
                            icon: Icons.copy,
                            label: 'Copy',
                            color: const Color(0xFF64D2FF),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ScaleTap(
                          onTap: () async {
                            Navigator.pop(context);
                            await _controller.deleteItem(item.hash);
                            _loadItems();
                            ToastService.showInfo('Item deleted');
                          },
                          child: _ActionButton(
                            icon: Icons.delete_outline,
                            label: 'Delete',
                            color: const Color(0xFFFF453A),
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
    );
  }

  IconData _getKindIcon(String kind) {
    switch (kind.toLowerCase()) {
      case 'link': return Icons.link;
      case 'note': return Icons.note;
      case 'file': return Icons.insert_drive_file;
      default: return Icons.text_snippet;
    }
  }

  Color _getKindColor(String kind) {
    switch (kind.toLowerCase()) {
      case 'link': return const Color(0xFF0A84FF);
      case 'note': return const Color(0xFFFFD60A);
      case 'file': return const Color(0xFF30D158);
      default: return const Color(0xFF64D2FF);
    }
  }

  String _formatExpiry(DateTime expiry) {
    final diff = expiry.difference(DateTime.now());
    if (diff.isNegative) return 'Expired';
    if (diff.inMinutes < 60) return 'in ${diff.inMinutes}m';
    if (diff.inHours < 24) return 'in ${diff.inHours}h';
    return 'in ${diff.inDays}d';
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// HELPER WIDGETS
// ═══════════════════════════════════════════════════════════════════════════

class _CategoryData {
  final String name;
  final IconData icon;
  final Color color;
  
  _CategoryData(this.name, this.icon, this.color);
}

class _KnowledgeCard extends StatelessWidget {
  final KnowledgeItem item;
  final VoidCallback onTap;

  const _KnowledgeCard({
    required this.item,
    required this.onTap,
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
                  // Icon with gradient
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          _getKindColor(item.kind).withOpacity(0.4),
                          _getKindColor(item.kind).withOpacity(0.2),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: _getKindColor(item.kind).withOpacity(0.2),
                          blurRadius: 8,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                    child: Icon(
                      _getKindIcon(item.kind),
                      color: _getKindColor(item.kind),
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
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
                          item.kind.toUpperCase(),
                          style: TextStyle(
                            color: _getKindColor(item.kind).withOpacity(0.8),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _ScoreBadge(score: item.score, mini: true),
                ],
              ),
              if (item.payloadText != null && item.payloadText!.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(
                  item.payloadText!,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.6),
                    fontSize: 14,
                    height: 1.4,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  IconData _getKindIcon(String kind) {
    switch (kind.toLowerCase()) {
      case 'link': return Icons.link;
      case 'note': return Icons.note;
      case 'file': return Icons.insert_drive_file;
      default: return Icons.text_snippet;
    }
  }

  Color _getKindColor(String kind) {
    switch (kind.toLowerCase()) {
      case 'link': return const Color(0xFF0A84FF);
      case 'note': return const Color(0xFFFFD60A);
      case 'file': return const Color(0xFF30D158);
      default: return const Color(0xFF64D2FF);
    }
  }
}

class _ScoreBadge extends StatelessWidget {
  final int score;
  final bool mini;

  const _ScoreBadge({
    required this.score,
    this.mini = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: mini ? 10 : 12,
        vertical: mini ? 5 : 6,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFFFF9F0A).withOpacity(0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: const Color(0xFFFF9F0A).withOpacity(0.2),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.star_rounded,
            size: mini ? 12 : 14,
            color: const Color(0xFFFF9F0A),
          ),
          SizedBox(width: mini ? 3 : 4),
          Text(
            '$score',
            style: TextStyle(
              color: const Color(0xFFFF9F0A),
              fontSize: mini ? 12 : 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _KindChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  const _KindChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.color,
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          gradient: selected
              ? LinearGradient(
                  colors: [color, color.withOpacity(0.7)],
                )
              : null,
          color: selected ? null : Colors.white.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: color.withOpacity(0.3),
                    blurRadius: 12,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: selected ? Colors.white : Colors.white.withOpacity(0.6),
              size: 18,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : Colors.white.withOpacity(0.6),
                fontSize: 14,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
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
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: color.withOpacity(0.3),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
