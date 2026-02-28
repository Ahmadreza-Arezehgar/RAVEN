import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'device_identity_service.dart';
import 'network_detector.dart';
import 'api_service.dart';
import '../mesh_bridge.dart';

/// QR Friend Service - Handles QR-based friend pairing with signed payloads
/// 
/// Security features:
/// - Digital signature verification (anti-fake)
/// - 10-minute timestamp expiry
/// - Nonce for replay prevention
/// - Fingerprint verification against public key
class QrFriendService {
  static final QrFriendService instance = QrFriendService._();
  QrFriendService._();

  final _identity = DeviceIdentityService.instance;
  
  static const int _qrValidityMinutes = 10;
  static const int _qrVersion = 1;

  // ═══════════════════════════════════════════════════════════════════════════
  // QR PAYLOAD GENERATION
  // ═══════════════════════════════════════════════════════════════════════════

  /// Build a signed QR payload for displaying "My QR Code"
  /// Returns base64-encoded JSON with signature
  Future<String> buildMyQrPayload({
    required String userId,
    required String username,
    String? avatarUrl,
  }) async {
    final fingerprint = await _identity.getDeviceFingerprint();
    final pubKeyPem = await _identity.getPublicKeyPem();
    final shortFp = _identity.getShortFingerprint(fingerprint);
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final nonce = const Uuid().v4();

    // Build payload without signature
    final payload = <String, dynamic>{
      'v': _qrVersion,
      'type': 'friend_qr',
      'userId': userId,
      'username': username,
      'deviceFp': shortFp,
      'pubKey': pubKeyPem,
      'ts': timestamp,
      'nonce': nonce,
    };
    if (avatarUrl != null) {
      payload['avatarUrl'] = avatarUrl;
    }

    // Create signature over ordered fields
    final dataToSign = _getCanonicalPayloadString(payload);
    final signature = await _identity.signChallenge(dataToSign);
    
    if (signature == null) {
      throw Exception('Failed to sign QR payload');
    }

    payload['sig'] = signature;

    // Encode as base64 JSON
    final jsonStr = jsonEncode(payload);
    return base64Encode(utf8.encode(jsonStr));
  }

