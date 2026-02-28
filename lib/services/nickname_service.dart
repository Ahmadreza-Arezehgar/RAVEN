import 'package:flutter/foundation.dart';
import 'database_helper.dart';
import '../models/contact_model.dart';

/// NicknameService - Local-only nickname management
/// 
/// Nicknames are stored on-device and never synced to server.
/// Display priority: nickname → displayName → username
class NicknameService extends ChangeNotifier {
  static final NicknameService _instance = NicknameService._internal();
  static NicknameService get instance => _instance;
  
  NicknameService._internal();
  
  final DatabaseHelper _db = DatabaseHelper.instance;
  
  // In-memory cache for quick lookups
  final Map<String, String> _nicknameCache = {};
  
  /// Initialize cache from database
  Future<void> init() async {
    final contacts = await _db.getAllContacts();
    for (final c in contacts) {
      if (c.nickname != null && c.nickname!.isNotEmpty) {
        _nicknameCache[c.userId] = c.nickname!;
      }
    }
    debugPrint('✅ [NicknameService] Loaded ${_nicknameCache.length} nicknames');
  }
  
  /// Get nickname for a peer (from cache)
  String? getNickname(String peerId) {
    return _nicknameCache[peerId];
  }
  
  /// Set nickname for a peer
  Future<void> setNickname(String peerId, String nickname) async {
    final trimmed = nickname.trim();
    if (trimmed.isEmpty) {
      await removeNickname(peerId);
      return;
    }
    
    // Get contact to find the contact id
    final contact = await _db.getContact(peerId);
    if (contact == null) {
      debugPrint('⚠️ [NicknameService] Contact not found for peerId: $peerId');
      return;
    }
    
    // Update database
    await _db.updateNickname(contact.id, trimmed);
    
    // Update cache
    _nicknameCache[peerId] = trimmed;
    
    debugPrint('✏️ [NicknameService] Set nickname for $peerId: "$trimmed"');
    notifyListeners();
  }
  
  /// Remove nickname for a peer
  Future<void> removeNickname(String peerId) async {
    // Get contact to find the contact id
    final contact = await _db.getContact(peerId);
    if (contact == null) {
      debugPrint('⚠️ [NicknameService] Contact not found for peerId: $peerId');
      return;
    }
    
    // Clear in database
    await _db.updateNickname(contact.id, null);
    
    // Remove from cache
    _nicknameCache.remove(peerId);
    
    debugPrint('🗑 [NicknameService] Removed nickname for $peerId');
    notifyListeners();
  }
  
  /// Check if peer has a nickname
  bool hasNickname(String peerId) {
    return _nicknameCache.containsKey(peerId) && 
           _nicknameCache[peerId]!.isNotEmpty;
  }
  
  /// Resolve display name with priority: nickname → displayName → username
  /// 
  /// Use this method everywhere names are displayed to ensure consistent
  /// nickname application across the app.
  String resolveDisplayName(Contact contact) {
    // Check cache first (most common case)
    final nickname = _nicknameCache[contact.userId];
    if (nickname != null && nickname.isNotEmpty) {
      return nickname;
    }
    
    // Fallback to contact's displayName getter (firstname + lastname or username)
    return contact.displayName;
  }
  
  /// Resolve display name from user data (for cases where we don't have a Contact)
  String resolveDisplayNameFromData({
    required String peerId,
    String? displayName,
    required String username,
  }) {
    final nickname = _nicknameCache[peerId];
    if (nickname != null && nickname.isNotEmpty) {
      return nickname;
    }
    if (displayName != null && displayName.isNotEmpty) {
      return displayName;
    }
    return username;
  }
  
  /// Invalidate cache entry (call when contact is updated externally)
  void invalidateCache(String peerId) {
    _nicknameCache.remove(peerId);
  }
  
  /// Refresh single entry from database
  Future<void> refreshNickname(String peerId) async {
    final contact = await _db.getContact(peerId);
    if (contact != null && contact.nickname != null && contact.nickname!.isNotEmpty) {
      _nicknameCache[peerId] = contact.nickname!;
    } else {
      _nicknameCache.remove(peerId);
    }
    notifyListeners();
  }
}
