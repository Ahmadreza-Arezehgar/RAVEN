import 'dart:async';
import 'dart:convert';  // ✅ For jsonEncode
import 'dart:developer';
import 'dart:io';  // ✅ For HttpClient reachability check
import 'package:connectivity_plus/connectivity_plus.dart';
import '../models/message_model.dart';
import '../mesh_bridge.dart';  // ✅ ADDED for MeshBridge
import 'message_dedup_service.dart';
import 'api_service.dart';
import 'ble_service.dart';
import 'database_helper.dart';
import 'dtn_router_service.dart';  // ✅ DTN Store-and-Forward routing

/// Mesh Router - Hybrid messaging with Internet-first, Mesh-fallback
/// 
/// Routing Policy:
/// - Online → Server API only (no BLE forwarding)
/// - Offline → BLE Mesh (hop-by-hop until internet or recipient)
class MeshRouter {
  static final MeshRouter _instance = MeshRouter._internal();
  static MeshRouter get instance => _instance;
  MeshRouter._internal();

  // Connectivity state
  bool _hasInternet = true;
  StreamSubscription<dynamic>? _connectivitySubscription;  // ✅ dynamic for API compatibility
  
  // Callbacks for network mode changes
  final List<void Function(bool isOnline)> _networkModeListeners = [];
  
  // Max neighbors to forward to (fanout limit)
  static const int maxFanout = 3;
  
  // Default hop limit
  static const int defaultHopLimit = 10;
  
  // Default TTL in minutes
  static const int defaultTtlMinutes = 15;

  /// Initialize the router and start listening for connectivity changes
  Future<void> init() async {
    // Check initial connectivity
    // ✅ FIX: Handle both API versions (single result or List)
    final dynamic result = await Connectivity().checkConnectivity();
    if (result is List) {
      _hasInternet = _isConnectedFromList(result.cast<ConnectivityResult>());
    } else {
      _hasInternet = _isConnectedSingle(result as ConnectivityResult);
    }
    
    // Listen for changes
    // ✅ FIX: Use dynamic to handle API differences across versions
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((dynamic result) async {
      final wasOnline = _hasInternet;
      
      // Handle both List and single result (API varies by version)
      if (result is List) {
        _hasInternet = _isConnectedFromList(result.cast<ConnectivityResult>());
      } else {
        _hasInternet = _isConnectedSingle(result as ConnectivityResult);
      }
      
      if (wasOnline != _hasInternet) {
        log('🌐 Network mode changed: ${_hasInternet ? "ONLINE" : "OFFLINE"}');
        _notifyNetworkModeChange(_hasInternet);
        
        // ✅ Restart mesh when going offline to switch to Bluetooth-only discovery
        // ✅ FIX: Fire-and-forget to prevent UI freeze (don't await)
        if (!_hasInternet) {
          log('🔄 [MeshRouter] Restarting mesh for Bluetooth discovery...');
          // ignore: unawaited_futures
          MeshBridge.restart().catchError((e) {
            log('⚠️ [MeshRouter] Mesh restart error (non-blocking): $e');
          });
        }
      }
    });
    
    log('✅ MeshRouter initialized (${_hasInternet ? "Online" : "Offline"})');
  }
  
  bool _isConnectedFromList(List<ConnectivityResult> results) {
    return results.any((r) => 
      r == ConnectivityResult.wifi || 
      r == ConnectivityResult.mobile ||
      r == ConnectivityResult.ethernet
    );
  }
  
  bool _isConnectedSingle(ConnectivityResult result) {
    return result == ConnectivityResult.wifi || 
           result == ConnectivityResult.mobile ||
           result == ConnectivityResult.ethernet;
  }
  
  /// Dispose the router
  void dispose() {
    _connectivitySubscription?.cancel();
    _networkModeListeners.clear();
  }
  
  /// Add listener for network mode changes
  void addNetworkModeListener(void Function(bool isOnline) listener) {
    _networkModeListeners.add(listener);
  }
  
  /// Remove listener
  void removeNetworkModeListener(void Function(bool isOnline) listener) {
    _networkModeListeners.remove(listener);
  }
  
  void _notifyNetworkModeChange(bool isOnline) {
    for (final listener in _networkModeListeners) {
      listener(isOnline);
    }
  }
  
  /// Check if currently online
  bool get isOnline => _hasInternet;
  
  /// Check if WiFi/Mobile is connected (online mode)
  bool get isWiFiMode => _hasInternet;
  
  /// Check if in Bluetooth mesh mode (offline)
  bool get isBluetoothMode => !_hasInternet;
  
