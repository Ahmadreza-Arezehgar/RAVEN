import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'crypto_service.dart';

/// DeviceIdentityService - Manages device identity and public key fingerprints
/// 
/// This service handles:
/// - Device fingerprint generation (SHA256 of public key)
/// - Public key retrieval for mesh networking
/// - Identity verification for pairing
class DeviceIdentityService {
  static final DeviceIdentityService instance = DeviceIdentityService._();
  DeviceIdentityService._();
  
  final _crypto = CryptoService.instance;
  final _storage = const FlutterSecureStorage();
  
  String? _cachedFingerprint;
  
  /// Get device fingerprint (SHA256 hash of public key)
  /// This is used as the unique identifier for mesh networking
  Future<String> getDeviceFingerprint() async {
    // Return cached value if available
    if (_cachedFingerprint != null) {
      return _cachedFingerprint!;
    }
    
    // Get or generate public key
    var publicKey = await _crypto.getPublicKey();
    
    if (publicKey == null) {
      // First run: generate keypair
      print('🔑 [Identity] Generating new device keypair...');
      final keypair = await _crypto.generateKeyPair();
      await _crypto.storePrivateKey(keypair.privateKey as RSAPrivateKey);
      await _crypto.storePublicKey(keypair.publicKey as RSAPublicKey);
      publicKey = keypair.publicKey as RSAPublicKey;
    }
    
    // Generate fingerprint from public key
    final pem = _crypto.publicKeyToPem(publicKey);
    final hash = sha256.convert(utf8.encode(pem));
    final fingerprint = hash.toString();
    
    _cachedFingerprint = fingerprint;
    
    print('✅ [Identity] Device fingerprint: ${fingerprint.substring(0, 16)}...');
    return fingerprint;
  }
  
  /// Get public key in PEM format for sharing with peers
  Future<String> getPublicKeyPem() async {
    var publicKey = await _crypto.getPublicKey();
    
    if (publicKey == null) {
      // Generate if doesn't exist
      await getDeviceFingerprint(); // This will generate the keypair
      publicKey = await _crypto.getPublicKey();
    }
    
    return _crypto.publicKeyToPem(publicKey!);
  }
  
  /// Verify that a fingerprint matches a given public key
  /// Used during peer pairing to prevent spoofing
  bool verifyFingerprint(String publicKeyPem, String claimedFingerprint) {
    try {
      final hash = sha256.convert(utf8.encode(publicKeyPem));
      final actualFingerprint = hash.toString();
      
      final matches = actualFingerprint == claimedFingerprint;
      
      if (!matches) {
        print('⚠️ [Identity] Fingerprint mismatch!');
        print('   Claimed: ${claimedFingerprint.substring(0, 16)}...');
        print('   Actual:  ${actualFingerprint.substring(0, 16)}...');
      }
      
      return matches;
    } catch (e) {
      print('❌ [Identity] Fingerprint verification failed: $e');
      return false;
    }
  }
  
  /// Format fingerprint for display (human-readable)
  /// Example: A1B2-C3D4-E5F6-...
  String formatFingerprintForDisplay(String fingerprint) {
    if (fingerprint.length < 16) return fingerprint;
    
    final groups = <String>[];
    for (var i = 0; i < 16; i += 4) {
      groups.add(fingerprint.substring(i, i + 4).toUpperCase());
    }
    
    return '${groups.join('-')}...';
  }
  
  /// Get short fingerprint (first 8 chars) for quick verification
  String getShortFingerprint(String fingerprint) {
    return fingerprint.substring(0, 8).toUpperCase();
  }
  
  /// Clear cached fingerprint (e.g., after key regeneration)
  void clearCache() {
    _cachedFingerprint = null;
  }
  
  /// Generate a challenge for peer verification
  /// Returns a random nonce that the peer must sign
  String generateChallenge() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = DateTime.now().microsecondsSinceEpoch;
    return '$timestamp-$random';
  }
  
  /// Sign a challenge with device's private key
  Future<String?> signChallenge(String challenge) async {
    try {
      final privateKey = await _crypto.getPrivateKey();
      if (privateKey == null) {
        print('❌ [Identity] No private key available for signing');
        return null;
      }
      
      final signature = _crypto.signMessage(challenge, privateKey);
      return signature;
    } catch (e) {
      print('❌ [Identity] Challenge signing failed: $e');
      return null;
    }
  }
  
  /// Verify a challenge signature from a peer
  Future<bool> verifyChallenge(
    String challenge,
    String signature,
    String publicKeyPem,
  ) async {
    try {
      final publicKey = _crypto.pemToPublicKey(publicKeyPem);
      return _crypto.verifySignature(challenge, signature, publicKey);
    } catch (e) {
      print('❌ [Identity] Challenge verification failed: $e');
      return false;
    }
  }
}
