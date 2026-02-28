import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart';
import '../theme/ios_design_system.dart';
import '../services/api_service.dart';
import '../services/news_service.dart';
import '../services/location_service.dart';
import '../services/database_helper.dart';
import '../services/peek_pop_controller.dart';
import '../services/toast_service.dart';
import '../models/news_article.dart';
import '../models/post_model.dart';
import 'package:url_launcher/url_launcher.dart';
import '../widgets/glass_header.dart';
import '../widgets/ios_post_card.dart';
import 'user_profile_page.dart';

/// Search Page - Explore People & Posts with horizontal/vertical layout
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

enum SearchMode { explore, news }

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  
  SearchMode _mode = SearchMode.explore; // Default: Explore
  List<Map<String, dynamic>> _peopleResults = [];
  List<Post> _postResults = [];
  List<NewsArticle> _newsArticles = [];
  bool _isSearching = false;
  bool _loadingNews = true;
  
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _loadNews();
    _loadInitialContent();
    
    // Listen for focus trigger from Haptic Menu
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkFocusTrigger();
    });
  }

  void _checkFocusTrigger() {
    final model = context.read<AppModel>();
    if (model.shouldFocusSearchField) {
      model.consumeSearchFieldFocus();
      Future.delayed(const Duration(milliseconds: 100), () {
        _searchFocusNode.requestFocus();
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _checkFocusTrigger();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  /// Load initial content (trending/recent people & posts)
  Future<void> _loadInitialContent() async {
    // Load some initial content for Explore mode
    if (_mode == SearchMode.explore) {
      setState(() => _isSearching = true);
      try {
        // Get recent/suggested users (could be friends of friends, etc.)
        // For now, just leave empty until user searches
        _peopleResults = [];
        _postResults = [];
      } catch (e) {
        print('Error loading initial content: $e');
      }
      if (mounted) setState(() => _isSearching = false);
    }
  }

  Future<void> _loadNews({bool forceRefresh = false}) async {
    if (!mounted) return;
    setState(() => _loadingNews = true);

    try {
      final country = await LocationService.getUserCountry();
      final prefs = await SharedPreferences.getInstance();
      final interests = prefs.getStringList('news_interests') ?? ['general'];
      
      final articles = await NewsService.fetchNews(
        country: country,
        interests: interests,
        forceRefresh: forceRefresh,
      );

      if (!mounted) return;
      setState(() {
        _newsArticles = articles;
        _loadingNews = false;
      });
    } catch (e) {
      print('Error loading news: $e');
      if (!mounted) return;
      setState(() => _loadingNews = false);
    }
  }

  void _onQueryChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      await _performSearch(q);
    });
  }

  Future<void> _performSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) {
      if (!mounted) return;
      setState(() {
        _peopleResults = [];
        _postResults = [];
      });
      return;
    }

    if (!mounted) return;
    setState(() => _isSearching = true);

    try {
      // Search both people and posts simultaneously
      final peopleResults = await ApiService.searchUsers(q);
      
      // Search posts: hashtag or text
      List<Post> postResults = [];
      if (q.startsWith('#')) {
        final tag = q.substring(1).toLowerCase();
        postResults = await DatabaseHelper.instance.searchPostsByHashtag(tag);
      } else {
        try {
          postResults = await ApiService.searchPosts(q);
        } catch (_) {}
        
        // Also search local database
        final localResults = await DatabaseHelper.instance.searchPostsByText(q);
        final existingIds = postResults.map((p) => p.id).toSet();
        for (final post in localResults) {
          if (!existingIds.contains(post.id)) {
            postResults.add(post);
          }
        }
        postResults.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      }

      if (!mounted) return;
      setState(() {
        _peopleResults = peopleResults;
        _postResults = postResults;
        _isSearching = false;
      });
    } catch (e) {
      print('Search error: $e');
      if (!mounted) return;
      setState(() => _isSearching = false);
    }
  }

  void _onModeChanged(SearchMode mode) {
    HapticFeedback.selectionClick();
    setState(() {
      _mode = mode;
      if (mode == SearchMode.news) {
        _loadNews();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    final bottomNavHeight = 100.0; // Floating dock height
    
    // Total bottom padding = keyboard height OR bottom nav, whichever is active
    final bottomPadding = keyboardHeight > 0 ? keyboardHeight : bottomNavHeight;
    
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => FocusScope.of(context).unfocus(),
      child: Column(
        children: [
          // Fixed Header Area
          _buildHeader(),
          
          // Content - uses Expanded for proper layout
          Expanded(
            child: _mode == SearchMode.news
                ? _buildNewsContent(bottomPadding)
                : _buildExploreContent(bottomPadding),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.3),
      ),
      child: Column(
        children: [
          // Top row: Back + Search Bar + Filter
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            child: Row(
              children: [
                // Back button
                IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                
                // Search bar (capsule)
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                      child: Container(
                        height: 40,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.15),
                            width: 0.5,
                          ),
                        ),
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          onChanged: _onQueryChanged,
                          style: const TextStyle(color: Colors.white, fontSize: 15),
                          decoration: InputDecoration(
                            hintText: 'Search people, posts...',
                            hintStyle: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 15),
                            prefixIcon: Icon(Icons.search, color: Colors.white.withOpacity(0.5), size: 20),
                            suffixIcon: _searchController.text.isNotEmpty
                                ? IconButton(
                                    icon: Icon(Icons.close_rounded, color: Colors.white.withOpacity(0.5), size: 18),
                                    onPressed: () {
                                      _searchController.clear();
                                      setState(() {
                                        _peopleResults = [];
                                        _postResults = [];
                                      });
                                    },
                                  )
                                : null,
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                
                // Filter button
                IconButton(
                  icon: Icon(Icons.tune_rounded, color: Colors.white.withOpacity(0.7), size: 22),
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    ToastService.showInfo('Filter options coming soon');
                  },
                ),
              ],
            ),
          ),
          
          // Segment: Explore / News (right-aligned)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _buildSegmentChip('Explore', SearchMode.explore),
                const SizedBox(width: 8),
                _buildSegmentChip('News', SearchMode.news),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSegmentChip(String label, SearchMode mode) {
    final isSelected = _mode == mode;
    return GestureDetector(
      onTap: () => _onModeChanged(mode),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected 
              ? const Color(0xFF0A84FF).withOpacity(0.25)
              : Colors.white.withOpacity(0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF0A84FF).withOpacity(0.5)
                : Colors.white.withOpacity(0.12),
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? const Color(0xFF0A84FF) : Colors.white.withOpacity(0.7),
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildExploreContent(double bottomPadding) {
    return RefreshIndicator(
      onRefresh: () => _performSearch(_searchController.text),
      child: CustomScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          // People Section (horizontal)
          SliverToBoxAdapter(
            child: _buildPeopleSection(),
          ),
          
          // Divider
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Container(
                height: 1,
                color: Colors.white.withOpacity(0.1),
              ),
            ),
          ),
          
          // Posts Section
          ..._buildPostsSection(),
          
          // ✅ Bottom padding for keyboard + bottom nav bar
          SliverPadding(
            padding: EdgeInsets.only(bottom: bottomPadding + 20),
          ),
        ],
      ),
    );
  }

  Widget _buildPeopleSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Title
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
          child: Text(
            'People',
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ),
        
        // Horizontal list
        SizedBox(
          height: 180, // ✅ Increased to fit new card height of 175
          child: _isSearching
              ? ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  scrollDirection: Axis.horizontal,
                  itemCount: 6,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (_, __) => _buildPeopleSkeletonCard(),
                )
              : _peopleResults.isEmpty
                  ? Center(
                      child: Text(
                        _searchController.text.isEmpty 
                            ? 'Search for people' 
                            : 'No people found',
                        style: TextStyle(color: Colors.white.withOpacity(0.4)),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      scrollDirection: Axis.horizontal,
                      itemCount: _peopleResults.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 12),
                      itemBuilder: (context, index) => _buildPeopleCard(_peopleResults[index]),
                    ),
        ),
      ],
    );
  }

  Widget _buildPeopleCard(Map<String, dynamic> user) {
    final username = user['username'] ?? 'Unknown';
    final userId = user['id'];
    final firstName = user['first_name'] ?? '';
    final lastName = user['last_name'] ?? '';
    final displayName = '$firstName $lastName'.trim();
    final avatarUrl = user['avatar_path'] ?? user['avatar_url'] ?? user['photo_url'] ?? user['profile_image'];
    
    // Check if already friends or pending request
    final friendshipStatus = user['friendship_status'] ?? 'none'; // none, pending, friends

    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => UserProfilePage(userId: userId ?? ''),
          ),
        );
      },
      onLongPressStart: (details) {
        if (userId == null) return;
        PeekPopController.instance.showPeek(
          context: context,
          anchor: details.globalPosition,
          onPop: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => UserProfilePage(userId: userId)),
            );
          },
          child: ProfilePeekCard(
            username: username,
            avatarUrl: avatarUrl,
            bio: user['bio'],
            onMessage: () {
              PeekPopController.instance.hide();
              final model = context.read<AppModel>();
              model.startChatWith(userId, username);
              Navigator.pushNamed(context, '/chat');
            },
            onFollow: () async {
              PeekPopController.instance.hide();
              await ApiService.sendFriendRequest(userId);
              ToastService.showSuccess('Friend request sent');
            },
          ),
        );
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
          child: Container(
            width: 120,
            height: 175, // ✅ Fixed height to prevent overflow
            padding: const EdgeInsets.all(10), // ✅ Reduced padding
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.1),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: Colors.white.withOpacity(0.15),
                width: 0.5,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                // Avatar
                CircleAvatar(
                  radius: 28, // ✅ Slightly smaller
                  backgroundColor: const Color(0xFF0A84FF).withOpacity(0.2),
                  backgroundImage: avatarUrl != null 
                      ? NetworkImage(avatarUrl) 
                      : null,
                  child: avatarUrl == null
                      ? Text(
                          username.isNotEmpty ? username[0].toUpperCase() : '?',
                          style: const TextStyle(
                            color: Color(0xFF0A84FF),
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        )
                      : null,
                ),
                const SizedBox(height: 8),
                
                // Name - constrained
                Text(
                  displayName.isNotEmpty ? displayName : username,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  textAlign: TextAlign.center,
                ),
                
                // Username - constrained
                Text(
                  '@$username',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.5),
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                ),
                
                // Spacer pushes Add button to bottom
                const Spacer(),
                
                // Add button - pinned at bottom with state handling
                _buildAddButton(userId, friendshipStatus),
              ],
            ),
          ),
        ),
      ),
    );
  }
  
  /// Build Add button with optimistic UI state
  Widget _buildAddButton(String? userId, String friendshipStatus) {
    // Determine button state
    final bool isPending = friendshipStatus == 'pending';
    final bool isFriends = friendshipStatus == 'friends';
    
    if (isFriends) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.green.withOpacity(0.2),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Text(
          'Friends',
          style: TextStyle(
            color: Colors.green,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    
    if (isPending) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.orange.withOpacity(0.2),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Text(
          'Pending',
          style: TextStyle(
            color: Colors.orange,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    
    return GestureDetector(
      onTap: () async {
        HapticFeedback.mediumImpact();
        if (userId == null) {
          ToastService.showError('User ID not found');
          return;
        }
        
        // Log the action
        print('🔵 [Add] Tapping Add for user: $userId');
        
        try {
          final result = await ApiService.sendFriendRequest(userId);
          print('🔵 [Add] Result: $result');
          
          if (result) {
            ToastService.showSuccess('Friend request sent!');
            // Optimistic UI: Update state immediately
            setState(() {
              // Find and update the user in _peopleResults
              final index = _peopleResults.indexWhere((u) => u['id'] == userId);
              if (index != -1) {
                _peopleResults[index]['friendship_status'] = 'pending';
              }
            });
          }
        } catch (e) {
          print('❌ [Add] Error: $e');
          // Check for specific error codes
          if (e.toString().contains('409')) {
            ToastService.showInfo('Request already sent');
          } else if (e.toString().contains('401')) {
            ToastService.showError('Please log in again');
          } else {
            ToastService.showError('Failed to send request');
          }
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFF0A84FF),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Text(
          'Add',
          style: TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildPeopleSkeletonCard() {
    return Container(
      width: 120,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            width: 80,
            height: 14,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.1),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(height: 6),
          Container(
            width: 60,
            height: 12,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildPostsSection() {
    // Title
    final titleSliver = SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Text(
          'Posts',
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ),
    );

    if (_isSearching) {
      return [
        titleSliver,
        // ✅ Use SliverToBoxAdapter instead of SliverFillRemaining to avoid overflow
        SliverToBoxAdapter(
          child: SizedBox(
            height: 150,
            child: const Center(child: CircularProgressIndicator(color: Color(0xFF0A84FF))),
          ),
        ),
      ];
    }

    if (_postResults.isEmpty) {
      return [
        titleSliver,
        // ✅ Use SliverToBoxAdapter instead of SliverFillRemaining
        SliverToBoxAdapter(
          child: SizedBox(
            height: 200,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.article_outlined, size: 48, color: Colors.white.withOpacity(0.3)),
                  const SizedBox(height: 16),
                  Text(
                    _searchController.text.isEmpty ? 'Search for posts' : 'No posts found',
                    style: TextStyle(color: Colors.white.withOpacity(0.4)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ];
    }

    return [
      titleSliver,
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: iOSPostCard(post: _postResults[index]),
          ),
          childCount: _postResults.length,
        ),
      ),
    ];
  }

  Widget _buildNewsContent(double bottomPadding) {
    if (_loadingNews) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFF0A84FF)));
    }

    if (_newsArticles.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.newspaper, size: 48, color: Colors.white.withOpacity(0.3)),
            const SizedBox(height: 16),
            Text(
              'No news available',
              style: TextStyle(color: Colors.white.withOpacity(0.4)),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _loadNews(forceRefresh: true),
      child: ListView.builder(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        // ✅ Add bottom padding for keyboard + bottom nav
        padding: EdgeInsets.only(top: 8, bottom: bottomPadding + 20),
        itemCount: _newsArticles.length,
        itemBuilder: (context, index) => _buildNewsCard(_newsArticles[index]),
      ),
    );
  }

  Widget _buildNewsCard(NewsArticle article) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: iOSDesignSystem.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: iOSDesignSystem.glassBorderMedium,
          width: iOSDesignSystem.glassBorderWidth,
        ),
      ),
      child: InkWell(
        onTap: () async {
          final uri = Uri.parse(article.url);
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri);
          }
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            article.title,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: iOSDesignSystem.accentBlue.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            _getSourceInitials(article.source),
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: iOSDesignSystem.accentBlue,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      article.description,
                      style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.7)),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _formatTimestamp(article.publishedAt),
                      style: TextStyle(fontSize: 10, color: iOSDesignSystem.textSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: iOSDesignSystem.surfaceElevated,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: iOSDesignSystem.glassBorderLight, width: 1),
                ),
                child: article.imageUrl != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.network(
                          article.imageUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _buildImagePlaceholder(),
                        ),
                      )
                    : _buildImagePlaceholder(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImagePlaceholder() {
    return Center(
      child: Icon(Icons.newspaper, size: 32, color: iOSDesignSystem.textTertiary),
    );
  }

  String _getSourceInitials(String source) {
    if (source.toLowerCase().contains('bbc')) return 'BBC';
    if (source.toLowerCase().contains('bloomberg')) return 'BLM';
    if (source.toLowerCase().contains('cnn')) return 'CNN';
    if (source.toLowerCase().contains('fox')) return 'FOX';
    return source.length >= 3 ? source.substring(0, 3).toUpperCase() : source.toUpperCase();
  }

  String _formatTimestamp(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${time.day}/${time.month}/${time.year}';
  }
}
