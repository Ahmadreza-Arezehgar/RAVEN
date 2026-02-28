import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:audioplayers/audioplayers.dart';
import '../main.dart';
import '../models/message_model.dart';
import '../services/database_helper.dart';

/// Chat Details Page - Shows media (Photos/Files/Voice) for a chat
/// Liquid Glass + Capsule design
class ChatDetailsPage extends StatefulWidget {
  final String chatId;
  final String title;
  final String lastSeenText;
  final String? avatarUrl;

  const ChatDetailsPage({
    super.key,
    required this.chatId,
    required this.title,
    required this.lastSeenText,
    this.avatarUrl,
  });

  @override
  State<ChatDetailsPage> createState() => _ChatDetailsPageState();
}

class _ChatDetailsPageState extends State<ChatDetailsPage> {
  int _tab = 0; // 0=Photos, 1=Files, 2=Voice
  
  List<ChatMessage> _photos = [];
  List<ChatMessage> _files = [];
  List<ChatMessage> _voices = [];
  bool _isLoading = true;
  
  // Audio player state
  final AudioPlayer _audioPlayer = AudioPlayer();
  String? _playingVoiceId;
  bool _isPlaying = false;
  Duration _currentPosition = Duration.zero;
  Duration _totalDuration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _loadMedia();
    _setupAudioPlayer();
  }
  
  void _setupAudioPlayer() {
    _audioPlayer.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() {
          _isPlaying = state == PlayerState.playing;
        });
      }
    });
    
    _audioPlayer.onPositionChanged.listen((position) {
      if (mounted) {
        setState(() {
          _currentPosition = position;
        });
      }
    });
    
    _audioPlayer.onDurationChanged.listen((duration) {
      if (mounted) {
        setState(() {
          _totalDuration = duration;
        });
      }
    });
    
    _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playingVoiceId = null;
          _isPlaying = false;
          _currentPosition = Duration.zero;
        });
      }
    });
  }
  
  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _loadMedia() async {
    final model = context.read<AppModel>();
    final myId = model.currentUser?.id ?? '';
    
    // Get roomId
    final roomId = _getRoomId(myId, widget.chatId);
    
    // Load all messages for this chat from local DB
    final allMessages = await DatabaseHelper.instance.getMessagesForRoom(roomId);
    
    setState(() {
      // Filter by type
      _photos = allMessages.where((m) => m.type == MessageType.image).toList();
      _files = allMessages.where((m) => m.type == MessageType.file).toList();
      _voices = allMessages.where((m) => m.type == MessageType.voice).toList();
      _isLoading = false;
    });
  }

  String _getRoomId(String a, String b) {
    if (b == 'broadcast' || b == 'general') return b;
    return (a.compareTo(b) < 0) ? '${a}_$b' : '${b}_$a';
  }

  String _getInitials(String name) {
    final parts = name.trim().split(' ');
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts[0].isNotEmpty ? parts[0][0].toUpperCase() : '?';
    return '${parts[0][0]}${parts.last[0]}'.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      body: Container(
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
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 10),

              // ═══════════════════════════════════════════════════════════════
              // HEADER: Back | Name + Last Seen | Avatar
              // ═══════════════════════════════════════════════════════════════
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    // Back button
                    _GlassCapsuleButton(
                      onTap: () => Navigator.pop(context),
                      size: const Size(48, 44),
                      child: const Icon(
                        Icons.chevron_left_rounded,
                        color: Colors.white,
                        size: 26,
                      ),
                    ),

                    const SizedBox(width: 10),

                    // Name + Last Seen
                    Expanded(
                      child: _GlassCapsule(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16.5,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                                letterSpacing: -0.3,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.lastSeenText,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: Colors.white.withOpacity(0.55),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(width: 10),

                    // Avatar
                    _GlassCapsule(
                      padding: const EdgeInsets.all(4),
                      child: ClipOval(
                        child: widget.avatarUrl != null && widget.avatarUrl!.isNotEmpty
                            ? Image.network(
                                widget.avatarUrl!,
                                width: 36,
                                height: 36,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => _buildInitials(),
                              )
                            : _buildInitials(),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // ═══════════════════════════════════════════════════════════════
              // GLASS SEGMENTED TABS: Photos / Files / Voice
              // ═══════════════════════════════════════════════════════════════
              Center(
                child: _buildGlassSegmentedTabs(),
              ),

              const SizedBox(height: 16),

              // ═══════════════════════════════════════════════════════════════
              // TAB CONTENT
              // ═══════════════════════════════════════════════════════════════
              Expanded(
                child: _isLoading
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: Colors.white30,
                          strokeWidth: 2,
                        ),
                      )
                    : AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        switchInCurve: Curves.easeOutCubic,
                        child: _buildTabContent(),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInitials() {
    return Container(
      width: 36,
      height: 36,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [Color(0xFF5856D6), Color(0xFF0A84FF)],
        ),
      ),
      child: Center(
        child: Text(
          _getInitials(widget.title),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildGlassSegmentedTabs() {
    final tabs = ['Photos', 'Files', 'Voice'];
    
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          height: 40,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: Colors.white.withOpacity(0.08),
            border: Border.all(
              color: Colors.white.withOpacity(0.14),
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(tabs.length, (i) {
              final isSelected = _tab == i;
              return GestureDetector(
                onTap: () {
                  HapticFeedback.lightImpact();
                  setState(() => _tab = i);
                },
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    color: isSelected ? Colors.white.withOpacity(0.16) : Colors.transparent,
                  ),
                  child: Text(
                    tabs[i],
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isSelected ? Colors.white : Colors.white.withOpacity(0.55),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }

  Widget _buildTabContent() {
    switch (_tab) {
      case 0:
        return _buildPhotosGrid(key: const ValueKey('photos'));
      case 1:
        return _buildFilesList(key: const ValueKey('files'));
      case 2:
        return _buildVoiceList(key: const ValueKey('voice'));
      default:
        return const SizedBox.shrink();
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PHOTOS GRID
  // ═══════════════════════════════════════════════════════════════════════════
  Widget _buildPhotosGrid({Key? key}) {
    if (_photos.isEmpty) {
      return _buildEmptyState(
        key: key,
        icon: Icons.photo_library_outlined,
        text: 'No photos yet',
      );
    }

    return GridView.builder(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: _photos.length,
      itemBuilder: (context, index) {
        final msg = _photos[index];
        // Use thumbnailUrl first, fallback to audioUrl (main URL)
        final url = msg.thumbnailUrl ?? msg.audioUrl;
        final fullUrl = msg.audioUrl ?? msg.thumbnailUrl;
        
        return GestureDetector(
          onTap: () {
            if (fullUrl != null) {
              HapticFeedback.lightImpact();
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => _FullscreenImageViewer(
                    imageUrl: fullUrl,
                    heroTag: 'photo_$index',
                    allPhotos: _photos,
                    initialIndex: index,
                  ),
                ),
              );
            }
          },
          child: Hero(
            tag: 'photo_$index',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: url != null
                  ? Image.network(
                      url,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        color: Colors.white10,
                        child: const Icon(Icons.broken_image, color: Colors.white30),
                      ),
                    )
                  : Container(
                      color: Colors.white10,
                      child: const Icon(Icons.image, color: Colors.white30),
                    ),
            ),
          ),
        );
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // FILES LIST
  // ═══════════════════════════════════════════════════════════════════════════
  Widget _buildFilesList({Key? key}) {
    if (_files.isEmpty) {
      return _buildEmptyState(
        key: key,
        icon: Icons.folder_outlined,
        text: 'No files yet',
      );
    }

    return ListView.separated(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _files.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final msg = _files[index];
        final filename = msg.fileName ?? 'Unknown file';
        final fileUrl = msg.audioUrl;
        final mimeType = msg.mimeType ?? '';
        final fileSize = msg.fileSize;
        
        // Get appropriate icon based on MIME type
        IconData fileIcon = Icons.insert_drive_file;
        Color iconColor = Colors.white70;
        if (mimeType.contains('pdf')) {
          fileIcon = Icons.picture_as_pdf;
          iconColor = const Color(0xFFFF3B30);
        } else if (mimeType.contains('word') || mimeType.contains('document')) {
          fileIcon = Icons.description;
          iconColor = const Color(0xFF007AFF);
        } else if (mimeType.contains('spreadsheet') || mimeType.contains('excel')) {
          fileIcon = Icons.table_chart;
          iconColor = const Color(0xFF34C759);
        } else if (mimeType.contains('zip') || mimeType.contains('archive')) {
          fileIcon = Icons.folder_zip;
          iconColor = const Color(0xFFFF9500);
        }
        
        return GestureDetector(
          onTap: () async {
            if (fileUrl != null) {
              HapticFeedback.lightImpact();
              final uri = Uri.parse(fileUrl);
              try {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Could not open file: $e')),
                  );
                }
              }
            }
          },
          child: _GlassCapsule(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: iconColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    fileIcon,
                    color: iconColor,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        filename,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (fileSize != null) ...[
                            Text(
                              _formatFileSize(fileSize),
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.white.withOpacity(0.5),
                              ),
                            ),
                            Text(
                              ' • ',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.white.withOpacity(0.3),
                              ),
                            ),
                          ],
                          Text(
                            _formatTimestamp(msg.timestamp),
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white.withOpacity(0.5),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.open_in_new_rounded,
                  color: Colors.white.withOpacity(0.4),
                  size: 20,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
  
  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // VOICE LIST
  // ═══════════════════════════════════════════════════════════════════════════
  Widget _buildVoiceList({Key? key}) {
    if (_voices.isEmpty) {
      return _buildEmptyState(
        key: key,
        icon: Icons.mic_none_rounded,
        text: 'No voice messages yet',
      );
    }

    return ListView.separated(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _voices.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final msg = _voices[index];
        final voiceUrl = msg.audioUrl;
        final isCurrentlyPlaying = _playingVoiceId == msg.id;
        final durationSeconds = msg.audioDurationSeconds ?? 0;
        
        // Format duration
        String formatDuration(int seconds) {
          final mins = seconds ~/ 60;
          final secs = seconds % 60;
          return '$mins:${secs.toString().padLeft(2, '0')}';
        }
        
        // Get display duration
        String displayDuration;
        double progress = 0.0;
        if (isCurrentlyPlaying && _totalDuration.inSeconds > 0) {
          displayDuration = '${formatDuration(_currentPosition.inSeconds)} / ${formatDuration(_totalDuration.inSeconds)}';
          progress = _currentPosition.inMilliseconds / _totalDuration.inMilliseconds;
        } else {
          displayDuration = formatDuration(durationSeconds);
        }
        
        return GestureDetector(
          onTap: () async {
            if (voiceUrl == null) return;
            
            HapticFeedback.lightImpact();
            
            if (isCurrentlyPlaying) {
              // Toggle play/pause
              if (_isPlaying) {
                await _audioPlayer.pause();
              } else {
                await _audioPlayer.resume();
              }
            } else {
              // Start playing new voice
              setState(() {
                _playingVoiceId = msg.id;
                _currentPosition = Duration.zero;
              });
              await _audioPlayer.stop();
              await _audioPlayer.play(UrlSource(voiceUrl));
            }
          },
          child: _GlassCapsule(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                // Play/Pause button
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A84FF).withOpacity(0.2),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Icon(
                    isCurrentlyPlaying && _isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: const Color(0xFF0A84FF),
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                
                // Progress and duration
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Waveform / progress bar
                      if (isCurrentlyPlaying)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: progress.clamp(0.0, 1.0),
                            backgroundColor: Colors.white.withOpacity(0.1),
                            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF0A84FF)),
                            minHeight: 4,
                          ),
                        )
                      else
                        Container(
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            displayDuration,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: isCurrentlyPlaying 
                                  ? const Color(0xFF0A84FF)
                                  : Colors.white.withOpacity(0.7),
                            ),
                          ),
                          Text(
                            _formatTimestamp(msg.timestamp),
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.white.withOpacity(0.4),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                
                // Stop button (when playing)
                if (isCurrentlyPlaying) ...[
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () async {
                      HapticFeedback.lightImpact();
                      await _audioPlayer.stop();
                      setState(() {
                        _playingVoiceId = null;
                        _isPlaying = false;
                        _currentPosition = Duration.zero;
                      });
                    },
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(
                        Icons.stop_rounded,
                        color: Colors.white.withOpacity(0.7),
                        size: 18,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildEmptyState({Key? key, required IconData icon, required String text}) {
    return Center(
      key: key,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 48,
            color: Colors.white.withOpacity(0.2),
          ),
          const SizedBox(height: 12),
          Text(
            text,
            style: TextStyle(
              fontSize: 15,
              color: Colors.white.withOpacity(0.4),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTimestamp(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    
    if (diff.inDays == 0) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } else if (diff.inDays < 7) {
      return '${diff.inDays}d ago';
    } else {
      return '${dt.day}/${dt.month}/${dt.year}';
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// GLASS CAPSULE - Base container with blur
// ═══════════════════════════════════════════════════════════════════════════
class _GlassCapsule extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final double borderRadius;

  const _GlassCapsule({
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    this.borderRadius = 22,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E).withOpacity(0.45),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              color: Colors.white.withOpacity(0.12),
              width: 0.5,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// GLASS CAPSULE BUTTON - Tappable with micro-animation
// ═══════════════════════════════════════════════════════════════════════════
class _GlassCapsuleButton extends StatefulWidget {
  final VoidCallback? onTap;
  final Widget child;
  final Size size;

  const _GlassCapsuleButton({
    this.onTap,
    required this.child,
    this.size = const Size(48, 44),
  });

  @override
  State<_GlassCapsuleButton> createState() => _GlassCapsuleButtonState();
}

class _GlassCapsuleButtonState extends State<_GlassCapsuleButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _scaleController;
  late Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _scaleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: 0.96).animate(
      CurvedAnimation(parent: _scaleController, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _scaleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _scaleController.forward(),
      onTapUp: (_) => _scaleController.reverse(),
      onTapCancel: () => _scaleController.reverse(),
      onTap: () {
        HapticFeedback.lightImpact();
        widget.onTap?.call();
      },
      child: AnimatedBuilder(
        animation: _scaleController,
        builder: (context, child) => Transform.scale(
          scale: _scaleAnim.value,
          child: child,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.size.height / 2),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
            child: Container(
              width: widget.size.width,
              height: widget.size.height,
              decoration: BoxDecoration(
                color: const Color(0xFF1C1C1E).withOpacity(0.45),
                borderRadius: BorderRadius.circular(widget.size.height / 2),
                border: Border.all(
                  color: Colors.white.withOpacity(0.12),
                  width: 0.5,
                ),
              ),
              child: Center(child: widget.child),
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// FULLSCREEN IMAGE VIEWER - With swipe navigation and pinch-to-zoom
// ═══════════════════════════════════════════════════════════════════════════
class _FullscreenImageViewer extends StatefulWidget {
  final String imageUrl;
  final String heroTag;
  final List<ChatMessage> allPhotos;
  final int initialIndex;

  const _FullscreenImageViewer({
    required this.imageUrl,
    required this.heroTag,
    required this.allPhotos,
    required this.initialIndex,
  });

  @override
  State<_FullscreenImageViewer> createState() => _FullscreenImageViewerState();
}

class _FullscreenImageViewerState extends State<_FullscreenImageViewer> {
  late PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Photo PageView
          PageView.builder(
            controller: _pageController,
            itemCount: widget.allPhotos.length,
            onPageChanged: (index) {
              setState(() => _currentIndex = index);
            },
            itemBuilder: (context, index) {
              final msg = widget.allPhotos[index];
              final url = msg.audioUrl ?? msg.thumbnailUrl ?? '';
              
              return GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Center(
                  child: Hero(
                    tag: 'photo_$index',
                    child: InteractiveViewer(
                      minScale: 0.5,
                      maxScale: 4.0,
                      child: Image.network(
                        url,
                        fit: BoxFit.contain,
                        loadingBuilder: (context, child, progress) {
                          if (progress == null) return child;
                          return Center(
                            child: CircularProgressIndicator(
                              value: progress.expectedTotalBytes != null
                                  ? progress.cumulativeBytesLoaded / progress.expectedTotalBytes!
                                  : null,
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          );
                        },
                        errorBuilder: (_, __, ___) => const Center(
                          child: Icon(
                            Icons.broken_image,
                            color: Colors.white30,
                            size: 64,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          
          // Close button
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 16,
            child: GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(
                  Icons.close,
                  color: Colors.white,
                  size: 24,
                ),
              ),
            ),
          ),
          
          // Page indicator
          if (widget.allPhotos.length > 1)
            Positioned(
              bottom: MediaQuery.of(context).padding.bottom + 24,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${_currentIndex + 1} / ${widget.allPhotos.length}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
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
