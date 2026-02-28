import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// IdentityService - Manages peer identities and public key verification
/// 
/// Maps displayName (public key fingerprint) to userId and publicKey
/// Verifies that peers are who they claim to be
class IdentityService extends ChangeNotifier {
  static final IdentityService instance = IdentityService._();
  IdentityService._();
  
  // Map: displayName -> UserIdentity
  final Map<String, UserIdentity> _knownIdentities = {};
  
  // Map: userId -> displayName (reverse lookup)
  final Map<String, String> _userIdToDisplayName = {};
  
  /// Register a peer's identity
  Future<void> registerIdentity({
    required String userId,
    required String publicKey,
  }) async {
    final displayName = _generateDisplayName(publicKey);
    
    final identity = UserIdentity(
      userId: userId,
      publicKey: publicKey,
      displayName: displayName,
      registeredAt: DateTime.now(),
    );
    
    _knownIdentities[displayName] = identity;
    _userIdToDisplayName[userId] = displayName;
    
    print('✅ Registered identity: $displayName -> $userId');
    notifyListeners();
  }
  
  /// Verify a peer's identity claim
  bool verifyPeer({
    required String displayName,
    required String claimedUserId,
    required String publicKey,
  }) {
    // Check if displayName matches public key
    final expectedDisplayName = _generateDisplayName(publicKey);
    if (displayName != expectedDisplayName) {
      print('⚠️ DisplayName mismatch: $displayName != $expectedDisplayName');
      return false;
    }
    
    // Check if we've seen this identity before
    if (_knownIdentities.containsKey(displayName)) {
      final known = _knownIdentities[displayName]!;
      
      // Verify userId matches
      if (known.userId != claimedUserId) {
        print('⚠️ UserId mismatch for $displayName');
        return false;
      }
      
      // Verify public key matches
      if (known.publicKey != publicKey) {
        print('⚠️ Public key mismatch for $displayName');
        return false;
      }
    }
    
    return true;
  }
  
  /// Get userId from displayName
  String? getUserId(String displayName) {
    return _knownIdentities[displayName]?.userId;
  }
  
  /// Get displayName from userId
  String? getDisplayName(String userId) {
    return _userIdToDisplayName[userId];
  }
  
  /// Get public key for userId
  String? getPublicKey(String userId) {
    final displayName = _userIdToDisplayName[userId];
    if (displayName == null) return null;
    return _knownIdentities[displayName]?.publicKey;
  }
  
  /// Check if identity is known
  bool isKnown(String displayName) {
    return _knownIdentities.containsKey(displayName);
  }
  
  /// Generate displayName from public key (fingerprint)
  String _generateDisplayName(String publicKeyPem) {
    final hash = sha256.convert(utf8.encode(publicKeyPem));
    return hash.toString().substring(0, 16);
  }
  
  /// Get all known identities
  List<UserIdentity> getAllIdentities() {
    return _knownIdentities.values.toList();
  }
  
  /// Remove an identity (e.g., after blocking)
  void removeIdentity(String displayName) {
    final identity = _knownIdentities.remove(displayName);
    if (identity != null) {
      _userIdToDisplayName.remove(identity.userId);
      print('🗑 Removed identity: $displayName');
      notifyListeners();
    }
  }
  
  /// Clear all identities (e.g., on logout)
  void clearAll() {
    _knownIdentities.clear();
    _userIdToDisplayName.clear();
    print('🗑 Cleared all identities');
    notifyListeners();
  }
}

/// UserIdentity - Represents a verified peer identity
class UserIdentity {
  final String userId;
  final String publicKey;
  final String displayName;
  final DateTime registeredAt;
  
  UserIdentity({
    required this.userId,
    required this.publicKey,
    required this.displayName,
    required this.registeredAt,
  });
  
  Map<String, dynamic> toJson() => {
    'userId': userId,
    'publicKey': publicKey,
    'displayName': displayName,
    'registeredAt': registeredAt.toIso8601String(),
  };
  
  factory UserIdentity.fromJson(Map<String, dynamic> json) {
    return UserIdentity(
      userId: json['userId'] as String,
      publicKey: json['publicKey'] as String,
      displayName: json['displayName'] as String,
      registeredAt: DateTime.parse(json['registeredAt'] as String),
    );
  }
}
