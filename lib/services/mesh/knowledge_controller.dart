import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../models/mesh_envelope.dart';
import '../database_helper.dart';

/// KnowledgeController - Local Knowledge Cache feature
/// 
/// Enables users to share and discover knowledge items (text, links, files)
/// with nearby peers. Items are cached locally and synced via announce/want/chunk.
/// 
/// Protocol:
/// - type: 'knowledge'
/// - payload.op: 'announce' | 'want' | 'chunk'
/// 
/// announce: Broadcast catalog of available items
/// want: Request a specific item by hash
/// chunk: Send data chunks for requested item
class KnowledgeController {
  static final KnowledgeController _instance = KnowledgeController._();
  static KnowledgeController get instance => _instance;
  
  KnowledgeController._();

  final _updateController = StreamController<void>.broadcast();
  
  /// Stream that emits when knowledge data changes
  Stream<void> get onUpdate => _updateController.stream;
  
  /// Pending chunk requests (hash -> completer)
  final Map<String, Completer<KnowledgeItem?>> _pendingRequests = {};
  
  /// Received chunks being assembled (hash -> list of chunks)
  final Map<String, List<KnowledgeChunk>> _receivedChunks = {};

  // ═══════════════════════════════════════════════════════════════
  // CREATING ITEMS
  // ═══════════════════════════════════════════════════════════════

  /// Create a new knowledge item from text content
  Future<KnowledgeItem> createTextItem({
    required String title,
    required String text,
    int expiresSec = 86400,
  }) async {
    final hash = sha256.convert(utf8.encode(text)).toString();
    
    final item = KnowledgeItem(
      hash: hash,
      title: title,
      kind: 'text',
      mime: 'text/plain',
      size: text.length,
      expiresAt: DateTime.now().add(Duration(seconds: expiresSec)),
      payloadText: text,
    );
    
    await _storeItem(item);
    return item;
  }

  /// Create a new knowledge item from a link
  Future<KnowledgeItem> createLinkItem({
    required String title,
    required String url,
    int expiresSec = 86400,
  }) async {
    final hash = sha256.convert(utf8.encode(url)).toString();
    
    final item = KnowledgeItem(
      hash: hash,
      title: title,
      kind: 'link',
      mime: 'text/uri-list',
      size: url.length,
      expiresAt: DateTime.now().add(Duration(seconds: expiresSec)),
      payloadText: url,
    );
    
    await _storeItem(item);
    return item;
  }

  // ═══════════════════════════════════════════════════════════════
  // ANNOUNCE
  // ═══════════════════════════════════════════════════════════════

