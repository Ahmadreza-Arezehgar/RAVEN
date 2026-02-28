import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../theme/ios_design_system.dart';
import '../services/api_service.dart';
import '../services/toast_service.dart';

/// Edit Bio Screen - Bio, Hobbies, and Spotify 15s preview
class EditBioScreen extends StatefulWidget {
  const EditBioScreen({super.key});

  @override
  State<EditBioScreen> createState() => _EditBioScreenState();
}

class _EditBioScreenState extends State<EditBioScreen> {
  final _bioController = TextEditingController();
  final _secureStorage = const FlutterSecureStorage();
  final _audioPlayer = AudioPlayer();
  
  bool _isLoading = false;
  bool _isSaving = false;
  bool _isPlaying = false;
  
  // Hobbies
  static const List<String> _allHobbies = [
    'Tech', 'Music', 'Sports', 'Movies', 'Travel', 'Art', 
    'Gaming', 'Books', 'Photography', 'Cooking', 'Fitness',
    'Fashion', 'Nature', 'Coffee', 'Cars', 'Crypto',
  ];
  final Set<String> _selectedHobbies = {};
  
  // Spotify
  String? _spotifyTrackId;
  String? _spotifyTrackName;
  String? _spotifyArtistName;
  String? _spotifyPreviewUrl;
  String? _spotifyCoverUrl;
  
  @override
  void initState() {
    super.initState();
    _loadProfile();
  }
  
  @override
  void dispose() {
    _bioController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }
  
