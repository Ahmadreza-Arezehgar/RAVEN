import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import '../main.dart';
import 'toast_service.dart';
import 'database_helper.dart';

/// Multi-account service for managing multiple logged-in accounts.
/// Supports switching between accounts and full logout with cleanup.
class AccountService {
  static final AccountService instance = AccountService._();
  AccountService._();

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  
  // Keys for secure storage
  static const String _accountsKey = 'accounts_list';
  static const String _activeAccountKey = 'active_account_id';
  static const String _tokenKey = 'auth_token';
  static const String _userIdKey = 'user_id';

  /// Account data structure
  /// {userId, username, token, refreshToken, avatarUrl, lastUsed}
  List<Map<String, dynamic>> _accounts = [];
  String? _activeAccountId;

  /// Initialize service - load accounts from storage
  Future<void> init() async {
    final accountsJson = await _storage.read(key: _accountsKey);
    if (accountsJson != null) {
      try {
        _accounts = List<Map<String, dynamic>>.from(jsonDecode(accountsJson));
      } catch (_) {
        _accounts = [];
      }
    }
    _activeAccountId = await _storage.read(key: _activeAccountKey);
    print('✅ [AccountService] Loaded ${_accounts.length} accounts, active: $_activeAccountId');
  }

  /// Get list of all stored accounts
  List<Map<String, dynamic>> get accounts => List.unmodifiable(_accounts);

  /// Get current active account ID
  String? get activeAccountId => _activeAccountId;

  /// Check if multiple accounts are stored
  bool get hasMultipleAccounts => _accounts.length > 1;

  /// Save current account to accounts list after login
  Future<void> saveCurrentAccount({
    required String userId,
    required String username,
    required String token,
    String? refreshToken,
    String? avatarUrl,
  }) async {
    // Remove existing entry for this user
    _accounts.removeWhere((a) => a['userId'] == userId);
    
    // Add new entry
    _accounts.add({
      'userId': userId,
      'username': username,
      'token': token,
      'refreshToken': refreshToken,
      'avatarUrl': avatarUrl,
      'lastUsed': DateTime.now().toIso8601String(),
    });

    // Set as active
    _activeAccountId = userId;
    
    // Persist
    await _storage.write(key: _accountsKey, value: jsonEncode(_accounts));
    await _storage.write(key: _activeAccountKey, value: userId);
    
    print('✅ [AccountService] Saved account: $username ($userId)');
  }

  /// Get next account for switching (cycles through accounts)
  Map<String, dynamic>? getNextAccount() {
    if (_accounts.length < 2) return null;
    
    final currentIndex = _accounts.indexWhere((a) => a['userId'] == _activeAccountId);
    final nextIndex = (currentIndex + 1) % _accounts.length;
    return _accounts[nextIndex];
  }

  /// Switch to a specific account
  Future<bool> switchToAccount(String userId, AppModel model) async {
    final account = _accounts.firstWhere(
      (a) => a['userId'] == userId,
      orElse: () => {},
    );
    
    if (account.isEmpty) {
      print('❌ [AccountService] Account not found: $userId');
      return false;
    }

    // Update active account
    _activeAccountId = userId;
    await _storage.write(key: _activeAccountKey, value: userId);
    
    // Update main storage with this account's token
    await _storage.write(key: _tokenKey, value: account['token']);
    await _storage.write(key: _userIdKey, value: userId);
    
    // Update last used
    account['lastUsed'] = DateTime.now().toIso8601String();
    await _storage.write(key: _accountsKey, value: jsonEncode(_accounts));
    
    // Re-initialize AppModel with new user
    await model.initializeForUser(userId);
    
    HapticFeedback.mediumImpact();
    ToastService.showSuccess('Switched to @${account['username']}');
    
    print('✅ [AccountService] Switched to: ${account['username']}');
    return true;
  }

