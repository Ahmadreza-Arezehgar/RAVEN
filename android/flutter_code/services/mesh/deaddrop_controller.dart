import 'dart:async';
import '../../models/mesh_envelope.dart';
import '../database_helper.dart';
import '../geohash_service.dart';

/// DeadDropController - Location-bound messages feature
/// 
/// Allows users to leave messages at a location that others
/// can discover when they enter the same area.
/// 
/// Protocol:
/// - type: 'deaddrop'
/// - TTL: 24 hours
/// - maxHop: 2 (can relay through one intermediary)
/// - payload: { cell, title, text, dropExpiresSec }
/// 
/// Note: Uses GeoHash with low precision (6-7 chars) for privacy.
/// For MVP, user manually selects "This Area".
class DeadDropController {
  static final DeadDropController _instance = DeadDropController._();
  static DeadDropController get instance => _instance;
  
  DeadDropController._();

  final _dropUpdateController = StreamController<void>.broadcast();
  
  /// Stream that emits when dead-drop data changes
  Stream<void> get onDropUpdate => _dropUpdateController.stream;

  /// Current cell/area (set by location service or user selection)
  String? _currentCell;
  
  /// Set the current area/cell
  void setCurrentCell(String cell) {
    _currentCell = cell;
  }
  
  String? get currentCell => _currentCell;

  /// Create a new dead-drop message
  Future<MeshEnvelope> createDrop({
    required String userId,
    required String fingerprint,
    required String nickname,
    required String cell,
    required String title,
    required String text,
  }) async {
    final envelope = MeshEnvelope.deadDrop(
      from: MeshSender(
        userId: userId,
        fingerprint: fingerprint,
        nickname: nickname,
      ),
      cell: cell,
      title: title,
      text: text,
    );
    
    // Store locally
    await _storeDrop(envelope);
    
    return envelope;
  }

  /// Handle incoming dead-drop message
  Future<void> handle(MeshEnvelope envelope) async {
    if (envelope.type != 'deaddrop') return;
    if (envelope.isExpired) return;
    
    // Always store dead-drops (they may be relevant when user moves areas)
    await _storeDrop(envelope);
    _dropUpdateController.add(null);
  }

  /// Store dead-drop in local database
  Future<void> _storeDrop(MeshEnvelope envelope) async {
    final db = await DatabaseHelper.instance.database;
    final payload = envelope.payload;
    
    final cell = payload['cell'] as String? ?? '';
    final title = payload['title'] as String? ?? '';
    final text = payload['text'] as String? ?? '';
    final dropExpiresSec = payload['dropExpiresSec'] as int? ?? 86400;
    
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(envelope.ts)
        .add(Duration(seconds: dropExpiresSec))
        .millisecondsSinceEpoch;
    
    await db.rawInsert('''
      INSERT OR REPLACE INTO dead_drops 
      (id, cell, title, text, expiresAt, storedAt, seen, fromNickname, fromFingerprint)
      VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)
    ''', [
      envelope.id,
      cell,
      title,
      text,
      expiresAt,
      envelope.ts,
      envelope.from.nickname,
      envelope.from.fingerprint,
    ]);
  }

  /// Get dead-drops for a specific cell/area
  Future<List<DeadDrop>> getDropsForCell(String cell) async {
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    
    final results = await db.query(
      'dead_drops',
      where: 'cell = ? AND expiresAt > ?',
      whereArgs: [cell, now],
      orderBy: 'storedAt DESC',
    );
    
    return results.map((row) => DeadDrop.fromMap(row)).toList();
  }

  /// Get all dead-drops (for current area plus nearby)
  Future<List<DeadDrop>> getAllActiveDrops() async {
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    
    final results = await db.query(
      'dead_drops',
      where: 'expiresAt > ?',
      whereArgs: [now],
      orderBy: 'storedAt DESC',
    );
    
    return results.map((row) => DeadDrop.fromMap(row)).toList();
  }

  /// Get unread dead-drops count
  Future<int> getUnreadCount() async {
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    
    final result = await db.rawQuery('''
      SELECT COUNT(*) as count FROM dead_drops 
      WHERE expiresAt > ? AND seen = 0
    ''', [now]);
    
    return result.first['count'] as int? ?? 0;
  }

