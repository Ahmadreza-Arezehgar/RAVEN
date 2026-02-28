import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';

/// ProfilePreviewSheet - Liquid Glass profile preview shown on avatar long-press
/// 
/// Features:
/// - Fetches fresh profile data from API
/// - Shows skeleton while loading
/// - Displays avatar with glow, username, bio, and interests as capsule chips
/// - Action buttons: Message, Add Friend, Block, Report
class ProfilePreviewSheet extends StatefulWidget {
  final String userId;
  final String? initialUsername;
  final String? initialAvatarUrl;
  final VoidCallback? onMessage;
  final VoidCallback? onAddFriend;
  final VoidCallback? onBlock;
  final VoidCallback? onReport;

  const ProfilePreviewSheet({
    super.key,
    required this.userId,
    this.initialUsername,
    this.initialAvatarUrl,
    this.onMessage,
    this.onAddFriend,
    this.onBlock,
    this.onReport,
  });

  /// Show the profile preview sheet
  static Future<void> show(
    BuildContext context, {
    required String userId,
    String? initialUsername,
    String? initialAvatarUrl,
    VoidCallback? onMessage,
    VoidCallback? onAddFriend,
    VoidCallback? onBlock,
    VoidCallback? onReport,
  }) {
    HapticFeedback.mediumImpact();
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.5),
      builder: (_) => ProfilePreviewSheet(
        userId: userId,
        initialUsername: initialUsername,
        initialAvatarUrl: initialAvatarUrl,
        onMessage: onMessage,
        onAddFriend: onAddFriend,
        onBlock: onBlock,
        onReport: onReport,
      ),
    );
  }

  @override
  State<ProfilePreviewSheet> createState() => _ProfilePreviewSheetState();
}

