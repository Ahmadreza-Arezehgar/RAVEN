import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../models/post_model.dart';
import '../services/toast_service.dart';
import '../widgets/ios_post_card.dart';

/// Hashtag Feed Page - Shows all posts with a specific hashtag
class HashtagFeedPage extends StatefulWidget {
  final String hashtag;

  const HashtagFeedPage({
    super.key,
    required this.hashtag,
  });

  @override
  State<HashtagFeedPage> createState() => _HashtagFeedPageState();
}

class _HashtagFeedPageState extends State<HashtagFeedPage> {
  bool _isFollowing = false;
  String _sortMode = 'new'; // 'new' or 'top'
  bool _isLoading = true;
  List<Post> _posts = [];

  @override
  void initState() {
    super.initState();
    _loadPosts();
  }

  Future<void> _loadPosts() async {
    setState(() => _isLoading = true);
    
    // Get posts from AppModel and filter by hashtag
    final model = context.read<AppModel>();
    final allPosts = await model.getPosts(isLocal: true);
    
    // Filter posts containing the hashtag
    final tagLower = widget.hashtag.toLowerCase();
    final filtered = allPosts.where((post) {
      final text = post.content.toLowerCase();
      return text.contains('#$tagLower') || 
             text.contains('#${widget.hashtag}');
    }).toList();
    
    // Sort based on mode
    if (_sortMode == 'new') {
      filtered.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    } else {
      // Top: sort by likes
      filtered.sort((a, b) => b.likes.compareTo(a.likes));
    }
    
    setState(() {
      _posts = filtered;
      _isLoading = false;
    });
  }

  void _toggleFollow() {
    HapticFeedback.selectionClick();
    setState(() => _isFollowing = !_isFollowing);
    
    // TODO: Call API to follow/unfollow hashtag
    ToastService.showSuccess(_isFollowing 
        ? 'Following #${widget.hashtag}' 
        : 'Unfollowed #${widget.hashtag}');
  }

  void _changeSortMode(String mode) {
    if (_sortMode == mode) return;
    HapticFeedback.selectionClick();
    setState(() => _sortMode = mode);
    _loadPosts();
  }

  @override
  Widget build(BuildContext context) {
    final safeTop = MediaQuery.of(context).padding.top;
    final safeBottom = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          // ═══════════════════════════════════════════════════════════
          // HEADER
          // ═══════════════════════════════════════════════════════════
          ClipRRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
              child: Container(
                padding: EdgeInsets.only(
                  top: safeTop + 8,
                  left: 8,
                  right: 16,
                  bottom: 16,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.4),
                  border: Border(
                    bottom: BorderSide(
                      color: Colors.white.withOpacity(0.08),
                      width: 0.5,
                    ),
                  ),
                ),
                child: Column(
                  children: [
                    // Top row: Back, Title, Follow
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(
                            Icons.arrow_back_ios,
                            color: Color(0xFF0A84FF),
                          ),
                          onPressed: () {
                            HapticFeedback.selectionClick();
                            Navigator.pop(context);
                          },
                        ),
                        
                        const Spacer(),
                        
                        // Hashtag title
                        Column(
                          children: [
                            Text(
                              '#${widget.hashtag}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${_posts.length} posts',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.5),
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                        
                        const Spacer(),
                        
                        // Follow button
                        GestureDetector(
                          onTap: _toggleFollow,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: _isFollowing
                                  ? Colors.white.withOpacity(0.1)
                                  : const Color(0xFF0A84FF),
                              borderRadius: BorderRadius.circular(20),
                              border: _isFollowing
                                  ? Border.all(
                                      color: Colors.white.withOpacity(0.2),
                                      width: 1,
                                    )
                                  : null,
                            ),
                            child: Text(
                              _isFollowing ? 'Following' : 'Follow',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    
                    const SizedBox(height: 12),
                    
                    // Sort toggle
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _SortButton(
                          title: 'New',
                          isSelected: _sortMode == 'new',
                          onTap: () => _changeSortMode('new'),
                        ),
                        const SizedBox(width: 8),
                        _SortButton(
                          title: 'Top',
                          isSelected: _sortMode == 'top',
                          onTap: () => _changeSortMode('top'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ═══════════════════════════════════════════════════════════
          // POSTS LIST
          // ═══════════════════════════════════════════════════════════
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(
                      color: Color(0xFF0A84FF),
                    ),
                  )
                : _posts.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.tag,
                              size: 48,
                              color: Colors.white.withOpacity(0.3),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No posts with #${widget.hashtag}',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.5),
                                fontSize: 16,
                              ),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        color: const Color(0xFF0A84FF),
                        backgroundColor: Colors.black.withOpacity(0.8),
                        onRefresh: _loadPosts,
                        child: ListView.builder(
                          padding: EdgeInsets.only(
                            top: 8,
                            bottom: safeBottom + 100,
                          ),
                          itemCount: _posts.length,
                          itemBuilder: (context, index) {
                            final post = _posts[index];
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              child: iOSPostCard(post: post),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// SORT BUTTON
// ══════════════════════════════════════════════════════════════════════════
class _SortButton extends StatelessWidget {
  final String title;
  final bool isSelected;
  final VoidCallback onTap;

  const _SortButton({
    required this.title,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF0A84FF).withOpacity(0.2)
              : Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF0A84FF).withOpacity(0.5)
                : Colors.white.withOpacity(0.1),
            width: 1,
          ),
        ),
        child: Text(
          title,
          style: TextStyle(
            color: isSelected 
                ? const Color(0xFF0A84FF) 
                : Colors.white.withOpacity(0.6),
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
