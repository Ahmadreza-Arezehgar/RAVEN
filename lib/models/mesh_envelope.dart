import 'dart:convert';
import 'package:uuid/uuid.dart';

/// Mesh message types
enum MeshMessageType {
  presence,   // Check-in / "I'm here"
  deaddrop,   // Location-bound messages
  ptt,        // Push-to-Talk voice chunks
  knowledge,  // Shared knowledge cache
}

/// Sender identity in mesh messages
class MeshSender {
  final String userId;       // Server user ID or local ID
  final String fingerprint;  // SHA256(publicKey)
  final String nickname;     // Display name

  const MeshSender({
    required this.userId,
    required this.fingerprint,
    required this.nickname,
  });

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'fingerprint': fingerprint,
    'nickname': nickname,
  };

  factory MeshSender.fromJson(Map<String, dynamic> json) => MeshSender(
    userId: json['userId'] as String? ?? '',
    fingerprint: json['fingerprint'] as String? ?? '',
    nickname: json['nickname'] as String? ?? 'Unknown',
  );
}

/// MeshEnvelope - Unified envelope format for all Mesh messages
/// 
/// This provides a standardized format for:
/// - Message deduplication (via id)
/// - TTL-based expiration
/// - Hop counting for relay control
/// - Type-based routing
/// 
/// Example envelope:
/// ```json
/// {
///   "v": 1,
///   "id": "uuid",
///   "type": "presence",
///   "ts": 1700000000000,
///   "from": {
///     "userId": "server_user_id",
///     "fingerprint": "sha256...",
///     "nickname": "AHMD"
///   },
///   "ttlSec": 900,
///   "hop": 0,
///   "maxHop": 1,
///   "payload": { ... }
/// }
/// ```
class MeshEnvelope {
  /// Protocol version (for future compatibility)
  final int v;
  
  /// Unique message ID for deduplication
  final String id;
  
  /// Message type: presence, deaddrop, ptt, knowledge
  final String type;
  
  /// Timestamp (milliseconds since epoch)
  final int ts;
  
  /// Sender identity
  final MeshSender from;
  
  /// Time-to-live in seconds
  final int ttlSec;
  
  /// Current hop count (incremented on each relay)
  final int hop;
  
  /// Maximum allowed hops
  final int maxHop;
  
  /// Type-specific payload data
  final Map<String, dynamic> payload;

  MeshEnvelope({
    this.v = 1,
    String? id,
    required this.type,
    int? ts,
    required this.from,
    required this.ttlSec,
    this.hop = 0,
    required this.maxHop,
    required this.payload,
  }) : id = id ?? const Uuid().v4(),
       ts = ts ?? DateTime.now().millisecondsSinceEpoch;

  /// Check if this message has expired
  bool get isExpired {
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(ts)
        .add(Duration(seconds: ttlSec));
    return DateTime.now().isAfter(expiresAt);
  }

  /// Check if this message can be relayed further
  bool get canRelay => hop < maxHop && !isExpired;

  /// Create a relayed copy with incremented hop count
  MeshEnvelope relay() {
    return MeshEnvelope(
      v: v,
      id: id,
      type: type,
      ts: ts,
      from: from,
      ttlSec: ttlSec,
      hop: hop + 1,
      maxHop: maxHop,
      payload: payload,
    );
  }

  /// Convert to JSON map
  Map<String, dynamic> toJson() => {
    'v': v,
    'id': id,
    'type': type,
    'ts': ts,
    'from': from.toJson(),
    'ttlSec': ttlSec,
    'hop': hop,
    'maxHop': maxHop,
    'payload': payload,
  };

  /// Parse from JSON map
  factory MeshEnvelope.fromJson(Map<String, dynamic> json) => MeshEnvelope(
    v: json['v'] as int? ?? 1,
    id: json['id'] as String?,
    type: json['type'] as String? ?? 'unknown',
    ts: json['ts'] as int?,
    from: MeshSender.fromJson(json['from'] as Map<String, dynamic>? ?? {}),
    ttlSec: json['ttlSec'] as int? ?? 60,
    hop: json['hop'] as int? ?? 0,
    maxHop: json['maxHop'] as int? ?? 1,
    payload: json['payload'] as Map<String, dynamic>? ?? {},
  );

