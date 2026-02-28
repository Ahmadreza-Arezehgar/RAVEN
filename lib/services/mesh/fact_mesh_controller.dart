import '../../models/mesh_envelope.dart';
import '../../models/fact_model.dart';
import '../knowledge_service.dart';

/// FactMeshController - Sync Facts over Mesh Network
/// 
/// Broadcasts new/updated facts to peers and receives facts from mesh.
/// Uses 'knowledge' message type with op='fact' for fact synchronization.
/// 
/// Protocol:
/// - type: 'knowledge'
/// - payload.op: 'fact'
/// - payload.fact: serialized Fact object
class FactMeshController {
  static final FactMeshController _instance = FactMeshController._();
  static FactMeshController get instance => _instance;
  
  FactMeshController._();
  
  final KnowledgeService _service = KnowledgeService();
  
  // ═══════════════════════════════════════════════════════════════
  // BROADCASTING FACTS
  // ═══════════════════════════════════════════════════════════════
  
  /// Create envelope to broadcast a fact
  MeshEnvelope createFactEnvelope({
    required String userId,
    required String fingerprint,
    required String nickname,
    required Fact fact,
  }) {
    return MeshEnvelope(
      type: 'knowledge',
      from: MeshSender(
        userId: userId,
        fingerprint: fingerprint,
        nickname: nickname,
      ),
      ttlSec: 3600, // 1 hour
      maxHop: 2,    // Allow 2 hops for wider spread
      payload: {
        'op': 'fact',
        'fact': fact.toJson(),
      },
    );
  }
  
  /// Create envelope to request facts from peers
  MeshEnvelope createFactRequestEnvelope({
    required String userId,
    required String fingerprint,
    required String nickname,
    String? tag,         // Optional tag filter
    int sinceHoursAgo = 24, // Only facts from last N hours
  }) {
    return MeshEnvelope(
      type: 'knowledge',
      from: MeshSender(
        userId: userId,
        fingerprint: fingerprint,
        nickname: nickname,
      ),
      ttlSec: 60,
      maxHop: 1,
      payload: {
        'op': 'fact_request',
        if (tag != null) 'tag': tag,
        'sinceHoursAgo': sinceHoursAgo,
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // RECEIVING FACTS
  // ═══════════════════════════════════════════════════════════════
  
  /// Handle incoming knowledge message with fact op
  /// Returns list of fact envelopes to send back (for fact_request)
  Future<List<MeshEnvelope>?> handle(
    MeshEnvelope envelope, {
    required String myUserId,
    required String myFingerprint,
    required String myNickname,
  }) async {
    if (envelope.type != 'knowledge') return null;
    if (envelope.isExpired) return null;
    
    final op = envelope.payload['op'] as String?;
    
    switch (op) {
      case 'fact':
        await _handleFact(envelope);
        return null;
        
      case 'fact_request':
        return await _handleFactRequest(
          envelope,
          myUserId,
          myFingerprint,
          myNickname,
        );
        
      default:
        return null; // Not a fact operation
    }
  }
  
  /// Handle received fact
  Future<void> _handleFact(MeshEnvelope envelope) async {
    final factData = envelope.payload['fact'] as Map<String, dynamic>?;
    if (factData == null) return;
    
    try {
      final fact = Fact.fromJson(factData);
      
      // Use mesh sync method to handle deduplication/updates
      final synced = await _service.syncFromMesh(fact);
      
      if (synced) {
        print('📚 [FactMesh] Synced fact: ${fact.title}');
      } else {
        print('📚 [FactMesh] Ignored (duplicate/older): ${fact.id}');
      }
    } catch (e) {
      print('❌ [FactMesh] Parse error: $e');
    }
  }
  
  /// Handle fact request - return our facts that match criteria
  Future<List<MeshEnvelope>?> _handleFactRequest(
    MeshEnvelope envelope,
    String myUserId,
    String myFingerprint,
    String myNickname,
  ) async {
    final tag = envelope.payload['tag'] as String?;
    final sinceHours = envelope.payload['sinceHoursAgo'] as int? ?? 24;
    
    List<Fact> facts;
    
    if (tag != null) {
      facts = await _service.getFactsByTag(tag, limit: 10);
    } else {
      facts = await _service.getFactsForSync(limit: 20);
    }
    
    // Filter by time
    final cutoff = DateTime.now().subtract(Duration(hours: sinceHours));
    facts = facts.where((f) => f.createdAt.isAfter(cutoff)).toList();
    
    if (facts.isEmpty) return null;
    
    // Create envelopes for each fact
    return facts.map((fact) => createFactEnvelope(
      userId: myUserId,
      fingerprint: myFingerprint,
      nickname: myNickname,
      fact: fact,
    )).toList();
  }
  
  // ═══════════════════════════════════════════════════════════════
  // CONVENIENCE METHODS
  // ═══════════════════════════════════════════════════════════════
  
  /// Get recent synced facts (received from mesh)
  Future<List<Fact>> getRecentMeshFacts({int limit = 50}) async {
    final facts = await _service.getFacts(limit: limit);
    // Filter to only facts that have been synced
    return facts.where((f) => f.syncCount > 0).toList();
  }
}
