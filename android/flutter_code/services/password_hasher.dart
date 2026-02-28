import 'package:crypto/crypto.dart';
import 'dart:convert';

/// Password hashing utility using SHA-256
class PasswordHasher {
  /// Hash a password using SHA-256
  static String hash(String password) {
    final bytes = utf8.encode(password);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }
  
  /// Verify a password against a hash
  static bool verify(String password, String hash) {
    return hashPassword(password) == hash;
  }
  
  /// Hash password (alias for hash for backwards compatibility)
  static String hashPassword(String password) {
    return hash(password);
  }
}