  Future<void> _loadProfile() async {
    setState(() => _isLoading = true);
    
    try {
      // Load bio and hobbies from server
      final profile = await ApiService.getCurrentUser();
      if (profile != null) {
        _bioController.text = profile['bio'] ?? '';
        
        // Parse hobbies - could be a List or JSON string
        final hobbies = profile['hobbies'];
        if (hobbies is List) {
          _selectedHobbies.addAll(hobbies.cast<String>());
        } else if (hobbies is String && hobbies.isNotEmpty) {
          try {
            final parsed = List<String>.from(
              (hobbies.startsWith('[') ? hobbies : '[$hobbies]') as Iterable
            );
            _selectedHobbies.addAll(parsed);
          } catch (_) {
            // If JSON parse fails, try comma-separated
            _selectedHobbies.addAll(hobbies.split(',').map((e) => e.trim()));
          }
        }
      }
      
      // Load Spotify from secure storage
      _spotifyTrackId = await _secureStorage.read(key: 'spotify_track_id');
      _spotifyTrackName = await _secureStorage.read(key: 'spotify_track_name');
      _spotifyArtistName = await _secureStorage.read(key: 'spotify_artist_name');
      _spotifyPreviewUrl = await _secureStorage.read(key: 'spotify_preview_url');
      _spotifyCoverUrl = await _secureStorage.read(key: 'spotify_cover_url');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }
  
  Future<void> _connectSpotify() async {
    HapticFeedback.mediumImpact();
    
    // TODO: Implement Spotify OAuth with PKCE
    // 1. Use flutter_web_auth_2 or url_launcher
    // 2. Get authorization code
    // 3. Exchange for access_token
    // 4. Store securely
    
    ToastService.showInfo('Spotify integration coming soon!');
  }
  
  Future<void> _pickSpotifyTrack() async {
    HapticFeedback.selectionClick();
    
    // TODO: Open track search screen
    // After selection:
    // setState(() {
    //   _spotifyTrackId = track.id;
    //   _spotifyTrackName = track.name;
    //   _spotifyArtistName = track.artist;
    //   _spotifyPreviewUrl = track.previewUrl;
    //   _spotifyCoverUrl = track.coverUrl;
    // });
    
    ToastService.showInfo('Track picker coming soon!');
  }
  
  Future<void> _playPreview() async {
    if (_spotifyPreviewUrl == null) return;
    
    HapticFeedback.lightImpact();
    
    if (_isPlaying) {
      await _audioPlayer.stop();
      setState(() => _isPlaying = false);
    } else {
      await _audioPlayer.setUrl(_spotifyPreviewUrl!);
      _audioPlayer.play();
      setState(() => _isPlaying = true);
      
      // Stop after 15 seconds
      Future.delayed(const Duration(seconds: 15), () {
        if (mounted && _isPlaying) {
          _audioPlayer.stop();
          setState(() => _isPlaying = false);
        }
      });
    }
  }
  
  Future<void> _save() async {
    HapticFeedback.mediumImpact();
    setState(() => _isSaving = true);
    
    try {
      // Save Spotify to secure storage
      if (_spotifyTrackId != null) {
        await _secureStorage.write(key: 'spotify_track_id', value: _spotifyTrackId);
        await _secureStorage.write(key: 'spotify_track_name', value: _spotifyTrackName);
        await _secureStorage.write(key: 'spotify_artist_name', value: _spotifyArtistName);
        await _secureStorage.write(key: 'spotify_preview_url', value: _spotifyPreviewUrl);
        await _secureStorage.write(key: 'spotify_cover_url', value: _spotifyCoverUrl);
      }
      
      // ✅ Save bio + hobbies to server API
      final result = await ApiService.updateProfile(
        bio: _bioController.text,
        hobbies: _selectedHobbies.toList(),
      );
      
      if (result == null) {
        if (mounted) {
          ToastService.showError('Failed to save profile');
        }
        return;
      }
      
      // ✅ Update AppModel state immediately so UI reflects changes
      if (mounted) {
        final model = context.read<AppModel>();
        await model.updateUserProfile(bio: _bioController.text);
      }
      
      if (mounted) {
        HapticFeedback.heavyImpact();
        ToastService.showSuccess('Profile updated!');
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ToastService.showError('Error saving: $e');
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Edit Bio', style: TextStyle(color: Colors.white)),
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          TextButton(
            onPressed: _isSaving ? null : _save,
            child: _isSaving
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text('Save', style: TextStyle(color: Color(0xFF0A84FF), fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusScope.of(context).unfocus(),
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.all(16),
                children: [
                // ═══════════════════════════════════════════════════════
                // BIO SECTION
                // ═══════════════════════════════════════════════════════
                _buildSectionHeader('Bio', Icons.edit_outlined),
                const SizedBox(height: 12),
                _buildGlassContainer(
                  child: TextField(
                    controller: _bioController,
                    maxLines: 4,
                    maxLength: 160,
                    style: const TextStyle(color: Colors.white, fontSize: 15),
                    decoration: InputDecoration(
                      hintText: 'Write something about yourself...',
                      hintStyle: TextStyle(color: Colors.white.withOpacity(0.4)),
                      border: InputBorder.none,
                      counterStyle: TextStyle(color: Colors.white.withOpacity(0.4)),
                    ),
                  ),
                ),
                
                const SizedBox(height: 28),
                
                // ═══════════════════════════════════════════════════════
                // HOBBIES SECTION
                // ═══════════════════════════════════════════════════════
                _buildSectionHeader('Hobbies & Interests', Icons.favorite_border),
                const SizedBox(height: 12),
                _buildGlassContainer(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _allHobbies.map((hobby) {
                      final isSelected = _selectedHobbies.contains(hobby);
                      return GestureDetector(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          setState(() {
                            if (isSelected) {
                              _selectedHobbies.remove(hobby);
                            } else if (_selectedHobbies.length < 10) {
                              _selectedHobbies.add(hobby);
                            }
                          });
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? const Color(0xFF0A84FF)
                                : Colors.white.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isSelected
                                  ? const Color(0xFF0A84FF)
                                  : Colors.white.withOpacity(0.15),
                            ),
                          ),
                          child: Text(
                            hobby,
                            style: TextStyle(
                              color: isSelected ? Colors.white : Colors.white.withOpacity(0.8),
                              fontSize: 14,
                              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                Text(
                  'Select up to 10 interests',
                  style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 12),
                ),
                
                const SizedBox(height: 28),
                
                // ═══════════════════════════════════════════════════════
                // SPOTIFY SECTION
                // ═══════════════════════════════════════════════════════
                _buildSectionHeader('Spotify', Icons.music_note_outlined),
                const SizedBox(height: 12),
                
                // Connect button
                _buildActionTile(
                  icon: Icons.link,
                  title: 'Connect Spotify',
                  subtitle: 'Login to pick your profile track',
                  onTap: _connectSpotify,
                ),
                
                const SizedBox(height: 10),
                
                // Pick track button
                _buildActionTile(
                  icon: Icons.library_music_outlined,
                  title: 'Choose Profile Track',
                  subtitle: '15 second preview on your profile',
                  onTap: _pickSpotifyTrack,
                ),
                
                // Current track preview
                if (_spotifyTrackName != null) ...[
                  const SizedBox(height: 16),
                  _buildSpotifyPreview(),
                ],
                
                const SizedBox(height: 12),
                Text(
                  'Note: Some tracks may not have preview available.',
                  style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 12),
                ),
                
                const SizedBox(height: 40),
              ],
            ),
      ),
    );
  }
  
  Widget _buildSectionHeader(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: Colors.white.withOpacity(0.7), size: 20),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
  
  Widget _buildGlassContainer({required Widget child}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(0.1)),
          ),
          child: child,
        ),
      ),
    );
  }
  
  Widget _buildActionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.06),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.1)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1DB954).withOpacity(0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: const Color(0xFF1DB954), size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500)),
                      Text(subtitle, style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 13)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: Colors.white.withOpacity(0.3)),
              ],
            ),
          ),
        ),
      ),
    );
  }
  
  Widget _buildSpotifyPreview() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF1DB954).withOpacity(0.15),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF1DB954).withOpacity(0.3)),
          ),
          child: Row(
            children: [
              // Cover
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: _spotifyCoverUrl != null
                    ? Image.network(_spotifyCoverUrl!, width: 56, height: 56, fit: BoxFit.cover)
                    : Container(
                        width: 56, height: 56,
                        color: const Color(0xFF1DB954),
                        child: const Icon(Icons.music_note, color: Colors.white),
                      ),
              ),
              const SizedBox(width: 14),
              
              // Track info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _spotifyTrackName ?? 'Unknown',
                      style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      _spotifyArtistName ?? 'Unknown Artist',
                      style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              
              // Play button
              GestureDetector(
                onTap: _spotifyPreviewUrl != null ? _playPreview : null,
                child: Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(
                    color: _spotifyPreviewUrl != null
                        ? const Color(0xFF1DB954)
                        : Colors.grey,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                    size: 26,
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
