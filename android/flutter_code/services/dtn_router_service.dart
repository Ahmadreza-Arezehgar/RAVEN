import 'dart:async';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../models/message_model.dart';
import '../mesh_bridge.dart';
import 'database_helper.dart';
import 'crypto_service.dart';
import 'api_service.dart';
import 'dtn_analytics_service.dart';
import 'dtn_config_service.dart';

/// DTN Router Service
/// Implements Delay-Tolerant Networking with Spray-and-Wait routing
/// 
/// Priority:
/// 1. WiFi/Server (if available)
/// 2. Bluetooth Mesh (if peers available)
/// 3. Store-and-Forward (for later delivery)
class DTNRouterService {
  static final DTNRouterService instance = DTNRouterService._init();
  DTNRouterService._init();

  final _db = DatabaseHelper.instance;
  final _crypto = CryptoService.instance;
  final _connectivity = Connectivity();
  final _analytics = DTNAnalyticsService.instance;
  
  String? _myUserId;
  String? _myDeviceId;
  String? _sharedSecret;  // For HMAC authentication
  
  // Store messages for relay
  final _relayQueue = <ChatMessage>[];
  final _seenMessages = <String>{};  // Message IDs we've already processed
  
  // Callbacks for network operations
  Function(ChatMessage)? onMessageDelivered;
  Function(ChatMessage)? onBluetoothBroadcast;
  Function(String msgId)? onServerUpload;
  
  Timer? _cleanupTimer;
  StreamSubscription<String>? _meshSubscription;
  bool _isConnectedToMesh = false;

  /// Initialize the DTN router
  void initialize({
    required String userId,
    required String deviceId,
    required String sharedSecret,
  }) {
    _myUserId = userId;
    _myDeviceId = deviceId;
    _sharedSecret = sharedSecret;
    
    _startCleanupService();
    _analytics.initialize();
    print('✅ [DTNRouter] Initialized for user: $userId, device: $deviceId');
  }

  /// Connect DTN callbacks to actual MeshBridge
  void connectToMesh() {
    if (_isConnectedToMesh) {
      print('⚠️ [DTNRouter] Already connected to mesh');
      return;
    }
    
    // Wire outbound: DTN → Mesh
    onBluetoothBroadcast = (msg) async {
      final envelope = msg.toMeshEnvelope();
      final success = await MeshBridge.send(jsonEncode(envelope));
      if (success) {
        print('📤 [DTNRouter] Sent via mesh: ${msg.id}');
      } else {
        print('⚠️ [DTNRouter] Mesh send failed for: ${msg.id}');
      }
    };
    
    // Wire inbound: Mesh → DTN
    _meshSubscription?.cancel();
    _meshSubscription = MeshBridge.messages().listen((data) {
      try {
        final json = jsonDecode(data) as Map<String, dynamic>;
        if (json['type'] == 'chat') {
          print('📩 [DTNRouter] Received chat from mesh');
          final msg = ChatMessage.fromMeshEnvelope(json);
          handleIncomingMessage(msg);
        }
      } catch (e) {
        // Log parse error for debugging
        print('⚠️ [DTNRouter] Mesh message parse error: $e');
      }
    });
    
    _isConnectedToMesh = true;
    print('✅ [DTNRouter] Connected to MeshBridge');
  }

  /// Handle incoming message from mesh network
  Future<void> handleIncomingMessage(ChatMessage msg) async {
    print('📩 [DTNRouter] Received message: ${msg.id}');
    
    // 1. Check if we've already seen this message (prevent loops)
    if (_seenMessages.contains(msg.id)) {
      print('⚠️ [DTNRouter] Already seen message ${msg.id}, ignoring');
      return;
    }
    _seenMessages.add(msg.id);
    
    // 2. Verify HMAC signature
    if (!_verifyMessageSignature(msg)) {
      print('❌ [DTNRouter] Invalid signature for message ${msg.id}');
      return;
    }
    
    // 3. Check TTL
    if (!msg.isAlive()) {
      print('⚠️ [DTNRouter] Message ${msg.id} TTL expired (ttl: ${msg.ttl})');
      return;
    }
    
    // 4. Check if message is for me
    if (msg.isForMe(_myUserId!)) {
      print('✅ [DTNRouter] Message is for me, delivering');
      await _deliverToUser(msg);
      return;
    }
    
    // 5. Check if we're already in the route path (loop prevention)
    if (msg.hasPassedThrough(_myDeviceId!)) {
      print('⚠️ [DTNRouter] Already in route path, not relaying');
      return;
    }
    
    // 6. Relay the message
    print('🔄 [DTNRouter] Relaying message ${msg.id}');
    await _relayMessage(msg);
  }

