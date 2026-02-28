import 'dart:async';
import 'package:just_audio/just_audio.dart';

/// VoiceQueueController - Manages sequential voice message playback
/// 
/// Singleton pattern ensures only one audio player across all voice bubbles.
/// Uses ConcatenatingAudioSource for queue management.
/// 
/// Behavior:
/// - Play voices in order from tapped message
/// - Stop at end (no loop/restart)
/// - New play cancels current queue
class VoiceQueueController {
  // Singleton
  static final VoiceQueueController _instance = VoiceQueueController._();
  static VoiceQueueController get instance => _instance;
  VoiceQueueController._() {
    _init();
  }
  
  final AudioPlayer _player = AudioPlayer();
  ConcatenatingAudioSource? _queue;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<int?>? _indexSub;
  
  // Current queue info
  List<String> _currentVoiceIds = [];
  String? _currentPlayingId;
  
  // Streams for UI updates
  final _playingIdController = StreamController<String?>.broadcast();
  Stream<String?> get playingIdStream => _playingIdController.stream;
  
  final _positionController = StreamController<Duration>.broadcast();
  Stream<Duration> get positionStream => _positionController.stream;
  
  // ✅ Duration stream for accurate voice length display
  final _durationController = StreamController<Duration>.broadcast();
  Stream<Duration> get durationStream => _durationController.stream;
  
  void _init() {
    // ✅ CRITICAL: Disable loop to prevent restart at end
    _player.setLoopMode(LoopMode.off);
    
    // Forward position updates
    _player.positionStream.listen((pos) {
      _positionController.add(pos);
    });
    
    // ✅ Forward duration updates for accurate UI
    _player.durationStream.listen((d) {
      if (d != null) _durationController.add(d);
    });
    
    // Listen to state changes
    _stateSub = _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        // ✅ Queue finished - stop and clear
        print('🎵 [VoiceQueue] Queue completed, stopping');
        _currentPlayingId = null;
        _playingIdController.add(null);
      }
    });
    
    // Track which voice is currently playing
    _indexSub = _player.currentIndexStream.listen((index) {
      if (index != null && index < _currentVoiceIds.length) {
        _currentPlayingId = _currentVoiceIds[index];
        _playingIdController.add(_currentPlayingId);
        print('🎵 [VoiceQueue] Now playing index $index: ${_currentPlayingId?.substring(0, 8)}...');
      }
    });
  }
  
  /// Play voices in order starting from startIndex
  /// 
  /// [voiceItems] - List of voice items with id and url, ordered as displayed in chat
  /// [startIndex] - Index of the voice that was tapped
  Future<void> playVoicesInOrder({
    required List<VoiceQueueItem> voiceItems,
    required int startIndex,
  }) async {
    if (voiceItems.isEmpty) {
      print('🎵 [VoiceQueue] No voices to play');
      return;
    }
    
    // Validate startIndex
    if (startIndex < 0 || startIndex >= voiceItems.length) {
      print('🎵 [VoiceQueue] Invalid startIndex: $startIndex');
      startIndex = 0;
    }
    
    print('🎵 [VoiceQueue] Building queue with ${voiceItems.length} voices, starting at $startIndex');
    
    // Stop current playback
    await stop();
    
    // Store voice IDs for tracking
    _currentVoiceIds = voiceItems.map((v) => v.id).toList();
    
    // Build audio source queue
    final sources = <AudioSource>[];
    for (final item in voiceItems) {
      if (item.localPath != null && item.localPath!.isNotEmpty) {
        sources.add(AudioSource.file(item.localPath!));
      } else if (item.url != null && item.url!.isNotEmpty) {
        sources.add(AudioSource.uri(Uri.parse(item.url!)));
      } else {
        // Skip invalid sources (will affect indexing though)
        print('⚠️ [VoiceQueue] Skipping voice ${item.id} - no valid source');
      }
    }
    
    if (sources.isEmpty) {
      print('🎵 [VoiceQueue] No valid audio sources');
      return;
    }
    
    _queue = ConcatenatingAudioSource(
      useLazyPreparation: true,
      children: sources,
    );
    
    try {
      await _player.setAudioSource(
        _queue!,
        initialIndex: startIndex,
        initialPosition: Duration.zero,
      );
      
      _currentPlayingId = _currentVoiceIds[startIndex];
      _playingIdController.add(_currentPlayingId);
      
      await _player.play();
      print('🎵 [VoiceQueue] Started playing from index $startIndex');
    } catch (e) {
      print('❌ [VoiceQueue] Error setting audio source: $e');
      _currentPlayingId = null;
      _playingIdController.add(null);
    }
  }
  
  /// Stop playback and clear queue
  Future<void> stop() async {
    await _player.stop();
    await _player.seek(Duration.zero);
    _currentPlayingId = null;
    _playingIdController.add(null);
    print('🎵 [VoiceQueue] Stopped');
  }
  
  /// Pause current playback
  Future<void> pause() async {
    await _player.pause();
    print('🎵 [VoiceQueue] Paused');
  }
  
  /// Resume playback
  Future<void> resume() async {
    await _player.play();
    print('🎵 [VoiceQueue] Resumed');
  }
  
  /// Toggle play/pause for a specific voice
  /// If a different voice is playing, starts new queue from that voice
  Future<void> togglePlayPause({
    required String voiceId,
    required List<VoiceQueueItem> allVoices,
  }) async {
    if (_currentPlayingId == voiceId && _player.playing) {
      // Same voice, currently playing -> pause
      await pause();
    } else if (_currentPlayingId == voiceId && !_player.playing) {
      // Same voice, paused -> resume
      await resume();
    } else {
      // Different voice or not playing -> start new queue
      final startIndex = allVoices.indexWhere((v) => v.id == voiceId);
      if (startIndex >= 0) {
        await playVoicesInOrder(
          voiceItems: allVoices,
          startIndex: startIndex,
        );
      }
    }
  }
  
  /// Check if a specific voice is currently playing
  bool isPlaying(String voiceId) {
    return _currentPlayingId == voiceId && _player.playing;
  }
  
  /// Check if a specific voice is the current one (playing or paused)
  bool isCurrent(String voiceId) {
    return _currentPlayingId == voiceId;
  }
  
  /// Get current position for the playing voice
  Duration get currentPosition => _player.position;
  
  /// Get duration of current track
  Duration? get currentDuration => _player.duration;
  
  /// Seek to position in current track
  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }
  
  /// Dispose (call on app close)
  void dispose() {
    _stateSub?.cancel();
    _indexSub?.cancel();
    _playingIdController.close();
    _positionController.close();
    _durationController.close(); // ✅ Clean up duration stream
    _player.dispose();
  }
}

/// Voice queue item with id and audio source
class VoiceQueueItem {
  final String id;          // Message ID for tracking
  final String? url;        // CDN URL
  final String? localPath;  // Local file path (preferred)
  
  const VoiceQueueItem({
    required this.id,
    this.url,
    this.localPath,
  });
}
