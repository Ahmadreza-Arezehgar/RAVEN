import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:collection';  // ✅ For LinkedHashMap
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:uuid/uuid.dart';
import '../models/message_model.dart';
import '../models/dtn_types.dart';
import 'database_helper.dart';
import 'api_service.dart';
import 'media_chunking_service.dart';
import 'mesh_router.dart' hide MessageAck, AckType;  // ✅ Hide conflicting types

/// DTN-enabled Message Router with Store-and-Forward
/// Implements mesh relay with bridge-to-server capability
class MessageRouter {
  static final MessageRouter instance = MessageRouter._init();
  MessageRouter._init();

  final _db = DatabaseHelper.instance;
  final _chunking = MediaChunkingService();
  final _forwardQueue = <ChatMessage>[];
  Timer? _forwardTimer;
  
  /// Seen message IDs for deduplication (LinkedHashMap for insertion-order LRU)
  final LinkedHashMap<String, DateTime> _seenMessageIds = LinkedHashMap();
  
  /// Seen ACK IDs for deduplication
  final LinkedHashMap<String, DateTime> _seenAckIds = LinkedHashMap();
  
  /// Current network mode
  NetworkMode networkMode = NetworkMode.online;
  
  String? _myUserId;
  Function(ChatMessage)? onMessageReceived;
  Function(String payload)? onSendToMesh;
  Function(ChatMessage)? onSendToInternet;
  Function(MessageAck)? onAckReceived;
  Function(String mediaId, String localPath)? onMediaReceived;

  void initialize(String myUserId) {
    _myUserId = myUserId;
    _startForwardingService();
  }