  /// Route a message using the appropriate channel
  /// Returns true if successfully sent/queued
  Future<bool> routeMessage(ChatMessage message) async {
    // 1. Check for duplicate
    if (MessageDedupService.instance.isDuplicate(message.id)) {
      log('⏭️ Dropping duplicate message: ${message.id}');
      return false;
    }
    
    // 2. Mark as seen
    MessageDedupService.instance.markAsSeen(message.id);
    
    // 3. Real-time connectivity check with ACTUAL internet test
    // Note: Connectivity() only checks interface status, not actual reachability
    final dynamic result = await Connectivity().checkConnectivity();
    bool interfaceConnected;
    if (result is List) {
      interfaceConnected = _isConnectedFromList(result.cast<ConnectivityResult>());
    } else {
      interfaceConnected = _isConnectedSingle(result as ConnectivityResult);
    }
    
    // 4. If interface says connected, verify with actual network request
    bool hasRealInternet = false;
    if (interfaceConnected) {
      try {
        // Quick reachability test with 3 second timeout
        final testClient = HttpClient()..connectionTimeout = const Duration(seconds: 3);
        final request = await testClient.headUrl(Uri.parse('https://raven-server-5iwa2y5n3a-ww.a.run.app/health'));
        final response = await request.close().timeout(const Duration(seconds: 3));
        hasRealInternet = response.statusCode == 200;
        testClient.close();
        log('📡 [MeshRouter] Reachability test: ${hasRealInternet ? "✅ ONLINE" : "❌ UNREACHABLE"}');
      } catch (e) {
        log('📡 [MeshRouter] Reachability test FAILED: $e');
        hasRealInternet = false;
      }
    } else {
      log('📡 [MeshRouter] Interface disconnected, going to mesh directly');
    }
    
    log('📡 [MeshRouter.routeMessage] interfaceConnected=$interfaceConnected, hasRealInternet=$hasRealInternet');
    
    // 5. Route based on REAL connectivity, with fallback
    if (hasRealInternet) {
      // Try server first, fallback to mesh on exception
      try {
        final success = await _sendViaServer(message);
        if (success) return true;
        log('⚠️ [MeshRouter] Server returned false, falling back to mesh');
      } catch (e) {
        log('⚠️ [MeshRouter] Server exception: $e, falling back to mesh');
      }
    }
    
    // Fallback to mesh
    log('📡 [MeshRouter] Using MESH for delivery');
    return await _sendViaMesh(message);
  }
  
  /// Send message via server API (when online)
  Future<bool> _sendViaServer(ChatMessage message) async {
    log('📤 Routing via SERVER: ${message.id}');
    
    try {
      // Mark as sent via server
      final updatedMessage = message.copyWith(
        deliveryAuthority: DeliveryAuthority.server,
        status: MessageStatus.sending,
      );
      
      // Save locally first
      await DatabaseHelper.instance.insertMessage(updatedMessage);
      
      // Send to server
      final success = await ApiService.sendMessage(
        recipientId: message.recipientId,
        content: message.text,
        messageId: message.id,  // For idempotency
      );
      
      if (success) {
        // Update status to sent
        await DatabaseHelper.instance.updateMessageStatus(
          message.id, 
          MessageStatus.sent,
        );
        log('✅ Message sent via server: ${message.id}');
        return true;
      } else {
        // Queue for retry
        await DatabaseHelper.instance.updateMessageStatus(
          message.id, 
          MessageStatus.failed,
        );
        log('❌ Server send failed, queued for retry: ${message.id}');
        return false;
      }
    } catch (e) {
      log('❌ Server send error: $e');
      return false;
    }
  }
  
  /// Send message via BLE mesh (when offline)
  /// ✅ Now uses DTNRouterService for Spray-and-Wait Store-and-Forward
  Future<bool> _sendViaMesh(ChatMessage message) async {
    log('📡 [MeshRouter] Routing via DTN (offline mode)');
    
    try {
      // ✅ Use DTNRouterService for proper DTN routing with:
      // - Spray-and-Wait algorithm
      // - TTL and hop counting
      // - Multi-hop relay
      // - Store-and-forward
      await DTNRouterService.instance.sendMessage(message);
      
      // Update status to sent (DTN will handle actual delivery)
      await DatabaseHelper.instance.insertMessage(message.copyWith(
        status: MessageStatus.sent,
        via: 'mesh_dtn',
        deliveryAuthority: DeliveryAuthority.mesh,
      ));
      log('✅ [MeshRouter] Message queued in DTN router: ${message.id}');
      return true;
      
    } catch (e) {
      log('❌ [MeshRouter] DTN send error: $e');
      
      // Fallback: Save locally for later
      try {
        await DatabaseHelper.instance.insertMessage(message.copyWith(
          status: MessageStatus.pending,
        ));
        log('💾 [MeshRouter] Message saved locally for later sync');
      } catch (dbError) {
        log('❌ [MeshRouter] Failed to save message locally: $dbError');
      }
      
      return false;
    }
  }
  
