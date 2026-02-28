import 'dart:convert';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/message_model.dart';

/// CryptoService - Handles E2EE, signing, and key management
class CryptoService {
  static final CryptoService instance = CryptoService._();
  CryptoService._();
  
  final _storage = const FlutterSecureStorage();
  
  // === KEY GENERATION ===
  
  /// Generate RSA key pair for E2EE
  Future<AsymmetricKeyPair<PublicKey, PrivateKey>> generateKeyPair() async {
    final keyGen = RSAKeyGenerator()
      ..init(ParametersWithRandom(
        RSAKeyGeneratorParameters(BigInt.parse('65537'), 2048, 64),
        FortunaRandom()..seed(KeyParameter(_randomBytes(32))),
      ));
    
    return keyGen.generateKeyPair();
  }
  
  /// Store private key in iOS Keychain
  Future<void> storePrivateKey(RSAPrivateKey key) async {
    final pem = privateKeyToPem(key);
    await _storage.write(
      key: 'rsa_private_key',
      value: pem,
    );
  }
  
  /// Retrieve private key from Keychain
  Future<RSAPrivateKey?> getPrivateKey() async {
    final pem = await _storage.read(key: 'rsa_private_key');
    if (pem == null) return null;
    return pemToPrivateKey(pem);
  }
  
  /// Store public key (can be stored in DB)
  Future<void> storePublicKey(RSAPublicKey key) async {
    final pem = publicKeyToPem(key);
    await _storage.write(key: 'rsa_public_key', value: pem);
  }
  
  /// Get public key
  Future<RSAPublicKey?> getPublicKey() async {
    final pem = await _storage.read(key: 'rsa_public_key');
    if (pem == null) return null;
    return pemToPublicKey(pem);
  }
  
  // === E2EE MESSAGE ENCRYPTION ===
  
  /// Encrypt message with receiver's public key
  String encryptMessage(String plaintext, RSAPublicKey receiverPublicKey) {
    // Generate random AES key
    final aesKey = _randomBytes(32);
    
    // Encrypt message with AES
    final encryptedContent = _encryptAES(plaintext, aesKey);
    
    // Encrypt AES key with RSA
    final encryptedKey = _encryptRSA(aesKey, receiverPublicKey);
    
    // Return combined
    return jsonEncode({
      'content': base64Encode(encryptedContent),
      'key': base64Encode(encryptedKey),
    });
  }
  
  /// Decrypt message with private key
  String decryptMessage(String encrypted, RSAPrivateKey privateKey) {
    final data = jsonDecode(encrypted);
    
    // Decrypt AES key with RSA
    final encryptedKey = base64Decode(data['key']);
    final aesKey = _decryptRSA(encryptedKey, privateKey);
    
    // Decrypt content with AES
    final encryptedContent = base64Decode(data['content']);
    return _decryptAES(encryptedContent, aesKey);
  }
  
  // === MESSAGE SIGNING ===
  
  /// Sign message hash to prevent tampering
  String signMessage(String message, RSAPrivateKey privateKey) {
    final hash = sha256.convert(utf8.encode(message)).bytes;
    final signer = RSASigner(SHA256Digest(), '0609608648016503040201');
    signer.init(true, PrivateKeyParameter<RSAPrivateKey>(privateKey));
    
    final signature = signer.generateSignature(Uint8List.fromList(hash));
    return base64Encode(signature.bytes);
  }
  
  /// Verify message signature
  bool verifySignature(String message, String signature, RSAPublicKey publicKey) {
    try {
      final hash = sha256.convert(utf8.encode(message)).bytes;
      final sig = RSASignature(base64Decode(signature));
      
      final verifier = RSASigner(SHA256Digest(), '0609608648016503040201');
      verifier.init(false, PublicKeyParameter<RSAPublicKey>(publicKey));
      
      return verifier.verifySignature(Uint8List.fromList(hash), sig);
    } catch (e) {
      return false;
    }
  }
  
  // === HMAC MESSAGE AUTHENTICATION (for DTN Mesh) ===
  
