import 'package:flutter/foundation.dart';

/// Badge state provider for bottom navigation tabs
/// Manages badge counts for Home, Messages, Search, and Account tabs
class BadgeState extends ChangeNotifier {
  int _home = 0;
  int _messages = 0;
  int _account = 0;
  
  // Optional: per-segment badges inside Home
  int _localFeed = 0;
  int _friendsFeed = 0;
  
  // Getters
  int get home => _home;
  int get messages => _messages;
  int get account => _account;
  int get localFeed => _localFeed;
  int get friendsFeed => _friendsFeed;
  
  /// Format count for display (0 = hidden, >9999 = "9999+")
  String format(int n) {
    if (n <= 0) return '';
    if (n > 9999) return '9999+';
    return '$n';
  }
  
  // ══════════════════════════════════════════════════════════════
  // HOME BADGE
  // ══════════════════════════════════════════════════════════════
  void setHome(int n) {
    if (_home == n) return;
    _home = n;
    notifyListeners();
  }
  
  void incrementHome([int by = 1]) {
    _home += by;
    notifyListeners();
  }
  
  void clearHome() {
    if (_home == 0) return;
    _home = 0;
    notifyListeners();
  }
  
  // ══════════════════════════════════════════════════════════════
  // MESSAGES BADGE
  // ══════════════════════════════════════════════════════════════
  void setMessages(int n) {
    if (_messages == n) return;
    _messages = n;
    notifyListeners();
  }
  
  void incrementMessages([int by = 1]) {
    _messages += by;
    notifyListeners();
  }
  
  void clearMessages() {
    if (_messages == 0) return;
    _messages = 0;
    notifyListeners();
  }
  
  // ══════════════════════════════════════════════════════════════
  // ACCOUNT BADGE (Security alerts, notices)
  // ══════════════════════════════════════════════════════════════
  void setAccount(int n) {
    if (_account == n) return;
    _account = n;
    notifyListeners();
  }
  
  void incrementAccount([int by = 1]) {
    _account += by;
    notifyListeners();
  }
  
  void clearAccount() {
    if (_account == 0) return;
    _account = 0;
    notifyListeners();
  }
  
  // ══════════════════════════════════════════════════════════════
  // PER-SEGMENT BADGES (Local/Friends inside Home)
  // ══════════════════════════════════════════════════════════════
  void setLocalFeed(int n) {
    if (_localFeed == n) return;
    _localFeed = n;
    notifyListeners();
  }
  
  void setFriendsFeed(int n) {
    if (_friendsFeed == n) return;
    _friendsFeed = n;
    notifyListeners();
  }
  
  void clearLocalFeed() {
    if (_localFeed == 0) return;
    _localFeed = 0;
    notifyListeners();
  }
  
  void clearFriendsFeed() {
    if (_friendsFeed == 0) return;
    _friendsFeed = 0;
    notifyListeners();
  }
  
  // ══════════════════════════════════════════════════════════════
  // BULK UPDATE (from /counts API)
  // ══════════════════════════════════════════════════════════════
  void updateFromServer({
    int? unreadMessages,
    int? newLocalPosts,
    int? newFriendPosts,
    int? securityAlerts,
  }) {
    bool changed = false;
    
    if (unreadMessages != null && _messages != unreadMessages) {
      _messages = unreadMessages;
      changed = true;
    }
    
    if (newLocalPosts != null && _localFeed != newLocalPosts) {
      _localFeed = newLocalPosts;
      changed = true;
    }
    
    if (newFriendPosts != null && _friendsFeed != newFriendPosts) {
      _friendsFeed = newFriendPosts;
      changed = true;
    }
    
    if (securityAlerts != null && _account != securityAlerts) {
      _account = securityAlerts;
      changed = true;
    }
    
    // Home = local + friends
    final newHome = _localFeed + _friendsFeed;
    if (_home != newHome) {
      _home = newHome;
      changed = true;
    }
    
    if (changed) notifyListeners();
  }
}
