import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/user_model.dart';
import '../services/api_service.dart';
import '../services/toast_service.dart';

/// Full-screen profile picture viewer with screenshot detection
class ProfileViewScreen extends StatefulWidget {
  final User user;
  final String? token;
  
  const ProfileViewScreen({
    super.key,
    required this.user,
    this.token,
  });

  @override
  State<ProfileViewScreen> createState() => _ProfileViewScreenState();
}

class _ProfileViewScreenState extends State<ProfileViewScreen> with WidgetsBindingObserver {
  bool _isOwnProfile = false;
  
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }
  
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
  
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    
    // Detect screenshot when app becomes inactive then active
    if (state == AppLifecycleState.inactive) {
      _handleScreenshot();
    }
  }
  
  Future<void> _handleScreenshot() async {
    if (_isOwnProfile || widget.token == null) {
      return; // Don't record if viewing own profile or not authenticated
    }
    
    try {
      final url = Uri.parse('${ApiService.baseUrl}/api/users/${widget.user.id}/screenshot-notification');
      final response = await http.post(
        url,
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json',
        },
      );
      
      if (response.statusCode == 200) {
        ToastService.showWarning('${widget.user.username} has been notified of your screenshot');
      }
    } catch (e) {
      print('Error recording screenshot notification: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          widget.user.username,
          style: const TextStyle(color: Colors.white),
        ),
      ),
      body: Center(
        child: widget.user.avatarPath != null
            ? InteractiveViewer(
                child: CachedNetworkImage(
                  imageUrl: '${ApiService.baseUrl}${widget.user.avatarPath}',
                  fit: BoxFit.contain,
                  placeholder: (context, url) => const CircularProgressIndicator(),
                  errorWidget: (context, url, error) => const Icon(
                    Icons.error,
                    color: Colors.white,
                    size: 64,
                  ),
                ),
              )
            : const Icon(
                Icons.person,
                size: 200,
                color: Colors.white,
              ),
      ),
    );
  }
}