  /// Create announce envelope for our available items
  Future<MeshEnvelope> createAnnounceEnvelope({
    required String userId,
    required String fingerprint,
    required String nickname,
  }) async {
    final items = await getLocalItems();
    
    final itemsList = items.map((item) => {
      'hash': item.hash,
      'kind': item.kind,
      'title': item.title,
      'size': item.size,
      'expiresSec': item.expiresAt.difference(DateTime.now()).inSeconds,
    }).toList();
    
    return MeshEnvelope.knowledgeAnnounce(
      from: MeshSender(
        userId: userId,
        fingerprint: fingerprint,
        nickname: nickname,
      ),
      items: itemsList,
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // WANT / REQUEST
  // ═══════════════════════════════════════════════════════════════

  /// Create want envelope to request an item
  MeshEnvelope createWantEnvelope({
    required String userId,
    required String fingerprint,
    required String nickname,
    required String hash,
  }) {
    return MeshEnvelope.knowledgeWant(
      from: MeshSender(
        userId: userId,
        fingerprint: fingerprint,
        nickname: nickname,
      ),
      hash: hash,
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // CHUNK SENDING
  // ═══════════════════════════════════════════════════════════════

  /// Create chunk envelopes for an item (split into multiple if needed)
  Future<List<MeshEnvelope>> createChunkEnvelopes({
    required String userId,
    required String fingerprint,
    required String nickname,
    required String hash,
    int chunkSize = 4096, // 4KB chunks
  }) async {
    final item = await getItemByHash(hash);
    if (item == null || item.payloadText == null) return [];
    
    final data = utf8.encode(item.payloadText!);
    final totalChunks = (data.length / chunkSize).ceil();
    final envelopes = <MeshEnvelope>[];
    
    for (var i = 0; i < totalChunks; i++) {
      final start = i * chunkSize;
      final end = (start + chunkSize).clamp(0, data.length);
      final chunk = data.sublist(start, end);
      
      envelopes.add(MeshEnvelope.knowledgeChunk(
        from: MeshSender(
          userId: userId,
          fingerprint: fingerprint,
          nickname: nickname,
        ),
        hash: hash,
        seq: i,
        total: totalChunks,
        dataB64: base64Encode(chunk),
        mime: item.mime,
      ));
    }
    
    return envelopes;
  }

  // ═══════════════════════════════════════════════════════════════
  // HANDLING INCOMING
  // ═══════════════════════════════════════════════════════════════

  /// Handle incoming knowledge message
  Future<List<MeshEnvelope>?> handle(
    MeshEnvelope envelope, {
    required String myUserId,
    required String myFingerprint,
    required String myNickname,
  }) async {
    if (envelope.type != 'knowledge') return null;
    if (envelope.isExpired) return null;
    
    final op = envelope.payload['op'] as String?;
    
    switch (op) {
      case 'announce':
        await _handleAnnounce(envelope);
        break;
      case 'want':
        // Return chunks if we have the item
        return await _handleWant(envelope, myUserId, myFingerprint, myNickname);
      case 'chunk':
        await _handleChunk(envelope);
        break;
    }
    
    return null;
  }

  Future<void> _handleAnnounce(MeshEnvelope envelope) async {
    final items = envelope.payload['items'] as List<dynamic>? ?? [];
    
    for (final itemData in items) {
      final map = itemData as Map<String, dynamic>;
      final hash = map['hash'] as String? ?? '';
      
      // Record that this peer has this item
      await _recordPeer(hash, envelope.from.fingerprint);
    }
    
    _updateController.add(null);
  }

  Future<List<MeshEnvelope>?> _handleWant(
    MeshEnvelope envelope,
    String myUserId,
    String myFingerprint,
    String myNickname,
  ) async {
    final hash = envelope.payload['hash'] as String? ?? '';
    
    // Check if we have this item
    final item = await getItemByHash(hash);
    if (item != null && item.payloadText != null) {
      // Send chunks back
      return await createChunkEnvelopes(
        userId: myUserId,
        fingerprint: myFingerprint,
        nickname: myNickname,
        hash: hash,
      );
    }
    
    return null;
  }

  Future<void> _handleChunk(MeshEnvelope envelope) async {
    final hash = envelope.payload['hash'] as String? ?? '';
    final seq = envelope.payload['seq'] as int? ?? 0;
    final total = envelope.payload['total'] as int? ?? 1;
    final dataB64 = envelope.payload['dataB64'] as String? ?? '';
    final mime = envelope.payload['mime'] as String? ?? 'text/plain';
    
    // Initialize chunk list for this hash
    _receivedChunks[hash] ??= [];
    
    // Add chunk
    _receivedChunks[hash]!.add(KnowledgeChunk(
      seq: seq,
      total: total,
      data: base64Decode(dataB64),
      mime: mime,
    ));
    
    // Check if we have all chunks
    final chunks = _receivedChunks[hash]!;
    if (chunks.length == total) {
      // Sort by sequence and reassemble
      chunks.sort((a, b) => a.seq.compareTo(b.seq));
      
      final assembledData = <int>[];
      for (final chunk in chunks) {
        assembledData.addAll(chunk.data);
      }
      
      final text = utf8.decode(assembledData);
      
      // Create and store the item
      final item = KnowledgeItem(
        hash: hash,
        title: 'Downloaded Item', // Will be updated from announce
        kind: 'text',
        mime: mime,
        size: text.length,
        expiresAt: DateTime.now().add(const Duration(days: 1)),
        payloadText: text,
      );
      
      await _storeItem(item);
      _receivedChunks.remove(hash);
      
      // Complete pending request
      _pendingRequests[hash]?.complete(item);
      _pendingRequests.remove(hash);
      
      _updateController.add(null);
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // DATABASE OPERATIONS
  // ═══════════════════════════════════════════════════════════════

  Future<void> _storeItem(KnowledgeItem item) async {
    final db = await DatabaseHelper.instance.database;
    
    await db.rawInsert('''
      INSERT OR REPLACE INTO knowledge_items 
      (hash, title, kind, mime, size, expiresAt, payloadText, localPath, score)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', [
      item.hash,
      item.title,
      item.kind,
      item.mime,
      item.size,
      item.expiresAt.millisecondsSinceEpoch,
      item.payloadText,
      item.localPath,
      item.score,
    ]);
  }

  Future<void> _recordPeer(String hash, String fingerprint) async {
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    
    await db.rawInsert('''
      INSERT OR REPLACE INTO knowledge_peers 
      (hash, fingerprint, lastSeenAt)
      VALUES (?, ?, ?)
    ''', [hash, fingerprint, now]);
    
    // Update item score (popularity)
    await db.rawUpdate('''
      UPDATE knowledge_items 
      SET score = (SELECT COUNT(*) FROM knowledge_peers WHERE hash = ?)
      WHERE hash = ?
    ''', [hash, hash]);
  }

  /// Get all local knowledge items
  Future<List<KnowledgeItem>> getLocalItems() async {
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    
    final results = await db.query(
      'knowledge_items',
      where: 'expiresAt > ?',
      whereArgs: [now],
      orderBy: 'score DESC, expiresAt DESC',
    );
    
    return results.map((row) => KnowledgeItem.fromMap(row)).toList();
  }

  /// Get trending items (most peers)
  Future<List<KnowledgeItem>> getTrendingItems({int limit = 20}) async {
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    
    final results = await db.query(
      'knowledge_items',
      where: 'expiresAt > ?',
      whereArgs: [now],
      orderBy: 'score DESC',
      limit: limit,
    );
    
    return results.map((row) => KnowledgeItem.fromMap(row)).toList();
  }

  /// Get item by hash
  Future<KnowledgeItem?> getItemByHash(String hash) async {
    final db = await DatabaseHelper.instance.database;
    
    final results = await db.query(
      'knowledge_items',
      where: 'hash = ?',
      whereArgs: [hash],
      limit: 1,
    );
    
    if (results.isEmpty) return null;
    return KnowledgeItem.fromMap(results.first);
  }

  /// Get peer count for an item
  Future<int> getPeerCount(String hash) async {
    final db = await DatabaseHelper.instance.database;
    
    final result = await db.rawQuery('''
      SELECT COUNT(*) as count FROM knowledge_peers WHERE hash = ?
    ''', [hash]);
    
    return result.first['count'] as int? ?? 0;
  }

  /// Cleanup expired items
  Future<void> cleanupExpired() async {
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    
    await db.delete(
      'knowledge_items',
      where: 'expiresAt <= ?',
      whereArgs: [now],
    );
  }
  
  // ═══════════════════════════════════════════════════════════════
  // UI HELPER METHODS (used by KnowledgePanelScreen)
  // ═══════════════════════════════════════════════════════════════
  
  /// Get all items (alias for getLocalItems) for UI
  Future<List<KnowledgeItem>> getAllItems() async {
    return getLocalItems();
  }
  
  /// Search items by title
  Future<List<KnowledgeItem>> searchByTitle(String query) async {
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    
    final results = await db.query(
      'knowledge_items',
      where: 'expiresAt > ? AND title LIKE ?',
      whereArgs: [now, '%$query%'],
      orderBy: 'score DESC, expiresAt DESC',
    );
    
    return results.map((row) => KnowledgeItem.fromMap(row)).toList();
  }
  
  /// Simplified publish for UI
  Future<bool> publishItem({
    required String title,
    required String kind,
    required String content,
  }) async {
    try {
      if (kind == 'link') {
        await createLinkItem(title: title, url: content);
      } else {
        await createTextItem(title: title, text: content);
      }
      _updateController.add(null);
      return true;
    } catch (e) {
      return false;
    }
  }
  
  /// Delete an item by hash
  Future<void> deleteItem(String hash) async {
    final db = await DatabaseHelper.instance.database;
    await db.delete(
      'knowledge_items',
      where: 'hash = ?',
      whereArgs: [hash],
    );
    _updateController.add(null);
  }
  
  void dispose() {
    _updateController.close();
    _pendingRequests.clear();
    _receivedChunks.clear();
  }
}

/// Model for knowledge item
class KnowledgeItem {
  final String hash;
  final String title;
  final String kind; // 'text', 'link', 'file'
  final String mime;
  final int size;
  final DateTime expiresAt;
  final String? payloadText;
  final String? localPath;
  final int score;

  KnowledgeItem({
    required this.hash,
    required this.title,
    required this.kind,
    required this.mime,
    required this.size,
    required this.expiresAt,
    this.payloadText,
    this.localPath,
    this.score = 0,
  });

  factory KnowledgeItem.fromMap(Map<String, dynamic> map) => KnowledgeItem(
    hash: map['hash'] as String? ?? '',
    title: map['title'] as String? ?? '',
    kind: map['kind'] as String? ?? 'text',
    mime: map['mime'] as String? ?? 'text/plain',
    size: map['size'] as int? ?? 0,
    expiresAt: DateTime.fromMillisecondsSinceEpoch(map['expiresAt'] as int? ?? 0),
    payloadText: map['payloadText'] as String?,
    localPath: map['localPath'] as String?,
    score: map['score'] as int? ?? 0,
  );

  bool get isExpired => DateTime.now().isAfter(expiresAt);
  bool get hasContent => payloadText != null || localPath != null;
}

/// Chunk during assembly
class KnowledgeChunk {
  final int seq;
  final int total;
  final List<int> data;
  final String mime;

  KnowledgeChunk({
    required this.seq,
    required this.total,
    required this.data,
    required this.mime,
  });
}
