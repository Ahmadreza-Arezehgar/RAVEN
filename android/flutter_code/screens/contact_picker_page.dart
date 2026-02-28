import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../services/database_helper.dart';
import '../models/contact_model.dart';

/// Picker mode for contact selection
enum PickerMode { single, multi }

/// Contact Picker Page - Unified for New Message and Create Group
class ContactPickerPage extends StatefulWidget {
  final PickerMode mode;

  const ContactPickerPage({
    super.key,
    required this.mode,
  });

  @override
  State<ContactPickerPage> createState() => _ContactPickerPageState();
}

class _ContactPickerPageState extends State<ContactPickerPage> {
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selectedIds = {};
  String _searchQuery = '';
  
  // ✅ Combined friends list from both sources
  List<Map<String, dynamic>> _allFriends = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadFriends();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// ✅ Load friends from BOTH in-memory list AND database
  Future<void> _loadFriends() async {
    setState(() => _isLoading = true);
    
    try {
      // 🔍 DEBUG: First dump all contacts to see what's in DB
      await DatabaseHelper.instance.debugDumpContacts();
      
      // Get from AppModel (in-memory, from server)
      final model = context.read<AppModel>();
      final memoryFriends = List<Map<String, dynamic>>.from(model.friends);
      
      // Get from database (includes newly synced friends)
      final dbContacts = await DatabaseHelper.instance.getFriendsContacts();
      
      // Merge both sources (DB might have friends that memory doesn't)
      final allIds = <String>{};
      final merged = <Map<String, dynamic>>[];
      
      // First add memory friends
      for (final f in memoryFriends) {
        final id = f['id'] as String? ?? '';
        if (id.isNotEmpty && !allIds.contains(id)) {
          allIds.add(id);
          merged.add(f);
        }
      }
      
      // Then add DB friends not in memory
      for (final c in dbContacts) {
        if (!allIds.contains(c.userId)) {
          allIds.add(c.userId);
          merged.add({
            'id': c.userId,
            'username': c.username,
            'avatar_path': c.avatarUrl,
          });
        }
      }
      
      if (mounted) {
        setState(() {
          _allFriends = merged;
          _isLoading = false;
        });
      }
      
      print('👥 [ContactPicker] Loaded ${merged.length} friends (${memoryFriends.length} memory + ${dbContacts.length} DB)');
    } catch (e) {
      print('❌ [ContactPicker] Failed to load friends: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  bool get isSingleMode => widget.mode == PickerMode.single;
  bool get isMultiMode => widget.mode == PickerMode.multi;

  List<Map<String, dynamic>> _getFilteredFriends(List<Map<String, dynamic>> friends) {
    if (_searchQuery.isEmpty) return friends;
    
    return friends.where((f) {
      final username = (f['username'] as String? ?? '').toLowerCase();
      final name = (f['name'] as String? ?? '').toLowerCase();
      final query = _searchQuery.toLowerCase();
      return username.contains(query) || name.contains(query);
    }).toList();
  }

  void _onFriendTap(Map<String, dynamic> friend) {
    HapticFeedback.selectionClick();
    
    final userId = friend['id'] as String? ?? '';
    
    if (isSingleMode) {
      // Single mode: return immediately
      Navigator.pop(context, friend);
    } else {
      // Multi mode: toggle selection
      setState(() {
        if (_selectedIds.contains(userId)) {
          _selectedIds.remove(userId);
        } else {
          _selectedIds.add(userId);
        }
      });
    }
  }

  void _onNextTap(List<Map<String, dynamic>> friends) {
    if (_selectedIds.isEmpty) return;
    
    HapticFeedback.lightImpact();
    
    // Return selected friends
    final selectedFriends = friends.where(
      (f) => _selectedIds.contains(f['id'] as String? ?? '')
    ).toList();
    
    Navigator.pop(context, selectedFriends);
  }

  @override
  Widget build(BuildContext context) {
    final filteredFriends = _getFilteredFriends(_allFriends);
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
                  bottom: 12,
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
                child: Row(
                  children: [
                    // Back button
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios, color: Color(0xFF0A84FF)),
                      onPressed: () {
                        HapticFeedback.selectionClick();
                        Navigator.pop(context);
                      },
                    ),
                    
                    const Spacer(),
                    
                    // Title
                    Text(
                      isSingleMode ? 'Select Contact' : 'Add Members',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    
                    const Spacer(),
                    
                    // Refresh button
                    IconButton(
                      icon: const Icon(Icons.refresh, color: Color(0xFF0A84FF)),
                      onPressed: () {
                        HapticFeedback.selectionClick();
                        _loadFriends();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ═══════════════════════════════════════════════════════════
          // SEARCH BAR
          // ═══════════════════════════════════════════════════════════
          Padding(
            padding: const EdgeInsets.all(16),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.white.withOpacity(0.1),
                  width: 0.5,
                ),
              ),
              child: TextField(
                controller: _searchController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Search friends...',
                  hintStyle: TextStyle(color: Colors.white.withOpacity(0.4)),
                  prefixIcon: Icon(Icons.search, color: Colors.white.withOpacity(0.5)),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                ),
                onChanged: (value) {
                  setState(() => _searchQuery = value);
                },
              ),
            ),
          ),

          // ═══════════════════════════════════════════════════════════
          // SELECTED CHIPS (Multi mode only)
          // ═══════════════════════════════════════════════════════════
          if (isMultiMode && _selectedIds.isNotEmpty)
            Container(
              height: 50,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: _selectedIds.length,
                itemBuilder: (context, index) {
                  final userId = _selectedIds.elementAt(index);
                  final friend = _allFriends.firstWhere(
                    (f) => f['id'] == userId,
                    orElse: () => {'username': 'Unknown'},
                  );
                  final username = friend['username'] as String? ?? 'Unknown';
                  
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => _selectedIds.remove(userId));
                      },
                      child: Chip(
                        backgroundColor: const Color(0xFF0A84FF).withOpacity(0.2),
                        label: Text(
                          username,
                          style: const TextStyle(color: Color(0xFF0A84FF)),
                        ),
                        deleteIcon: const Icon(Icons.close, size: 16, color: Color(0xFF0A84FF)),
                        onDeleted: () {
                          HapticFeedback.selectionClick();
                          setState(() => _selectedIds.remove(userId));
                        },
                      ),
                    ),
                  );
                },
              ),
            ),

          // ═══════════════════════════════════════════════════════════
          // FRIENDS LIST
          // ═══════════════════════════════════════════════════════════
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF0A84FF)))
                : filteredFriends.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.people_outline,
                              size: 48,
                              color: Colors.white.withOpacity(0.3),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              _allFriends.isEmpty ? 'No friends yet' : 'No results',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.5),
                                fontSize: 16,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: EdgeInsets.only(bottom: isMultiMode ? 100 : safeBottom + 16),
                        itemCount: filteredFriends.length,
                        itemBuilder: (context, index) {
                          final friend = filteredFriends[index];
                          final userId = friend['id'] as String? ?? '';
                          final username = friend['username'] as String? ?? 'Unknown';
                          final name = friend['name'] as String? ?? username;
                          final isSelected = _selectedIds.contains(userId);
                          
                          return _FriendListTile(
                            username: username,
                            name: name,
                            isSelected: isSelected,
                            showCheckbox: isMultiMode,
                            onTap: () => _onFriendTap(friend),
                          );
                        },
                      ),
          ),

          // ═══════════════════════════════════════════════════════════
          // NEXT BUTTON (Multi mode only)
          // ═══════════════════════════════════════════════════════════
          if (isMultiMode)
            Container(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 12,
                bottom: safeBottom + 12,
              ),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.8),
                border: Border(
                  top: BorderSide(
                    color: Colors.white.withOpacity(0.1),
                    width: 0.5,
                  ),
                ),
              ),
              child: GestureDetector(
                onTap: _selectedIds.isNotEmpty 
                    ? () => _onNextTap(_allFriends) 
                    : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  height: 52,
                  decoration: BoxDecoration(
                    color: _selectedIds.isNotEmpty
                        ? const Color(0xFF0A84FF)
                        : Colors.white.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(26),
                  ),
                  child: Center(
                    child: Text(
                      _selectedIds.isEmpty
                          ? 'Select members'
                          : 'Next (${_selectedIds.length} selected)',
                      style: TextStyle(
                        color: _selectedIds.isNotEmpty
                            ? Colors.white
                            : Colors.white.withOpacity(0.4),
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// FRIEND LIST TILE
// ══════════════════════════════════════════════════════════════════════════
class _FriendListTile extends StatelessWidget {
  final String username;
  final String name;
  final bool isSelected;
  final bool showCheckbox;
  final VoidCallback onTap;

  const _FriendListTile({
    required this.username,
    required this.name,
    required this.isSelected,
    required this.showCheckbox,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF0A84FF).withOpacity(0.1) : Colors.transparent,
          border: Border(
            bottom: BorderSide(
              color: Colors.white.withOpacity(0.05),
              width: 0.5,
            ),
          ),
        ),
        child: Row(
          children: [
            // Avatar
            CircleAvatar(
              radius: 24,
              backgroundColor: const Color(0xFF0A84FF).withOpacity(0.2),
              child: Text(
                username.isNotEmpty ? username[0].toUpperCase() : '?',
                style: const TextStyle(
                  color: Color(0xFF0A84FF),
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 14),
            
            // Name & Username
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '@$username',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.5),
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
            
            // Checkbox (multi mode)
            if (showCheckbox)
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isSelected ? const Color(0xFF0A84FF) : Colors.transparent,
                  border: Border.all(
                    color: isSelected 
                        ? const Color(0xFF0A84FF) 
                        : Colors.white.withOpacity(0.3),
                    width: 2,
                  ),
                ),
                child: isSelected
                    ? const Icon(Icons.check, color: Colors.white, size: 16)
                    : null,
              ),
          ],
        ),
      ),
    );
  }
}