  /// Verify HMAC signature on incoming message
  bool _verifyMessageSignature(ChatMessage msg) {
    if (msg.messageSignature == null || _sharedSecret == null) {
      print('⚠️ [DTNRouter] No signature or shared secret, skipping verification');
      return true;  // Allow unsigned messages for now (backwards compatibility)
    }
    
    return _crypto.verifyMessageHMAC(msg, msg.messageSignature!, _sharedSecret!);
  }

  /// Deliver message to local user
  Future<void> _deliverToUser(ChatMessage msg) async {
    // Decrypt if needed, store, and notify
    final deliveredMsg = msg.copyWith(
      status: MessageStatus.delivered,
      via: 'mesh',
    );
    
    await _db.insertMessage(deliveredMsg);
    onMessageDelivered?.call(deliveredMsg);
    
    // Track analytics
    _analytics.trackMessageDelivered(deliveredMsg);
    
    print('✅ [DTNRouter] Message delivered to user');
  }

  /// Relay message using Spray-and-Wait algorithm
  Future<void> _relayMessage(ChatMessage msg) async {
    // Update message: decrement TTL, add to route path, increment hop count
    final config = DTNConfigService.instance.config;
    final relayedMsg = msg.copyWith(
      ttl: msg.ttl - 1,
      routePath: [...msg.routePath, _myDeviceId!],
      hopCount: msg.hopCount + 1,
    );
    
    // Track relay
    _analytics.trackRelay(msg.id, relayedMsg.hopCount);
    
    // Check if we're in spray phase or wait phase
    if (relayedMsg.sprayCounter > 0) {
      await _sprayPhase(relayedMsg);
    } else {
      await _waitPhase(relayedMsg);
    }
  }

  /// Spray phase: actively forward message to multiple peers
  Future<void> _sprayPhase(ChatMessage msg) async {
    print('💨 [DTNRouter] Spray phase for ${msg.id} (counter: ${msg.sprayCounter})');
    
    final config = DTNConfigService.instance.config;
    
    // Priority 1: Try server/WiFi (unless preferBluetoothOverServer)
    final hasInternet = await _hasInternet();
    if (hasInternet && !config.preferBluetoothOverServer) {
      print('🌐 [DTNRouter] Internet available, uploading to server');
      await _uploadToServer(msg);
      return;
    }
    
    // Priority 2: Bluetooth mesh (especially in event/camp mode)
    if (config.preferBluetoothOverServer || !hasInternet) {
      print('📶 [DTNRouter] Using Bluetooth mesh (priority mode)');
    }
    
    // Decrement spray counter
    final msgCopy = msg.copyWith(
      sprayCounter: msg.sprayCounter - 1,
    );
    
    // Store for relay
    await _storeForRelay(msgCopy);
    
    // Broadcast to Bluetooth peers
    _analytics.trackBluetoothBroadcast(msgCopy.id);
    onBluetoothBroadcast?.call(msgCopy);
  }

  /// Wait phase: only forward to direct contact
  Future<void> _waitPhase(ChatMessage msg) async {
    print('⏳ [DTNRouter] Wait phase for ${msg.id}, storing for direct delivery');
    
    // Just store the message, wait for direct contact with recipient
    await _storeForRelay(msg);
  }

  /// Store message in relay queue
  Future<void> _storeForRelay(ChatMessage msg) async {
    _relayQueue.add(msg);
    
    // Also persist to database
    await _db.insertMessage(msg.copyWith(
      status: MessageStatus.forwarding,
      via: 'relay_queue',
    ));
    
    print('💾 [DTNRouter] Message stored in relay queue');
  }

