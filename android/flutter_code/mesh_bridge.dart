import 'dart:async';
import 'package:flutter/services.dart';

class MeshBridge {
  static const _channel = MethodChannel('mesh_channel');
  static const _eventChannel = EventChannel('mesh_events');

  /// Start mesh networking with full identity
  /// [service] - The service type (e.g., "hybrid-msg")
  /// [displayName] - User's display name
  /// [fingerprint] - SHA256 hash of device's public key
  /// [publicKey] - PEM-encoded public key for verification
  static Future<void> start({
    required String service,
    required String displayName,
    required String fingerprint,
    required String publicKey,
  }) async {
    try {
      print('🔵 [MeshBridge] Starting with:');
      print('   service: $service');
      print('   displayName: $displayName');
      print('   fingerprint: ${fingerprint.substring(0, 16)}...');
      print('   publicKey: ${publicKey.length} chars');
      
      await _channel.invokeMethod('start', {
        'service': service,
        'displayName': displayName,
        'fingerprint': fingerprint,  // ✅ ADDED
        'publicKey': publicKey,       // ✅ ADDED
      });
      print('✅ [MeshBridge] Started successfully');
    } catch (e) {
      print('❌ [MeshBridge] start error: $e');
      rethrow;
    }
  }

  /// Restart mesh networking (to re-trigger discovery after network change)
  static Future<void> restart() async {
    try {
      print('🔄 [MeshBridge] Restarting mesh...');
      await _channel.invokeMethod('restart');
      print('✅ [MeshBridge] Restarted successfully');
    } catch (e) {
      print('⚠️ [MeshBridge] restart error: $e');
    }
  }

  /// Check if mesh is currently running
  static Future<bool> isRunning() async {
    try {
      final result = await _channel.invokeMethod('isRunning');
      return result == true;
    } catch (e) {
      print('⚠️ [MeshBridge] isRunning error: $e');
      return false;
    }
  }

  /// Get list of currently connected peer fingerprints
  static Future<List<String>> getConnectedPeers() async {
    try {
      final result = await _channel.invokeMethod('getConnectedPeers');
      return (result as List?)?.cast<String>() ?? [];
    } catch (e) {
      print('⚠️ [MeshBridge] getConnectedPeers error: $e');
      return [];
    }
  }

  /// Send a payload to all connected peers
  static Future<bool> send(String payload) async {
    try {
      print('📤 [MeshBridge] Sending ${payload.length} chars');
      final result = await _channel.invokeMethod('send', {'payload': payload});
      return result == true;
    } catch (e) {
      print('❌ [MeshBridge] send error: $e');
      return false;
    }
  }

  /// Add a peer fingerprint to trusted list
  static Future<void> addTrustedPeer(String fingerprint) async {
    try {
      print('➕ [MeshBridge] Adding trusted peer: ${fingerprint.substring(0, 16)}...');
      await _channel.invokeMethod('addTrustedPeer', {'fingerprint': fingerprint});
    } catch (e) {
      print('❌ [MeshBridge] addTrustedPeer error: $e');
      rethrow;
    }
  }

  /// Remove a peer fingerprint from trusted list
  static Future<void> removeTrustedPeer(String fingerprint) async {
    try {
      print('➖ [MeshBridge] Removing trusted peer: ${fingerprint.substring(0, 16)}...');
      await _channel.invokeMethod('removeTrustedPeer', {'fingerprint': fingerprint});
    } catch (e) {
      print('❌ [MeshBridge] removeTrustedPeer error: $e');
      rethrow;
    }
  }

  /// Get list of pending pairing requests
  static Future<List<String>> getPendingPairings() async {
    try {
      final result = await _channel.invokeMethod('getPendingPairings');
      return (result as List?)?.cast<String>() ?? [];
    } catch (e) {
      print('❌ [MeshBridge] getPendingPairings error: $e');
      return [];
    }
  }

  /// ✅ Invite a discovered peer by fingerprint
  static Future<bool> invitePeer(String fingerprint) async {
    try {
      print('📤 [MeshBridge] Inviting peer: ${fingerprint.substring(0, 16)}...');
      final result = await _channel.invokeMethod('invitePeer', {'fingerprint': fingerprint});
      return result == true;
    } catch (e) {
      print('❌ [MeshBridge] invitePeer error: $e');
      return false;
    }
  }

  /// Stream of incoming messages and events
  /// Events include: chat messages, peers changed, pairing requests, screenshots
  static Stream<String> messages() {
    return _eventChannel.receiveBroadcastStream().map((event) {
      print('📥 [MeshBridge] Event received: ${(event as String).substring(0, event.length > 50 ? 50 : event.length)}...');
      return event;
    });
  }
  
  /// Debug mesh state - logs comprehensive info to console
  static Future<Map<String, dynamic>> debugMesh() async {
    try {
      print('🔍 [MeshBridge] Requesting mesh debug info...');
      final result = await _channel.invokeMethod('debugMesh');
      print('🔍 [MeshBridge] Debug info received: $result');
      return Map<String, dynamic>.from(result ?? {});
    } catch (e) {
      print('❌ [MeshBridge] debugMesh error: $e');
      return {'error': e.toString()};
    }
  }
}