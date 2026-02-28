import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import '../models/user_model.dart';
import '../theme/ios_design_system.dart';

/// Profile Glass Sheet - Opens when tapping on avatar
/// Shows: Avatar, Name, Bio, Hobbies, Spotify preview
class ProfileGlassSheet extends StatefulWidget {
  final UserProfile profile;
  final bool isOwnProfile;
  final VoidCallback? onEditTap;
  
  const ProfileGlassSheet({
    super.key,
    required this.profile,
    this.isOwnProfile = false,
    this.onEditTap,
  });
  
  /// Show profile sheet for a user
  static Future<void> show(
    BuildContext context, {
    required UserProfile profile,
    bool isOwnProfile = false,
    VoidCallback? onEditTap,
  }) {
    HapticFeedback.mediumImpact();
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ProfileGlassSheet(
        profile: profile,
        isOwnProfile: isOwnProfile,
        onEditTap: onEditTap,
      ),
    );
  }
  
  @override
  State<ProfileGlassSheet> createState() => _ProfileGlassSheetState();
}

class _ProfileGlassSheetState extends State<ProfileGlassSheet> {
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isPlaying = false;
  Duration _playProgress = Duration.zero;
  Duration _totalDuration = const Duration(seconds: 15);
  
  @override
  void initState() {
    super.initState();
    _audioPlayer.onPositionChanged.listen((pos) {
      if (mounted) setState(() => _playProgress = pos);
      // Stop after 15 seconds
      if (pos.inSeconds >= 15 && _isPlaying) {
        _stopPreview();
      }
    });
    _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _isPlaying = false);
    });
  }
  
  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }
  
  Future<void> _playPreview() async {
    if (widget.profile.spotifyPreviewUrl == null) return;
    
    HapticFeedback.lightImpact();
    
    if (_isPlaying) {
      await _stopPreview();
    } else {
      await _audioPlayer.setSourceUrl(widget.profile.spotifyPreviewUrl!);
      await _audioPlayer.resume();
      setState(() => _isPlaying = true);
    }
  }
  
  Future<void> _stopPreview() async {
    await _audioPlayer.stop();
    setState(() {
      _isPlaying = false;
      _playProgress = Duration.zero;
    });
  }
  
  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.of(context).padding.bottom;
    
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white.withOpacity(0.12),
                Colors.white.withOpacity(0.06),
              ],
            ),
            border: Border(
              top: BorderSide(color: Colors.white.withOpacity(0.2), width: 0.5),
            ),
          ),
          padding: EdgeInsets.only(bottom: safeBottom + 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle
              Container(
                margin: const EdgeInsets.only(top: 12),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              
              const SizedBox(height: 24),
              
              // Avatar
              _buildAvatar(),
              
              const SizedBox(height: 16),
              
              // Name & Username
              Text(
                widget.profile.displayName ?? widget.profile.username ?? 'User',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (widget.profile.username != null)
                Text(
                  '@${widget.profile.username}',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.6),
                    fontSize: 15,
                  ),
                ),
              
              const SizedBox(height: 8),
              
              // Member since
              if (widget.profile.joinedAt != null)
                Text(
                  'Member since ${_formatDate(widget.profile.joinedAt!)}',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.4),
                    fontSize: 13,
                  ),
                ),
              
              const SizedBox(height: 20),
              
              // Bio
              if (widget.profile.bio != null && widget.profile.bio!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    widget.profile.bio!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.8),
                      fontSize: 15,
                      height: 1.4,
                    ),
                  ),
                ),
              
              const SizedBox(height: 20),
              
              // Hobbies
              if (widget.profile.hobbies != null && widget.profile.hobbies!.isNotEmpty)
                _buildHobbies(),
              
              const SizedBox(height: 20),
              
              // Spotify section
              if (widget.profile.spotifyPreviewUrl != null)
                _buildSpotifySection(),
              
              const SizedBox(height: 24),
              
              // Edit button (own profile)
              if (widget.isOwnProfile && widget.onEditTap != null)
                _buildEditButton(),
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _buildAvatar() {
    return Container(
      width: 100,
      height: 100,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withOpacity(0.3), width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipOval(
        child: widget.profile.avatarPath != null
            ? Image.network(
                widget.profile.avatarPath!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _defaultAvatar(),
              )
            : _defaultAvatar(),
      ),
    );
  }
  
  Widget _defaultAvatar() {
    return Container(
      color: const Color(0xFF0A84FF).withOpacity(0.3),
      child: Center(
        child: Text(
          (widget.profile.username ?? 'U')[0].toUpperCase(),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 40,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
  
  Widget _buildHobbies() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: widget.profile.hobbies!.map((hobby) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.1),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.2)),
            ),
            child: Text(
              hobby,
              style: TextStyle(
                color: Colors.white.withOpacity(0.9),
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
  
  Widget _buildSpotifySection() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1DB954).withOpacity(0.15),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1DB954).withOpacity(0.3)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              // Album cover
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: widget.profile.spotifyCoverUrl != null
                    ? Image.network(
                        widget.profile.spotifyCoverUrl!,
                        width: 56,
                        height: 56,
                        fit: BoxFit.cover,
                      )
                    : Container(
                        width: 56,
                        height: 56,
                        color: const Color(0xFF1DB954),
                        child: const Icon(Icons.music_note, color: Colors.white),
                      ),
              ),
              
              const SizedBox(width: 12),
              
              // Track info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.profile.spotifyTrackTitle ?? 'Unknown Track',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      widget.profile.spotifyTrackArtist ?? 'Unknown Artist',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.6),
                        fontSize: 13,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              
              // Play button
              GestureDetector(
                onTap: _playPreview,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1DB954),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF1DB954).withOpacity(0.4),
                        blurRadius: 12,
                      ),
                    ],
                  ),
                  child: Icon(
                    _isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              ),
            ],
          ),
          
          // Progress bar
          if (_isPlaying || _playProgress.inMilliseconds > 0)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: _playProgress.inMilliseconds / 15000, // 15 seconds max
                  backgroundColor: Colors.white.withOpacity(0.2),
                  valueColor: const AlwaysStoppedAnimation(Color(0xFF1DB954)),
                  minHeight: 3,
                ),
              ),
            ),
        ],
      ),
    );
  }
  
  Widget _buildEditButton() {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        Navigator.pop(context);
        widget.onEditTap?.call();
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 24),
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF0A84FF),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Center(
          child: Text(
            'Edit Profile',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
  
  String _formatDate(DateTime date) {
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[date.month - 1]} ${date.year}';
  }
}

/// User profile data model for profile sheet
class UserProfile {
  final String? id;
  final String? username;
  final String? displayName;
  final String? avatarPath;
  final String? bio;
  final List<String>? hobbies;
  final DateTime? joinedAt;
  final String? spotifyTrackId;
  final String? spotifyTrackTitle;
  final String? spotifyTrackArtist;
  final String? spotifyCoverUrl;
  final String? spotifyPreviewUrl;
  
  const UserProfile({
    this.id,
    this.username,
    this.displayName,
    this.avatarPath,
    this.bio,
    this.hobbies,
    this.joinedAt,
    this.spotifyTrackId,
    this.spotifyTrackTitle,
    this.spotifyTrackArtist,
    this.spotifyCoverUrl,
    this.spotifyPreviewUrl,
  });
}