  /// Upload message to server
  Future<void> _uploadToServer(ChatMessage msg) async {
    try {
      // Use existing ApiService to send message
      final success = await ApiService.sendMessage(
        recipientId: msg.recipientId,
        content: msg.text,
        messageId: msg.id,  // For idempotency
      );
      
      if (success) {
        print('✅ [DTNRouter] Message uploaded to server');
        onServerUpload?.call(msg.id);
        _relayQueue.remove(msg);
      } else {
        print('⚠️ [DTNRouter] Server upload failed');
      }
    } catch (e) {
      print('❌ [DTNRouter] Server upload error: $e');
    }
  }

  /// Check if internet is available
  Future<bool> _hasInternet() async {
    try {
      final result = await _connectivity.checkConnectivity();
      return result == ConnectivityResult.wifi || 
             result == ConnectivityResult.mobile;
    } catch (e) {
      return false;
    }
  }

  /// Process relay queue periodically
  Future<void> processRelayQueue() async {
    if (_relayQueue.isEmpty) return;
    
    print('🔄 [DTNRouter] Processing relay queue (${_relayQueue.length} messages)');
    
    final hasInternet = await _hasInternet();
    
    for (final msg in List<ChatMessage>.from(_relayQueue)) {
      if (hasInternet) {
        await _uploadToServer(msg);
      } else {
        // Try Bluetooth broadcast
        onBluetoothBroadcast?.call(msg);
      }
      
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }
  
  /// Get relay queue size for UI
  int get relayQueueSize => _relayQueue.length;
  
  /// Get pending messages for Outbox UI
  List<ChatMessage> getPendingMessages() {
    return List<ChatMessage>.from(_relayQueue);
  }

  /// Start cleanup service to remove old messages
  void _startCleanupService() {
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(const Duration(hours: 1), (_) {
      _cleanupOldMessages();
    });
  }

  /// Clean up old messages from relay queue and seen set
  void _cleanupOldMessages() {
    final now = DateTime.now();
    
    // Remove messages older than 24 hours
    _relayQueue.removeWhere((msg) {
      final age = now.difference(msg.timestamp);
      return age.inHours > 24;
    });
    
    // Clear seen messages occasionally to prevent memory growth
    if (_seenMessages.length > 1000) {
      _seenMessages.clear();
      print('🧹 [DTNRouter] Cleared seen messages cache');
    }
    
    print('🧹 [DTNRouter] Cleanup complete. Relay queue: ${_relayQueue.length}');
  }

  /// Send a new message using DTN
  Future<void> sendMessage(ChatMessage msg) async {
    print('📤 [DTNRouter] Sending new message: ${msg.id}');
    
    final config = DTNConfigService.instance.config;
    
    // Set origin device with config-based settings
    final msgWithOrigin = msg.copyWith(
      originDeviceId: _myDeviceId,
      routePath: [_myDeviceId!],
      sprayCounter: config.sprayCounter,  // از config
      ttl: config.ttl,                     // از config
    );
    
    // Sign message
    final signedMsg = await _signMessage(msgWithOrigin);
    
    // Check network with config preference
    final hasInternet = await _hasInternet();
    
    if (hasInternet && !config.preferBluetoothOverServer) {
      print('🌐 [DTNRouter] Sending via WiFi/Server');
      _analytics.trackMessageSent(signedMsg, 'wifi');
      await _uploadToServer(signedMsg);
    } else {
      print('📶 [DTNRouter] Sending via Bluetooth mesh');
      _analytics.trackMessageSent(signedMsg, 'bluetooth');
      await _storeForRelay(signedMsg);
      onBluetoothBroadcast?.call(signedMsg);
    }
  }

  /// Sign message with HMAC
  Future<ChatMessage> _signMessage(ChatMessage msg) async {
    if (_sharedSecret == null) {
      print('⚠️ [DTNRouter] No shared secret, skipping signing');
      return msg;
    }
    
    final signature = _crypto.generateMessageHMAC(msg, _sharedSecret!);
    return msg.copyWith(messageSignature: signature);
  }

  void dispose() {
    _cleanupTimer?.cancel();
    _meshSubscription?.cancel();
    _isConnectedToMesh = false;
  }
}
