import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/user_model.dart';
import '../services/api_service.dart';
import '../services/toast_service.dart';
import '../widgets/liquid_glass_card.dart';
import '../theme/ios_design_system.dart';

/// User Profile Page with Bio, Hobbies, and Spotify Preview
class UserProfilePage extends StatefulWidget {
  final String userId;
  
  const UserProfilePage({
    super.key,
    required this.userId,
  });

  @override
  State<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends State<UserProfilePage> {
  User? _user;
  bool _isLoading = true;
  bool _isSubscribed = false;  // Post notification subscription state
  
  // ✅ Stats from API
  int _postCount = 0;
  int _followersCount = 0;
  int _followingCount = 0;
  List<String> _interests = [];
  
  // ✅ Friendship status
  String _friendshipStatus = 'none';  // none, sent, received, friends, self
  String? _friendshipRequestId;
  bool _isFriendActionLoading = false;

  @override
  void initState() {
    super.initState();
    _loadUserProfile();
  }

  Future<void> _loadUserProfile() async {
    print('📱 [Profile] Loading user: ${widget.userId}');
    
    try {
      final userData = await ApiService.getUserById(widget.userId);
      
      if (!mounted) return;
      
      if (userData != null) {
        // ✅ Parse stats from API response
        final stats = userData['stats'] as Map<String, dynamic>? ?? {};
        final interestsList = userData['interests'] as List<dynamic>? ?? [];
        
        setState(() {
          _isLoading = false;
          _user = User(
            id: userData['id'] ?? widget.userId,
            username: userData['username'] ?? userData['display_name'] ?? 'Unknown',
            bio: userData['bio'],
            avatarPath: userData['avatar_path'] ?? userData['avatar_url'],
            createdAt: DateTime.tryParse(userData['created_at'] ?? '') ?? DateTime.now(),
            firstName: userData['first_name'] as String?,
            lastName: userData['last_name'] as String?,
          );
          
          // ✅ Load real stats
          _postCount = stats['posts'] as int? ?? 0;
          _followersCount = stats['followers'] as int? ?? stats['friends'] as int? ?? 0;
          _followingCount = stats['following'] as int? ?? 0;
          
          // ✅ Load friendship status
          final friendship = userData['friendship'] as Map<String, dynamic>? ?? {};
          _friendshipStatus = (friendship['status'] as String?) ?? 'none';
          _friendshipRequestId = friendship['request_id'] as String?;
          _interests = interestsList.map((e) => e.toString()).toList();
        });
        print('✅ [Profile] Loaded: ${_user?.username}');
      } else {
        // User not found - show error state
        setState(() {
          _isLoading = false;
          _user = User(
            id: widget.userId,
            username: 'User not found',
            bio: 'This profile could not be loaded',
            createdAt: DateTime.now(),
          );
        });
        print('❌ [Profile] User not found: ${widget.userId}');
      }
      
      // Load subscription status
      final isSubscribed = await ApiService.getPostNotifyStatus(widget.userId);
      if (mounted) {
        setState(() => _isSubscribed = isSubscribed);
      }
    } catch (e) {
      print('❌ [Profile] Error loading profile: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _user = User(
            id: widget.userId,
            username: 'Error',
            bio: 'Failed to load profile',
            createdAt: DateTime.now(),
          );
        });
      }
    }
  }

  /// Format join date as "DD MMM YYYY"
  String _formatJoinDate(DateTime? date) {
    if (date == null) return '';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 
                    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }

  /// Helper to get avatar image provider (handles both URL and file paths)
  ImageProvider? _getAvatarImage(String? avatarPath) {
    if (avatarPath == null || avatarPath.isEmpty) return null;
    
    // Network URL
    if (avatarPath.startsWith('http://') || avatarPath.startsWith('https://')) {
      return CachedNetworkImageProvider(avatarPath);
    }
    
    // Server path (needs base URL)
    if (avatarPath.startsWith('/uploads/') || avatarPath.startsWith('/static/')) {
      return CachedNetworkImageProvider('${ApiService.baseUrl}$avatarPath');
    }
    
    // Local file
    final file = File(avatarPath);
    if (file.existsSync()) {
      return FileImage(file);
    }
    
    return null;
  }

  /// Send friend request to this user
  Future<void> _sendFriendRequest() async {
    if (_isFriendActionLoading) return;
    setState(() => _isFriendActionLoading = true);
    
    try {
      final success = await ApiService.sendFriendRequest(widget.userId);
      if (success && mounted) {
        setState(() {
          _friendshipStatus = 'sent';
        });
        ToastService.showSuccess('Friend request sent!');
      } else if (mounted) {
        ToastService.showWarning('Could not send friend request');
      }
    } catch (e) {
      print('❌ [Profile] Error sending friend request: $e');
      ToastService.showWarning('Could not send friend request');
    } finally {
      if (mounted) setState(() => _isFriendActionLoading = false);
    }
  }

  /// Accept friend request from this user
  Future<void> _acceptFriendRequest() async {
    if (_isFriendActionLoading || _friendshipRequestId == null) return;
    setState(() => _isFriendActionLoading = true);
    
    try {
      final result = await ApiService.acceptFriendRequest(_friendshipRequestId!);
      if (result != null && mounted) {
        setState(() => _friendshipStatus = 'friends');
        ToastService.showSuccess('You are now friends!');
      }
    } catch (e) {
      print('❌ [Profile] Error accepting friend request: $e');
      ToastService.showWarning('Could not accept request');
    } finally {
      if (mounted) setState(() => _isFriendActionLoading = false);
    }
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: GestureDetector(
          onTap: () {
            HapticFeedback.lightImpact();
            Navigator.pop(context);
          },
          child: Container(
            margin: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.3),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.arrow_back, color: Colors.white),
          ),
        ),
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Colors.white),
            )
          : SingleChildScrollView(
                  child: Column(
                    children: [
                      // Header with avatar
                      _buildHeader(),
                      
                      const SizedBox(height: 24),
                      
                      // Bio Section
                      if (_user?.bio != null && _user!.bio!.isNotEmpty)
                        _buildBioSection(),
                      
                      const SizedBox(height: 16),
                      
                      // Stats Section
                      _buildStatsSection(),
                      
                      const SizedBox(height: 16),
                      
                      // Hobbies / Interests
                      _buildInterestsSection(),
                      
                      const SizedBox(height: 100),
                    ],
                  ),
                ),
    );
  }

  Widget _buildHeader() {
    final safeTop = MediaQuery.of(context).padding.top;
    
    return ClipRRect(
      borderRadius: const BorderRadius.only(
        bottomLeft: Radius.circular(24),
        bottomRight: Radius.circular(24),
      ),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: EdgeInsets.only(top: safeTop + 16, bottom: 24),
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E).withOpacity(0.85),
            borderRadius: const BorderRadius.only(
              bottomLeft: Radius.circular(24),
              bottomRight: Radius.circular(24),
            ),
            border: Border(
              bottom: BorderSide(
                color: Colors.white.withOpacity(0.08),
                width: 0.5,
              ),
            ),
          ),
          child: Column(
            children: [
              // Avatar - Minimal glass style, no gradient ring
              Hero(
                tag: 'avatar_${widget.userId}',
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withOpacity(0.15),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.3),
                        blurRadius: 20,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: CircleAvatar(
                    radius: 44,
                    backgroundColor: const Color(0xFF2C2C2E),
                    backgroundImage: _getAvatarImage(_user?.avatarPath),
                    child: _getAvatarImage(_user?.avatarPath) == null
                        ? Text(
                            _user?.username.isNotEmpty == true
                                ? _user!.username[0].toUpperCase()
                                : 'U',
                            style: const TextStyle(
                              fontSize: 32,
                              fontWeight: FontWeight.w600,
                              color: Colors.white70,
                            ),
                          )
                        : null,
                  ),
                ),
              ),
              
              const SizedBox(height: 14),
              
              // Full Name (FirstName LastName)
              Text(
                _user?.displayName ?? 'User',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                  letterSpacing: -0.3,
                ),
              ),
              
              const SizedBox(height: 2),
              
              // @username
              Text(
                '@${_user?.username.toLowerCase() ?? 'user'}',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white.withOpacity(0.5),
                ),
              ),
              
              const SizedBox(height: 4),
              
              // Joined date
              Text(
                'Joined: ${_formatJoinDate(_user?.createdAt)}',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withOpacity(0.35),
                ),
              ),
              
              // Notify Bell Toggle (only show for other users)
              if (_friendshipStatus != 'self') ...[
                const SizedBox(height: 16),
                _buildNotifyBellToggle(),
              ],
              
              // Friendship Action Button (only for other users)
              if (_friendshipStatus != 'self') ...[
                const SizedBox(height: 12),
                _buildFriendshipButton(),
              ],
            ],
          ),
        ),
      ),
    );
  }
  
  // Bell toggle for post notifications
  Widget _buildNotifyBellToggle() {
    return GestureDetector(
      onTap: () async {
        HapticFeedback.selectionClick();
        setState(() => _isSubscribed = !_isSubscribed);
        
        if (_isSubscribed) {
          await ApiService.enablePostNotify(widget.userId);
        } else {
          await ApiService.disablePostNotify(widget.userId);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: _isSubscribed 
              ? iOSDesignSystem.accentBlue.withOpacity(0.2)
              : Colors.white.withOpacity(0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _isSubscribed
                ? iOSDesignSystem.accentBlue.withOpacity(0.4)
                : Colors.white.withOpacity(0.1),
            width: 0.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _isSubscribed ? Icons.notifications_active : Icons.notifications_none,
              size: 16,
              color: _isSubscribed 
                  ? iOSDesignSystem.accentBlue 
                  : Colors.white.withOpacity(0.6),
            ),
            const SizedBox(width: 6),
            Text(
              _isSubscribed ? 'Subscribed' : 'Notify me',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: _isSubscribed
                    ? iOSDesignSystem.accentBlue
                    : Colors.white.withOpacity(0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Build friendship action button based on status
  Widget _buildFriendshipButton() {
    // Determine button appearance based on friendship status
    IconData icon;
    String label;
    Color bgColor;
    Color borderColor;
    Color contentColor;
    VoidCallback? onTap;
    
    switch (_friendshipStatus) {
      case 'none':
        icon = Icons.person_add_alt_1;
        label = 'Add Friend';
        bgColor = iOSDesignSystem.accentBlue.withOpacity(0.2);
        borderColor = iOSDesignSystem.accentBlue.withOpacity(0.4);
        contentColor = iOSDesignSystem.accentBlue;
        onTap = _sendFriendRequest;
        break;
      case 'sent':
        icon = Icons.hourglass_empty;
        label = 'Requested';
        bgColor = Colors.white.withOpacity(0.08);
        borderColor = Colors.white.withOpacity(0.1);
        contentColor = Colors.white.withOpacity(0.5);
        onTap = null;  // Disabled
        break;
      case 'received':
        icon = Icons.check_circle_outline;
        label = 'Accept Request';
        bgColor = iOSDesignSystem.accentGreen.withOpacity(0.2);
        borderColor = iOSDesignSystem.accentGreen.withOpacity(0.4);
        contentColor = iOSDesignSystem.accentGreen;
        onTap = _acceptFriendRequest;
        break;
      case 'friends':
        icon = Icons.chat_bubble_outline;
        label = 'Message';
        bgColor = iOSDesignSystem.accentBlue.withOpacity(0.2);
        borderColor = iOSDesignSystem.accentBlue.withOpacity(0.4);
        contentColor = iOSDesignSystem.accentBlue;
        onTap = () {
          // TODO: Navigate to chat with this user
          ToastService.showInfo('Opening chat...');
        };
        break;
      default:
        return const SizedBox.shrink();
    }
    
    return GestureDetector(
      onTap: _isFriendActionLoading ? null : () {
        HapticFeedback.selectionClick();
        onTap?.call();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: borderColor, width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isFriendActionLoading)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: contentColor,
                ),
              )
            else
              Icon(icon, size: 16, color: contentColor),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: contentColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBioSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: LiquidGlassCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline,
                    size: 16, color: Colors.white.withOpacity(0.6)),
                const SizedBox(width: 8),
                Text(
                  'Bio',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white.withOpacity(0.6),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              _user?.bio ?? '',
              style: TextStyle(
                fontSize: 15,
                height: 1.4,
                color: Colors.white.withOpacity(0.9),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: LiquidGlassCard(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildStatItem('Posts', '$_postCount'),  // ✅ Real stats
            _buildStatDivider(),
            _buildStatItem('Followers', '$_followersCount'),
            _buildStatDivider(),
            _buildStatItem('Following', '$_followingCount'),
          ],
        ),
      ),
    );
  }

  Widget _buildStatItem(String label, String value) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: Colors.white.withOpacity(0.5),
          ),
        ),
      ],
    );
  }

  Widget _buildStatDivider() {
    return Container(
      width: 1,
      height: 30,
      color: Colors.white.withOpacity(0.1),
    );
  }

  Widget _buildInterestsSection() {
    // ✅ Use real interests from API, fallback to defaults if empty
    final interests = _interests.isNotEmpty 
        ? _interests 
        : ['Music', 'Travel', 'Photography', 'Tech'];
    
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: LiquidGlassCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.favorite_outline,
                    size: 16, color: Colors.white.withOpacity(0.6)),
                const SizedBox(width: 8),
                Text(
                  'Interests',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white.withOpacity(0.6),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: interests.map((interest) {
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: iOSDesignSystem.accentBlue.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: iOSDesignSystem.accentBlue.withOpacity(0.3),
                    ),
                  ),
                  child: Text(
                    interest,
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.white.withOpacity(0.9),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }
}
