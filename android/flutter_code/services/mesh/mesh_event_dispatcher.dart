import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../models/mesh_envelope.dart';
import '../../mesh_bridge.dart';
import 'seen_cache.dart';
import 'presence_controller.dart';
import 'deaddrop_controller.dart';
import 'ptt_controller.dart';
import 'knowledge_controller.dart';
import 'fact_mesh_controller.dart';
import 'mesh_notification_service.dart';

/// MeshEventDispatcher - Central router for all Mesh messages
/// 
/// Listens to MeshBridge.messages() and dispatches to appropriate controllers
/// based on message type. Handles deduplication via SeenCache.
/// 
/// Message flow:
/// 1. Raw JSON received from MeshBridge
/// 2. Parse into MeshEnvelope
/// 3. Check SeenCache for duplicates
/// 4. Route to appropriate controller
/// 5. Optionally relay to other peers
class MeshEventDispatcher {
  static final MeshEventDispatcher _instance = MeshEventDispatcher._();
  static MeshEventDispatcher get instance => _instance;
  
  MeshEventDispatcher._();

  /// Identity for sending messages
  String? _userId;
  String? _fingerprint;
  String? _nickname;
  
  /// Controllers
  final SeenCache seen = SeenCache.instance;
  final PresenceController presence = PresenceController.instance;
  final DeadDropController deadDrop = DeadDropController.instance;
  final PttController ptt = PttController.instance;
  final KnowledgeController knowledge = KnowledgeController.instance;
  final FactMeshController factMesh = FactMeshController.instance;
  final MeshNotificationService notifications = MeshNotificationService.instance;
  
  /// ✅ In-app overlay callback (set from AppModel)
  /// Called when presence check-in is received to show in-app toast
  Function({required String id, required String nickname, String? note})? onPresenceReceived;
  
  /// ✅ In-app overlay callback for dead drops
  Function({required String id, required String title, required String preview})? onDeadDropReceived;
  
  bool _isInitialized = false;

  /// Initialize the dispatcher with user identity
  void init({
    required String userId,
    required String fingerprint,
    required String nickname,
  }) {
    if (_isInitialized) return;
    
    _userId = userId;
    _fingerprint = fingerprint;
    _nickname = nickname;
    
    seen.init();
    
    // Subscribe to MeshBridge messages
    MeshBridge.messages().listen(_onMeshMessage);
    
    _isInitialized = true;
    debugPrint('🌐 [MeshDispatcher] Initialized for $nickname');
  }

  /// Update identity (e.g., after nickname change)
  void updateIdentity({
    String? userId,
    String? fingerprint,
    String? nickname,
  }) {
    _userId = userId ?? _userId;
    _fingerprint = fingerprint ?? _fingerprint;
    _nickname = nickname ?? _nickname;
  }

  /// Handle raw message from MeshBridge
  void _onMeshMessage(String jsonStr) {
    try {
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      
      // Check if this is a mesh envelope (has our envelope fields)
      if (!json.containsKey('type') || !json.containsKey('id')) {
        // Not a mesh envelope - might be a legacy message
        debugPrint('📨 [MeshDispatcher] Non-envelope message, skipping');
        return;
      }
      
      final envelope = MeshEnvelope.fromJson(json);
      _handleEnvelope(envelope);
    } catch (e) {
      debugPrint('❌ [MeshDispatcher] Parse error: $e');
    }
  }

