/// Relationship status for two-step friend system
enum RelationshipStatus {
  stranger,           // 0 - No relationship
  pending,            // 1 - Request sent, waiting for response
  following,          // 2 - A accepted, B is follower (one-way)
  followbackPending,  // 3 - A wants mutual, waiting for B
  friends,            // 4 - Both accepted, mutual friends
  declined,           // 5 - Request declined
  blocked,            // 6 - Blocked
}

extension RelationshipStatusExt on RelationshipStatus {
  int get value => index;
  
  static RelationshipStatus fromValue(int value) {
    if (value < 0 || value >= RelationshipStatus.values.length) {
      return RelationshipStatus.stranger;
    }
    return RelationshipStatus.values[value];
  }
  
  bool get isFriend => this == RelationshipStatus.friends;
  bool get canChat => this == RelationshipStatus.friends;
}

class Contact {
  final String id;
  final String userId;
  final String username;
  final String? nickname;
  final String? avatarUrl;
  final DateTime addedAt;
  
  String get displayName => nickname ?? username;
  final int status; // Legacy: 0=Stranger, 1=Friend, 2=RequestReceived, 3=RequestSent
  final RelationshipStatus relationshipStatus; // New: two-step friend state
  final bool pinned;
  final bool blocked;
  final int unreadCount;
  final DateTime? lastMessageTime;
  final String? lastMessagePreview;
  
  // ✅ Group chat support
  final bool isGroup;
  final String? roomId;  // For groups: group_<uuid>

  Contact({
    required this.id,
    required this.userId,
    required this.username,
    this.nickname,
    this.avatarUrl,
    required this.addedAt,
    this.status = 0,
    this.relationshipStatus = RelationshipStatus.stranger,
    this.pinned = false,
    this.blocked = false,
    this.unreadCount = 0,
    this.lastMessageTime,
    this.lastMessagePreview,
    this.isGroup = false,
    this.roomId,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'userId': userId,
        'username': username,
        'nickname': nickname,
        'avatarUrl': avatarUrl,
        'addedAt': addedAt.toIso8601String(),
        'status': status,
        'relationshipStatus': relationshipStatus.index,
        'pinned': pinned ? 1 : 0,
        'blocked': blocked ? 1 : 0,
        'unreadCount': unreadCount,
        'lastMessageTime': lastMessageTime?.toIso8601String(),
        'lastMessagePreview': lastMessagePreview,
        'isGroup': isGroup ? 1 : 0,
        'roomId': roomId,
      };

  factory Contact.fromJson(Map<String, dynamic> json) => Contact(
        id: json['id'] as String,
        userId: json['userId'] as String,
        username: json['username'] as String,
        nickname: json['nickname'] as String?,
        avatarUrl: json['avatarUrl'] as String?,
        addedAt: DateTime.parse(json['addedAt'] as String),
        status: json['status'] as int? ?? 0,
        relationshipStatus: RelationshipStatusExt.fromValue(
          json['relationshipStatus'] as int? ?? 0,
        ),
        pinned: (json['pinned'] as int? ?? 0) == 1,
        blocked: (json['blocked'] as int? ?? 0) == 1,
        unreadCount: json['unreadCount'] as int? ?? 0,
        lastMessageTime: json['lastMessageTime'] != null
            ? DateTime.parse(json['lastMessageTime'] as String)
            : null,
        lastMessagePreview: json['lastMessagePreview'] as String?,
        isGroup: (json['isGroup'] as int? ?? 0) == 1,
        roomId: json['roomId'] as String?,
      );

  Contact copyWith({
    String? username,
    String? nickname,
    String? avatarUrl,
    int? status,
    RelationshipStatus? relationshipStatus,
    bool? pinned,
    bool? blocked,
    int? unreadCount,
    DateTime? lastMessageTime,
    String? lastMessagePreview,
    bool? isGroup,
    String? roomId,
  }) =>
      Contact(
        id: id,
        userId: userId,
        username: username ?? this.username,
        nickname: nickname ?? this.nickname,
        avatarUrl: avatarUrl ?? this.avatarUrl,
        addedAt: addedAt,
        status: status ?? this.status,
        relationshipStatus: relationshipStatus ?? this.relationshipStatus,
        pinned: pinned ?? this.pinned,
        blocked: blocked ?? this.blocked,
        unreadCount: unreadCount ?? this.unreadCount,
        lastMessageTime: lastMessageTime ?? this.lastMessageTime,
        lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
        isGroup: isGroup ?? this.isGroup,
        roomId: roomId ?? this.roomId,
      );
}