  /// Handle incoming message from mesh
  /// Called when BLE receives a message
  Future<void> handleIncomingMeshMessage(ChatMessage message, String myUserId) async {
    // 1. Dedup check
    if (MessageDedupService.instance.checkAndMark(message.id)) {
      log('⏭️ Duplicate mesh message dropped: ${message.id}');
      return;
    }
    
    // 2. Check if I'm the recipient
    if (message.isForMe(myUserId)) {
      log('📩 Message is for me: ${message.id}');
      await _deliverToSelf(message);
      await _sendAck(message, AckType.deliveredToPeer);
      return;
    }
    
    // 3. Check if I have internet → upload to server
    if (_hasInternet) {
      log('🌐 I have internet, uploading to server: ${message.id}');
      final success = await _uploadToServer(message);
      if (success) {
        await _sendAck(message, AckType.uploadedToServer);
      }
      return;
    }
    
    // 4. Forward to other peers
    if (message.hopCount < message.hopLimit) {
      log('📡 Forwarding to other peers: ${message.id}');
      await _forwardToPeers(message);
    } else {
      log('⚠️ Hop limit reached, not forwarding: ${message.id}');
    }
  }
  
  Future<void> _deliverToSelf(ChatMessage message) async {
    final delivered = message.copyWith(
      status: MessageStatus.delivered,
      deliveredAt: DateTime.now(),
    );
    await DatabaseHelper.instance.insertMessage(delivered);
    log('✅ Message delivered locally: ${message.id}');
  }
  
  Future<bool> _uploadToServer(ChatMessage message) async {
    try {
      final success = await ApiService.sendMessage(
        recipientId: message.recipientId,
        content: message.text,
        messageId: message.id,  // For idempotency
      );
      if (success) {
        log('✅ Mesh message uploaded to server: ${message.id}');
        return true;
      }
    } catch (e) {
      log('❌ Failed to upload mesh message: $e');
    }
    return false;
  }
  
  /// Forward message to nearby peers (BLE mesh)
  /// ✅ IMPLEMENTED: Forwards via MeshBridge with proper DTN routing
  Future<void> _forwardToPeers(ChatMessage message) async {
    log('📡 [MeshRouter] Forwarding message ${message.id} to mesh peers');
    
    // Increment hop count and decrement spray counter
    final forwardedMessage = message.copyWith(
      hopCount: message.hopCount + 1,
      sprayCounter: message.sprayCounter > 1 ? message.sprayCounter - 1 : 1,
      status: MessageStatus.forwarding,
    );
    
    // Check spray limit (Spray-and-Wait optimization)
    if (forwardedMessage.sprayCounter <= 0) {
      log('📡 [MeshRouter] Spray counter exhausted, holding message');
      return;
    }
    
    // Build the envelope
    final envelope = jsonEncode({
      'type': 'chat',
      'msg': forwardedMessage.toJson(),
    });
    
    // Send via MeshBridge
    final success = await MeshBridge.send(envelope);
    
    if (success) {
      log('✅ [MeshRouter] Forwarded message via mesh (hop=${forwardedMessage.hopCount}, spray=${forwardedMessage.sprayCounter})');
    } else {
      log('⚠️ [MeshRouter] Forward failed - no peers available');
    }
  }
  
  /// Send ACK to mesh
  /// ✅ IMPLEMENTED: Sends ACK via MeshBridge for multi-hop confirmation
  Future<void> _sendAck(ChatMessage message, AckType ackType) async {
    log('📡 [MeshRouter] Sending ACK for ${message.id} (${ackType.name})');
    
    // Mark as finalized locally
    MessageDedupService.instance.markAsFinalized(message.id);
    
    // Build ACK message
    final ack = MessageAck(
      messageId: message.id,
      ackType: ackType,
      timestamp: DateTime.now(),
    );
    
    // Build envelope
    final envelope = jsonEncode({
      'type': 'ack',
      'ack': ack.toJson(),
    });
    
    // Send via MeshBridge
    final success = await MeshBridge.send(envelope);
    
    if (success) {
      log('✅ [MeshRouter] ACK sent via mesh');
    } else {
      log('⚠️ [MeshRouter] ACK send failed - will retry on next peer connect');
    }
  }
  
  /// Handle incoming ACK from mesh
  void handleAck(MessageAck ack) {
    log('✅ ACK received for: ${ack.messageId} (${ack.ackType})');
    MessageDedupService.instance.markAsFinalized(ack.messageId);
    
    // Update message status if we have it locally
    DatabaseHelper.instance.updateMessageStatus(
      ack.messageId,
      MessageStatus.delivered,
    );
  }
}

/// ACK types for mesh routing
enum AckType {
  deliveredToPeer,    // Recipient got it directly
  uploadedToServer,   // Internet node uploaded to server
  confirmed,          // Server confirmed delivery
}

/// Message acknowledgment
class MessageAck {
  final String messageId;
  final AckType ackType;
  final DateTime timestamp;
  
  MessageAck({
    required this.messageId,
    required this.ackType,
    required this.timestamp,
  });
  
  Map<String, dynamic> toJson() => {
    'type': 'ack',
    'messageId': messageId,
    'ackType': ackType.index,
    'timestamp': timestamp.toIso8601String(),
  };
  
  factory MessageAck.fromJson(Map<String, dynamic> json) => MessageAck(
    messageId: json['messageId'] as String,
    ackType: AckType.values[json['ackType'] as int],
    timestamp: DateTime.parse(json['timestamp'] as String),
  );
}