  /// Process a parsed envelope
  Future<void> _handleEnvelope(MeshEnvelope envelope) async {
    // Check for duplicates
    if (!seen.checkAndMark(envelope.id, ttlSeconds: envelope.ttlSec)) {
      debugPrint('🔄 [MeshDispatcher] Duplicate: ${envelope.id.substring(0, 8)}');
      return;
    }
    
    // Check expiration
    if (envelope.isExpired) {
      debugPrint('⏰ [MeshDispatcher] Expired: ${envelope.id.substring(0, 8)}');
      return;
    }
    
    debugPrint('📬 [MeshDispatcher] Handling ${envelope.type} from ${envelope.from.nickname}');
    
    // Route to appropriate controller
    List<MeshEnvelope>? responseEnvelopes;
    
    switch (envelope.type) {
      case 'presence':
        debugPrint('📍 MESH_RX type=presence eventId=${envelope.id.substring(0, 8)} fromPeer=${envelope.from.nickname}');
        await presence.handle(envelope);
        
        // ✅ System push notification
        notifications.notifyPresenceCheckIn(
          nickname: envelope.from.nickname,
          fingerprint: envelope.from.fingerprint,
          note: envelope.payload['note'] as String?,
        );
        
        // ✅ In-app overlay notification (if callback set)
        if (onPresenceReceived != null) {
          debugPrint('🔔 NOTIF_ADD type=presence title=${envelope.from.nickname}');
          onPresenceReceived!(
            id: envelope.id,
            nickname: envelope.from.nickname,
            note: envelope.payload['note'] as String?,
          );
        }
        break;
        
      case 'deaddrop':
        debugPrint('📦 MESH_RX type=deaddrop dropId=${envelope.id.substring(0, 8)} fromPeer=${envelope.from.nickname}');
        await deadDrop.handle(envelope);
        
        final dropTitle = envelope.payload['title'] as String? ?? 'New Drop';
        final dropText = envelope.payload['text'] as String? ?? '';
        
        // ✅ System push notification
        notifications.notifyDeadDropDiscovered(
          title: dropTitle,
          previewText: dropText,
          dropId: envelope.id,
        );
        
        // ✅ In-app overlay notification (if callback set)
        if (onDeadDropReceived != null) {
          debugPrint('🔔 NOTIF_ADD type=deaddrop title=$dropTitle');
          onDeadDropReceived!(
            id: envelope.id,
            title: dropTitle,
            preview: dropText,
          );
        }
        break;
        
      case 'ptt':
        ptt.handle(envelope);
        // Only notify on first chunk of stream (seq == 0)
        if ((envelope.payload['seq'] as int? ?? 0) == 0) {
          notifications.notifyPttMessage(
            fromNickname: envelope.from.nickname,
            fromFingerprint: envelope.from.fingerprint,
          );
        }
        break;
        
      case 'knowledge':
        // Check if this is a fact operation first
        final op = envelope.payload['op'] as String?;
        if (op == 'fact' || op == 'fact_request') {
          responseEnvelopes = await factMesh.handle(
            envelope,
            myUserId: _userId ?? '',
            myFingerprint: _fingerprint ?? '',
            myNickname: _nickname ?? '',
          );
          // Notify about new fact
          if (op == 'fact') {
            final factData = envelope.payload['fact'] as Map<String, dynamic>?;
            notifications.notifyKnowledgeReceived(
              title: factData?['title'] as String? ?? 'New Fact',
              kind: 'fact',
              hash: factData?['id'] as String? ?? envelope.id,
            );
          }
        } else {
          // Handle legacy knowledge items
          responseEnvelopes = await knowledge.handle(
            envelope,
            myUserId: _userId ?? '',
            myFingerprint: _fingerprint ?? '',
            myNickname: _nickname ?? '',
          );
          // Notify about new knowledge (only for data payloads, not announce/want)
          if (envelope.payload['kind'] != null) {
            notifications.notifyKnowledgeReceived(
              title: envelope.payload['title'] as String? ?? 'Knowledge',
              kind: envelope.payload['kind'] as String? ?? 'text',
              hash: envelope.payload['hash'] as String? ?? envelope.id,
            );
          }
        }
        break;
        
      default:
        debugPrint('⚠️ [MeshDispatcher] Unknown type: ${envelope.type}');
    }
    
    // Send response envelopes if any
    if (responseEnvelopes != null) {
      for (final response in responseEnvelopes) {
        await _sendEnvelope(response);
      }
    }
    
    // Relay if allowed
    if (envelope.canRelay) {
      await _relayEnvelope(envelope);
    }
  }

  /// Send an envelope via MeshBridge
  Future<bool> _sendEnvelope(MeshEnvelope envelope) async {
    final json = envelope.toJsonString();
    return await MeshBridge.send(json);
  }