  /// Mark a dead-drop as read
  Future<void> markAsRead(String dropId) async {
    final db = await DatabaseHelper.instance.database;
    await db.update(
      'dead_drops',
      {'seen': 1},
      where: 'id = ?',
      whereArgs: [dropId],
    );
    _dropUpdateController.add(null);
  }

  /// Delete a dead-drop locally
  Future<void> deleteDrop(String dropId) async {
    final db = await DatabaseHelper.instance.database;
    await db.delete(
      'dead_drops',
      where: 'id = ?',
      whereArgs: [dropId],
    );
    _dropUpdateController.add(null);
  }

  /// Clear expired dead-drops
  Future<int> cleanupExpired() async {
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    
    return await db.delete(
      'dead_drops',
      where: 'expiresAt <= ?',
      whereArgs: [now],
    );
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // UI HELPER METHODS (used by DeadDropListScreen)
  // ═══════════════════════════════════════════════════════════════════════════
  
  /// Get current geo cell using GPS + geohash encoding
  /// Precision 7 gives ~153m accuracy (good for "nearby" discovery)
  Future<String> getCurrentCell() async {
    // Return cached if available
    if (_currentCell != null && _currentCell!.isNotEmpty) {
      return _currentCell!;
    }
    
    // Get real geohash from GPS
    final geohash = await GeohashService.instance.getCurrentGeohash(precision: 7);
    if (geohash.isNotEmpty) {
      _currentCell = geohash;
      return geohash;
    }
    
    // Fallback for MVP/testing
    return 'u4pruydqq';
  }
  
  /// Get local drops for a cell (alias for getDropsForCell)
  Future<List<DeadDrop>> getLocalDrops(String cell) async {
    return getDropsForCell(cell);
  }
  
  /// Get drops created by current user
  Future<List<DeadDrop>> getMyDrops() async {
    // For MVP, return all drops (would filter by fingerprint in production)
    return getAllActiveDrops();
  }
  
  /// Simplified create drop for UI (uses stored fingerprint)
  Future<bool> createDropSimplified({
    required String title,
    required String text,
    required String cell,
    int ttlSeconds = 86400,
  }) async {
    try {
      final envelope = MeshEnvelope.deadDrop(
        from: MeshSender(
          userId: 'local',
          fingerprint: 'local',
          nickname: 'Me',
        ),
        cell: cell,
        title: title,
        text: text,
        dropExpiresSec: ttlSeconds,
      );
      
      await _storeDrop(envelope);
      _dropUpdateController.add(null);
      
      return true;
    } catch (e) {
      return false;
    }
  }
  
  void dispose() {
    _dropUpdateController.close();
  }
}

/// Model for dead-drop from database
class DeadDrop {
  final String id;
  final String cell;
  final String title;
  final String text;
  final DateTime expiresAt;
  final DateTime storedAt;
  final bool seen;
  final String fromNickname;
  final String fromFingerprint;

  DeadDrop({
    required this.id,
    required this.cell,
    required this.title,
    required this.text,
    required this.expiresAt,
    required this.storedAt,
    required this.seen,
    required this.fromNickname,
    required this.fromFingerprint,
  });

  factory DeadDrop.fromMap(Map<String, dynamic> map) => DeadDrop(
    id: map['id'] as String? ?? '',
    cell: map['cell'] as String? ?? '',
    title: map['title'] as String? ?? '',
    text: map['text'] as String? ?? '',
    expiresAt: DateTime.fromMillisecondsSinceEpoch(map['expiresAt'] as int? ?? 0),
    storedAt: DateTime.fromMillisecondsSinceEpoch(map['storedAt'] as int? ?? 0),
    seen: (map['seen'] as int? ?? 0) == 1,
    fromNickname: map['fromNickname'] as String? ?? 'Unknown',
    fromFingerprint: map['fromFingerprint'] as String? ?? '',
  );

  /// Time remaining until expiration
  Duration get timeRemaining {
    final remaining = expiresAt.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Human-readable time remaining
  String get timeRemainingText {
    final remaining = timeRemaining;
    if (remaining.inHours > 0) {
      return '${remaining.inHours}h remaining';
    } else if (remaining.inMinutes > 0) {
      return '${remaining.inMinutes}m remaining';
    }
    return 'Expiring soon';
  }

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}