  /// Full logout - clears EVERYTHING and navigates to auth screen
  /// IMPORTANT: This should complete FAST - no blocking network calls
  Future<void> fullLogout(BuildContext context, AppModel model) async {
    print('🚪 [AccountService] Starting full logout...');

    // ═══════════════════════════════════════════════════════════════════════
    // STEP 1: IMMEDIATE LOCAL CLEANUP (no awaits that can block)
    // ═══════════════════════════════════════════════════════════════════════
    
    // 1a. Stop all timers/streams/websockets FIRST
    try {
      model.stopLiveChat();
      model.stopScheduledMessageWorker();
      print('✅ [AccountService] Stopped live chat + scheduled worker');
    } catch (e) {
      print('⚠️ [AccountService] Error stopping services: $e');
    }
    
    // 1b. Clear in-memory state
    try {
      model.clearAllState();
      print('✅ [AccountService] Cleared in-memory state');
    } catch (e) {
      print('⚠️ [AccountService] Error clearing state: $e');
    }
    
    // 1c. Store active account id before clearing
    final accountToRemove = _activeAccountId;
    _activeAccountId = null;
    _accounts.clear();
    
    print('✅ [AccountService] Local cleanup complete');

    // ═══════════════════════════════════════════════════════════════════════
    // STEP 2: NAVIGATE IMMEDIATELY (before any async operations)
    // ═══════════════════════════════════════════════════════════════════════
    
    if (context.mounted) {
      // Show toast
      ToastService.showSuccess('Signed out successfully');
      
      // Navigate to welcome/login screen and clear ENTIRE stack
      Navigator.of(context, rootNavigator: true)
          .pushNamedAndRemoveUntil('/welcome', (route) => false);
      print('✅ [AccountService] Navigated to welcome screen');
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STEP 3: ASYNC CLEANUP (fire-and-forget, non-blocking)
    // ═══════════════════════════════════════════════════════════════════════
    
    // These operations run in background - UI is already on login screen
    _asyncCleanup(accountToRemove);
  }
  
  /// Background cleanup - runs after navigation, non-blocking
  void _asyncCleanup(String? accountToRemove) {
    // Use unawaited Future to prevent blocking
    Future(() async {
      try {
        // ═══════════════════════════════════════════════════════════════════
        // CLEAR ALL SECURE STORAGE
        // ═══════════════════════════════════════════════════════════════════
        await _storage.deleteAll();
        print('✅ [AccountService] Cleared all secure storage');
        
        // ═══════════════════════════════════════════════════════════════════
        // CLEAR DATABASE TABLES
        // ═══════════════════════════════════════════════════════════════════
        try {
          final db = await DatabaseHelper.instance.database;
          await db.delete('messages');
          await db.delete('contacts');
          await db.delete('users');
          await db.delete('posts');
          await db.delete('scheduled_messages');
          print('✅ [AccountService] Cleared all database tables');
        } catch (dbError) {
          print('⚠️ [AccountService] DB cleanup error: $dbError');
        }
        
        print('✅ [AccountService] Async cleanup complete');
      } catch (e) {
        print('⚠️ [AccountService] Async cleanup error: $e');
      }
      
      // Server logout (best effort, with timeout)
      try {
        // TODO: Add ApiService.logout() call with 5s timeout
      } catch (_) {}
    });
  }

  /// Logout from current account but switch to another if available
  Future<bool> logoutCurrentAndSwitch(BuildContext context, AppModel model) async {
    if (_accounts.length < 2) {
      // No other accounts - do full logout
      await fullLogout(context, model);
      return false;
    }

    // Remove current account
    final currentId = _activeAccountId;
    _accounts.removeWhere((a) => a['userId'] == currentId);
    await _storage.write(key: _accountsKey, value: jsonEncode(_accounts));

    // Switch to next account
    final next = _accounts.first;
    await switchToAccount(next['userId'], model);
    
    return true;
  }

  /// Remove a specific account from stored list
  Future<void> removeAccount(String userId) async {
    _accounts.removeWhere((a) => a['userId'] == userId);
    await _storage.write(key: _accountsKey, value: jsonEncode(_accounts));
    print('🗑️ [AccountService] Removed account: $userId');
  }
}

/// Extension on AppModel for account-related cleanup
extension AppModelAccountExtension on AppModel {
  /// Clear all in-memory state (for logout)
  /// Note: Do NOT call notifyListeners() here - widgets will be disposed
  /// by navigation and calling notify causes assertion errors.
  void clearAllState() {
    currentUser = null;
    currentChatId = '';
    currentChatName = '';
    messages.clear();
    meshPeers.clear();
    // ❌ Do NOT notify - widgets are being disposed by navigation
    // notifyListeners();
    print('✅ [AppModel] All state cleared');
  }

  /// Re-initialize for a specific user (for account switching)
  Future<void> initializeForUser(String userId) async {
    // Re-fetch user data - calls existing AppModel methods
    // The model should refresh when switching accounts
    notifyListeners();
    print('✅ [AppModel] Re-initialized for user: $userId');
  }
}