  /// Serialize to JSON string
  String toJsonString() => jsonEncode(toJson());

  /// Parse from JSON string
  factory MeshEnvelope.fromJsonString(String jsonStr) {
    final json = jsonDecode(jsonStr) as Map<String, dynamic>;
    return MeshEnvelope.fromJson(json);
  }

  // ═══════════════════════════════════════════════════════════════
  // FACTORY CONSTRUCTORS FOR SPECIFIC MESSAGE TYPES
  // ═══════════════════════════════════════════════════════════════

  /// Create a Presence (check-in) message
  /// TTL: 15 minutes, maxHop: 1
  factory MeshEnvelope.presence({
    required MeshSender from,
    String status = 'here',
    String? note,
  }) {
    return MeshEnvelope(
      type: 'presence',
      from: from,
      ttlSec: 15 * 60, // 15 minutes
      maxHop: 1,
      payload: {
        'status': status,
        if (note != null) 'note': note,
      },
    );
  }

  /// Create a Dead-Drop message
  /// TTL: 24 hours, maxHop: 2
  factory MeshEnvelope.deadDrop({
    required MeshSender from,
    required String cell,
    required String title,
    required String text,
    int dropExpiresSec = 86400,
  }) {
    return MeshEnvelope(
      type: 'deaddrop',
      from: from,
      ttlSec: 86400, // 24 hours
      maxHop: 2,
      payload: {
        'cell': cell,
        'title': title,
        'text': text,
        'dropExpiresSec': dropExpiresSec,
      },
    );
  }

  /// Create a PTT voice chunk message
  /// TTL: 3 seconds, maxHop: 1
  factory MeshEnvelope.pttChunk({
    required MeshSender from,
    required String streamId,
    required int seq,
    required String chunkB64,
    String codec = 'aac',
    int sampleRate = 16000,
    bool isEnd = false,
  }) {
    return MeshEnvelope(
      type: 'ptt',
      from: from,
      ttlSec: 3, // Very short TTL for voice
      maxHop: 1,
      payload: {
        'streamId': streamId,
        'seq': seq,
        'codec': codec,
        'sampleRate': sampleRate,
        'chunkB64': chunkB64,
        'end': isEnd,
      },
    );
  }

  /// Create a Knowledge announce message
  /// TTL: 1 hour, maxHop: 1
  factory MeshEnvelope.knowledgeAnnounce({
    required MeshSender from,
    required List<Map<String, dynamic>> items,
  }) {
    return MeshEnvelope(
      type: 'knowledge',
      from: from,
      ttlSec: 3600, // 1 hour
      maxHop: 1,
      payload: {
        'op': 'announce',
        'items': items,
      },
    );
  }

  /// Create a Knowledge want (request) message
  /// TTL: 1 minute, maxHop: 1
  factory MeshEnvelope.knowledgeWant({
    required MeshSender from,
    required String hash,
  }) {
    return MeshEnvelope(
      type: 'knowledge',
      from: from,
      ttlSec: 60,
      maxHop: 1,
      payload: {
        'op': 'want',
        'hash': hash,
      },
    );
  }

  /// Create a Knowledge chunk (response) message
  /// TTL: 1 minute, maxHop: 1
  factory MeshEnvelope.knowledgeChunk({
    required MeshSender from,
    required String hash,
    required int seq,
    required int total,
    required String dataB64,
    required String mime,
  }) {
    return MeshEnvelope(
      type: 'knowledge',
      from: from,
      ttlSec: 60,
      maxHop: 1,
      payload: {
        'op': 'chunk',
        'hash': hash,
        'seq': seq,
        'total': total,
        'dataB64': dataB64,
        'mime': mime,
      },
    );
  }

  @override
  String toString() => 'MeshEnvelope(type: $type, id: ${id.substring(0, 8)}, hop: $hop/$maxHop)';
}