  /// Relay envelope to other peers (with incremented hop)
  Future<void> _relayEnvelope(MeshEnvelope envelope) async {
    final relayed = envelope.relay();
    await _sendEnvelope(relayed);
    debugPrint('🔀 [MeshDispatcher] Relayed ${envelope.type} hop ${envelope.hop} -> ${relayed.hop}');
  }

  // ═══════════════════════════════════════════════════════════════
  // PUBLIC SEND METHODS
  // ═══════════════════════════════════════════════════════════════

  /// Send presence check-in
  Future<bool> sendPresenceCheckIn({String? note}) async {
    if (_userId == null || _fingerprint == null || _nickname == null) {
      debugPrint('❌ [MeshDispatcher] Not initialized');
      return false;
    }
    
    final envelope = await presence.sendCheckIn(
      userId: _userId!,
      fingerprint: _fingerprint!,
      nickname: _nickname!,
      note: note,
    );
    
    return await _sendEnvelope(envelope);
  }

  /// Send dead-drop message
  Future<bool> sendDeadDrop({
    required String cell,
    required String title,
    required String text,
  }) async {
    if (_userId == null || _fingerprint == null || _nickname == null) {
      return false;
    }
    
    final envelope = await deadDrop.createDrop(
      userId: _userId!,
      fingerprint: _fingerprint!,
      nickname: _nickname!,
      cell: cell,
      title: title,
      text: text,
    );
    
    return await _sendEnvelope(envelope);
  }

  /// Send PTT voice chunk
  Future<bool> sendPttChunk({
    required List<int> audioData,
    bool isEnd = false,
  }) async {
    if (_userId == null || _fingerprint == null || _nickname == null) {
      return false;
    }
    
    final envelope = ptt.createChunkEnvelope(
      userId: _userId!,
      fingerprint: _fingerprint!,
      nickname: _nickname!,
      audioData: Uint8List.fromList(audioData),
      isEnd: isEnd,
    );
    
    return await _sendEnvelope(envelope);
  }

  /// Announce our knowledge items
  Future<bool> announceKnowledge() async {
    if (_userId == null || _fingerprint == null || _nickname == null) {
      return false;
    }
    
    final envelope = await knowledge.createAnnounceEnvelope(
      userId: _userId!,
      fingerprint: _fingerprint!,
      nickname: _nickname!,
    );
    
    return await _sendEnvelope(envelope);
  }

  /// Request a knowledge item
  Future<bool> requestKnowledgeItem(String hash) async {
    if (_userId == null || _fingerprint == null || _nickname == null) {
      return false;
    }
    
    final envelope = knowledge.createWantEnvelope(
      userId: _userId!,
      fingerprint: _fingerprint!,
      nickname: _nickname!,
      hash: hash,
    );
    
    return await _sendEnvelope(envelope);
  }

  /// Broadcast a fact to mesh peers
  Future<bool> sendFact(dynamic fact) async {
    if (_userId == null || _fingerprint == null || _nickname == null) {
      return false;
    }
    
    final envelope = factMesh.createFactEnvelope(
      userId: _userId!,
      fingerprint: _fingerprint!,
      nickname: _nickname!,
      fact: fact,
    );
    
    return await _sendEnvelope(envelope);
  }

  /// Request facts from mesh peers
  Future<bool> requestFacts({String? tag, int sinceHoursAgo = 24}) async {
    if (_userId == null || _fingerprint == null || _nickname == null) {
      return false;
    }
    
    final envelope = factMesh.createFactRequestEnvelope(
      userId: _userId!,
      fingerprint: _fingerprint!,
      nickname: _nickname!,
      tag: tag,
      sinceHoursAgo: sinceHoursAgo,
    );
    
    return await _sendEnvelope(envelope);
  }

  void dispose() {
    seen.dispose();
    presence.dispose();
    deadDrop.dispose();
    ptt.dispose();
    knowledge.dispose();
    _isInitialized = false;
  }
}