class _ProfilePreviewSheetState extends State<ProfilePreviewSheet>
    with SingleTickerProviderStateMixin {
  bool _isLoading = true;
  Map<String, dynamic>? _profile;
  
  late AnimationController _animController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    
    _animController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _scaleAnimation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOutBack,
    );
    
    _animController.forward();
    _loadProfile();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    try {
      final profile = await ApiService.getUserById(widget.userId);
      if (mounted) {
        setState(() {
          _profile = profile;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  List<String> _parseHobbies(dynamic hobbies) {
    if (hobbies == null) return [];
    if (hobbies is List) return hobbies.cast<String>();
    if (hobbies is String && hobbies.isNotEmpty) {
      try {
        // Try JSON parse first
        if (hobbies.startsWith('[')) {
          return List<String>.from((hobbies as dynamic));
        }
        // Fallback to comma-separated
        return hobbies.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      } catch (_) {
        return [];
      }
    }
    return [];
  }

  /// Format join date as "DD MMM YYYY"
  String _formatJoinDate(DateTime date) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 
                    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    final username = _profile?['username'] ?? widget.initialUsername ?? 'User';
    final avatarUrl = _profile?['avatar_path'] ?? widget.initialAvatarUrl;
    final bio = _profile?['bio'] as String?;
    final hobbies = _parseHobbies(_profile?['hobbies']);
    final firstName = _profile?['first_name'] as String?;
    final lastName = _profile?['last_name'] as String?;
    final createdAtStr = _profile?['created_at'] as String?;
    final createdAt = createdAtStr != null ? DateTime.tryParse(createdAtStr) : null;
    
    // Build display name: "FirstName LastName" or fallback to username
    final fullName = [firstName, lastName]
        .where((s) => s?.trim().isNotEmpty == true)
        .join(' ')
        .trim();
    final displayName = fullName.isNotEmpty ? fullName : username;
    
    return GestureDetector(
      onTap: () => Navigator.pop(context),
      behavior: HitTestBehavior.opaque,
      child: Container(
        color: Colors.transparent,
        child: GestureDetector(
          onTap: () {}, // Prevent dismiss on sheet tap
          child: ScaleTransition(
            scale: _scaleAnimation,
            child: DraggableScrollableSheet(
              initialChildSize: 0.45,
              minChildSize: 0.3,
              maxChildSize: 0.7,
              builder: (context, scrollController) {
                return ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF1C1C1E).withOpacity(0.92),
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.12),
                          width: 0.5,
                        ),
                      ),
                      child: SingleChildScrollView(
                        controller: scrollController,
                        child: Column(
                          children: [
                            // Drag handle
                            Container(
                              margin: const EdgeInsets.only(top: 12),
                              width: 36,
                              height: 4,
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.3),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            
                            const SizedBox(height: 24),
                            
                            // Avatar with glow
                            _buildAvatar(avatarUrl, username),
                            
                            const SizedBox(height: 16),
                            
                            // Full Name (FirstName LastName)
                            _isLoading
                                ? _buildSkeletonText(width: 140, height: 24)
                                : Text(
                                    displayName,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 22,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                            
                            const SizedBox(height: 4),
                            
                            // @username
                            _isLoading
                                ? _buildSkeletonText(width: 100, height: 16)
                                : Text(
                                    '@$username',
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.5),
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                            
                            const SizedBox(height: 4),
                            
                            // Joined date
                            if (!_isLoading && createdAt != null)
                              Text(
                                'Joined: ${_formatJoinDate(createdAt)}',
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.35),
                                  fontSize: 12,
                                ),
                              ),
                            
                            const SizedBox(height: 16),
                            
                            // Bio
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 24),
                              child: _isLoading
                                  ? Column(
                                      children: [
                                        _buildSkeletonText(width: double.infinity, height: 14),
                                        const SizedBox(height: 6),
                                        _buildSkeletonText(width: 200, height: 14),
                                      ],
                                    )
                                  : bio != null && bio.isNotEmpty
                                      ? Text(
                                          bio,
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: Colors.white.withOpacity(0.7),
                                            fontSize: 15,
                                            height: 1.4,
                                          ),
                                          maxLines: 3,
                                          overflow: TextOverflow.ellipsis,
                                        )
                                      : Text(
                                          'No bio yet',
                                          style: TextStyle(
                                            color: Colors.white.withOpacity(0.4),
                                            fontSize: 14,
                                            fontStyle: FontStyle.italic,
                                          ),
                                        ),
                            ),
                            
                            const SizedBox(height: 20),
                            
                            // Hobbies/Interests chips
                            if (!_isLoading && hobbies.isNotEmpty)
                              _buildHobbiesSection(hobbies),
                            
                            const SizedBox(height: 24),
                            
                            // Action buttons
                            _buildActionButtons(),
                            
                            const SizedBox(height: 32),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAvatar(String? avatarUrl, String username) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0A84FF).withOpacity(0.3),
            blurRadius: 30,
            spreadRadius: 8,
          ),
        ],
      ),
      child: CircleAvatar(
        radius: 50,
        backgroundColor: const Color(0xFF3A3A3C),
        backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
        child: avatarUrl == null
            ? Text(
                username.isNotEmpty ? username[0].toUpperCase() : '?',
                style: const TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              )
            : null,
      ),
    );
  }

  Widget _buildHobbiesSection(List<String> hobbies) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: hobbies.take(8).map((hobby) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: const Color(0xFF0A84FF).withOpacity(0.15),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: const Color(0xFF0A84FF).withOpacity(0.3),
              ),
            ),
            child: Text(
              hobby,
              style: const TextStyle(
                color: Color(0xFF0A84FF),
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildActionButtons() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          // Message button
          Expanded(
            child: _buildActionButton(
              icon: Icons.message_rounded,
              label: 'Message',
              onTap: widget.onMessage,
              isPrimary: true,
            ),
          ),
          
          const SizedBox(width: 12),
          
          // Add Friend button
          Expanded(
            child: _buildActionButton(
              icon: Icons.person_add_rounded,
              label: 'Add Friend',
              onTap: widget.onAddFriend,
            ),
          ),
          
          const SizedBox(width: 12),
          
          // More options (Block/Report)
          _buildMoreButton(),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
    bool isPrimary = false,
  }) {
    return GestureDetector(
      onTap: onTap != null
          ? () {
              HapticFeedback.selectionClick();
              Navigator.pop(context);
              onTap();
            }
          : null,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: isPrimary
              ? const Color(0xFF0A84FF)
              : Colors.white.withOpacity(0.1),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: Colors.white),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMoreButton() {
    return PopupMenuButton<String>(
      onSelected: (value) {
        Navigator.pop(context);
        if (value == 'block') {
          widget.onBlock?.call();
        } else if (value == 'report') {
          widget.onReport?.call();
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: 'block',
          child: Row(
            children: [
              Icon(Icons.block, color: Colors.red, size: 18),
              SizedBox(width: 8),
              Text('Block', style: TextStyle(color: Colors.red)),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'report',
          child: Row(
            children: [
              Icon(Icons.flag_outlined, color: Colors.orange, size: 18),
              SizedBox(width: 8),
              Text('Report'),
            ],
          ),
        ),
      ],
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.1),
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Icon(Icons.more_horiz, color: Colors.white),
      ),
    );
  }

  Widget _buildSkeletonText({required double width, required double height}) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}
