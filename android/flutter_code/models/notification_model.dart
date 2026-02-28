import 'package:flutter/foundation.dart';

/// نوع notification
enum NotificationType {
  message,           // پیام جدید
  friendRequest,     // درخواست دوستی (receiver)
  friendRequestSent, // درخواست دوستی ارسال شده (sender)
  mention,           // mention شدن در پست
  like,              // لایک شدن پست
  comment,           // کامنت روی پست
  presence,          // ✅ Mesh: Someone checked in nearby
  deadDrop,          // ✅ Mesh: New dead drop discovered
  security,          // 🔐 Security events (login, password change)
}

/// Notification Model
class AppNotification {
  final String id;
  final NotificationType type;
  final String title;
  final String body;
  final String? avatarPath;
  final String? userId;
  final DateTime timestamp;
  final bool isRead;
  final Map<String, dynamic>? data; // برای اطلاعات اضافی
  
  AppNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    this.avatarPath,
    this.userId,
    required this.timestamp,
    this.isRead = false,
    this.data,
  });
  
  /// Copy with
  AppNotification copyWith({
    String? id,
    NotificationType? type,
    String? title,
    String? body,
    String? avatarPath,
    String? userId,
    DateTime? timestamp,
    bool? isRead,
    Map<String, dynamic>? data,
  }) {
    return AppNotification(
      id: id ?? this.id,
      type: type ?? this.type,
      title: title ?? this.title,
      body: body ?? this.body,
      avatarPath: avatarPath ?? this.avatarPath,
      userId: userId ?? this.userId,
      timestamp: timestamp ?? this.timestamp,
      isRead: isRead ?? this.isRead,
      data: data ?? this.data,
    );
  }
  
  /// To JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type.index,
      'title': title,
      'body': body,
      'avatarPath': avatarPath,
      'userId': userId,
      'timestamp': timestamp.toIso8601String(),
      'isRead': isRead,
      'data': data,
    };
  }
  
  /// From JSON
  factory AppNotification.fromJson(Map<String, dynamic> json) {
    return AppNotification(
      id: json['id'] as String,
      type: NotificationType.values[json['type'] as int],
      title: json['title'] as String,
      body: json['body'] as String,
      avatarPath: json['avatarPath'] as String?,
      userId: json['userId'] as String?,
      timestamp: DateTime.parse(json['timestamp'] as String),
      isRead: json['isRead'] as bool? ?? false,
      data: json['data'] as Map<String, dynamic>?,
    );
  }
}

/// Notification Service for managing notifications
class NotificationService extends ChangeNotifier {
  final List<AppNotification> _notifications = [];
  
  List<AppNotification> get notifications => List.unmodifiable(_notifications);
  
  int get unreadCount => _notifications.where((n) => !n.isRead).length;
  
  /// اضافه کردن notification جدید
  void addNotification(AppNotification notification) {
    _notifications.insert(0, notification); // جدیدترین اول
    notifyListeners();
  }
  
  /// Mark as read
  void markAsRead(String id) {
    final index = _notifications.indexWhere((n) => n.id == id);
    if (index != -1) {
      _notifications[index] = _notifications[index].copyWith(isRead: true);
      notifyListeners();
    }
  }
  
  /// Mark all as read
  void markAllAsRead() {
    for (int i = 0; i < _notifications.length; i++) {
      _notifications[i] = _notifications[i].copyWith(isRead: true);
    }
    notifyListeners();
  }
  
  /// حذف notification
  void removeNotification(String id) {
    _notifications.removeWhere((n) => n.id == id);
    notifyListeners();
  }
  
  /// Clear all
  void clearAll() {
    _notifications.clear();
    notifyListeners();
  }
}
