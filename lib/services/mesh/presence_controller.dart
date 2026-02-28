import 'dart:async';
import 'dart:convert';
import '../../models/mesh_envelope.dart';
import '../database_helper.dart';

/// PresenceController - Handles Mesh Presence (Check-in) feature
/// 
/// Enables users to broadcast their presence to nearby devices.
/// Others can see who is currently in the area.
/// 
/// Protocol:
/// - type: 'presence'
/// - TTL: 15 minutes
/// - maxHop: 1 (direct neighbors only)
/// - payload: { status: 'here', note?: 'optional message' }
class PresenceController {
  static final PresenceController _instance = PresenceController._();
  static PresenceController get instance => _instance;
  
  PresenceController._();

  final _presenceUpdateController = StreamController<void>.broadcast();
  
  /// Stream that emits when presence data changes
  Stream<void> get onPresenceUpdate => _presenceUpdateController.stream;

  /// Send a check-in presence broadcast
  Future<MeshEnvelope> sendCheckIn({
    required String userId,
    required String fingerprint,
    required String nickname,
    String? note,
  }) async {
    final envelope = MeshEnvelope.presence(
      from: MeshSender(
        userId: userId,
        fingerprint: fingerprint,
        nickname: nickname,
      ),
      status: 'here',
      note: note,
    );
    
    // Store our own presence locally
    await _storePresence(envelope);
    
    return envelope;
  }

  /// Handle incoming presence message
  Future<void> handle(MeshEnvelope envelope) async {
    if (envelope.type != 'presence') return;
    if (envelope.isExpired) return;
    
    await _storePresence(envelope);
    _presenceUpdateController.add(null);
  }

  /// Store presence in local database
  Future<void> _storePresence(MeshEnvelope envelope) async {
    final db = await DatabaseHelper.instance.database;
    final fingerprint = envelope.from.fingerprint;
    final nickname = envelope.from.nickname;
    final lastSeenAt = envelope.ts;
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(envelope.ts)
        .add(Duration(seconds: envelope.ttlSec))
        .millisecondsSinceEpoch;
    
    await db.rawInsert('''
      INSERT OR REPLACE INTO presence_events 
      (fingerprint, nickname, lastSeenAt, expiresAt)
      VALUES (?, ?, ?, ?)
    ''', [fingerprint, nickname, lastSeenAt, expiresAt]);
  }

  /// Get list of active (non-expired) presences
  Future<List<PresenceEvent>> getActivePresences() async {
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    
    final results = await db.query(
      'presence_events',
      where: 'expiresAt > ?',
      whereArgs: [now],
      orderBy: 'lastSeenAt DESC',
    );
    
    return results.map((row) => PresenceEvent.fromMap(row)).toList();
  }

  /// Clear expired presences
  Future<int> cleanupExpired() async {
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    
    return await db.delete(
      'presence_events',
      where: 'expiresAt <= ?',
      whereArgs: [now],
    );
  }
  
  void dispose() {
    _presenceUpdateController.close();
  }
}

/// Model for presence event from database
class PresenceEvent {
  final String fingerprint;
  final String nickname;
  final DateTime lastSeenAt;
  final DateTime expiresAt;

  PresenceEvent({
    required this.fingerprint,
    required this.nickname,
    required this.lastSeenAt,
    required this.expiresAt,
  });

  factory PresenceEvent.fromMap(Map<String, dynamic> map) => PresenceEvent(
    fingerprint: map['fingerprint'] as String? ?? '',
    nickname: map['nickname'] as String? ?? 'Unknown',
    lastSeenAt: DateTime.fromMillisecondsSinceEpoch(map['lastSeenAt'] as int? ?? 0),
    expiresAt: DateTime.fromMillisecondsSinceEpoch(map['expiresAt'] as int? ?? 0),
  );

  /// Time remaining until expiration
  Duration get timeRemaining {
    final remaining = expiresAt.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Human-readable time remaining
  String get timeRemainingText {
    final remaining = timeRemaining;
    if (remaining.inMinutes > 0) {
      return '${remaining.inMinutes}m remaining';
    } else if (remaining.inSeconds > 0) {
      return '${remaining.inSeconds}s remaining';
    }
    return 'Expired';
  }

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}
