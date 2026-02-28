import 'dart:convert';

class ChatMessage {
  final String id;
  final String roomId;
  final String senderId;
  final String senderName;
  final String recipientId;
  final String text;
  final DateTime timestamp;
  final String via;
  final MessageStatus status;
  final MessageType type;
  final int ttl;
  final List<String> routePath;
  final bool needsForwarding;
  final DateTime? deliveredAt;
  final DateTime? readAt;
  
  // DTN Mesh Networking fields
  final String? messageSignature;  // HMAC signature for authentication
  final int sprayCounter;           // Remaining copies for Spray-and-Wait
  final String? originDeviceId;     // Original device that created the message
  final int hopCount;               // Number of relay hops
  final int hopLimit;               // Maximum allowed hops (default 10)
  final DeliveryAuthority deliveryAuthority; // server or mesh routing
  
  // Media fields (for image/file/voice)
  final String? audioUrl;           // URL for media (CDN) - used for voice/image/file
  final String? fileName;           // Original filename e.g. "photo_2024.jpg"
  final String? mimeType;           // MIME type e.g. "image/jpeg", "application/pdf"
  final int? fileSize;              // File size in bytes
  final String? thumbnailUrl;       // Thumbnail URL for image previews
  final int? audioDurationSeconds;   // Duration of voice message in seconds
  
  // Voice transcript fields
  final String? transcriptText;     // Transcribed text
  final String? transcriptLang;     // Language of transcript (en, fa, es, etc.)
  final int transcriptStatus;       // 0=none, 1=generating, 2=ready, 3=failed

  // ===== OFFLINE-FIRST SYNC FIELDS =====
  final String? serverId;           // Server-assigned ID after sync
  final SyncState syncState;        // localOnly, queued, uploading, synced, failed
  final String? localPath;          // Local file path (for media before upload)
  final int retryCount;             // Number of sync retry attempts
  final String? lastError;          // Last sync error message

  // ===== REPLY FIELDS =====
  final String? replyToMessageId;   // ID of message being replied to
  final String? replyToTextPreview; // Preview text (max 50 chars)
  final String? replyToSenderName;  // Sender name of replied message
  final MessageType? replyToType;   // Type of replied message

  // ===== LIKE FIELD =====
  final bool isLiked;               // Whether current user liked this message

  // ===== SCHEDULED MESSAGE FIELDS =====
  final String sendMode;            // instant, scheduled
  final DateTime? scheduledAtUtc;   // When to send (UTC)

  ChatMessage({
    required this.id,
    required this.roomId,
    required this.senderId,
    required this.senderName,
    required this.recipientId,
    required this.text,
    required this.timestamp,
    this.via = '',
    this.status = MessageStatus.pending,
    this.type = MessageType.text,
    this.ttl = 10,
    this.routePath = const [],
    this.needsForwarding = true,
    this.deliveredAt,
    this.readAt,
    // DTN fields
    this.messageSignature,
    this.sprayCounter = 5,
    this.originDeviceId,
    this.hopCount = 0,
    this.hopLimit = 10,
    this.deliveryAuthority = DeliveryAuthority.server,
    // Media fields
    this.audioUrl,
    this.fileName,
    this.mimeType,
    this.fileSize,
    this.thumbnailUrl,
    this.audioDurationSeconds,
    // Voice transcript fields
    this.transcriptText,
    this.transcriptLang,
    this.transcriptStatus = 0,
    // Offline-first sync fields
    this.serverId,
    this.syncState = SyncState.localOnly,
    this.localPath,
    this.retryCount = 0,
    this.lastError,
    // Reply fields
    this.replyToMessageId,
    this.replyToTextPreview,
    this.replyToSenderName,
    this.replyToType,
    // Like field
    this.isLiked = false,
    // Scheduled message fields
    this.sendMode = 'instant',
    this.scheduledAtUtc,
  });

  bool isForMe(String myUserId) {
    return recipientId == myUserId || roomId == 'broadcast';
  }

  bool hasPassedThrough(String deviceId) {
    return routePath.contains(deviceId);
  }

  bool isAlive() {
    return ttl > 0;
  }

