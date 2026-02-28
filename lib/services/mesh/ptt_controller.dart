import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../../models/mesh_envelope.dart';
import '../audio_codec_service.dart';

/// PTT state for UI
enum PttState { idle, recording, sending }

/// PttController - Push-to-Talk Voice streaming over Mesh
/// 
/// Enables walkie-talkie style voice communication.
/// Voice is streamed in small chunks (200ms) for low latency.
/// 
/// Protocol:
/// - type: 'ptt'
/// - TTL: 3 seconds (very short, voice is ephemeral)
/// - maxHop: 1 (direct neighbors only)
/// - payload: { streamId, seq, codec, sampleRate, chunkB64, end }
/// 
/// Note: For MVP, uses low quality (8-16kHz) to handle BLE bandwidth.
/// No persistent storage - voice chunks are played and discarded.
class PttController {
  static final PttController _instance = PttController._();
  static PttController get instance => _instance;
  
  PttController._();

  // ═══════════════════════════════════════════════════════════════
  // STREAM MANAGEMENT
  // ═══════════════════════════════════════════════════════════════

  /// Current outgoing stream ID (null if not transmitting)
  String? _currentStreamId;
  int _currentSeq = 0;
  
  /// Jitter buffer for incoming streams
  /// Map<streamId, SortedMap<seq, chunkData>>
  final Map<String, SplayTreeMap<int, Uint8List>> _jitterBuffers = {};
  
  /// Stream info for active incoming streams
  final Map<String, PttStreamInfo> _activeStreams = {};
  
  /// Playback position for each stream
  final Map<String, int> _playbackPositions = {};

  // ═══════════════════════════════════════════════════════════════
  // EVENT STREAMS
  // ═══════════════════════════════════════════════════════════════

  final _talkingController = StreamController<PttTalkingEvent>.broadcast();
  final _chunkReadyController = StreamController<PttChunkReady>.broadcast();
  final _stateController = StreamController<PttState>.broadcast();
  final _audioLevelController = StreamController<double>.broadcast();
  
  /// Stream of who is currently talking
  Stream<PttTalkingEvent> get onTalkingChanged => _talkingController.stream;
  
  /// Stream of audio chunks ready to play
  Stream<PttChunkReady> get onChunkReady => _chunkReadyController.stream;
  
  /// Stream of PTT state changes (for UI)
  Stream<PttState> get onStateChange => _stateController.stream;
  
  /// Stream of audio levels (0.0-1.0) for waveform visualization
  Stream<double> get onAudioLevel => _audioLevelController.stream;
  
  /// Current PTT state
  PttState _state = PttState.idle;
  PttState get state => _state;
  
  void _setState(PttState newState) {
    _state = newState;
    _stateController.add(newState);
  }
  
  // ═══════════════════════════════════════════════════════════════
  // UI HELPER METHODS
  // ═══════════════════════════════════════════════════════════════
  
  /// Start recording - uses AudioCodecService for real microphone capture
  Future<bool> startRecording() async {
    try {
      // Check permission first
      final hasPermission = await AudioCodecService.instance.hasPermission();
      if (!hasPermission) {
        debugPrint('🎙️ [PttController] No microphone permission');
        return false;
      }
      
      // Start real audio recording
      final path = await AudioCodecService.instance.startRecording();
      if (path == null) {
        debugPrint('🎙️ [PttController] Failed to start recording');
        return false;
      }
      
      _setState(PttState.recording);
      startTransmission();
      debugPrint('🎙️ [PttController] Recording started: $path');
      return true;
    } catch (e) {
      debugPrint('❌ [PttController] startRecording error: $e');
      _setState(PttState.idle);
      return false;
    }
  }
  
  /// Stop recording, encode, and send audio data
  Future<Uint8List?> stopRecording() async {
    _setState(PttState.sending);
    
    try {
      // Get the recorded audio data
      final audioData = await AudioCodecService.instance.stopRecording();
      
      if (audioData != null && audioData.isNotEmpty) {
        debugPrint('🎙️ [PttController] Recorded ${audioData.length} bytes');
        _currentStreamId = null;
        _currentSeq = 0;
        _setState(PttState.idle);
        return audioData;
      }
      
      debugPrint('⚠️ [PttController] No audio data recorded');
    } catch (e) {
      debugPrint('❌ [PttController] stopRecording error: $e');
    }
    
    _currentStreamId = null;
    _currentSeq = 0;
    _setState(PttState.idle);
    return null;
  }
  
  /// Cancel recording without sending
  Future<void> cancelRecording() async {
    await AudioCodecService.instance.cancelRecording();
    _currentStreamId = null;
    _currentSeq = 0;
    _setState(PttState.idle);
  }

  // ═══════════════════════════════════════════════════════════════
  // SENDING
  // ═══════════════════════════════════════════════════════════════

  /// Start a new PTT transmission
  String startTransmission() {
    _currentStreamId = DateTime.now().millisecondsSinceEpoch.toString();
    _currentSeq = 0;
    return _currentStreamId!;
  }

  /// Create envelope for a voice chunk
  MeshEnvelope createChunkEnvelope({
    required String userId,
    required String fingerprint,
    required String nickname,
    required Uint8List audioData,
    String codec = 'aac',
    int sampleRate = 16000,
    bool isEnd = false,
  }) {
    if (_currentStreamId == null) {
      _currentStreamId = startTransmission();
    }
    
    final chunkB64 = base64Encode(audioData);
    final seq = _currentSeq++;
    
    final envelope = MeshEnvelope.pttChunk(
      from: MeshSender(
        userId: userId,
        fingerprint: fingerprint,
        nickname: nickname,
      ),
      streamId: _currentStreamId!,
      seq: seq,
      chunkB64: chunkB64,
      codec: codec,
      sampleRate: sampleRate,
      isEnd: isEnd,
    );
    
    if (isEnd) {
      _currentStreamId = null;
      _currentSeq = 0;
    }
    
    return envelope;
  }

