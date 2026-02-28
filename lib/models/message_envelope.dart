import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../services/crypto_service.dart';

/// MessageEnvelope - Standardized message format with signature verification
/// 
/// Every message in the mesh network MUST be wrapped in this envelope
/// to ensure authenticity and prevent spoofing.
class MessageEnvelope {
  final String senderId;           // User UUID
  final String senderPublicKey;    // PEM-encoded RSA public key
  final String content;            // Message content (can be encrypted)
  final String signature;          // RSA signature of (senderId + content + timestamp)
  final DateTime timestamp;
  final int ttl;                   // Time-to-live for mesh routing
  final String type;               // Message type: 'chat', 'post', 'system', etc.
  
  MessageEnvelope({
    required this.senderId,
    required this.senderPublicKey,
    required this.content,
    required this.signature,
    required this.timestamp,
    this.ttl = 10,
    this.type = 'chat',
  });
  
  /// Create signed envelope from message content
  static Future<MessageEnvelope> create({
    required String senderId,
    required String content,
    required String type,
    int ttl = 10,
  }) async {
    final crypto = CryptoService.instance;
    
    // Get user's keys
    final publicKey = await crypto.getPublicKey();
    final privateKey = await crypto.getPrivateKey();
    
    if (publicKey == null || privateKey == null) {
      throw Exception('Keys not found - user must be registered');
    }
    
    final publicKeyPem = crypto.publicKeyToPem(publicKey);
    final timestamp = DateTime.now();
    
    // Create payload to sign: senderId + content + timestamp
    final payload = '$senderId|$content|${timestamp.toIso8601String()}';
    final signature = crypto.signMessage(payload, privateKey);
    
    return MessageEnvelope(
      senderId: senderId,
      senderPublicKey: publicKeyPem,
      content: content,
      signature: signature,
      timestamp: timestamp,
      ttl: ttl,
      type: type,
    );
  }
  
  /// Verify this message is authentic
  bool verify() {
    try {
      final crypto = CryptoService.instance;
      
      // Parse sender's public key
      final publicKey = crypto.pemToPublicKey(senderPublicKey);
      
      // Reconstruct payload
      final payload = '$senderId|$content|${timestamp.toIso8601String()}';
      
      // Verify signature
      return crypto.verifySignature(payload, signature, publicKey);
    } catch (e) {
      print('❌ Signature verification failed: $e');
      return false;
    }
  }
  
  /// Get displayName (public key fingerprint) for this sender
  String get displayName {
    // Generate fingerprint from public key
    final hash = sha256.convert(utf8.encode(senderPublicKey));
    return hash.toString().substring(0, 16);
  }
  
  /// Convert to JSON for transmission
  Map<String, dynamic> toJson() => {
    'senderId': senderId,
    'senderPublicKey': senderPublicKey,
    'content': content,
    'signature': signature,
    'timestamp': timestamp.toIso8601String(),
    'ttl': ttl,
    'type': type,
  };
  
  /// Parse from JSON
  factory MessageEnvelope.fromJson(Map<String, dynamic> json) {
    return MessageEnvelope(
      senderId: json['senderId'] as String,
      senderPublicKey: json['senderPublicKey'] as String,
      content: json['content'] as String,
      signature: json['signature'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      ttl: json['ttl'] as int? ?? 10,
      type: json['type'] as String? ?? 'chat',
    );
  }
  
  /// Convert to JSON string for mesh transmission
  String toJsonString() => jsonEncode(toJson());
  
  /// Parse from JSON string
  static MessageEnvelope fromJsonString(String jsonString) {
    final json = jsonDecode(jsonString) as Map<String, dynamic>;
    return MessageEnvelope.fromJson(json);
  }
}