  /// Convert to MeshEnvelope format for mesh transmission
  Map<String, dynamic> toMeshEnvelope() => {
    'v': 1,
    'id': id,
    'type': 'chat',
    'ts': timestamp.millisecondsSinceEpoch,
    'from': {
      'userId': senderId,
      'fingerprint': originDeviceId ?? '',
      'nickname': senderName,
    },
    'to': recipientId,
    'ttl': ttl,
    'hop': hopCount,
    'maxHop': hopLimit,
    'spray': sprayCounter,
    'route': routePath,
    'sig': messageSignature,
    'payload': {
      'text': text,
      'roomId': roomId,
      'type': type.index,
      'mediaUrl': audioUrl,       // ✅ Include file/image URL for media messages
      'fileName': fileName,       // ✅ Include original filename
      'mimeType': mimeType,       // ✅ Include MIME type
      'fileSize': fileSize,       // ✅ Include file size
      'thumbnailUrl': thumbnailUrl, // ✅ Include thumbnail URL
    },
  };

  /// Create ChatMessage from mesh envelope
  factory ChatMessage.fromMeshEnvelope(Map<String, dynamic> env) {
    // ✅ Safely cast nested maps (handle null and wrong types)
    final fromRaw = env['from'];
    final payloadRaw = env['payload'];
    
    final from = (fromRaw is Map) 
        ? Map<String, dynamic>.from(fromRaw) 
        : <String, dynamic>{};
    final payload = (payloadRaw is Map) 
        ? Map<String, dynamic>.from(payloadRaw) 
        : <String, dynamic>{};
    
    return ChatMessage(
      id: env['id'] as String? ?? '',
      roomId: payload['roomId'] as String? ?? '',
      senderId: from['userId'] as String? ?? '',
      senderName: from['nickname'] as String? ?? 'Unknown',
      recipientId: env['to'] as String? ?? '',
      text: payload['text'] as String? ?? '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(env['ts'] as int? ?? 0),
      via: 'mesh',
      status: MessageStatus.delivered,
      type: MessageType.values[(payload['type'] as int?) ?? 0],
      audioUrl: payload['mediaUrl'] as String?,      // ✅ Parse file/image URL
      fileName: payload['fileName'] as String?,      // ✅ Parse original filename
      mimeType: payload['mimeType'] as String?,      // ✅ Parse MIME type
      fileSize: payload['fileSize'] as int?,         // ✅ Parse file size
      thumbnailUrl: payload['thumbnailUrl'] as String?, // ✅ Parse thumbnail URL
      ttl: env['ttl'] as int? ?? 10,
      hopCount: env['hop'] as int? ?? 0,
      hopLimit: env['maxHop'] as int? ?? 10,
      sprayCounter: env['spray'] as int? ?? 5,
      routePath: (env['route'] as List?)?.whereType<String>().toList() ?? [],
      messageSignature: env['sig'] as String?,
      originDeviceId: from['fingerprint'] as String?,
      deliveryAuthority: DeliveryAuthority.mesh,
    );
  }

