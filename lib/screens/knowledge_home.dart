import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hybrid_messenger/models/fact_model.dart';
import 'package:hybrid_messenger/services/knowledge_service.dart';
import 'package:hybrid_messenger/widgets/fact_card.dart';
import 'package:hybrid_messenger/screens/fact_create_page.dart';
import 'package:hybrid_messenger/screens/fact_detail_page.dart';
import 'package:hybrid_messenger/theme/modern_theme.dart';

/// Main Knowledge Wiki screen with search and tabs
class KnowledgeHomePage extends StatefulWidget {
  const KnowledgeHomePage({super.key});

  @override
  State<KnowledgeHomePage> createState() => _KnowledgeHomePageState();
}

class _KnowledgeHomePageState extends State<KnowledgeHomePage>
    with SingleTickerProviderStateMixin {
  final KnowledgeService _knowledge = KnowledgeService();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  
  late TabController _tabController;
  
  List<Fact> _facts = [];
  List<Fact> _searchResults = [];
  bool _isLoading = true;
  bool _isSearching = false;
  String _currentQuery = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(_onTabChanged);
    _initService();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _initService() async {
    await _knowledge.init();
    await _loadFacts();
  }

  Future<void> _loadFacts() async {
    setState(() => _isLoading = true);
    
    try {
      List<Fact> facts;
      
      switch (_tabController.index) {
        case 0: // For You (all recent)
          facts = await _knowledge.getFacts(limit: 100);
          break;
        case 1: // Nearby (from mesh)
          // TODO: Filter by mesh sync
          facts = await _knowledge.getFacts(limit: 100);
          break;
        case 2: // Verified only
          facts = await _knowledge.getVerifiedFacts(limit: 100);
          break;
        default:
          facts = [];
      }
      
      setState(() {
        _facts = facts;
        _isLoading = false;
      });
    } catch (e) {
      print('❌ [Knowledge] Load error: $e');
      setState(() => _isLoading = false);
    }
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    setState(() {}); // ✅ Rebuild for tab highlight
    _loadFacts();
  }

  Future<void> _onSearch(String query) async {
    _currentQuery = query.trim();
    
    if (_currentQuery.isEmpty) {
      setState(() {
        _isSearching = false;
        _searchResults = [];
      });
      return;
    }

    setState(() => _isSearching = true);
    
    final results = await _knowledge.searchFacts(_currentQuery);
    
    setState(() {
      _searchResults = results;
    });
  }

  void _openCreateFact() {
    HapticFeedback.lightImpact();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FactCreatePage(
          initialTitle: _isSearching ? _currentQuery : null,
        ),
      ),
    ).then((_) => _loadFacts());
  }

  void _openFactDetail(Fact fact) {
    HapticFeedback.lightImpact();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FactDetailPage(fact: fact),
      ),
    ).then((_) => _loadFacts());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ModernTheme.background,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          // Gradient background
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFF0D0D0D),
                  Color(0xFF1A1A2E),
                  Color(0xFF16213E),
                ],
                stops: [0.0, 0.5, 1.0],
              ),
            ),
          ),
          
          SafeArea(
            child: Column(
              children: [
                // Header
                _buildHeader(),
                
                // Search bar
                _buildSearchBar(),
                
                // Tabs
                if (!_isSearching) _buildTabs(),
                
                // Content
                Expanded(
                  child: _isSearching 
                      ? _buildSearchResults()
                      : _buildFactList(),
                ),
              ],
            ),
          ),
          
          // FAB
          Positioned(
            right: 20,
            bottom: 30 + MediaQuery.of(context).padding.bottom,
            child: _buildFab(),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.arrow_back,
                color: Colors.white,
                size: 22,
              ),
            ),
          ),
          const SizedBox(width: 16),
          const Expanded(
            child: Text(
              'Knowledge',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
          Icon(
            Icons.auto_stories,
            color: Colors.white.withOpacity(0.6),
            size: 28,
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.12)),
            ),
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocus,
              onChanged: _onSearch,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              decoration: InputDecoration(
                hintText: 'Search knowledge...',
                hintStyle: TextStyle(color: Colors.white.withOpacity(0.4)),
                prefixIcon: Icon(
                  Icons.search,
                  color: Colors.white.withOpacity(0.5),
                ),
                suffixIcon: _isSearching
                    ? IconButton(
                        icon: Icon(
                          Icons.close,
                          color: Colors.white.withOpacity(0.5),
                        ),
                        onPressed: () {
                          _searchController.clear();
                          _onSearch('');
                          _searchFocus.unfocus();
                        },
                      )
                    : null,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTabs() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.06),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: Colors.white.withOpacity(0.12),
                width: 1,
              ),
            ),
            child: Row(
              children: List.generate(3, (i) {
                final labels = ['For You', 'Nearby', 'Verified'];
                final selected = _tabController.index == i;
                return Expanded(
                  child: GestureDetector(
                    onTap: () {
                      if (_tabController.index == i) return; // ✅ Prevent re-tap
                      HapticFeedback.selectionClick();
                      _tabController.animateTo(i); // ✅ listener handles setState
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: selected
                            ? Colors.white.withOpacity(0.14)
                            : Colors.transparent,
                      ),
                      child: Center(
                        child: Text(
                          labels[i],
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.white.withOpacity(selected ? 0.95 : 0.55),
                            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFactList() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white54),
      );
    }

    if (_facts.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_stories,
              size: 64,
              color: Colors.white.withOpacity(0.3),
            ),
            const SizedBox(height: 16),
            Text(
              'No facts yet',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Colors.white.withOpacity(0.7),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Be the first to share knowledge!',
              style: TextStyle(
                fontSize: 14,
                color: Colors.white.withOpacity(0.5),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadFacts,
      color: Colors.white,
      backgroundColor: Colors.white.withOpacity(0.1),
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 100),
        itemCount: _facts.length,
        itemBuilder: (context, index) {
          final fact = _facts[index];
          return FactCard(
            fact: fact,
            onTap: () => _openFactDetail(fact),
          );
        },
      ),
    );
  }

  Widget _buildSearchResults() {
    if (_searchResults.isEmpty) {
      return KnowledgeEmptyState(
        query: _currentQuery,
        onCreateFact: _openCreateFact,
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 100),
      itemCount: _searchResults.length,
      itemBuilder: (context, index) {
        final fact = _searchResults[index];
        return FactCard(
          fact: fact,
          onTap: () => _openFactDetail(fact),
        );
      },
    );
  }

  Widget _buildFab() {
    return GestureDetector(
      onTap: _openCreateFact,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF6366F1),
                  Color(0xFF8B5CF6),
                ],
              ),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF6366F1).withOpacity(0.4),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: const Icon(
              Icons.add,
              color: Colors.white,
              size: 28,
            ),
          ),
        ),
      ),
    );
  }
}
