import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Size of each chunk (32KB)
const int kChunkSize = 32 * 1024;

/// Media Chunk for Bluetooth Mesh transfer
/// Large files are split into chunks for reliable transmission
class MediaChunk {
  final String mediaId;      // Unique ID for the media file
  final int chunkIndex;      // 0-based index of this chunk
  final int totalChunks;     // Total number of chunks for this media
  final Uint8List data;      // Raw chunk data
  final String? sha256Hash;  // Hash of complete file (only on last chunk)
  
  const MediaChunk({
    required this.mediaId,
    required this.chunkIndex,
    required this.totalChunks,
    required this.data,
    this.sha256Hash,
  });
  
  /// Serialize chunk to JSON for mesh transmission
  Map<String, dynamic> toJson() => {
    'type': 'media_chunk',
    'mediaId': mediaId,
    'chunkIndex': chunkIndex,
    'totalChunks': totalChunks,
    'data': base64Encode(data),
    if (sha256Hash != null) 'sha256': sha256Hash,
  };
  
  /// Deserialize from JSON
  factory MediaChunk.fromJson(Map<String, dynamic> json) {
    return MediaChunk(
      mediaId: json['mediaId'] as String,
      chunkIndex: json['chunkIndex'] as int,
      totalChunks: json['totalChunks'] as int,
      data: base64Decode(json['data'] as String),
      sha256Hash: json['sha256'] as String?,
    );
  }
  
  /// Check if this is the last chunk
  bool get isLastChunk => chunkIndex == totalChunks - 1;
}

/// Chunking Service for splitting and reassembling media files
class MediaChunkingService {
  static final MediaChunkingService _instance = MediaChunkingService._internal();
  factory MediaChunkingService() => _instance;
  MediaChunkingService._internal();
  
  /// Pending chunks by mediaId → chunkIndex → data
  final Map<String, Map<int, Uint8List>> _pendingChunks = {};
  
  /// Expected total chunks per mediaId
  final Map<String, int> _expectedTotals = {};
  
  /// SHA256 hashes for verification
  final Map<String, String> _expectedHashes = {};
  
  /// Callbacks when file is complete
  final Map<String, Function(String mediaId, String localPath)> _completionCallbacks = {};
  
  /// Split a file into chunks for mesh transmission
  Future<List<MediaChunk>> splitFile(File file, String mediaId) async {
    final bytes = await file.readAsBytes();
    final totalSize = bytes.length;
    final totalChunks = (totalSize / kChunkSize).ceil();
    
    // Calculate SHA256 hash of complete file
    final digest = sha256.convert(bytes);
    final fileHash = digest.toString();
    
    print('📦 [Chunking] Splitting file: ${file.path}');
    print('📦 [Chunking] Size: $totalSize bytes, Chunks: $totalChunks');
    print('📦 [Chunking] SHA256: $fileHash');
    
    final chunks = <MediaChunk>[];
    
    for (int i = 0; i < totalChunks; i++) {
      final start = i * kChunkSize;
      final end = (start + kChunkSize > totalSize) ? totalSize : start + kChunkSize;
      final chunkData = bytes.sublist(start, end);
      
      chunks.add(MediaChunk(
        mediaId: mediaId,
        chunkIndex: i,
        totalChunks: totalChunks,
        data: Uint8List.fromList(chunkData),
        // Include hash only in last chunk
        sha256Hash: (i == totalChunks - 1) ? fileHash : null,
      ));
    }
    
    print('✅ [Chunking] Created ${chunks.length} chunks');
    return chunks;
  }
  
  /// Receive a chunk - returns completed file path if all chunks received
  Future<String?> receiveChunk(MediaChunk chunk) async {
    final mediaId = chunk.mediaId;
    
    print('📥 [Chunking] Received chunk ${chunk.chunkIndex + 1}/${chunk.totalChunks} for $mediaId');
    
    // Initialize storage for this media
    _pendingChunks[mediaId] ??= {};
    _expectedTotals[mediaId] = chunk.totalChunks;
    
    // Store chunk data
    _pendingChunks[mediaId]![chunk.chunkIndex] = chunk.data;
    
    // Store hash if present (last chunk)
    if (chunk.sha256Hash != null) {
      _expectedHashes[mediaId] = chunk.sha256Hash!;
    }
    
    // Check if all chunks received
    final received = _pendingChunks[mediaId]!.length;
    final expected = _expectedTotals[mediaId]!;
    
    print('📦 [Chunking] Progress: $received/$expected chunks');
    
    if (received == expected) {
      // All chunks received - reassemble
      return await _assembleFile(mediaId);
    }
    
    return null; // Not complete yet
  }
  