  /// End current transmission
  MeshEnvelope? endTransmission({
    required String userId,
    required String fingerprint,
    required String nickname,
  }) {
    if (_currentStreamId == null) return null;
    
    return createChunkEnvelope(
      userId: userId,
      fingerprint: fingerprint,
      nickname: nickname,
      audioData: Uint8List(0), // Empty final chunk
      isEnd: true,
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // RECEIVING
  // ═══════════════════════════════════════════════════════════════

  /// Handle incoming PTT chunk
  void handle(MeshEnvelope envelope) {
    if (envelope.type != 'ptt') return;
    if (envelope.isExpired) return;
    
    final payload = envelope.payload;
    final streamId = payload['streamId'] as String? ?? '';
    final seq = payload['seq'] as int? ?? 0;
    final chunkB64 = payload['chunkB64'] as String? ?? '';
    final codec = payload['codec'] as String? ?? 'aac';
    final sampleRate = payload['sampleRate'] as int? ?? 16000;
    final isEnd = payload['end'] as bool? ?? false;
    
    // Initialize jitter buffer for new stream
    if (!_jitterBuffers.containsKey(streamId)) {
      _jitterBuffers[streamId] = SplayTreeMap<int, Uint8List>();
      _playbackPositions[streamId] = 0;
      _activeStreams[streamId] = PttStreamInfo(
        streamId: streamId,
        fromNickname: envelope.from.nickname,
        fromFingerprint: envelope.from.fingerprint,
        codec: codec,
        sampleRate: sampleRate,
        startedAt: DateTime.now(),
      );
      
      // Notify that someone started talking
      _talkingController.add(PttTalkingEvent(
        streamId: streamId,
        nickname: envelope.from.nickname,
        fingerprint: envelope.from.fingerprint,
        isTalking: true,
      ));
    }
    
    // Decode and buffer chunk
    if (chunkB64.isNotEmpty) {
      try {
        final data = base64Decode(chunkB64);
        _jitterBuffers[streamId]![seq] = data;
        
        // Try to emit ready chunks in order
        _emitReadyChunks(streamId);
      } catch (e) {
        debugPrint('PTT: Failed to decode chunk: $e');
      }
    }
    
    // Handle end of stream
    if (isEnd) {
      _talkingController.add(PttTalkingEvent(
        streamId: streamId,
        nickname: envelope.from.nickname,
        fingerprint: envelope.from.fingerprint,
        isTalking: false,
      ));
      
      // Clean up after a delay (allow remaining chunks to play)
      Future.delayed(const Duration(seconds: 2), () {
        _jitterBuffers.remove(streamId);
        _playbackPositions.remove(streamId);
        _activeStreams.remove(streamId);
      });
    }
  }

  /// Emit chunks in sequence order from jitter buffer
  void _emitReadyChunks(String streamId) {
    final buffer = _jitterBuffers[streamId];
    if (buffer == null) return;
    
    var nextSeq = _playbackPositions[streamId] ?? 0;
    
    // Emit all consecutive available chunks
    while (buffer.containsKey(nextSeq)) {
      final data = buffer.remove(nextSeq)!;
      final info = _activeStreams[streamId];
      
      _chunkReadyController.add(PttChunkReady(
        streamId: streamId,
        seq: nextSeq,
        audioData: data,
        codec: info?.codec ?? 'aac',
        sampleRate: info?.sampleRate ?? 16000,
      ));
      
      nextSeq++;
      _playbackPositions[streamId] = nextSeq;
    }
  }

  /// Get info about who is currently talking
  List<PttStreamInfo> get activeTalkers => _activeStreams.values.toList();

  /// Check if anyone is currently talking
  bool get isAnyoneTalking => _activeStreams.isNotEmpty;

  /// Check if we are currently transmitting
  bool get isTransmitting => _currentStreamId != null;

  void dispose() {
    _talkingController.close();
    _chunkReadyController.close();
    _jitterBuffers.clear();
    _activeStreams.clear();
    _playbackPositions.clear();
  }
}

/// Info about an active PTT stream
class PttStreamInfo {
  final String streamId;
  final String fromNickname;
  final String fromFingerprint;
  final String codec;
  final int sampleRate;
  final DateTime startedAt;

  PttStreamInfo({
    required this.streamId,
    required this.fromNickname,
    required this.fromFingerprint,
    required this.codec,
    required this.sampleRate,
    required this.startedAt,
  });
}

/// Event when someone starts/stops talking
class PttTalkingEvent {
  final String streamId;
  final String nickname;
  final String fingerprint;
  final bool isTalking;

  PttTalkingEvent({
    required this.streamId,
    required this.nickname,
    required this.fingerprint,
    required this.isTalking,
  });
}

/// Event when an audio chunk is ready to play
class PttChunkReady {
  final String streamId;
  final int seq;
  final Uint8List audioData;
  final String codec;
  final int sampleRate;

  PttChunkReady({
    required this.streamId,
    required this.seq,
    required this.audioData,
    required this.codec,
    required this.sampleRate,
  });
}