  void _startForwardingService() {
    _forwardTimer?.cancel();
    _forwardTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _processForwardQueue();
    });
  }

  Future<void> handleIncomingMessage(String payload) async {
    try {
      final json = jsonDecode(payload) as Map<String, dynamic>;
      
      // Handle ACK messages
      if (json['type'] == 'ACK' || json['type'] == 'ack') {
        await _handleAck(json);
        return;
      }
      
      // ✅ Handle media chunks (voice/image files)
      if (json['type'] == 'media_chunk') {
        await _handleMediaChunk(json);
        return;
      }
      
      if (json['type'] != 'chat') return;

      // ✅ Detect format and use appropriate parser
      ChatMessage message;
      
      if (json['msg'] != null) {
        // Legacy format: { "type": "chat", "msg": { ...ChatMessage fields... } }
        final msgJson = (json['msg'] as Map).cast<String, dynamic>();
        message = ChatMessage.fromJson(msgJson);
      } else if (json['v'] != null && json['from'] != null) {
        // MeshEnvelope format: { "v": 1, "type": "chat", "from": {...}, "to": ..., "payload": {...} }
        print('📦 [Router] Detected MeshEnvelope format');
        message = ChatMessage.fromMeshEnvelope(json);
      } else if (json['senderId'] != null) {
        // Direct ChatMessage JSON format
        message = ChatMessage.fromJson(json);
      } else {
        print('❌ [Router] Unknown message format: ${json.keys.toList()}');
        return;
      }

      print('📩 [Router] Received message: ${message.id}');

      // ✅ DEDUPLICATION: Check if already seen (using LinkedHashMap for LRU)
      if (_seenMessageIds.containsKey(message.id)) {
        print('⚠️ [Router] Duplicate message ${message.id}, ignoring');
        return;
      }
      _seenMessageIds[message.id] = DateTime.now();
      
      // Cleanup old seen IDs (keep last 1000, LRU order preserved)
      while (_seenMessageIds.length > 1000) {
        _seenMessageIds.remove(_seenMessageIds.keys.first);
      }

      if (message.hasPassedThrough(_myUserId!)) {
        print('⚠️ [Router] Message already passed through this device, ignoring');
        return;
      }

      if (!message.isAlive()) {
        print('⚠️ [Router] Message TTL expired, discarding');
        return;
      }

      // Update route path and TTL
      message = message.copyWith(
        routePath: [...message.routePath, _myUserId!],
        ttl: message.ttl - 1,
        hopCount: message.hopCount + 1,
      );

      if (message.isForMe(_myUserId!)) {
        print('✅ [Router] Message is for me, storing');
        
        final plainMessage = message.copyWith(
          status: MessageStatus.delivered,
          via: 'mesh',
          deliveredAt: DateTime.now(),
        );
        
        await _db.insertMessage(plainMessage);
        
        // ✅ Update conversation list with incoming message
        await _db.touchConversation(
          otherUserId: message.senderId,
          otherUsername: message.senderName,
          preview: message.text,
          time: message.timestamp,
          incoming: true,
        );
        
        onMessageReceived?.call(plainMessage);
        
        // Send RECEIVED ACK
        _sendAck(message.id, message.senderId, AckStatus.received);
      } else {
        print('🔄 [Router] Message needs forwarding');
        await _forwardMessage(message);
      }
    } catch (e) {
      print('❌ [Router] Error handling message: $e');
    }
  }
  
  /// Handle incoming ACK
  Future<void> _handleAck(Map<String, dynamic> json) async {
    try {
      final ackId = json['ackId'] ?? json['messageId'] as String?;
      if (ackId == null) return;
      
      // Dedup ACKs (using LinkedHashMap for LRU)
      if (_seenAckIds.containsKey(ackId)) {
        print('⚠️ [Router] Duplicate ACK, ignoring');
        return;
      }
      _seenAckIds[ackId] = DateTime.now();
      
      final ack = MessageAck(
        ackId: ackId,
        ackForMessageId: json['ackForMessageId'] ?? json['messageId'] as String,
        from: json['from'] ?? json['receiverId'] as String,
        to: json['to'] ?? _myUserId!,
        status: _parseAckStatus(json['status'] as String?),
        timestamp: DateTime.now(),
      );
      
      print('✅ [Router] Received ACK: ${ack.status.name} for ${ack.ackForMessageId}');
      onAckReceived?.call(ack);
      
      // Update message status in DB
      await _db.updateMessageStatus(
        ack.ackForMessageId,
        ack.status == AckStatus.seen ? MessageStatus.read : MessageStatus.delivered,
      );
    } catch (e) {
      print('❌ [Router] Error handling ACK: $e');
    }
  }
  
  AckStatus _parseAckStatus(String? status) {
    switch (status?.toUpperCase()) {
      case 'SEEN': return AckStatus.seen;
      case 'DELIVERED': return AckStatus.delivered;
      default: return AckStatus.received;
    }
  }

  /// Handle incoming media chunk from mesh
  Future<void> _handleMediaChunk(Map<String, dynamic> json) async {
    try {
      final chunk = MediaChunk.fromJson(json);
      print('📦 [Router] Media chunk received: ${chunk.mediaId} (${chunk.chunkIndex + 1}/${chunk.totalChunks})');
      
      // Process chunk - returns file path if complete
      final completedPath = await _chunking.receiveChunk(chunk);
      
      if (completedPath != null) {
        print('✅ [Router] Media file complete: $completedPath');
        onMediaReceived?.call(chunk.mediaId, completedPath);
      }
    } catch (e) {
      print('❌ [Router] Error handling media chunk: $e');
    }
  }
  
  /// Send media file via mesh using chunking
  /// Returns true if all chunks were sent
  Future<bool> sendMediaViaChunks(File file, String mediaId) async {
    try {
      print('📤 [Router] Sending media via chunks: $mediaId');
      
      // Split file into chunks
      final chunks = await _chunking.splitFile(file, mediaId);
      
      // Send each chunk
      for (final chunk in chunks) {
        final envelope = jsonEncode(chunk.toJson());
        onSendToMesh?.call(envelope);
        
        // Small delay between chunks to avoid flooding
        await Future.delayed(const Duration(milliseconds: 50));
      }
      
      print('✅ [Router] All ${chunks.length} chunks sent for $mediaId');
      return true;
    } catch (e) {
      print('❌ [Router] Error sending media chunks: $e');
      return false;
    }
  }

  Future<void> _forwardMessage(ChatMessage message) async {
    _forwardQueue.add(message);
    
    await _db.insertMessage(message.copyWith(
      status: MessageStatus.forwarding,
      via: 'forwarding',
    ));

    await _attemptForward(message);
  }

  Future<void> _attemptForward(ChatMessage message) async {
    try {
      // Check connectivity
      final connectivityResult = await Connectivity().checkConnectivity();
      final hasInternet = connectivityResult == ConnectivityResult.mobile || 
                          connectivityResult == ConnectivityResult.wifi;
                          
      if (hasInternet && message.recipientId != 'broadcast') {
        print('🌐 [Router] Internet available, attempting BRIDGE to server for ${message.id}');
        
        // ✅ BRIDGE-TO-SERVER: Upload message via API
        try {
          final success = await ApiService.sendMessage(
            recipientId: message.recipientId,
            content: message.text,
            messageId: message.id,  // For idempotency - prevents duplicates
          );
          
          if (success) {
            print('✅ [Router] BRIDGE successful - message uploaded to server');
            _forwardQueue.remove(message);
            
            // Update local status
            await _db.updateMessage(message.copyWith(
              status: MessageStatus.delivered,
              via: 'bridge',
            ));
            return;
          }
        } catch (e) {
          print('⚠️ [Router] Bridge failed: $e, falling back to mesh');
        }
      }
      
      // Fallback or default to Mesh
      final envelope = jsonEncode({
        'type': 'chat',
        'msg': message.toJson(),
      });

      print('📤 [Router] Forwarding via Mesh ${message.id}');
      onSendToMesh?.call(envelope);

      await _db.updateMessage(message.copyWith(
        status: MessageStatus.sent,
      ));
      
      _forwardQueue.remove(message);
    } catch (e) {
      print('❌ [Router] Forward failed: $e');
    }
  }

  Future<void> _processForwardQueue() async {
    if (_forwardQueue.isEmpty) return;

    print('🔄 [Router] Processing forward queue (${_forwardQueue.length} messages)');

    final messagesToForward = List<ChatMessage>.from(_forwardQueue);
    for (final message in messagesToForward) {
      await _attemptForward(message);
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  void _sendAck(String messageId, String recipientId, AckStatus status) {
    final ack = MessageAck(
      ackId: const Uuid().v4(),
      ackForMessageId: messageId,
      from: _myUserId!,
      to: recipientId,
      status: status,
      timestamp: DateTime.now(),
    );

    onSendToMesh?.call(jsonEncode(ack.toJson()));
    print('📤 [Router] Sent ${status.name} ACK for $messageId');
  }
  
  /// Send SEEN ACK when user reads a message
  void markMessageAsSeen(String messageId, String senderId) {
    _sendAck(messageId, senderId, AckStatus.seen);
  }

  /// Send a message - delegates to MeshRouter for single source of truth
  /// 
  /// ✅ CONSOLIDATED: MeshRouter is now the single routing authority.
  /// This method exists for backward compatibility with existing UI code.
  Future<void> sendMessage(ChatMessage message) async {
    print('📤 [MessageRouter.sendMessage] Delegating to MeshRouter...');
    
    // ✅ DELEGATE TO MESHROUTER (single source of truth)
    // MeshRouter handles: Internet-first, BLE fallback, dedup, ACK
    final success = await MeshRouter.instance.routeMessage(message);
    
    if (success) {
      print('✅ [MessageRouter.sendMessage] MeshRouter routing successful');
    } else {
      print('⚠️ [MessageRouter.sendMessage] MeshRouter routing failed, using legacy fallback');
      
      // Legacy fallback: use mesh callback directly
      try {
        final envelope = jsonEncode({
          'type': 'chat',
          'msg': message.toJson(),
        });
        
        if (onSendToMesh != null) {
          onSendToMesh?.call(envelope);
          await _db.updateMessage(message.copyWith(
            status: MessageStatus.sent,
            via: 'mesh',
          ));
        }
      } catch (e) {
        print('❌ [MessageRouter.sendMessage] Legacy fallback also failed: $e');
        _forwardQueue.add(message);
      }
    }
  }

  Future<void> syncWithInternet() async {
    print('🌐 [Router] Syncing pending messages with internet');

    final pendingMessages = await _db.getPendingMessages();
    
    for (final message in pendingMessages) {
      try {
        onSendToInternet?.call(message);
        
        await _db.updateMessage(message.copyWith(
          status: MessageStatus.delivered,
          via: 'internet',
        ));
        
        print('✅ [Router] Synced message ${message.id} via internet');
      } catch (e) {
        print('❌ [Router] Internet sync failed for ${message.id}: $e');
      }
    }
  }

  void dispose() {
    _forwardTimer?.cancel();
  }
}