  /// Reassemble chunks into complete file
  Future<String> _assembleFile(String mediaId) async {
    print('🔧 [Chunking] Assembling file: $mediaId');
    
    final chunks = _pendingChunks[mediaId]!;
    final totalChunks = _expectedTotals[mediaId]!;
    
    // Build complete file from ordered chunks
    final builder = BytesBuilder();
    for (int i = 0; i < totalChunks; i++) {
      final chunkData = chunks[i];
      if (chunkData == null) {
        throw Exception('Missing chunk $i for $mediaId');
      }
      builder.add(chunkData);
    }
    
    final completeData = builder.toBytes();
    
    // Verify hash
    final expectedHash = _expectedHashes[mediaId];
    if (expectedHash != null) {
      final actualHash = sha256.convert(completeData).toString();
      if (actualHash != expectedHash) {
        print('❌ [Chunking] Hash mismatch! Expected: $expectedHash, Got: $actualHash');
        _cleanup(mediaId);
        throw Exception('File integrity check failed');
      }
      print('✅ [Chunking] Hash verified');
    }
    
    // Save to file
    final dir = await getTemporaryDirectory();
    final extension = _guessExtension(completeData);
    final filePath = '${dir.path}/mesh_$mediaId$extension';
    
    final file = File(filePath);
    await file.writeAsBytes(completeData);
    
    print('✅ [Chunking] File saved: $filePath (${completeData.length} bytes)');
    
    // Cleanup pending chunks
    _cleanup(mediaId);
    
    // Notify callback if registered
    _completionCallbacks[mediaId]?.call(mediaId, filePath);
    _completionCallbacks.remove(mediaId);
    
    return filePath;
  }
  
  /// Guess file extension from magic bytes
  String _guessExtension(Uint8List data) {
    if (data.length < 12) return '';
    
    // Check for common file signatures
    // M4A/MP4 - starts with ftyp
    if (data[4] == 0x66 && data[5] == 0x74 && data[6] == 0x79 && data[7] == 0x70) {
      return '.m4a';
    }
    // JPEG
    if (data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) {
      return '.jpg';
    }
    // PNG
    if (data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47) {
      return '.png';
    }
    // OGG
    if (data[0] == 0x4F && data[1] == 0x67 && data[2] == 0x67 && data[3] == 0x53) {
      return '.ogg';
    }
    
    return '.bin';
  }
  
  /// Register callback for when file assembly completes
  void onFileComplete(String mediaId, Function(String mediaId, String localPath) callback) {
    _completionCallbacks[mediaId] = callback;
  }
  
  /// Get progress for specific media
  double getProgress(String mediaId) {
    final received = _pendingChunks[mediaId]?.length ?? 0;
    final expected = _expectedTotals[mediaId] ?? 1;
    return received / expected;
  }
  
  /// Check if media is in progress
  bool isInProgress(String mediaId) {
    return _pendingChunks.containsKey(mediaId);
  }
  
  /// Get missing chunk indices
  List<int> getMissingChunks(String mediaId) {
    if (!_pendingChunks.containsKey(mediaId)) return [];
    
    final expected = _expectedTotals[mediaId] ?? 0;
    final received = _pendingChunks[mediaId]!.keys.toSet();
    
    final missing = <int>[];
    for (int i = 0; i < expected; i++) {
      if (!received.contains(i)) {
        missing.add(i);
      }
    }
    return missing;
  }
  
  /// Cleanup after completion or failure
  void _cleanup(String mediaId) {
    _pendingChunks.remove(mediaId);
    _expectedTotals.remove(mediaId);
    _expectedHashes.remove(mediaId);
  }
  
  /// Cancel pending transfer
  void cancelTransfer(String mediaId) {
    print('❌ [Chunking] Cancelled transfer: $mediaId');
    _cleanup(mediaId);
    _completionCallbacks.remove(mediaId);
  }
}
