import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:ui';
import '../theme/ios_design_system.dart';
import '../models/post_model.dart';
import '../services/api_service.dart';
import '../services/toast_service.dart';

/// Forward sheet - Liquid Glass panel to send posts to friends
class ForwardSheet extends StatefulWidget {
  final Post post;
  final Function(List<String> recipientIds) onSend;
  
  const ForwardSheet({
    super.key,
    required this.post,
    required this.onSend,
  });
  
  /// Show the sheet as a modal bottom sheet
  static Future<void> show(
    BuildContext context, {
    required Post post,
    required Function(List<String> recipientIds) onSend,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => ForwardSheet(
          post: post,
          onSend: onSend,
        ),
      ),
    );
  }
  
  @override
  State<ForwardSheet> createState() => _ForwardSheetState();
}

class _ForwardSheetState extends State<ForwardSheet> {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _friends = [];
  List<Map<String, dynamic>> _filteredFriends = [];
  final Set<String> _selectedIds = {};
  bool _isLoading = true;
  bool _isSending = false;
  
  @override
  void initState() {
    super.initState();
    _loadFriends();
  }
  
  Future<void> _loadFriends() async {
    try {
      final friends = await ApiService.getFriends();
      setState(() {
        _friends = friends;
        _filteredFriends = friends;
        _isLoading = false;
      });
    } catch (e) {
      print('❌ Failed to load friends: $e');
      setState(() => _isLoading = false);
    }
  }
  
  void _filterFriends(String query) {
    setState(() {
      if (query.isEmpty) {
        _filteredFriends = _friends;
      } else {
        _filteredFriends = _friends.where((friend) {
          final name = (friend['username'] ?? '').toString().toLowerCase();
          return name.contains(query.toLowerCase());
        }).toList();
      }
    });
  }
  
  void _toggleSelection(String id) {
    HapticFeedback.selectionClick();
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }
  
  Future<void> _sendToSelected() async {
    if (_selectedIds.isEmpty) return;
    
    setState(() => _isSending = true);
    HapticFeedback.mediumImpact();
    
    try {
      widget.onSend(_selectedIds.toList());
      Navigator.pop(context);
      ToastService.showSuccess('Post forwarded to ${_selectedIds.length} friend${_selectedIds.length > 1 ? 's' : ''}');
    } catch (e) {
      ToastService.showError('Failed to forward post');
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: Container(
          decoration: BoxDecoration(
            color: iOSDesignSystem.surfaceElevated.withOpacity(0.92),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(
              color: Colors.white.withOpacity(0.12),
              width: 0.5,
            ),
          ),
          child: Column(
            children: [
              // Handle bar
              Container(
                margin: const EdgeInsets.only(top: 12),
                width: 36,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2.5),
                ),
              ),
              
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                child: Row(
                  children: [
                    Text(
                      'Forward to...',
                      style: iOSDesignSystem.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    if (_selectedIds.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: iOSDesignSystem.accentBlue.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${_selectedIds.length} selected',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: iOSDesignSystem.accentBlue,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              
              // Search bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: TextField(
                    controller: _searchController,
                    onChanged: _filterFriends,
                    style: TextStyle(color: iOSDesignSystem.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'Search friends...',
                      hintStyle: TextStyle(color: iOSDesignSystem.textTertiary),
                      prefixIcon: Icon(Icons.search, color: iOSDesignSystem.textTertiary),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    ),
                  ),
                ),
              ),
              
              const SizedBox(height: 12),
              
              // Post preview
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white.withOpacity(0.08)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.article_outlined, color: iOSDesignSystem.textTertiary, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.post.content.length > 60 
                            ? '${widget.post.content.substring(0, 60)}...' 
                            : widget.post.content,
                        style: TextStyle(
                          fontSize: 13,
                          color: iOSDesignSystem.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              
              const SizedBox(height: 8),
              
              // Friends list
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _filteredFriends.isEmpty
                        ? Center(
                            child: Text(
                              'No friends found',
                              style: TextStyle(color: iOSDesignSystem.textTertiary),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            itemCount: _filteredFriends.length,
                            itemBuilder: (context, index) {
                              final friend = _filteredFriends[index];
                              final id = friend['id'] as String;
                              final isSelected = _selectedIds.contains(id);
                              
                              return _FriendTile(
                                friend: friend,
                                isSelected: isSelected,
                                onTap: () => _toggleSelection(id),
                              );
                            },
                          ),
              ),
              
              // Send button
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: AnimatedOpacity(
                    opacity: _selectedIds.isNotEmpty ? 1.0 : 0.5,
                    duration: const Duration(milliseconds: 200),
                    child: SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        onPressed: _selectedIds.isNotEmpty ? _sendToSelected : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: iOSDesignSystem.accentBlue,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          elevation: 0,
                        ),
                        child: _isSending
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.send, size: 18),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Send${_selectedIds.isNotEmpty ? ' (${_selectedIds.length})' : ''}',
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FriendTile extends StatelessWidget {
  final Map<String, dynamic> friend;
  final bool isSelected;
  final VoidCallback onTap;
  
  const _FriendTile({
    required this.friend,
    required this.isSelected,
    required this.onTap,
  });
  
  @override
  Widget build(BuildContext context) {
    final username = friend['username'] ?? 'Unknown';
    final avatar = friend['avatar_path'] as String?;
    
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected 
              ? iOSDesignSystem.accentBlue.withOpacity(0.15) 
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected 
                ? iOSDesignSystem.accentBlue.withOpacity(0.3) 
                : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            // Avatar
            CircleAvatar(
              radius: 22,
              backgroundColor: iOSDesignSystem.accentBlue.withOpacity(0.2),
              backgroundImage: avatar != null ? NetworkImage(avatar) : null,
              child: avatar == null 
                  ? Text(
                      username.substring(0, 1).toUpperCase(),
                      style: TextStyle(
                        color: iOSDesignSystem.accentBlue,
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  : null,
            ),
            
            const SizedBox(width: 12),
            
            // Name
            Expanded(
              child: Text(
                username,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: iOSDesignSystem.textPrimary,
                ),
              ),
            ),
            
            // Checkbox
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isSelected 
                    ? iOSDesignSystem.accentBlue 
                    : Colors.transparent,
                border: Border.all(
                  color: isSelected 
                      ? iOSDesignSystem.accentBlue 
                      : iOSDesignSystem.textTertiary,
                  width: 2,
                ),
              ),
              child: isSelected
                  ? const Icon(Icons.check, size: 16, color: Colors.white)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
