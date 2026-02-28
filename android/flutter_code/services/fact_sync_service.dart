import 'dart:async';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hybrid_messenger/models/fact_model.dart';
import 'package:hybrid_messenger/services/knowledge_service.dart';
import 'package:hybrid_messenger/services/mesh/mesh_event_dispatcher.dart';

/// FactSyncService - Hybrid sync for Facts
/// 
/// Syncs facts via:
/// - Internet (when available): Upload/download from server
/// - Mesh/Bluetooth (when offline): Share with nearby peers
/// 
/// Automatically switches based on connectivity.
class FactSyncService {
  static final FactSyncService _instance = FactSyncService._internal();
  factory FactSyncService() => _instance;
  FactSyncService._internal();

  final KnowledgeService _knowledge = KnowledgeService();
  final MeshEventDispatcher _mesh = MeshEventDispatcher.instance;
  
  StreamSubscription? _connectivitySubscription;
  Timer? _syncTimer;
  bool _isOnline = false;
  
  static const String _baseUrl = 'https://raiven.replit.app';
  static const String _lastSyncKey = 'fact_last_sync';
  
  // ═══════════════════════════════════════════════════════════════
  // INITIALIZATION
  // ═══════════════════════════════════════════════════════════════
  
  /// Initialize sync service
  Future<void> init() async {
    await _knowledge.init();
    await _checkConnectivity();
    _startConnectivityListener();
    _startPeriodicSync();
    print('🔄 [FactSync] Initialized (${_isOnline ? "Online" : "Offline"})');
  }
  
  /// Check current connectivity
  Future<void> _checkConnectivity() async {
    final dynamic result = await Connectivity().checkConnectivity();
    if (result is List) {
      _isOnline = (result.cast<ConnectivityResult>()).any((r) => 
        r == ConnectivityResult.wifi || 
        r == ConnectivityResult.mobile ||
        r == ConnectivityResult.ethernet
      );
    } else {
      final r = result as ConnectivityResult;
      _isOnline = r == ConnectivityResult.wifi || 
                  r == ConnectivityResult.mobile ||
                  r == ConnectivityResult.ethernet;
    }
  }
  
  /// Listen for connectivity changes
  void _startConnectivityListener() {
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((dynamic result) {
      bool wasOnline = _isOnline;
      
      if (result is List) {
        _isOnline = (result.cast<ConnectivityResult>()).any((r) => 
          r == ConnectivityResult.wifi || 
          r == ConnectivityResult.mobile ||
          r == ConnectivityResult.ethernet
        );
      } else {
        final r = result as ConnectivityResult;
        _isOnline = r == ConnectivityResult.wifi || 
                    r == ConnectivityResult.mobile ||
                    r == ConnectivityResult.ethernet;
      }
      
      // When coming back online, sync with server (fire-and-forget to prevent UI freeze)
      if (!wasOnline && _isOnline) {
        print('🌐 [FactSync] Back online - syncing with server');
        // ignore: unawaited_futures
        syncWithServer().catchError((e) {
          print('⚠️ [FactSync] Sync error (non-blocking): $e');
        });
      }
    });
  }
  
  /// Start periodic sync (every 5 minutes)
  void _startPeriodicSync() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      syncAll();
    });
  }
  
  // ═══════════════════════════════════════════════════════════════
  // UNIFIED SYNC
  // ═══════════════════════════════════════════════════════════════
  
  /// Sync a newly created or updated fact
  Future<void> syncFact(Fact fact) async {
    if (_isOnline) {
      // Try server first
      final success = await _uploadFactToServer(fact);
      if (success) {
        print('☁️ [FactSync] Uploaded to server: ${fact.title}');
        return;
      }
    }
    
    // Fallback to mesh (or if offline)
    final meshSuccess = await _mesh.sendFact(fact);
    if (meshSuccess) {
      print('📡 [FactSync] Broadcast to mesh: ${fact.title}');
    }
  }
  
  /// Sync all pending facts
  Future<void> syncAll() async {
    if (_isOnline) {
      await syncWithServer();
    } else {
      await syncWithMesh();
    }
  }
  
  // ═══════════════════════════════════════════════════════════════
  // SERVER SYNC
  // ═══════════════════════════════════════════════════════════════
  
  /// Sync with server (upload local, download new)
  Future<void> syncWithServer() async {
    if (!_isOnline) return;
    
    try {
      // 1. Get local facts that need upload
      final localFacts = await _knowledge.getFactsForSync(limit: 50);
      
      // 2. Get last sync timestamp
      final prefs = await SharedPreferences.getInstance();
      final lastSync = prefs.getInt(_lastSyncKey) ?? 0;
      
      // 3. Upload local facts
      for (final fact in localFacts) {
        if (fact.updatedAt.millisecondsSinceEpoch > lastSync) {
          await _uploadFactToServer(fact);
        }
      }
      
      // 4. Download new facts from server
      await _downloadFactsFromServer(since: lastSync);
      
      // 5. Update last sync timestamp
      await prefs.setInt(_lastSyncKey, DateTime.now().millisecondsSinceEpoch);
      
      print('✅ [FactSync] Server sync complete');
    } catch (e) {
      print('❌ [FactSync] Server sync error: $e');
    }
  }
  
  /// Upload a fact to server
  Future<bool> _uploadFactToServer(Fact fact) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('access_token');
      
      final response = await http.post(
        Uri.parse('$_baseUrl/api/knowledge/facts'),
        headers: {
          'Content-Type': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        },
        body: jsonEncode(fact.toJson()),
      ).timeout(const Duration(seconds: 15));
      
      return response.statusCode == 200 || response.statusCode == 201;
    } catch (e) {
      print('❌ [FactSync] Upload error: $e');
      return false;
    }
  }
  
  /// Download facts from server
  Future<void> _downloadFactsFromServer({int? since}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('access_token');
      
      final uri = Uri.parse('$_baseUrl/api/knowledge/facts').replace(
        queryParameters: since != null ? {'since': since.toString()} : null,
      );
      
      final response = await http.get(
        uri,
        headers: {
          if (token != null) 'Authorization': 'Bearer $token',
        },
      ).timeout(const Duration(seconds: 15));
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final facts = (data['facts'] as List? ?? [])
            .map((j) => Fact.fromJson(j as Map<String, dynamic>))
            .toList();
        
        for (final fact in facts) {
          await _knowledge.syncFromMesh(fact);
        }
        
        print('📥 [FactSync] Downloaded ${facts.length} facts from server');
      }
    } catch (e) {
      print('❌ [FactSync] Download error: $e');
    }
  }
  
  // ═══════════════════════════════════════════════════════════════
  // MESH SYNC
  // ═══════════════════════════════════════════════════════════════
  
  /// Sync with mesh peers
  Future<void> syncWithMesh() async {
    // Request facts from nearby peers
    final success = await _mesh.requestFacts(sinceHoursAgo: 24);
    if (success) {
      print('📡 [FactSync] Requested facts from mesh peers');
    }
  }
  
  /// Broadcast all recent facts to mesh
  Future<void> broadcastToMesh() async {
    final facts = await _knowledge.getFactsForSync(limit: 20);
    
    for (final fact in facts) {
      await _mesh.sendFact(fact);
    }
    
    print('📡 [FactSync] Broadcast ${facts.length} facts to mesh');
  }
  
  // ═══════════════════════════════════════════════════════════════
  // STATUS
  // ═══════════════════════════════════════════════════════════════
  
  /// Check if currently online
  bool get isOnline => _isOnline;
  
  /// Dispose resources
  void dispose() {
    _connectivitySubscription?.cancel();
    _syncTimer?.cancel();
  }
}
