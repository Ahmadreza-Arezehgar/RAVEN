import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hybrid_messenger/models/fact_model.dart';
import 'package:hybrid_messenger/services/knowledge_service.dart';
import 'package:hybrid_messenger/services/badge_service.dart';

/// Result of AI verification
class VerifyResult {
  final bool isLikelyTrue;
  final double confidence;      // 0.0 - 1.0
  final String category;        // science, history, health, etc.
  final List<String> keyReasons;
  final List<String> suggestedSources;
  final String summary;

  VerifyResult({
    required this.isLikelyTrue,
    required this.confidence,
    required this.category,
    required this.keyReasons,
    this.suggestedSources = const [],
    required this.summary,
  });

  factory VerifyResult.fromJson(Map<String, dynamic> json) {
    return VerifyResult(
      isLikelyTrue: json['is_likely_true'] as bool? ?? false,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      category: json['category'] as String? ?? 'general',
      keyReasons: (json['key_reasons'] as List?)?.cast<String>() ?? [],
      suggestedSources: (json['suggested_sources'] as List?)?.cast<String>() ?? [],
      summary: json['summary'] as String? ?? '',
    );
  }
}

/// Service for verifying facts using AI (Gemini)
class VerifyService {
  static final VerifyService _instance = VerifyService._internal();
  factory VerifyService() => _instance;
  VerifyService._internal();

  final KnowledgeService _knowledge = KnowledgeService();
  final BadgeService _badges = BadgeService();
  
  // Queue for offline verification
  static const String _queueKey = 'verify_queue';
  
  // Thresholds for verification decisions
  static const double verifiedThreshold = 0.85;
  static const double needsReviewThreshold = 0.60;

  /// Check if device has internet connectivity
  Future<bool> _hasInternet() async {
    final dynamic result = await Connectivity().checkConnectivity();
    if (result is List) {
      return (result.cast<ConnectivityResult>()).any((r) => 
        r == ConnectivityResult.wifi || 
        r == ConnectivityResult.mobile ||
        r == ConnectivityResult.ethernet
      );
    } else {
      final r = result as ConnectivityResult;
      return r == ConnectivityResult.wifi || 
             r == ConnectivityResult.mobile ||
             r == ConnectivityResult.ethernet;
    }
  }

  /// Verify a fact using AI
  Future<VerifyStatus> verifyFact(String factId, {String? authorId}) async {
    final fact = await _knowledge.getFact(factId);
    if (fact == null) {
      print('❌ [Verify] Fact not found: $factId');
      return VerifyStatus.unverified;
    }

    // Mark as pending
    await _knowledge.updateVerifyStatus(factId, status: VerifyStatus.pending);

    // Check connectivity
    final hasInternet = await _hasInternet();

    if (!hasInternet) {
      // Queue for later verification
      await _addToQueue(factId);
      print('📥 [Verify] Queued for later: $factId');
      return VerifyStatus.pending;
    }

    try {
      // Call AI verification API
      final result = await _callVerifyApi(fact);
      
      // Determine status based on confidence
      final status = _determineStatus(result);
      
      // Update fact with verification result
      await _knowledge.updateVerifyStatus(
        factId,
        status: status,
        score: (result.confidence * 100).round(),
        reason: result.summary,
      );

      // Check for badge unlock if verified
      if (status == VerifyStatus.verified && authorId != null) {
        final previousCount = await _knowledge.getUserVerifiedCount(authorId) - 1;
        final newBadge = await _badges.checkNewBadge(authorId, previousCount);
        if (newBadge != null) {
          print('🏆 [Verify] User earned badge: ${newBadge.name}');
          // TODO: Show celebration UI
        }
      }

      print('✅ [Verify] Completed: $factId -> ${status.name} (${result.confidence})');
      return status;

    } catch (e) {
      print('❌ [Verify] API error: $e');
      await _addToQueue(factId);
      return VerifyStatus.pending;
    }
  }

  /// Call the verification API
  Future<VerifyResult> _callVerifyApi(Fact fact) async {
    // Use the app's API service base URL
    const baseUrl = 'https://raiven.replit.app'; // Replace with your server URL
    const apiUrl = '$baseUrl/api/knowledge/verify';
    
    // Get auth token
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('access_token');
    
    final response = await http.post(
      Uri.parse(apiUrl),
      headers: {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'title': fact.title,
        'claim': fact.claim,
        'lang': fact.lang,
        'tags': fact.tags,
      }),
    ).timeout(const Duration(seconds: 30));

    if (response.statusCode == 200) {
      return VerifyResult.fromJson(jsonDecode(response.body));
    } else {
      throw Exception('Verify API failed: ${response.statusCode}');
    }
  }

  /// Determine verification status based on AI result
  VerifyStatus _determineStatus(VerifyResult result) {
    if (result.confidence >= verifiedThreshold && result.isLikelyTrue) {
      return VerifyStatus.verified;
    } else if (result.confidence >= needsReviewThreshold) {
      return VerifyStatus.needsReview;
    } else if (!result.isLikelyTrue && result.confidence >= 0.70) {
      return VerifyStatus.rejected;
    } else {
      return VerifyStatus.unverified;
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // OFFLINE QUEUE
  // ═══════════════════════════════════════════════════════════════════

  /// Add a fact to the verification queue
  Future<void> _addToQueue(String factId) async {
    final prefs = await SharedPreferences.getInstance();
    final queue = prefs.getStringList(_queueKey) ?? [];
    if (!queue.contains(factId)) {
      queue.add(factId);
      await prefs.setStringList(_queueKey, queue);
    }
  }

  /// Remove a fact from the queue
  Future<void> _removeFromQueue(String factId) async {
    final prefs = await SharedPreferences.getInstance();
    final queue = prefs.getStringList(_queueKey) ?? [];
    queue.remove(factId);
    await prefs.setStringList(_queueKey, queue);
  }

  /// Get queued fact IDs
  Future<List<String>> getQueue() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_queueKey) ?? [];
  }

  /// Process all queued verifications (call when internet is available)
  Future<void> processQueue() async {
    final hasInternet = await _hasInternet();

    if (!hasInternet) {
      print('📴 [Verify] No internet, skipping queue');
      return;
    }

    final queue = await getQueue();
    if (queue.isEmpty) {
      print('✅ [Verify] Queue is empty');
      return;
    }

    print('🔄 [Verify] Processing ${queue.length} queued verifications');

    for (final factId in queue) {
      try {
        await verifyFact(factId);
        await _removeFromQueue(factId);
      } catch (e) {
        print('❌ [Verify] Queue processing error for $factId: $e');
      }
    }
  }

  /// Listen for connectivity changes and process queue
  void startQueueListener() {
    Connectivity().onConnectivityChanged.listen((dynamic result) async {
      bool hasInternet;
      if (result is List) {
        hasInternet = (result.cast<ConnectivityResult>()).any((r) => 
          r == ConnectivityResult.wifi || 
          r == ConnectivityResult.mobile ||
          r == ConnectivityResult.ethernet
        );
      } else {
        final r = result as ConnectivityResult;
        hasInternet = r == ConnectivityResult.wifi || 
                      r == ConnectivityResult.mobile ||
                      r == ConnectivityResult.ethernet;
      }
      
      if (hasInternet) {
        // Fire-and-forget to prevent UI freeze
        // ignore: unawaited_futures
        processQueue().catchError((e) {
          print('⚠️ [Verify] Queue processing error (non-blocking): $e');
        });
      }
    });
    
    print('📡 [Verify] Queue listener started');
  }
}