  ChatMessage copyWith({
    String? text,
    String? via,
    MessageStatus? status,
    int? ttl,
    List<String>? routePath,
    bool? needsForwarding,
    DateTime? deliveredAt,
    DateTime? readAt,
    String? messageSignature,
    int? sprayCounter,
    String? originDeviceId,
    int? hopCount,
    int? hopLimit,
    DeliveryAuthority? deliveryAuthority,
    String? audioUrl,
    String? fileName,
    String? mimeType,
    int? fileSize,
    String? thumbnailUrl,
    int? audioDurationSeconds,
    String? transcriptText,
    String? transcriptLang,
    int? transcriptStatus,
    // Sync fields
    String? serverId,
    SyncState? syncState,
    String? localPath,
    int? retryCount,
    String? lastError,
    // Reply fields
    String? replyToMessageId,
    String? replyToTextPreview,
    String? replyToSenderName,
    MessageType? replyToType,
    // Like field
    bool? isLiked,
    // Scheduled fields
    String? sendMode,
    DateTime? scheduledAtUtc,
  }) =>
      ChatMessage(
        id: id,
        roomId: roomId,
        senderId: senderId,
        senderName: senderName,
        recipientId: recipientId,
        text: text ?? this.text,
        timestamp: timestamp,
        via: via ?? this.via,
        status: status ?? this.status,
        type: type,
        ttl: ttl ?? this.ttl,
        routePath: routePath ?? this.routePath,
        needsForwarding: needsForwarding ?? this.needsForwarding,
        deliveredAt: deliveredAt ?? this.deliveredAt,
        readAt: readAt ?? this.readAt,
        messageSignature: messageSignature ?? this.messageSignature,
        sprayCounter: sprayCounter ?? this.sprayCounter,
        originDeviceId: originDeviceId ?? this.originDeviceId,
        hopCount: hopCount ?? this.hopCount,
        hopLimit: hopLimit ?? this.hopLimit,
        deliveryAuthority: deliveryAuthority ?? this.deliveryAuthority,
        audioUrl: audioUrl ?? this.audioUrl,
        fileName: fileName ?? this.fileName,
        mimeType: mimeType ?? this.mimeType,
        fileSize: fileSize ?? this.fileSize,
        thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
        audioDurationSeconds: audioDurationSeconds ?? this.audioDurationSeconds,
        transcriptText: transcriptText ?? this.transcriptText,
        transcriptLang: transcriptLang ?? this.transcriptLang,
        transcriptStatus: transcriptStatus ?? this.transcriptStatus,
        // Sync fields
        serverId: serverId ?? this.serverId,
        syncState: syncState ?? this.syncState,
        localPath: localPath ?? this.localPath,
        retryCount: retryCount ?? this.retryCount,
        lastError: lastError ?? this.lastError,
        // Reply fields
        replyToMessageId: replyToMessageId ?? this.replyToMessageId,
        replyToTextPreview: replyToTextPreview ?? this.replyToTextPreview,
        replyToSenderName: replyToSenderName ?? this.replyToSenderName,
        replyToType: replyToType ?? this.replyToType,
        // Like field
        isLiked: isLiked ?? this.isLiked,
        // Scheduled fields
        sendMode: sendMode ?? this.sendMode,
        scheduledAtUtc: scheduledAtUtc ?? this.scheduledAtUtc,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'roomId': roomId,
        'senderId': senderId,
        'senderName': senderName,
        'recipientId': recipientId,
        'text': text,
        'timestamp': timestamp.toIso8601String(),
        'via': via,
        'status': status.index,
        'type': type.index,
        'ttl': ttl,
        'routePath': jsonEncode(routePath),
        'needsForwarding': needsForwarding ? 1 : 0,
        'deliveredAt': deliveredAt?.toIso8601String(),
        'readAt': readAt?.toIso8601String(),
        // DTN fields
        'messageSignature': messageSignature,
        'sprayCounter': sprayCounter,
        'originDeviceId': originDeviceId,
        'hopCount': hopCount,
        'hopLimit': hopLimit,
        'deliveryAuthority': deliveryAuthority.index,
        // Media fields
        'audioUrl': audioUrl,
        'fileName': fileName,
        'mimeType': mimeType,
        'fileSize': fileSize,
        'thumbnailUrl': thumbnailUrl,
        'audioDurationSeconds': audioDurationSeconds,
        // Voice transcript fields
        'transcriptText': transcriptText,
        'transcriptLang': transcriptLang,
        'transcriptStatus': transcriptStatus,
        // Offline-first sync fields
        'serverId': serverId,
        'syncState': syncState.index,
        'localPath': localPath,
        'retryCount': retryCount,
        'lastError': lastError,
        // Reply fields
        'replyToMessageId': replyToMessageId,
        'replyToTextPreview': replyToTextPreview,
        'replyToSenderName': replyToSenderName,
        'replyToType': replyToType?.index,
        // Like field
        'isLiked': isLiked ? 1 : 0,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    // ✅ Helper to safely parse int from either int or String
    int? safeInt(dynamic val) {
      if (val == null) return null;
      if (val is int) return val;
      if (val is String) return int.tryParse(val);
      return null;
    }
    
    // ✅ Helper to safely get enum value with bounds check
    T safeEnum<T>(List<T> values, int? index, T defaultValue) {
      if (index == null || index < 0 || index >= values.length) {
        return defaultValue;
      }
      return values[index];
    }
    
    // ✅ Safe routePath parsing - filter non-strings to prevent cast errors
    List<String> parsePath = [];
    if (json['routePath'] != null) {
      try {
        if (json['routePath'] is String) {
          final decoded = jsonDecode(json['routePath'] as String);
          if (decoded is List) {
            parsePath = decoded.whereType<String>().toList();
          }
        } else if (json['routePath'] is List) {
          parsePath = (json['routePath'] as List).whereType<String>().toList();
        }
      } catch (e) {
        parsePath = [];  // Fallback on any parse error
      }
    }

    return ChatMessage(
      id: json['id'] as String,
      roomId: json['roomId'] as String,
      senderId: json['senderId'] as String,
      senderName: json['senderName'] as String,
      recipientId: json['recipientId'] as String,
      text: json['text'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      via: json['via'] as String? ?? '',
      // ✅ Use safeEnum to prevent RangeError on invalid index
      status: safeEnum(MessageStatus.values, safeInt(json['status']), MessageStatus.pending),
      type: safeEnum(MessageType.values, safeInt(json['type']), MessageType.text),
      ttl: safeInt(json['ttl']) ?? 10,
      routePath: parsePath,
      needsForwarding: (json['needsForwarding'] is int) 
          ? (json['needsForwarding'] as int) == 1
          : (json['needsForwarding'] as bool? ?? true),
      deliveredAt: json['deliveredAt'] != null
          ? DateTime.parse(json['deliveredAt'] as String)
          : null,
      readAt: json['readAt'] != null 
          ? DateTime.parse(json['readAt'] as String) 
          : null,
      // DTN fields
      messageSignature: json['messageSignature'] as String?,
      sprayCounter: safeInt(json['sprayCounter']) ?? 5,
      originDeviceId: json['originDeviceId'] as String?,
      hopCount: safeInt(json['hopCount']) ?? 0,
      hopLimit: safeInt(json['hopLimit']) ?? 10,
      deliveryAuthority: safeEnum(DeliveryAuthority.values, safeInt(json['deliveryAuthority']), DeliveryAuthority.server),
      // Media fields
      audioUrl: json['audioUrl'] as String?,
      fileName: json['fileName'] as String?,
      mimeType: json['mimeType'] as String?,
      fileSize: safeInt(json['fileSize']),
      thumbnailUrl: json['thumbnailUrl'] as String?,
      audioDurationSeconds: safeInt(json['audioDurationSeconds']),
      // Voice transcript fields
      transcriptText: json['transcriptText'] as String?,
      transcriptLang: json['transcriptLang'] as String?,
      transcriptStatus: safeInt(json['transcriptStatus']) ?? 0,
      // Offline-first sync fields
      serverId: json['serverId'] as String?,
      syncState: safeEnum(SyncState.values, safeInt(json['syncState']), SyncState.localOnly),
      localPath: json['localPath'] as String?,
      retryCount: safeInt(json['retryCount']) ?? 0,
      lastError: json['lastError'] as String?,
      // Reply fields
      replyToMessageId: json['replyToMessageId'] as String?,
      replyToTextPreview: json['replyToTextPreview'] as String?,
      replyToSenderName: json['replyToSenderName'] as String?,
      replyToType: json['replyToType'] != null 
          ? safeEnum(MessageType.values, safeInt(json['replyToType']), MessageType.text)
          : null,
      // Like field
      isLiked: (json['isLiked'] is int) 
          ? (json['isLiked'] as int) == 1 
          : (json['isLiked'] as bool? ?? false),
    );
  }
}

enum MessageStatus {
  pending,
  sending,
  sent,
  forwarding,
  delivered,
  read,
  failed,
  scheduled,  // ✅ NEW: Message waiting to be sent at scheduledAtUtc
}

enum MessageType {
  text,
  image,
  file,
  voice,
  location,
  snap,
}

/// Sync state for offline-first architecture
/// Tracks whether message is local only or synced to cloud
enum SyncState {
  /// Created locally, not yet sent anywhere
  localOnly,
  /// Queued for sync when internet available
  queued,
  /// Currently uploading to cloud
  uploading,
  /// Successfully synced to server
  synced,
  /// Sync failed, needs retry
  failed,
}

/// Delivery authority for hybrid routing
enum DeliveryAuthority {
  /// Sent via server API (when online)
  server,
  /// Sent via BLE mesh (when offline)
  mesh,
}
