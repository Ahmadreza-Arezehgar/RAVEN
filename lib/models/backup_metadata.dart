import 'dart:convert';

/// Metadata stored in backup files
class BackupMetadata {
  final String backupId;
  final DateTime timestamp;
  final int messageCount;
  final String appVersion;
  final String userId;

  BackupMetadata({
    required this.backupId,
    required this.timestamp,
    required this.messageCount,
    required this.appVersion,
    required this.userId,
  });

  Map<String, dynamic> toJson() => {
        'backupId': backupId,
        'timestamp': timestamp.toIso8601String(),
        'messageCount': messageCount,
        'appVersion': appVersion,
        'userId': userId,
      };

  factory BackupMetadata.fromJson(Map<String, dynamic> json) {
    return BackupMetadata(
      backupId: json['backupId'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      messageCount: json['messageCount'] as int,
      appVersion: json['appVersion'] as String,
      userId: json['userId'] as String,
    );
  }
}

/// Complete backup data structure
class BackupData {
  final BackupMetadata metadata;
  final List<Map<String, dynamic>> messages;

  BackupData({
    required this.metadata,
    required this.messages,
  });

  String toJsonString() {
    return jsonEncode({
      'metadata': metadata.toJson(),
      'messages': messages,
    });
  }

  factory BackupData.fromJsonString(String jsonString) {
    final data = jsonDecode(jsonString) as Map<String, dynamic>;
    return BackupData(
      metadata: BackupMetadata.fromJson(data['metadata'] as Map<String, dynamic>),
      messages: (data['messages'] as List).cast<Map<String, dynamic>>(),
    );
  }
}