  /// Get canonical string representation for signing
  String _getCanonicalPayloadString(Map<String, dynamic> payload) {
    // Order: v, type, userId, username, deviceFp, pubKey, ts, nonce
    return [
      payload['v'].toString(),
      payload['type'],
      payload['userId'],
      payload['username'],
      payload['deviceFp'],
      payload['pubKey'],
      payload['ts'].toString(),
      payload['nonce'],
    ].join('|');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // QR PAYLOAD VERIFICATION
  // ═══════════════════════════════════════════════════════════════════════════

  /// Parse and verify a scanned QR payload
  /// Returns [QrPayload] on success, throws on invalid
  Future<QrPayload> parseAndVerifyQrPayload(String rawData) async {
    try {
      // Decode base64 -> JSON
      final jsonStr = utf8.decode(base64Decode(rawData));
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;

      // Check version
      if (data['v'] != _qrVersion) {
        throw QrValidationException('Unsupported QR version: ${data['v']}');
      }

      // Check type
      if (data['type'] != 'friend_qr') {
        throw QrValidationException('Invalid QR type: ${data['type']}');
      }

      // Check timestamp (10 minute window)
      final ts = data['ts'] as int;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final ageSeconds = now - ts;
      
      if (ageSeconds < 0) {
        throw QrValidationException('QR code is from the future');
      }
      if (ageSeconds > _qrValidityMinutes * 60) {
        throw QrValidationException('QR code expired (${ageSeconds ~/ 60} minutes old)');
      }

      // Verify fingerprint matches public key
      final pubKeyPem = data['pubKey'] as String;
      final claimedFp = data['deviceFp'] as String;
      final fullFingerprint = _computeFingerprintFromPem(pubKeyPem);
      final shortFp = _identity.getShortFingerprint(fullFingerprint);
      
      if (shortFp != claimedFp) {
        throw QrValidationException('Fingerprint does not match public key');
      }

      // Verify signature
      final signature = data['sig'] as String;
      final payloadWithoutSig = Map<String, dynamic>.from(data)..remove('sig');
      final dataToVerify = _getCanonicalPayloadString(payloadWithoutSig);
      
      final isValid = await _identity.verifyChallenge(dataToVerify, signature, pubKeyPem);
      if (!isValid) {
        throw QrValidationException('Invalid signature - QR may be fake');
      }

      print('✅ [QrFriendService] QR payload verified for @${data['username']}');

      return QrPayload(
        userId: data['userId'] as String,
        username: data['username'] as String,
        deviceFingerprint: fullFingerprint,
        shortFingerprint: claimedFp,
        publicKeyPem: pubKeyPem,
        timestamp: DateTime.fromMillisecondsSinceEpoch(ts * 1000),
        nonce: data['nonce'] as String,
        avatarUrl: data['avatarUrl'] as String?,
      );
    } on FormatException catch (e) {
      throw QrValidationException('Invalid QR format: $e');
    } on QrValidationException {
      rethrow;
    } catch (e) {
      throw QrValidationException('Failed to parse QR: $e');
    }
  }

  /// Compute fingerprint from public key PEM
  String _computeFingerprintFromPem(String pubKeyPem) {
    // SHA256 hash of the public key PEM - same logic as DeviceIdentityService
    final hash = sha256.convert(utf8.encode(pubKeyPem));
    return hash.toString();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // DUAL-PATH FRIEND REQUEST (Online → API, Offline → Mesh)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Send friend request with automatic routing
  /// - Online: Uses server API
  /// - Offline: Uses Bluetooth Mesh
  Future<FriendRequestResult> sendFriendRequest({
    required String myUserId,
    required String myUsername,
    required QrPayload targetPayload,
  }) async {
    // Check connectivity
    final detector = NetworkDetector();
    final method = await detector.detectBestMethod(hasBluetoothPeers: false);
    
    print('🔀 [QrFriendService] Routing friend request via: $method');
    
    if (method == NetworkMethod.wifi) {
      // ✅ Online path - use server API
      return await _sendViaApi(targetPayload, myUserId);
    } else {
      // ✅ Offline path - use Mesh
      return await _sendViaMesh(targetPayload, myUserId, myUsername);
    }
  }

  /// Send friend request via server API (online path)
  Future<FriendRequestResult> _sendViaApi(QrPayload target, String myUserId) async {
    print('🌐 [QrFriendService] Sending friend request via API...');
    
    try {
      final success = await ApiService.sendFriendRequest(target.userId);
      
      if (success) {
        print('✅ [QrFriendService] Friend request sent via API');
        return FriendRequestResult.sent(via: 'server', username: target.username);
      } else {
        print('⚠️ [QrFriendService] API returned error, falling back to Mesh');
        return FriendRequestResult.failed(
          reason: 'Server unavailable',
          canRetryViaMesh: true,
        );
      }
    } catch (e) {
      print('❌ [QrFriendService] API error: $e, falling back to Mesh');
      return FriendRequestResult.failed(
        reason: e.toString(),
        canRetryViaMesh: true,
      );
    }
  }

  /// Send friend request via Bluetooth Mesh (offline path)
  Future<FriendRequestResult> _sendViaMesh(
    QrPayload targetPayload,
    String myUserId,
    String myUsername,
  ) async {
    print('📶 [QrFriendService] Sending friend request via Mesh...');
    
    final fingerprint = await _identity.getDeviceFingerprint();
    final pubKeyPem = await _identity.getPublicKeyPem();

    // Step 1: Add target device to trusted peers
    print('🔐 [QrFriendService] Adding trusted peer: ${targetPayload.deviceFingerprint.substring(0, 12)}...');
    await MeshBridge.addTrustedPeer(targetPayload.deviceFingerprint);
    
    // Step 2: Try direct invite (if already in discovered list)
    print('📤 [QrFriendService] Trying direct invite...');
    await MeshBridge.invitePeer(targetPayload.deviceFingerprint);
    
    // Step 3: Also restart mesh to trigger fresh discovery
    print('🔄 [QrFriendService] Restarting mesh to discover peer...');
    await MeshBridge.restart();
    
    // Step 4: Wait for connection (poll with longer timeout - 12 seconds)
    bool connected = false;
    print('⏳ [QrFriendService] Waiting for connection...');
    for (int i = 0; i < 15; i++) {
      await Future.delayed(const Duration(milliseconds: 800));
      final peers = await MeshBridge.getConnectedPeers();
      print('📡 [QrFriendService] Poll ${i + 1}/15 - Connected peers: $peers');
      if (peers.isNotEmpty) {
        connected = true;
        print('✅ [QrFriendService] Connected to ${peers.length} peer(s)!');
        break;
      }
    }
    
    if (!connected) {
      print('⚠️ [QrFriendService] No peers connected after 12 seconds');
      return FriendRequestResult.failed(
        reason: 'Could not connect. Make sure both devices have the app open and Wi-Fi/Bluetooth enabled.',
        canRetryViaMesh: false,
      );
    }

    // Step 5: Now send the request
    final message = jsonEncode({
      'type': 'FRIEND_PAIR_REQUEST',
      'fromUserId': myUserId,
      'fromUsername': myUsername,
      'fromDeviceFp': fingerprint,
      'fromPubKey': pubKeyPem,
      'toUserId': targetPayload.userId,
      'toDeviceFp': targetPayload.deviceFingerprint,
      'nonce': const Uuid().v4(),
      'ts': DateTime.now().millisecondsSinceEpoch,
    });

    print('📤 [QrFriendService] Sending FRIEND_PAIR_REQUEST to @${targetPayload.username}');
    final success = await MeshBridge.send(message);
    
    if (success) {
      return FriendRequestResult.sent(
        via: 'mesh',
        username: targetPayload.username,
        pendingSync: true, // Will sync to server when online
      );
    } else {
      return FriendRequestResult.failed(
        reason: 'Failed to send via Mesh',
        canRetryViaMesh: false,
      );
    }
  }

  /// Legacy method for backward compatibility
  Future<bool> sendFriendPairRequest({
    required String myUserId,
    required String myUsername,
    required QrPayload targetPayload,
  }) async {
    final result = await sendFriendRequest(
      myUserId: myUserId,
      myUsername: myUsername,
      targetPayload: targetPayload,
    );
    return result.success;
  }

  /// Send friend pair accept via Bluetooth mesh
  Future<bool> sendFriendPairAccept({
    required String myUserId,
    required String myUsername,
    required String toUserId,
    required String toDeviceFp,
    String? myAvatarUrl,
  }) async {
    final fingerprint = await _identity.getDeviceFingerprint();
    final pubKeyPem = await _identity.getPublicKeyPem();

    final message = jsonEncode({
      'type': 'FRIEND_PAIR_ACCEPT',
      'fromUserId': myUserId,
      'fromUsername': myUsername,
      'fromDeviceFp': fingerprint,
      'fromPubKey': pubKeyPem,
      'fromAvatarUrl': myAvatarUrl,
      'toUserId': toUserId,
      'toDeviceFp': toDeviceFp,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });

    print('✅ [QrFriendService] Sending FRIEND_PAIR_ACCEPT to $toUserId');
    return await MeshBridge.send(message);
  }

  /// Send friend pair decline via Bluetooth mesh
  Future<bool> sendFriendPairDecline({
    required String myUserId,
    required String toUserId,
    required String toDeviceFp,
  }) async {
    final fingerprint = await _identity.getDeviceFingerprint();

    final message = jsonEncode({
      'type': 'FRIEND_PAIR_DECLINE',
      'fromUserId': myUserId,
      'fromDeviceFp': fingerprint,
      'toUserId': toUserId,
      'toDeviceFp': toDeviceFp,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });

    print('❌ [QrFriendService] Sending FRIEND_PAIR_DECLINE to $toUserId');
    return await MeshBridge.send(message);
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// DATA MODELS
// ═══════════════════════════════════════════════════════════════════════════

/// Parsed and verified QR payload
class QrPayload {
  final String userId;
  final String username;
  final String deviceFingerprint;
  final String shortFingerprint;
  final String publicKeyPem;
  final DateTime timestamp;
  final String nonce;
  final String? avatarUrl;

  QrPayload({
    required this.userId,
    required this.username,
    required this.deviceFingerprint,
    required this.shortFingerprint,
    required this.publicKeyPem,
    required this.timestamp,
    required this.nonce,
    this.avatarUrl,
  });

  @override
  String toString() => 'QrPayload(@$username, fp:$shortFingerprint)';
}

/// Exception for QR validation errors
class QrValidationException implements Exception {
  final String message;
  QrValidationException(this.message);
  
  @override
  String toString() => 'QrValidationException: $message';
}

/// Result of a friend request attempt
class FriendRequestResult {
  final bool success;
  final String? via;  // 'server' or 'mesh'
  final String? username;
  final String? reason;
  final bool canRetryViaMesh;
  final bool pendingSync;  // Need to sync to server when online
  
  FriendRequestResult._({
    required this.success,
    this.via,
    this.username,
    this.reason,
    this.canRetryViaMesh = false,
    this.pendingSync = false,
  });
  
  /// Request was sent successfully
  factory FriendRequestResult.sent({
    required String via,
    required String username,
    bool pendingSync = false,
  }) => FriendRequestResult._(
    success: true,
    via: via,
    username: username,
    pendingSync: pendingSync,
  );
  
  /// Request failed
  factory FriendRequestResult.failed({
    required String reason,
    bool canRetryViaMesh = false,
  }) => FriendRequestResult._(
    success: false,
    reason: reason,
    canRetryViaMesh: canRetryViaMesh,
  );
  
  @override
  String toString() => success 
    ? 'FriendRequestResult.sent(via: $via, to: $username)'
    : 'FriendRequestResult.failed(reason: $reason)';
}
