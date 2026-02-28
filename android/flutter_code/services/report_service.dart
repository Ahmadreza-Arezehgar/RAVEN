import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Service for submitting reports and managing blocks via server API.
class ReportService {
  static final ReportService instance = ReportService._();
  ReportService._();

  // Use same base URL as ApiService
  static const String _baseUrl = 'https://raven-server-5iwa2y5n3a-ww.a.run.app';
  static const _storage = FlutterSecureStorage();

  /// Get headers with auth token
  Future<Map<String, String>> get _headers async {
    final token = await _storage.read(key: 'jwt_token');
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  /// Submit a report for a user, post, or message.
  Future<bool> submitReport({
    required String targetType,
    required String targetId,
    required String reason,
    String? note,
  }) async {
    try {
      final headers = await _headers;
      final response = await http.post(
        Uri.parse('$_baseUrl/reports/'),
        headers: headers,
        body: jsonEncode({
          'target_type': targetType,
          'target_id': targetId,
          'reason': reason,
          'note': note,
        }),
      );
      
      if (response.statusCode == 201) {
        print('✅ [Report] Submitted: $targetType/$targetId - $reason');
        return true;
      } else {
        print('❌ [Report] Failed: ${response.statusCode} ${response.body}');
        return false;
      }
    } catch (e) {
      print('❌ [Report] Error: $e');
      return false;
    }
  }

  /// Block a user
  Future<bool> blockUser(String userId) async {
    try {
      final headers = await _headers;
      final response = await http.post(
        Uri.parse('$_baseUrl/blocks/'),
        headers: headers,
        body: jsonEncode({'blocked_id': userId}),
      );
      
      if (response.statusCode == 201) {
        print('✅ [Block] Blocked user: $userId');
        return true;
      } else {
        print('❌ [Block] Failed: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      print('❌ [Block] Error: $e');
      return false;
    }
  }

  /// Unblock a user
  Future<bool> unblockUser(String userId) async {
    try {
      final headers = await _headers;
      final response = await http.delete(
        Uri.parse('$_baseUrl/blocks/$userId'),
        headers: headers,
      );
      
      if (response.statusCode == 200) {
        print('✅ [Unblock] Unblocked user: $userId');
        return true;
      } else {
        print('❌ [Unblock] Failed: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      print('❌ [Unblock] Error: $e');
      return false;
    }
  }

  /// Get blocked users list
  Future<List<Map<String, dynamic>>> getBlockedUsers() async {
    try {
      final headers = await _headers;
      final response = await http.get(
        Uri.parse('$_baseUrl/blocks/'),
        headers: headers,
      );
      
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.cast<Map<String, dynamic>>();
      }
      return [];
    } catch (e) {
      print('❌ [Block] Error getting blocked users: $e');
      return [];
    }
  }
}
