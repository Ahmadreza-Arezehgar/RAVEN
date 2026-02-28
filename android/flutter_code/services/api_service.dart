import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:dio/dio.dart' as dio_pkg;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/post_model.dart';
import '../models/notification_model.dart';
import '../models/comment.dart';

/// API Service برای ارتباط با Server (WiFi mode)
class ApiService {
  // Local Development Server (Mac IP for iPhone access)
  // static const String baseUrl = 'http://192.168.0.15:8080';
  // Production Server (Cloud Run) - Global access from anywhere
  static const String baseUrl = 'https://raven-server-5iwa2y5n3a-ww.a.run.app';
  static const _storage = FlutterSecureStorage();
  static String? _token;

  /// Get headers with auth token if available  
  static Future<Map<String, String>> get _headers async {
    final token = _token ?? await _storage.read(key: 'jwt_token');
    print('🔑 Token: ${token != null ? "✅ Present" : "❌ Missing"}');
    
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  // ==================== AUTHENTICATION ====================
  
  /// Register new user
  static Future<Map<String, dynamic>> register({
    required String username,
    required String password,
    required String firstName,
    required String lastName,
    required int birthYear,
    String? email,
    String? phone,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/auth/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username,
          'password': password,
          'first_name': firstName,
          'last_name': lastName,
          'birth_year': birthYear,
          if (email != null) 'email': email,
          if (phone != null) 'phone': phone,
        }),
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _token = data['token'];
        if (_token != null) {
          await _storage.write(key: 'jwt_token', value: _token);
          await _storage.write(key: 'user_id', value: data['user_id']);
        }
        return data;
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Registration failed');
      }
    } catch (e) {
      print('❌ Registration failed: $e');
      rethrow;
    }
  }

  /// Login existing user
  static Future<Map<String, dynamic>> login({
    required String username,
    required String password,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/auth/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username,
          'password': password,
        }),
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _token = data['token'];
        if (_token != null) {
          await _storage.write(key: 'jwt_token', value: _token);
          await _storage.write(key: 'user_id', value: data['user_id']);
        }
        return data;
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Invalid username or password');
      }
    } catch (e) {
      print('❌ Login failed: $e');
      rethrow;
    }
  }

  /// OAuth: Sign in with Google
  static Future<Map<String, dynamic>> oauthGoogle({
    required String idToken,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/auth/oauth/google'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'id_token': idToken,
        }),
      );
      
      // Check content type before decoding
      final contentType = response.headers['content-type'] ?? '';
      
      if (response.statusCode == 200) {
        if (!contentType.contains('application/json')) {
          print('❌ Server returned non-JSON response: ${response.body.substring(0, 200)}');
          throw Exception('Server error: Invalid response format');
        }
        final data = jsonDecode(response.body);
        _token = data['token'];
        if (_token != null) {
          await _storage.write(key: 'jwt_token', value: _token);
        }
        return data;
      } else {
        // Log full error for debugging
        print('❌ OAuth HTTP ${response.statusCode}: ${response.body}');
        
        if (contentType.contains('application/json')) {
          try {
            final error = jsonDecode(response.body);
            throw Exception(error['detail'] ?? 'Google authentication failed');
          } catch (e) {
            throw Exception('Server error (${response.statusCode})');
          }
        } else {
          throw Exception('Server error (${response.statusCode}): ${response.body.substring(0, 200)}');
        }
      }
    } catch (e) {
      print('❌ Google OAuth failed: $e');
      rethrow;
    }
  }

  /// OAuth: Sign in with Apple
  static Future<Map<String, dynamic>> oauthApple({
    required String identityToken,
    required String authorizationCode,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/auth/oauth/apple'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'identity_token': identityToken,
          'authorization_code': authorizationCode,
        }),
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _token = data['token'];
        if (_token != null) {
          await _storage.write(key: 'jwt_token', value: _token);
        }
        return data;
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Apple authentication failed');
      }
    } catch (e) {
      print('❌ Apple OAuth failed: $e');
      rethrow;
    }
  }

  /// Check if username is available
  static Future<bool> checkUsernameAvailability(String username) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/api/auth/check-username?username=$username'),
        headers: {'Content-Type': 'application/json'},
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['available'] == true;
      }
      return false;
    } catch (e) {
      print('❌ Check username failed: $e');
      return false;
    }
  }

  /// Set username for OAuth user
  static Future<Map<String, dynamic>> setUsername({
    required String username,
    required String tempToken,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/auth/set-username'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'username': username,
          'temp_token': tempToken,  // Send token in body as server expects
        }),
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        // Update stored token with the final one
        _token = tempToken;
        await _storage.write(key: 'jwt_token', value: tempToken);
        return data;
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Failed to set username');
      }
    } catch (e) {
      print('❌ Set username failed: $e');
      rethrow;
    }
  }

  /// Check username availability with suggestion
  static Future<Map<String, dynamic>> checkUsername({required String username}) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/api/auth/check-username?username=$username'),
        headers: {'Content-Type': 'application/json'},
      );
      
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      return {'available': false};
    } catch (e) {
      print('❌ Check username failed: $e');
      return {'available': false};
    }
  }

  /// Send verification code for registration/email verification
  static Future<void> sendVerificationCode({
    required String identifier,
    required String channel,
    required String purpose,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/auth/send-code'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'identifier': identifier,
          'channel': channel,
          'purpose': purpose,
        }),
      );
      
      if (response.statusCode == 200) {
        return;
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Failed to send code');
      }
    } catch (e) {
      print('❌ Send verification code failed: $e');
      rethrow;
    }
  }

  /// Verify code entered by user
  static Future<Map<String, dynamic>> verifyCode({
    required String identifier,
    required String code,
    required String purpose,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/auth/verify-code'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'identifier': identifier,
          'code': code,
          'purpose': purpose,
        }),
      );
      
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Invalid code');
      }
    } catch (e) {
      print('❌ Verify code failed: $e');
      rethrow;
    }
  }

  /// Get current user info
  static Future<Map<String, dynamic>?> getCurrentUser() async {
    try {
      final headers = await _headers;
      final response = await http.get(
        Uri.parse('$baseUrl/api/users/me'),
        headers: headers,
      );
      
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      return null;
    } catch (e) {
      print('❌ Get current user failed: $e');
      return null;
    }
  }

  /// Get current user's ID from storage (for local DB operations)
  static Future<String?> getCurrentUserId() async {
    return await _storage.read(key: 'user_id');
  }

  /// Get user by ID (for viewing other profiles)
  static Future<Map<String, dynamic>?> getUserById(String userId) async {
    try {
      print('👤 [API] Fetching user profile: $userId');
      final headers = await _headers;
      final response = await http.get(
        Uri.parse('$baseUrl/api/users/$userId'),
        headers: headers,
      );
      
      print('📬 [API] getUserById response: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        print('✅ [API] User fetched: ${data['username']}');
        return data;
      } else if (response.statusCode == 404) {
        print('❌ [API] User not found: $userId');
        return null;
      }
      print('❌ [API] Error: ${response.body}');
      return null;
    } catch (e) {
      print('❌ Get user by ID failed: $e');
      return null;
    }
  }

  /// Search users
  static Future<List<Map<String, dynamic>>> searchUsers(String query) async {
    try {
      final headers = await _headers;
      final response = await http.get(
        Uri.parse('$baseUrl/api/users/search?q=$query'),
        headers: headers,
      );
      
      if (response.statusCode == 200) {
        final List<dynamic> users = jsonDecode(response.body);
        return users.cast<Map<String, dynamic>>();
      }
      return [];
    } catch (e) {
      print('❌ Search users failed: $e');
      return [];
    }
  }

  /// Search posts
  static Future<List<Post>> searchPosts(String query, {String sort = 'latest'}) async {
    try {
      final headers = await _headers;
      final response = await http.get(
        Uri.parse('$baseUrl/api/search/posts?q=${Uri.encodeComponent(query)}&sort=$sort'),
        headers: headers,
      );
      
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((json) => Post.fromJson(json)).toList();
      }
      return [];
    } catch (e) {
      print('❌ Search posts failed: $e');
      return [];
    }
  }

  // ==================== TIME SYNC ====================

  /// Get server time for clock synchronization
  /// Returns UTC DateTime from server
  static Future<DateTime> getServerTime() async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/api/time'),
        headers: {'Content-Type': 'application/json'},
      ).timeout(const Duration(seconds: 5));
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final utcString = data['utc'] as String;
        final serverTime = DateTime.parse(utcString).toUtc();
        print('⏰ [API] Server time: $serverTime');
        return serverTime;
      } else {
        throw Exception('Failed to get server time: ${response.statusCode}');
      }
    } catch (e) {
      print('⚠️ [API] getServerTime failed: $e');
      // Return current UTC as fallback
      return DateTime.now().toUtc();
    }
  }

  // ==================== MESSAGING ====================

  /// Send message via WiFi (idempotent if messageId provided)
  /// 
  /// Supports all message types:
  /// - text: Just content, no media
  /// - voice: audioUrl with voice audio
  /// - image: mediaUrl with image URL
  /// - file: mediaUrl with file URL
  static Future<bool> sendMessage({
    required String recipientId,
    required String content,
    String? messageId,  // For idempotency - server won't create duplicate
    String? audioUrl,   // For voice messages (legacy param, prefer mediaUrl)
    String? messageType,  // 'text', 'image', 'file', 'voice'
    String? mediaUrl,     // URL for any media type (image/file/voice)
    String? fileName,     // ✅ Original filename for media
    String? mimeType,     // ✅ MIME type for media
    // ✅ Reply fields
    String? replyToMessageId,
    String? replyToTextPreview,
    String? replyToSenderName,
    String? replyToType,
    // ✅ Scheduled message fields
    String sendMode = 'instant',
    DateTime? scheduledAtUtc,
  }) async {
    try {
      print('📤 [ApiService.sendMessage] START');
      print('📤 [ApiService.sendMessage] recipientId: $recipientId');
      print('📤 [ApiService.sendMessage] messageId: $messageId');
      print('📤 [ApiService.sendMessage] content length: ${content.length}');
      print('📤 [ApiService.sendMessage] messageType: ${messageType ?? "text"}');
      print('📤 [ApiService.sendMessage] mediaUrl: ${mediaUrl ?? audioUrl ?? "none"}');
      
      final headers = await _headers;
      print('📤 [ApiService.sendMessage] Got headers (token present: ${headers['Authorization']?.isNotEmpty ?? false})');
      
      final body = <String, dynamic>{
        'recipient_id': recipientId,
        'content': content,
      };
      
      // Add message_id for idempotency if provided
      if (messageId != null) {
        body['message_id'] = messageId;
      }
      
      // Handle media messages (image, file, voice)
      // Server uses 'audio_url' field for all media types
      final effectiveMediaUrl = mediaUrl ?? audioUrl;
      final effectiveType = messageType ?? (audioUrl != null ? 'voice' : null);
      
      if (effectiveMediaUrl != null) {
        body['audio_url'] = effectiveMediaUrl;
      }
      if (effectiveType != null && effectiveType != 'text') {
        body['message_type'] = effectiveType;
      }
      
      // ✅ Include media metadata for receiver display
      if (fileName != null) {
        body['file_name'] = fileName;
      }
      if (mimeType != null) {
        body['mime_type'] = mimeType;
      }
      
      // ✅ Reply fields for receiver to see reply preview
      if (replyToMessageId != null) {
        body['reply_to_message_id'] = replyToMessageId;
      }
      if (replyToTextPreview != null) {
        body['reply_to_text_preview'] = replyToTextPreview;
      }
      if (replyToSenderName != null) {
        body['reply_to_sender_name'] = replyToSenderName;
      }
      if (replyToType != null) {
        body['reply_to_type'] = replyToType;
      }
      
      // ✅ Scheduled message fields
      body['send_mode'] = sendMode;
      if (scheduledAtUtc != null) {
        body['scheduled_at_utc'] = scheduledAtUtc.toIso8601String();
      }
      
      final bodyJson = jsonEncode(body);
      print('📤 [ApiService.sendMessage] Payload size: ${bodyJson.length} bytes');
      print('📤 [ApiService.sendMessage] POST $baseUrl/api/messages/send');
      
      final response = await http.post(
        Uri.parse('$baseUrl/api/messages/send'),
        headers: headers,
        body: bodyJson,
      ).timeout(const Duration(seconds: 15));
      
      print('📤 [ApiService.sendMessage] Response: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        print('✅ [ApiService.sendMessage] SUCCESS');
        return true;
      } else {
        print('❌ [ApiService.sendMessage] FAILED - Status: ${response.statusCode}');
        print('❌ [ApiService.sendMessage] Response body: ${response.body}');
        return false;
      }
    } on TimeoutException {
      print('❌ [ApiService.sendMessage] TIMEOUT after 15s');
      rethrow;  // ✅ Rethrow so caller can fallback to Mesh
    } catch (e) {
      print('❌ [ApiService.sendMessage] EXCEPTION: $e');
      rethrow;  // ✅ Rethrow so caller can fallback to Mesh
    }
  }

  /// Get inbox messages (all messages where user is recipient)
  /// Pass 'since' ISO timestamp to get only new messages
  static Future<List<Map<String, dynamic>>> getInbox({String? since}) async {
    try {
      final headers = await _headers;
      String url = '$baseUrl/api/messages/inbox';
      if (since != null) {
        url += '?since=$since';
      }
      
      final response = await http.get(
        Uri.parse(url),
        headers: headers,
      );
      
      if (response.statusCode == 200) {
        final List<dynamic> messages = jsonDecode(response.body);
        print('📥 [API] Got ${messages.length} inbox messages');
        return messages.cast<Map<String, dynamic>>();
      }
      print('❌ [API] getInbox failed: ${response.statusCode}');
      return [];
    } catch (e) {
      print('❌ Get inbox failed: $e');
      return [];
    }
  }

  /// Get messages with a specific user
  static Future<List<Map<String, dynamic>>> getMessages(String otherUserId) async {
    try {
      final headers = await _headers;
      final response = await http.get(
        Uri.parse('$baseUrl/api/messages/conversation/$otherUserId'),  // Fixed: was /api/messages/{id}
        headers: headers,
      );
      
      if (response.statusCode == 200) {
        final List<dynamic> messages = jsonDecode(response.body);
        return messages.cast<Map<String, dynamic>>();
      }
      return [];
    } catch (e) {
      print('❌ Get messages failed: $e');
      return [];
    }
  }
  
  // ==================== IMAGE UPLOAD ====================
  
  /// Upload image file to server
  static Future<String?> uploadImage(File imageFile) async {
    try {
      final headers = await _headers;
      final token = headers['Authorization']?.replaceFirst('Bearer ', '');
      
      print('═══════════════════════════════════════════════════');
      print('📤 [Upload] Starting image upload...');
      print('├── File path: ${imageFile.path}');
      print('├── File exists: ${await imageFile.exists()}');
      print('├── File size: ${await imageFile.length()} bytes');
      print('├── Token present: ${token != null}');
      print('├── URL: $baseUrl/api/uploads/image');
      
      var request = http.MultipartRequest(
        'POST',
        Uri.parse('$baseUrl/api/uploads/image'),
      );
      
      // Add auth header
      if (token != null) {
        request.headers['Authorization'] = 'Bearer $token';
      }
      
      // Add image file
      request.files.add(
        await http.MultipartFile.fromPath(
          'file',
          imageFile.path,
        ),
      );
      
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);
      
      print('├── Response code: ${response.statusCode}');
      print('├── Response body: ${response.body}');
      print('═══════════════════════════════════════════════════');
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final imageUrl = data['image_url'] as String;
        print('✅ Image uploaded successfully: $imageUrl');
        return imageUrl;
      } else {
        print('❌ Upload failed: ${response.statusCode} - ${response.body}');
        return null;
      }
    } catch (e, stack) {
      print('❌ Upload image exception: $e');
      print('Stack trace: $stack');
      return null;
    }
  }
  
  /// Update user's profile picture on server
  static Future<bool> updateProfilePicture(String imageUrl) async {
    try {
      final headers = await _headers;
      
      print('📷 [API] Updating profile picture to: $imageUrl');
      
      final response = await http.post(
        Uri.parse('$baseUrl/api/users/profile-picture'),
        headers: headers,
        body: jsonEncode({'image_url': imageUrl}),
      );
      
      print('📷 [API] Profile update response: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        print('✅ [API] Profile picture updated successfully');
        return true;
      } else {
        print('❌ [API] Profile update failed: ${response.statusCode} - ${response.body}');
        return false;
      }
    } catch (e) {
      print('❌ [API] updateProfilePicture error: $e');
      return false;
    }
  }
  
  /// Update current user's bio and tags/hobbies
  /// Returns the updated profile data or null on failure
  static Future<Map<String, dynamic>?> updateProfile({
    String? bio,
    List<String>? hobbies,
  }) async {
    try {
      final bioLog = bio != null && bio.length > 30 ? bio.substring(0, 30) : (bio ?? '');
      print('📝 [API] Updating profile: bio=$bioLog..., hobbies=$hobbies');
      
      final headers = await _headers;
      final body = <String, dynamic>{};
      
      if (bio != null) body['bio'] = bio;
      if (hobbies != null) body['hobbies'] = hobbies;
      
      final response = await http.patch(
        Uri.parse('$baseUrl/api/users/me'),
        headers: headers,
        body: jsonEncode(body),
      );
      
      print('📝 [API] Profile update response: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final bioPreview = data['bio']?.toString() ?? '';
        print('✅ [API] Profile updated: bio=${bioPreview.length > 20 ? bioPreview.substring(0, 20) : bioPreview}..., hobbies=${data['hobbies']}');
        return data;
      } else {
        print('❌ [API] Profile update failed: ${response.statusCode} - ${response.body}');
        return null;
      }
    } catch (e) {
      print('❌ [API] updateProfile error: $e');
      return null;
    }
  }
  
  /// Refresh current user data from server
  /// Useful after profile updates to sync local state
  static Future<Map<String, dynamic>?> refreshMe() async {
    return await getCurrentUser();
  }
  
  /// Upload voice file to server
  static Future<String?> uploadVoice(File voiceFile) async {
    try {
      final headers = await _headers;
      final token = headers['Authorization']?.replaceFirst('Bearer ', '');
      
      print('🎤 Uploading voice: ${voiceFile.path}');
      
      var request = http.MultipartRequest(
        'POST',
        Uri.parse('$baseUrl/api/voice/upload'),  // ✅ Fixed endpoint to match server
      );
      
      if (token != null) {
        request.headers['Authorization'] = 'Bearer $token';
      }
      
      request.files.add(
        await http.MultipartFile.fromPath(
          'file',
          voiceFile.path,
          filename: 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a',
          contentType: MediaType('audio', 'mp4'),  // m4a is audio/mp4
        ),
      );
      
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);
      
      print('📥 Voice upload response: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        // Server returns audio_url in response
        final voiceUrl = data['audio_url'] as String? ?? data['voice_url'] as String? ?? data['url'] as String?;
        print('✅ Voice uploaded: $voiceUrl');
        return voiceUrl;
      } else {
        print('❌ Voice upload error: ${response.statusCode} - ${response.body}');
        return null;
      }
    } catch (e) {
      print('❌ Upload voice failed: $e');
      return null;
    }
  }
  
  /// Upload file (PDF, DOC, etc.) with real-time progress callback
  /// Uses dio for onSendProgress support
  static Future<Map<String, dynamic>?> uploadFile(
    File file, {
    required void Function(double progress) onProgress,
  }) async {
    try {
      final headers = await _headers;
      final token = headers['Authorization']?.replaceFirst('Bearer ', '');
      
      final fileName = file.path.split('/').last;
      final fileExt = fileName.contains('.') ? fileName.split('.').last.toLowerCase() : '';
      
      print('📄 [Upload] Starting file upload: $fileName');
      print('├── Path: ${file.path}');
      print('├── Size: ${await file.length()} bytes');
      print('├── Extension: $fileExt');
      
      final dioClient = dio_pkg.Dio();
      dioClient.options.sendTimeout = const Duration(seconds: 60);
      dioClient.options.receiveTimeout = const Duration(seconds: 30);
      
      if (token != null) {
        dioClient.options.headers['Authorization'] = 'Bearer $token';
      }
      
      final formData = dio_pkg.FormData.fromMap({
        'file': await dio_pkg.MultipartFile.fromFile(
          file.path,
          filename: fileName,
        ),
      });
      
      final response = await dioClient.post(
        '$baseUrl/api/uploads/file',
        data: formData,
        onSendProgress: (sent, total) {
          if (total > 0) {
            final progress = sent / total;
            print('📤 Upload progress: ${(progress * 100).toStringAsFixed(0)}%');
            onProgress(progress);
          }
        },
      );
      
      print('📄 [Upload] Response: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        final data = response.data as Map<String, dynamic>;
        print('✅ File uploaded successfully: ${data['file_url']}');
        return data;
      } else {
        print('❌ File upload failed: ${response.statusCode}');
        return null;
      }
    } on dio_pkg.DioException catch (e) {
      print('❌ File upload DioException: ${e.message}');
      print('├── Type: ${e.type}');
      print('├── Response: ${e.response?.data}');
      return null;
    } catch (e) {
      print('❌ File upload error: $e');
      return null;
    }
  }
  
  // ==================== POSTS ====================
  
  /// Create post via WiFi
  static Future<bool> createPost(Post post) async {
    try {
      final headers = await _headers;
      print('📤 Sending post to server: ${post.content.substring(0, min(20, post.content.length))}...');
      
      final response = await http.post(
        Uri.parse('$baseUrl/api/posts/create'),
        headers: headers,
        body: jsonEncode({
          'content': post.content,
          'image_url': post.imageUrl,
          'is_local': post.isLocal,
        }),
      );
      
      print('📥 Server response: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        print('✅ Post created successfully');
        return true;
      } else {
        print('❌ Server error: ${response.statusCode} - ${response.body}');
        return false;
      }
    } catch (e) {
      print('❌ Create post failed: $e');
      return false;
    }
  }
  
  /// Get feed
  static Future<List<Post>> getFeed() async {
    try {
      final headers = await _headers;
      final response = await http.get(
        Uri.parse('$baseUrl/api/posts/feed'),
        headers: headers,
      );
      
      print('📥 Feed response: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        final List<dynamic> posts = jsonDecode(response.body);
        final result = posts.map((json) => Post.fromJson(json)).toList();
        
        // ✅ Debug: Show sendMethod distribution
        final wifiPosts = result.where((p) => p.sendMethod == PostSendMethod.wifi).length;
        final meshPosts = result.where((p) => p.sendMethod == PostSendMethod.bluetooth).length;
        final localPosts = result.where((p) => p.sendMethod == PostSendMethod.local).length;
        final unknownPosts = result.where((p) => p.sendMethod == PostSendMethod.unknown).length;
        
        print('📊 Feed sendMethod distribution: wifi=$wifiPosts, mesh=$meshPosts, local=$localPosts, unknown=$unknownPosts');
        
        // ✅ Debug: Show view_count for first few posts
        for (var i = 0; i < (result.length > 3 ? 3 : result.length); i++) {
          final p = result[i];
          print('   Post ${p.id.substring(0, 8)}... sendMethod=${p.sendMethod.name} viewCount=${p.viewCount}');
        }
        
        print('✅ Parsed ${result.length} posts from feed');
        return result;
      }
      
      print('❌ Feed error: ${response.statusCode}');
      return [];
    } catch (e) {
      print('❌ Get feed failed: $e');
      return [];
    }
  }
  
  // ==================== FRIEND REQUESTS ====================
  
  /// Send friend request
  static Future<bool> sendFriendRequest(String recipientId) async {
    try {
      final headers = await _headers;
      final response = await http.post(
        Uri.parse('$baseUrl/api/users/friend-request?recipient_id=$recipientId'),
        headers: headers,
      );
      
      print('📤 Friend request response: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        print('✅ Friend request sent');
        return true;
      } else {
        print('❌ Friend request error: ${response.body}');
        return false;
      }
    } catch (e) {
      print('❌ Send friend request failed: $e');
      return false;
    }
  }
  
  /// Get friend requests (only pending ones)
  static Future<List<AppNotification>> getFriendRequests() async {
    try {
      final headers = await _headers;
      final response = await http.get(
        Uri.parse('$baseUrl/api/users/friend-requests'),
        headers: headers,
      );
      
      print('📥 Friend requests response: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        
        // Debug: Show each request's details
        for (final json in data) {
          print('📋 Request: id=${json['id']} from ${json['requester_username']} status=${json['status']}');
        }
        
        // ✅ Only process PENDING requests - filter out accepted/declined
        final pendingData = data.where((json) {
          final status = json['status']?.toString().toLowerCase() ?? '';
          return status == 'pending';
        }).toList();
        
        print('📋 Filtered: ${pendingData.length} pending out of ${data.length} total');
        
        final notifications = pendingData.map((json) {
          return AppNotification(
            id: json['id'],
            type: NotificationType.friendRequest,
            title: json['requester_username'],
            body: 'sent you a friend request',
            avatarPath: json['requester_avatar'],
            userId: json['requester_id'],
            timestamp: DateTime.parse(json['created_at']),
            isRead: false,
            data: {
              'friend_request_id': json['id'],
              'status': json['status'],
            },
          );
        }).toList();
        
        print('✅ Got ${notifications.length} pending friend requests');
        return notifications;
      }
      
      return [];
    } catch (e) {
      print('❌ Get friend requests failed: $e');
      return [];
    }
  }
  
  /// Get ALL notifications (messages, likes, comments, friend requests, etc.)
  /// This is the unified notification endpoint
  static Future<List<AppNotification>> getNotifications({int limit = 50}) async {
    try {
      final headers = await _headers;
      final response = await http.get(
        Uri.parse('$baseUrl/api/notifications?limit=$limit'),
        headers: headers,
      );
      
      print('🔔 Notifications response: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        
        final notifications = data.map((json) {
          final typeStr = json['type']?.toString() ?? 'other';
          final Map<String, dynamic> dataMap = json['data'] is Map 
              ? Map<String, dynamic>.from(json['data'] as Map) 
              : {};
          
          return AppNotification(
            id: json['id'],
            type: _parseNotificationType(typeStr),
            title: _titleForType(typeStr, dataMap),
            body: _bodyForType(typeStr, dataMap),
            avatarPath: dataMap['sender_avatar'] ?? dataMap['liker_avatar'] ?? dataMap['commenter_avatar'],
            userId: dataMap['sender_id'] ?? dataMap['liker_id'] ?? dataMap['commenter_id'],
            timestamp: DateTime.parse(json['timestamp']),
            isRead: json['is_read'] ?? false,
            data: dataMap,
          );
        }).toList();
        
        print('✅ Got ${notifications.length} notifications');
        return notifications;
      }
      
      return [];
    } catch (e) {
      print('❌ Get notifications failed: $e');
      return [];
    }
  }
  
  /// Parse notification type from server string to enum
  static NotificationType _parseNotificationType(String typeStr) {
    switch (typeStr) {
      case 'message': return NotificationType.message;
      case 'voice': return NotificationType.message; // Voice is a subtype of message
      case 'like': return NotificationType.like;
      case 'comment': return NotificationType.comment;
      case 'mention': return NotificationType.mention;
      case 'friend_request': return NotificationType.friendRequest;
      default: return NotificationType.message;
    }
  }
  
  /// Generate title based on notification type
  static String _titleForType(String typeStr, Map<String, dynamic> data) {
    switch (typeStr) {
      case 'message':
      case 'voice':
        return data['sender_username'] ?? 'New Message';
      case 'like':
        return data['liker_username'] ?? 'Someone';
      case 'comment':
        return data['commenter_username'] ?? 'Someone';
      case 'mention':
        return data['mentioner_username'] ?? 'Someone';
      case 'friend_request':
        return data['requester_username'] ?? 'Friend Request';
      default:
        return 'Notification';
    }
  }
  
  /// Generate body based on notification type
  static String _bodyForType(String typeStr, Map<String, dynamic> data) {
    switch (typeStr) {
      case 'message':
        return data['preview'] ?? 'sent you a message';
      case 'voice':
        return '🎤 Voice message';
      case 'like':
        return 'liked your post';
      case 'comment':
        return data['preview'] ?? 'commented on your post';
      case 'mention':
        return data['preview'] ?? 'mentioned you in a comment';
      case 'friend_request':
        return 'sent you a friend request';
      default:
        return '';
    }
  }
  
  /// Get unread notification count
  static Future<int> getNotificationUnreadCount() async {
    try {
      final headers = await _headers;
      final response = await http.get(
        Uri.parse('$baseUrl/api/notifications/unread-count'),
        headers: headers,
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['unread_count'] ?? 0;
      }
      return 0;
    } catch (e) {
      print('❌ Get unread count failed: $e');
      return 0;
    }
  }
  
  /// Accept friend request - returns friend info from server
  static Future<Map<String, dynamic>?> acceptFriendRequest(String requestId) async {
    try {
      final headers = await _headers;
      final url = '$baseUrl/api/users/friend-request/$requestId/accept';
      
      print('🤝 [API] Accept request → $url');
      print('🤝 [API] requestId = $requestId');
      
      final response = await http.post(
        Uri.parse(url),
        headers: headers,
      );
      
      print('🤝 Accept response: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        print('✅ Friend request accepted');
        final data = jsonDecode(response.body);
        print('✅ Response data: $data');
        
        // ✅ Return friend info from server response
        return {
          'success': true,
          'friend_id': data['friend_id'],
          'friend_username': data['friend_username'],
          'friend_avatar': data['friend_avatar'],
        };
      } else {
        print('❌ Accept error: ${response.body}');
        return {'success': false};
      }
    } catch (e) {
      print('❌ Accept friend request failed: $e');
      return null;
    }
  }
  
  /// Reject friend request
  static Future<bool> rejectFriendRequest(String requestId) async {
    try {
      final headers = await _headers;
      final response = await http.post(
        Uri.parse('$baseUrl/api/users/friend-request/$requestId/reject'),
        headers: headers,
      );
      
      print('❌ Reject response: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        print('✅ Friend request rejected');
        return true;
      } else {
        print('❌ Reject error: ${response.body}');
        return false;
      }
    } catch (e) {
      print('❌ Reject friend request failed: $e');
      return false;
    }
  }
  
  /// Send followback request (two-step friend system)
  /// Called when A wants to become mutual friends with B after accepting their request
  static Future<bool> sendFollowbackRequest(String userId) async {
    try {
      final headers = await _headers;
      final response = await http.post(
        Uri.parse('$baseUrl/api/users/followback/$userId'),
        headers: headers,
      );
      
      print('🔄 Followback response: ${response.statusCode}');
      
      if (response.statusCode == 200 || response.statusCode == 201) {
        print('✅ Followback request sent');
        return true;
      } else {
        print('❌ Followback error: ${response.body}');
        return false;
      }
    } catch (e) {
      print('❌ Followback request failed: $e');
      return false;
    }
  }
  
  /// Get friends list (accepted friendships)
  static Future<List<Map<String, dynamic>>> getFriends() async {
    try {
      final headers = await _headers;
      final response = await http.get(
        Uri.parse('$baseUrl/api/users/friends'),
        headers: headers,
      );
      
      print('👥 Friends response: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        final friends = data.map((f) => f as Map<String, dynamic>).toList();
        print('✅ Got ${friends.length} friends from server');
        return friends;
      } else {
        print('❌ Friends error: ${response.body}');
        return [];
      }
    } catch (e) {
      print('❌ Get friends failed: $e');
      return [];
    }
  }
  
  // ==================== POST INTERACTIONS ====================
  
  /// Toggle like on a post - returns response with action, likes count, and is_liked status
  static Future<Map<String, dynamic>?> toggleLike(String postId) async {
    try {
      final headers = await _headers;
      final response = await http.post(
        Uri.parse('$baseUrl/api/posts/$postId/like'),
        headers: headers,
      );
      
      print('❤️ Like response: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        print('❤️ Post ${data['action']} - total: ${data['likes']}');
        return data;
      }
      return null;
    } catch (e) {
      print('❌ Toggle like failed: $e');
      return null;
    }
  }
  
  /// Repost a post - returns response with action, reposts count, and is_reposted status
  static Future<Map<String, dynamic>?> repost(String postId, {String? quote}) async {
    try {
      final headers = await _headers;
      final response = await http.post(
        Uri.parse('$baseUrl/api/posts/$postId/repost'),
        headers: headers,
        body: quote != null ? jsonEncode({'content': quote}) : null,
      );
      
      print('🔄 Repost response: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        print('🔄 Post ${data['action']} - total: ${data['reposts']}');
        return data;
      }
      return null;
    } catch (e) {
      print('❌ Repost failed: $e');
      return null;
    }
  }
  
  /// Edit a post's content (owner only)
  static Future<Post?> editPost(String postId, {required String content}) async {
    try {
      final headers = await _headers;
      final response = await http.patch(
        Uri.parse('$baseUrl/api/posts/$postId'),
        headers: headers,
        body: jsonEncode({'content': content}),
      );
      
      print('✏️ Edit post response: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        print('✏️ Post edited successfully');
        return Post.fromJson(data);
      } else if (response.statusCode == 403) {
        print('⚠️ Not authorized to edit this post');
      }
      return null;
    } catch (e) {
      print('❌ Edit post failed: $e');
      return null;
    }
  }
  
  /// Delete a post (owner only)
  static Future<bool> deletePost(String postId) async {
    try {
      final headers = await _headers;
      final response = await http.delete(
        Uri.parse('$baseUrl/api/posts/$postId'),
        headers: headers,
      );
      
      print('🗑️ Delete post response: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        print('🗑️ Post deleted successfully');
        return true;
      } else if (response.statusCode == 403) {
        print('⚠️ Not authorized to delete this post');
      }
      return false;
    } catch (e) {
      print('❌ Delete post failed: $e');
      return false;
    }
  }
  
  /// Record a unique view on a post (privacy-first: only count, no viewer list)
  static Future<int?> recordPostView(String postId) async {
    try {
      final headers = await _headers;
      
      // ✅ Debug: Check if token is present
      final hasToken = headers.containsKey('Authorization');
      print('👁️ [VIEW] Recording view for post ${postId.substring(0, 8)}...');
      print('   ├── Token present: $hasToken');
      
      if (!hasToken) {
        print('   └── ⚠️ SKIPPING: No auth token - view will not be recorded!');
        return null;
      }
      
      final response = await http.post(
        Uri.parse('$baseUrl/api/posts/$postId/view'),
        headers: headers,
      );
      
      print('   ├── Response status: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        
        // ✅ Debug: Print raw response to see what server returns
        print('   ├── Raw response: ${response.body}');
        
        // ✅ FIX: Handle both camelCase (viewCount) and snake_case (view_count)
        final count = _parseViewCount(data);
        print('   └── ✅ View recorded! New count: $count');
        return count;
      } else if (response.statusCode == 401) {
        print('   └── ❌ AUTH ERROR 401: Token invalid or expired');
        return null;
      } else if (response.statusCode == 404) {
        print('   └── ❌ POST NOT FOUND: Post $postId does not exist');
        return null;
      } else {
        print('   └── ❌ UNEXPECTED: ${response.statusCode} - ${response.body}');
        return null;
      }
    } catch (e) {
      print('❌ [VIEW] Record view failed: $e');
      return null;
    }
  }
  
  /// Helper to parse view count from server response (handles both naming conventions)
  static int? _parseViewCount(Map<String, dynamic> data) {
    // Try camelCase first, then snake_case
    final value = data['viewCount'] ?? data['view_count'];
    if (value == null) return null;
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  }
  
  // ==================== TWO-FACTOR AUTHENTICATION ====================
  
  /// Send 2FA verification code
  Future<bool> send2FACode(String userId, String method) async {
    try {
      final headers = await ApiService._headers;
      final response = await http.post(
        Uri.parse('${ApiService.baseUrl}/api/auth/2fa/send-code'),
        headers: headers,
        body: jsonEncode({
          'user_id': userId,
          'method': method, // 'email' or 'sms'
        }),
      );
      
      print('📧 2FA code send response: ${response.statusCode}');
      return response.statusCode == 200;
    } catch (e) {
      print('❌ Send 2FA code failed: $e');
      return false;
    }
  }
  
  /// Verify 2FA code
  Future<bool> verify2FACode(String userId, String code) async {
    try {
      final headers = await ApiService._headers;
      final response = await http.post(
        Uri.parse('${ApiService.baseUrl}/api/auth/2fa/verify'),
        headers: headers,
        body: jsonEncode({
          'user_id': userId,
          'code': code,
        }),
      );
      
      print('✅ 2FA verify response: ${response.statusCode}');
      return response.statusCode == 200;
    } catch (e) {
      print('❌ Verify 2FA code failed: $e');
      return false;
    }
  }
  
  // ==================== COMMENTS ====================
  
  /// Get comments for a post
  static Future<List<Comment>> getPostComments(String postId) async {
    try {
      final token = await _storage.read(key: 'jwt_token');
      final response = await http.get(
        Uri.parse('$baseUrl/api/comments/post/$postId'),
        headers: {
          'Content-Type': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        },
      );
      
      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        return data.map((json) => Comment.fromJson(json)).toList();
      }
      print('❌ Failed to load comments: ${response.statusCode}');
      return [];
    } catch (e) {
      print('❌ Error loading comments: $e');
      return [];
    }
  }
  
  /// Create a comment on a post
  /// [postImageUrl] - Optional, pass if AI should analyze the image (Vision API)
  /// [enableSearch] - Optional, enable AI web search for fact-checking
  static Future<Comment?> createComment({
    required String postId,
    required String content,
    String? parentCommentId,
    String? postImageUrl,  // ✅ For AI Vision analysis - MUST be public URL
    bool enableSearch = true,  // ✅ For AI Internet Search
  }) async {
    try {
      print('📝 Creating comment on post: $postId');
      print('📝 Content: $content');
      print('🖼️ Image URL for AI: ${postImageUrl ?? "none"}');
      print('🔍 Search enabled: $enableSearch');
      
      final token = await _storage.read(key: 'jwt_token');
      print('🔑 Token present: ${token != null}');
      
      final response = await http.post(
        Uri.parse('$baseUrl/api/comments/create'),
        headers: {
          'Content-Type': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        },
        body: json.encode({
          'post_id': postId,
          'content': content,
          if (parentCommentId != null) 'parent_comment_id': parentCommentId,
          // ✅ Send image URL so server can pass to AI Vision model
          if (postImageUrl != null && postImageUrl.isNotEmpty) 
            'image_url': postImageUrl,
          // ✅ Send search preference for AI fact-checking
          'enable_search': enableSearch,
        }),
      );
      
      print('📬 Comment response: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        print('✅ Comment created successfully');
        return Comment.fromJson(data);
      }
      print('❌ Failed to create comment: ${response.statusCode} - ${response.body}');
      return null;
    } catch (e) {
      print('❌ Error creating comment: $e');
      return null;
    }
  }

  
  /// Vote on a comment (like/dislike)
  /// vote: +1 = like, -1 = dislike, 0 = remove vote
  static Future<Map<String, dynamic>?> voteComment(String commentId, int vote) async {
    try {
      final token = await _storage.read(key: 'jwt_token');
      final response = await http.post(
        Uri.parse('$baseUrl/api/comments/$commentId/vote'),
        headers: {
          'Content-Type': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        },
        body: json.encode({'vote': vote}),
      );
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        print('🗳️ Comment vote ${data['action']} - myVote: ${data['my_vote']}, score: ${data['score']}');
        return data;
      }
      print('❌ Failed to vote on comment: ${response.statusCode}');
      return null;
    } catch (e) {
      print('❌ Error voting on comment: $e');
      return null;
    }
  }
  
  // ==================== BADGE COUNTS ====================
  
  /// Get badge counts for bottom navigation
  static Future<Map<String, int>> getCounts() async {
    try {
      final headers = await _headers;
      final response = await http.get(
        Uri.parse('$baseUrl/api/counts'),
        headers: headers,
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return {
          'unreadMessages': data['unread_messages'] ?? 0,
          'newLocalPosts': data['new_local_posts'] ?? 0,
          'newFriendPosts': data['new_friend_posts'] ?? 0,
          'securityAlerts': data['security_alerts'] ?? 0,
        };
      }
      return {};
    } catch (e) {
      print('❌ Get counts failed: $e');
      return {};
    }
  }
  
  // ==================== HEALTH CHECK ====================
  
  /// Health check
  static Future<bool> checkConnection() async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/health'));
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }
  
  // ==================== VOICE TRANSCRIPTION ====================
  
  /// Request voice message transcription from server
  /// Returns: { text: "...", language: "en", segments: [...] }
  static Future<Map<String, dynamic>> transcribeVoiceMessage({
    required String messageId,
    String? audioUrl,
  }) async {
    try {
      print('🎤 Requesting transcript for message: $messageId');
      
      final response = await http.post(
        Uri.parse('$baseUrl/api/messages/$messageId/transcribe'),
        headers: await _headers,
        body: jsonEncode({
          'audio_url': audioUrl,
        }),
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        print('✅ Transcript received: ${(data['text'] as String?)?.substring(0, 50) ?? 'empty'}...');
        return {
          'text': data['text'] ?? '',
          'language': data['language'] ?? 'en',
          'segments': data['segments'] ?? [],
        };
      } else {
        print('❌ Transcription failed: ${response.statusCode}');
        throw Exception('Transcription failed: ${response.statusCode}');
      }
    } catch (e) {
      print('❌ Transcription error: $e');
      rethrow;
    }
  }

  // ==================== POST NOTIFICATIONS ====================

  /// Enable post notifications for a user
  static Future<Map<String, dynamic>?> enablePostNotify(String targetId) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/profiles/$targetId/post-notify/enable'),
        headers: await _headers,
      );
      
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      return null;
    } catch (e) {
      print('❌ Enable post notify error: $e');
      return null;
    }
  }

  /// Disable post notifications for a user
  static Future<Map<String, dynamic>?> disablePostNotify(String targetId) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/profiles/$targetId/post-notify/disable'),
        headers: await _headers,
      );
      
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      return null;
    } catch (e) {
      print('❌ Disable post notify error: $e');
      return null;
    }
  }

  /// Get post notification status for a user
  static Future<bool> getPostNotifyStatus(String targetId) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/profiles/$targetId/post-notify/status'),
        headers: await _headers,
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['enabled'] ?? false;
      }
      return false;
    } catch (e) {
      print('❌ Get post notify status error: $e');
      return false;
    }
  }

  // ==================== ROOM VISIBILITY ====================

  /// Mark room as read
  static Future<bool> markRoomAsRead(String roomId) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/profiles/rooms/$roomId/mark-read'),
        headers: await _headers,
      );
      
      return response.statusCode == 200;
    } catch (e) {
      print('❌ Mark room as read error: $e');
      return false;
    }
  }

  /// Hide room (delete for me)
  static Future<bool> hideRoom(String roomId) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/profiles/rooms/$roomId/hide'),
        headers: await _headers,
      );
      
      return response.statusCode == 200;
    } catch (e) {
      print('❌ Hide room error: $e');
      return false;
    }
  }

  // ==================== DEVICE IDENTITY ====================

  /// Register device fingerprint with server
  /// Called on app startup when online to link this device to user
  static Future<bool> registerDevice({
    required String fingerprint,
    required String publicKey,
    String? platform,
    String? deviceName,
  }) async {
    try {
      final headers = await _headers;
      
      print('🔑 [API] Registering device: ${fingerprint.substring(0, 16)}...');
      
      final response = await http.post(
        Uri.parse('$baseUrl/api/devices/register'),
        headers: headers,
        body: jsonEncode({
          'device_fingerprint': fingerprint,
          'public_key': publicKey,
          if (platform != null) 'platform': platform,
          if (deviceName != null) 'device_name': deviceName,
        }),
      );
      
      if (response.statusCode == 200) {
        print('✅ [API] Device registered successfully');
        return true;
      } else if (response.statusCode == 409) {
        print('⚠️ [API] Device already registered to another user');
        return false;
      } else {
        print('❌ [API] Device registration failed: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      print('❌ [API] registerDevice error: $e');
      return false;
    }
  }

  /// Get fingerprints of all friends' devices
  /// Returns list of {user_id, username, fingerprint, avatar_path}
  static Future<List<Map<String, dynamic>>> getFriendFingerprints() async {
    try {
      final headers = await _headers;
      
      final response = await http.get(
        Uri.parse('$baseUrl/api/devices/friends'),
        headers: headers,
      );
      
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        print('✅ [API] Got ${data.length} friend fingerprints');
        return data.cast<Map<String, dynamic>>();
      }
      
      // ✅ Throw exception for auth errors to trigger cache fallback
      if (response.statusCode == 401) {
        print('⚠️ [API] getFriendFingerprints: Auth error (401) - using cache');
        throw Exception('Auth error 401');
      }
      
      print('❌ [API] getFriendFingerprints failed: ${response.statusCode}');
      return [];
    } catch (e) {
      print('❌ [API] getFriendFingerprints error: $e');
      rethrow; // Rethrow so cache fallback triggers
    }
  }

  /// Look up user info for a fingerprint (for Nearby People)
  /// Returns {user_id, username, avatar_path, is_friend}
  static Future<Map<String, dynamic>?> lookupFingerprint(String fingerprint) async {
    try {
      final headers = await _headers;
      
      final response = await http.get(
        Uri.parse('$baseUrl/api/devices/lookup/$fingerprint'),
        headers: headers,
      );
      
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else if (response.statusCode == 404) {
        // Unknown device
        return null;
      }
      
      return null;
    } catch (e) {
      print('❌ [API] lookupFingerprint error: $e');
      return null;
    }
  }

  /// Get list of my registered devices
  static Future<List<Map<String, dynamic>>> getMyDevices() async {
    try {
      final headers = await _headers;
      
      final response = await http.get(
        Uri.parse('$baseUrl/api/devices/my'),
        headers: headers,
      );
      
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.cast<Map<String, dynamic>>();
      }
      
      return [];
    } catch (e) {
      print('❌ [API] getMyDevices error: $e');
      return [];
    }
  }

  /// Revoke a device (e.g., after theft)
  static Future<bool> revokeDevice(String fingerprint) async {
    try {
      final headers = await _headers;
      
      final response = await http.delete(
        Uri.parse('$baseUrl/api/devices/revoke/$fingerprint'),
        headers: headers,
      );
      
      return response.statusCode == 200;
    } catch (e) {
      print('❌ [API] revokeDevice error: $e');
      return false;
    }
  }

  // ==================== EMAIL/SMS VERIFICATION ====================

  /// Send email OTP for verification
  static Future<void> sendEmailOtp() async {
    try {
      final headers = await _headers;
      
      final response = await http.post(
        Uri.parse('$baseUrl/api/auth/send-email-otp'),
        headers: headers,
      );
      
      if (response.statusCode == 200) {
        print('✅ [API] Email OTP sent successfully');
        return;
      } else if (response.statusCode == 429) {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Please wait before requesting a new code');
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Failed to send verification code');
      }
    } catch (e) {
      print('❌ [API] sendEmailOtp error: $e');
      rethrow;
    }
  }

  /// Verify email OTP code
  static Future<bool> verifyEmailOtp(String code) async {
    try {
      final headers = await _headers;
      
      final response = await http.post(
        Uri.parse('$baseUrl/api/auth/verify-email-otp'),
        headers: headers,
        body: jsonEncode({'code': code}),
      );
      
      if (response.statusCode == 200) {
        print('✅ [API] Email verified successfully');
        return true;
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Invalid verification code');
      }
    } catch (e) {
      print('❌ [API] verifyEmailOtp error: $e');
      rethrow;
    }
  }

  /// Send SMS OTP for verification
  static Future<void> sendSmsOtp() async {
    try {
      final headers = await _headers;
      
      final response = await http.post(
        Uri.parse('$baseUrl/api/auth/send-sms-otp'),
        headers: headers,
      );
      
      if (response.statusCode == 200) {
        print('✅ [API] SMS OTP sent successfully');
        return;
      } else if (response.statusCode == 429) {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Please wait before requesting a new code');
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Failed to send verification code');
      }
    } catch (e) {
      print('❌ [API] sendSmsOtp error: $e');
      rethrow;
    }
  }

  /// Verify SMS OTP code
  static Future<bool> verifySmsOtp(String code) async {
    try {
      final headers = await _headers;
      
      final response = await http.post(
        Uri.parse('$baseUrl/api/auth/verify-sms-otp'),
        headers: headers,
        body: jsonEncode({'code': code}),
      );
      
      if (response.statusCode == 200) {
        print('✅ [API] SMS verified successfully');
        return true;
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Invalid verification code');
      }
    } catch (e) {
      print('❌ [API] verifySmsOtp error: $e');
      rethrow;
    }
  }

  /// Get current verification status
  static Future<Map<String, dynamic>> getVerificationStatus() async {
    try {
      final headers = await _headers;
      
      final response = await http.get(
        Uri.parse('$baseUrl/api/auth/verification-status'),
        headers: headers,
      );
      
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        return {
          'email_verified': false,
          'phone_verified': false,
          'verification_status': 'pending',
        };
      }
    } catch (e) {
      print('❌ [API] getVerificationStatus error: $e');
      return {
        'email_verified': false,
        'phone_verified': false,
        'verification_status': 'pending',
      };
    }
  }

  // ==================== FORGOT PASSWORD ====================

  /// Request password reset OTP
  static Future<void> forgotPassword(String emailOrPhone) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/auth/forgot-password'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'identifier': emailOrPhone}),
      );
      
      if (response.statusCode == 200) {
        print('✅ [API] Password reset code sent');
        return;
      } else if (response.statusCode == 429) {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Too many attempts. Please wait.');
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Failed to send reset code');
      }
    } catch (e) {
      print('❌ [API] forgotPassword error: $e');
      rethrow;
    }
  }

  /// Reset password with OTP
  static Future<bool> resetPassword({
    required String emailOrPhone,
    required String code,
    required String newPassword,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/auth/reset-password'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'identifier': emailOrPhone,
          'code': code,
          'new_password': newPassword,
        }),
      );
      
      if (response.statusCode == 200) {
        print('✅ [API] Password reset successful');
        return true;
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Failed to reset password');
      }
    } catch (e) {
      print('❌ [API] resetPassword error: $e');
      rethrow;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP CHAT API
  // ═══════════════════════════════════════════════════════════════════════════

  /// Create a new group chat
  /// Returns group data with id, name, and member_count
  static Future<Map<String, dynamic>?> createGroup({
    required String name,
    required List<String> memberIds,
    String? avatarUrl,
    String? description,
  }) async {
    try {
      final token = await _storage.read(key: 'jwt_token');
      if (token == null) throw Exception('Not authenticated');

      final response = await http.post(
        Uri.parse('$baseUrl/api/groups'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'name': name,
          'member_ids': memberIds,
          if (avatarUrl != null) 'avatar_url': avatarUrl,
          if (description != null) 'description': description,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        print('✅ [API] Created group: ${data['name']} (${data['id']})');
        return data;
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Failed to create group');
      }
    } catch (e) {
      print('❌ [API] createGroup error: $e');
      rethrow;
    }
  }

  /// Get all groups the current user is a member of
  static Future<List<Map<String, dynamic>>> getMyGroups() async {
    try {
      final token = await _storage.read(key: 'jwt_token');
      if (token == null) throw Exception('Not authenticated');

      final response = await http.get(
        Uri.parse('$baseUrl/api/groups/mine'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        print('✅ [API] Got ${data.length} groups');
        return data.cast<Map<String, dynamic>>();
      } else {
        print('⚠️ [API] getMyGroups failed: ${response.statusCode}');
        return [];
      }
    } catch (e) {
      print('❌ [API] getMyGroups error: $e');
      return [];
    }
  }

  /// Get group details including member list
  static Future<Map<String, dynamic>?> getGroupDetails(String groupId) async {
    try {
      final token = await _storage.read(key: 'jwt_token');
      if (token == null) throw Exception('Not authenticated');

      final response = await http.get(
        Uri.parse('$baseUrl/api/groups/$groupId'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        print('⚠️ [API] getGroupDetails failed: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      print('❌ [API] getGroupDetails error: $e');
      return null;
    }
  }

  /// Leave a group
  static Future<bool> leaveGroup(String groupId) async {
    try {
      final token = await _storage.read(key: 'jwt_token');
      if (token == null) throw Exception('Not authenticated');

      final response = await http.post(
        Uri.parse('$baseUrl/api/groups/$groupId/leave'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        print('✅ [API] Left group $groupId');
        return true;
      } else {
        print('⚠️ [API] leaveGroup failed: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      print('❌ [API] leaveGroup error: $e');
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // ACCOUNT DELETION
  // ═══════════════════════════════════════════════════════════════════════════

  /// Delete user account permanently
  /// This will remove all user data from the server including:
  /// - Profile information
  /// - Posts and comments
  /// - Messages
  /// - Friend connections
  static Future<bool> deleteAccount() async {
    try {
      final token = await _storage.read(key: 'jwt_token');
      if (token == null) throw Exception('Not authenticated');

      print('🗑️ [API] Requesting account deletion...');

      final response = await http.delete(
        Uri.parse('$baseUrl/api/auth/delete-account'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );

      if (response.statusCode == 200) {
        print('✅ [API] Account deleted successfully');
        // Clear stored token
        await _storage.delete(key: 'jwt_token');
        await _storage.delete(key: 'current_user_id');
        return true;
      } else if (response.statusCode == 404) {
        // Account already deleted or doesn't exist
        print('⚠️ [API] Account not found (already deleted?)');
        await _storage.delete(key: 'jwt_token');
        return true;
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Failed to delete account');
      }
    } catch (e) {
      print('❌ [API] deleteAccount error: $e');
      rethrow;
    }
  }
}