  /// Generate HMAC signature for mesh message
  /// Used to prevent tampering and verify message authenticity in mesh network
  String generateMessageHMAC(ChatMessage msg, String sharedSecret) {
    // Create canonical representation of message for signing
    final canonical = _getCanonicalMessageData(msg);
    
    // Generate HMAC-SHA256
    final key = utf8.encode(sharedSecret);
    final bytes = utf8.encode(canonical);
    final hmac = Hmac(sha256, key);
    final digest = hmac.convert(bytes);
    
    return base64Encode(digest.bytes);
  }
  
  /// Verify HMAC signature for mesh message
  bool verifyMessageHMAC(ChatMessage msg, String signature, String sharedSecret) {
    try {
      final expectedSignature = generateMessageHMAC(msg, sharedSecret);
      return expectedSignature == signature;
    } catch (e) {
      print('❌ [CryptoService] HMAC verification failed: $e');
      return false;
    }
  }
  
  /// Create canonical message representation for signing
  /// This ensures consistent signing regardless of field order
  String _getCanonicalMessageData(ChatMessage msg) {
    return [
      msg.id,
      msg.senderId,
      msg.recipientId,
      msg.text,
      msg.timestamp.toIso8601String(),
      msg.originDeviceId ?? '',
    ].join('|');
  }
  
  // === UTILITIES ===
  
  Uint8List _randomBytes(int length) {
    final random = SecureRandom('Fortuna');
    final seeds = List<int>.generate(32, (_) => DateTime.now().millisecondsSinceEpoch % 256);
    random.seed(KeyParameter(Uint8List.fromList(seeds)));
    return random.nextBytes(length);
  }
  
  Uint8List _encryptAES(String plaintext, Uint8List key) {
    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    );
    
    final iv = _randomBytes(16);
    cipher.init(true, PaddedBlockCipherParameters(
      ParametersWithIV(KeyParameter(key), iv),
      null,
    ));
    
    final encrypted = cipher.process(Uint8List.fromList(utf8.encode(plaintext)));
    return Uint8List.fromList([...iv, ...encrypted]);
  }
  
  String _decryptAES(Uint8List encrypted, Uint8List key) {
    final iv = encrypted.sublist(0, 16);
    final ciphertext = encrypted.sublist(16);
    
    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    );
    
    cipher.init(false, PaddedBlockCipherParameters(
      ParametersWithIV(KeyParameter(key), iv),
      null,
    ));
    
    final decrypted = cipher.process(ciphertext);
    return utf8.decode(decrypted);
  }
  
  Uint8List _encryptRSA(Uint8List data, RSAPublicKey key) {
    final cipher = OAEPEncoding(RSAEngine());
    cipher.init(true, PublicKeyParameter<RSAPublicKey>(key));
    return cipher.process(data);
  }
  
  Uint8List _decryptRSA(Uint8List data, RSAPrivateKey key) {
    final cipher = OAEPEncoding(RSAEngine());
    cipher.init(false, PrivateKeyParameter<RSAPrivateKey>(key));
    return cipher.process(data);
  }
  
  // === PEM CONVERSION ===
  
  String publicKeyToPem(RSAPublicKey key) {
    // Simplified PEM encoding
    final modulus = key.modulus!.toRadixString(16);
    final exponent = key.exponent!.toRadixString(16);
    return 'RSA-PUBLIC:$modulus:$exponent';
  }
  
  RSAPublicKey pemToPublicKey(String pem) {
    final parts = pem.split(':');
    return RSAPublicKey(
      BigInt.parse(parts[1], radix: 16),
      BigInt.parse(parts[2], radix: 16),
    );
  }
  
  String privateKeyToPem(RSAPrivateKey key) {
    final modulus = key.modulus!.toRadixString(16);
    final d = key.privateExponent!.toRadixString(16);
    final p = key.p!.toRadixString(16);
    final q = key.q!.toRadixString(16);
    return 'RSA-PRIVATE:$modulus:$d:$p:$q';
  }
  
  RSAPrivateKey pemToPrivateKey(String pem) {
    final parts = pem.split(':');
    return RSAPrivateKey(
      BigInt.parse(parts[1], radix: 16),
      BigInt.parse(parts[2], radix: 16),
      BigInt.parse(parts[3], radix: 16),
      BigInt.parse(parts[4], radix: 16),
    );
  }
  
  /// Wipe all keys (security breach response)
  Future<void> wipeKeys() async {
    await _storage.delete(key: 'rsa_private_key');
    await _storage.delete(key: 'rsa_public_key');
  }
}
