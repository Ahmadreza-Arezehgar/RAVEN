import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Audio Codec Service - Recording and encoding for PTT
/// 
/// Uses the `record` package for cross-platform audio capture.
/// Encodes to AAC for efficient transmission over mesh.
/// 
/// Note: For maximum compatibility, AAC-LC at 16kHz/32kbps
/// provides good quality at ~4KB/second.
class AudioCodecService {
  static final AudioCodecService _instance = AudioCodecService._();
  static AudioCodecService get instance => _instance;
  AudioCodecService._();

  final AudioRecorder _recorder = AudioRecorder();
  String? _currentRecordingPath;
  StreamSubscription<Uint8List>? _streamSubscription;
  
  bool _isRecording = false;
  bool get isRecording => _isRecording;
  
  // Audio settings for mesh transmission
  static const int sampleRate = 16000; // 16kHz for speech
  static const int bitRate = 32000;    // 32kbps AAC - good for speech
  static const int numChannels = 1;    // Mono

  /// Check if microphone permission is granted
  Future<bool> hasPermission() async {
    return await _recorder.hasPermission();
  }

  /// Request microphone permission
  Future<bool> requestPermission() async {
    return await _recorder.hasPermission();
  }

  /// Start recording to a temporary file
  /// Returns the path to the recording file
  Future<String?> startRecording() async {
    if (_isRecording) return _currentRecordingPath;
    
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      debugPrint('🎙️ [AudioCodec] No microphone permission');
      return null;
    }
    
    try {
      // Get temp directory
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      _currentRecordingPath = '${tempDir.path}/ptt_$timestamp.m4a';
      
      // Configure and start recording
      await _recorder.start(
        RecordConfig(
          encoder: AudioEncoder.aacLc,
          sampleRate: sampleRate,
          bitRate: bitRate,
          numChannels: numChannels,
        ),
        path: _currentRecordingPath!,
      );
      
      _isRecording = true;
      debugPrint('🎙️ [AudioCodec] Recording started: $_currentRecordingPath');
      
      return _currentRecordingPath;
    } catch (e) {
      debugPrint('❌ [AudioCodec] Start recording error: $e');
      return null;
    }
  }

  /// Start streaming recording (returns audio chunks as stream)
  /// This is better for real-time PTT transmission
  Future<Stream<Uint8List>?> startRecordingStream() async {
    if (_isRecording) return null;
    
    try {
      // Using PCM16 for streaming since it's uncompressed
      // We'll encode chunks separately for transmission
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: sampleRate,
          numChannels: numChannels,
        ),
      );
      
      _isRecording = true;
      debugPrint('🎙️ [AudioCodec] Stream recording started');
      
      return stream;
    } catch (e) {
      debugPrint('❌ [AudioCodec] Start stream error: $e');
      return null;
    }
  }

  /// Stop recording and return the audio data
  Future<Uint8List?> stopRecording() async {
    if (!_isRecording) return null;
    
    try {
      final path = await _recorder.stop();
      _isRecording = false;
      
      if (path != null) {
        final file = File(path);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          debugPrint('🎙️ [AudioCodec] Recording stopped: ${bytes.length} bytes');
          
          // Cleanup temp file after a delay
          Future.delayed(const Duration(seconds: 5), () async {
            try {
              if (await file.exists()) {
                await file.delete();
              }
            } catch (_) {}
          });
          
          return bytes;
        }
      }
      
      debugPrint('⚠️ [AudioCodec] No recording data');
      return null;
    } catch (e) {
      debugPrint('❌ [AudioCodec] Stop recording error: $e');
      _isRecording = false;
      return null;
    }
  }

  /// Stop streaming and cleanup
  Future<void> stopStream() async {
    if (!_isRecording) return;
    
    try {
      await _recorder.stop();
      _streamSubscription?.cancel();
      _streamSubscription = null;
      _isRecording = false;
      debugPrint('🎙️ [AudioCodec] Stream stopped');
    } catch (e) {
      debugPrint('❌ [AudioCodec] Stop stream error: $e');
      _isRecording = false;
    }
  }

  /// Cancel recording without saving
  Future<void> cancelRecording() async {
    if (!_isRecording) return;
    
    try {
      final path = await _recorder.stop();
      _isRecording = false;
      
      // Delete the file
      if (path != null) {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      }
      
      debugPrint('🎙️ [AudioCodec] Recording cancelled');
    } catch (e) {
      _isRecording = false;
    }
  }

  /// Encode audio chunk to base64 for mesh transmission
  String encodeChunkToBase64(Uint8List chunk) {
    return base64Encode(chunk);
  }

  /// Decode base64 chunk back to audio bytes
  Uint8List decodeChunkFromBase64(String base64Str) {
    return base64Decode(base64Str);
  }

  /// Get estimated chunk size for given duration
  static int estimateChunkSize(Duration duration) {
    // At 32kbps, 1 second = 4KB
    return (bitRate / 8 * duration.inMilliseconds / 1000).round();
  }

  /// Dispose resources
  void dispose() {
    _streamSubscription?.cancel();
    _recorder.dispose();
  }
}
