/// Network connectivity modes for DTN routing
enum NetworkMode {
  /// Full internet + server connectivity
  online,
  
  /// Internet available but server unreachable
  degraded,
  
  /// No internet - mesh only
  offline,
}

/// Message acknowledgment status
enum AckStatus {
  /// Message received by device
  received,
  
  /// Message stored in inbox
  delivered,
  
  /// User opened/read the message
  seen,
}

/// Message acknowledgment for DTN protocol
class MessageAck {
  final String ackId;
  final String ackForMessageId;
  final String from;
  final String to;
  final AckStatus status;
  final DateTime timestamp;
  final int ttl;

  const MessageAck({
    required this.ackId,
    required this.ackForMessageId,
    required this.from,
    required this.to,
    required this.status,
    required this.timestamp,
    this.ttl = 6,
  });

  Map<String, dynamic> toJson() => {
    'type': 'ACK',
    'ackId': ackId,
    'ackForMessageId': ackForMessageId,
    'from': from,
    'to': to,
    'status': status.name.toUpperCase(),
    'timestamp': timestamp.toIso8601String(),
    'ttl': ttl,
  };

  factory MessageAck.fromJson(Map<String, dynamic> json) {
    return MessageAck(
      ackId: json['ackId'] as String,
      ackForMessageId: json['ackForMessageId'] as String,
      from: json['from'] as String,
      to: json['to'] as String,
      status: AckStatus.values.firstWhere(
        (s) => s.name.toUpperCase() == json['status'],
        orElse: () => AckStatus.received,
      ),
      timestamp: DateTime.parse(json['timestamp'] as String),
      ttl: json['ttl'] as int? ?? 6,
    );
  }
}
