import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:intl/intl.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../main.dart';
import '../theme/ios_design_system.dart';
import '../services/api_service.dart';

/// Model for screenshot notification
class ScreenshotNotification {
  final String id;
  final String screenshotterUsername;
  final String? screenshotterAvatar;
  final DateTime timestamp;
  final bool isRead;
  
  ScreenshotNotification({
    required this.id,
    required this.screenshotterUsername,
    this.screenshotterAvatar,
    required this.timestamp,
    required this.isRead,
  });
  
  factory ScreenshotNotification.fromJson(Map<String, dynamic> json) {
    return ScreenshotNotification(
      id: json['id'] as String,
      screenshotterUsername: json['screenshotter_username'] as String,
      screenshotterAvatar: json['screenshotter_avatar'] as String?,
      timestamp: DateTime.parse(json['timestamp'] as String),
      isRead: json['is_read'] as bool,
    );
  }
}

/// Page to display screenshot notification history
class ScreenshotNotificationsPage extends StatefulWidget {
  const ScreenshotNotificationsPage({super.key});

  @override
  State<ScreenshotNotificationsPage> createState() => _ScreenshotNotificationsPageState();
}

class _ScreenshotNotificationsPageState extends State<ScreenshotNotificationsPage> {

  List<ScreenshotNotification> _notifications = [];
  bool _isLoading = true;
  String? _error;
  
  @override
  void initState() {
    super.initState();
    _fetchNotifications();
  }
  
  Future<void> _fetchNotifications({bool markAsRead = false}) async {
    try {
      final url = Uri.parse('${ApiService.baseUrl}/api/users/screenshot-notifications?mark_as_read=$markAsRead');
      final response = await http.get(
        url,
        headers: {
          'Authorization': 'Bearer ', // TODO: Add proper auth token management
        },
      );
      
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        setState(() {
          _notifications = data.map((json) => ScreenshotNotification.fromJson(json)).toList();
          _isLoading = false;
          _error = null;
        });
      } else {
        setState(() {
          _error = 'Failed to load notifications';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Error: $e';
        _isLoading = false;
      });
    }
  }
  
  String _formatTimestamp(DateTime timestamp) {
    final now = DateTime.now();
    final difference = now.difference(timestamp);
    
    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inHours < 1) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inDays < 1) {
      return '${difference.inHours}h ago';
    } else if (difference.inDays < 7) {
      return '${difference.inDays}d ago';
    } else {
      return DateFormat('MMM d, y').format(timestamp);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: iOSDesignSystem.baseBackground,
      appBar: AppBar(
        title: const Text('Screenshot Alerts'),
        backgroundColor: iOSDesignSystem.baseBackground,
        elevation: 0,
        actions: [
          if (_notifications.isNotEmpty && _notifications.any((n) => !n.isRead))
            TextButton(
              onPressed: () => _fetchNotifications(markAsRead: true),
              child: const Text('Mark all read'),
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
              : _notifications.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.camera_alt_outlined,
                            size: 64,
                            color: iOSDesignSystem.textSecondary,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No screenshot alerts',
                            style: iOSDesignSystem.textTheme.bodyLarge?.copyWith(
                              color: iOSDesignSystem.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: () => _fetchNotifications(),
                      child: ListView.builder(
                        itemCount: _notifications.length,
                        itemBuilder: (context, index) {
                          final notification = _notifications[index];
                          return Container(
                            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            decoration: BoxDecoration(
                              color: notification.isRead
                                  ? iOSDesignSystem.surfaceCard
                                  : iOSDesignSystem.accentBlue.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: iOSDesignSystem.glassBorderMedium,
                                width: iOSDesignSystem.glassBorderWidth,
                              ),
                            ),
                            child: ListTile(
                              leading: notification.screenshotterAvatar != null
                                  ? CircleAvatar(
                                      backgroundImage: CachedNetworkImageProvider(
                                        '${ApiService.baseUrl}${notification.screenshotterAvatar}',
                                      ),
                                    )
                                  : CircleAvatar(
                                      backgroundColor: iOSDesignSystem.accentBlue.withOpacity(0.2),
                                      child: Text(
                                        notification.screenshotterUsername[0].toUpperCase(),
                                        style: const TextStyle(
                                          color: iOSDesignSystem.accentBlue,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                              title: RichText(
                                text: TextSpan(
                                  style: iOSDesignSystem.textTheme.bodyMedium,
                                  children: [
                                    TextSpan(
                                      text: notification.screenshotterUsername,
                                      style: const TextStyle(fontWeight: FontWeight.bold),
                                    ),
                                    const TextSpan(text: ' took a screenshot of your profile'),
                                  ],
                                ),
                              ),
                              subtitle: Text(
                                _formatTimestamp(notification.timestamp),
                                style: iOSDesignSystem.textTheme.bodySmall?.copyWith(
                                  color: iOSDesignSystem.textSecondary,
                                ),
                              ),
                              trailing: const Icon(
                                Icons.camera_alt,
                                color: iOSDesignSystem.accentBlue,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}
