import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';
import 'dart:io';
import '../main.dart';
import '../services/api_service.dart';
import '../services/toast_service.dart';
import '../widgets/liquid_glass.dart';
import '../theme/modern_theme.dart';

class ProfileEditScreen extends StatefulWidget {
  const ProfileEditScreen({super.key});

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  late TextEditingController _usernameController;
  late TextEditingController _bioController;
  File? _selectedAvatar;
  final _picker = ImagePicker();
  
  @override
  void initState() {
    super.initState();
    final model = context.read<AppModel>();
    _usernameController = TextEditingController(text: model.currentUser?.username ?? '');
    _bioController = TextEditingController(text: model.currentUser?.bio ?? '');
  }
  
  @override
  void dispose() {
    _usernameController.dispose();
    _bioController.dispose();
    super.dispose();
  }
  
  /// Pick image and open Instagram-style circular crop UI
  Future<void> _pickAvatar(ImageSource source) async {
    final pickedFile = await _picker.pickImage(
      source: source,
      maxWidth: 1024,  // Higher res for cropping
      maxHeight: 1024,
      imageQuality: 95,
    );
    
    if (pickedFile == null) return;
    
    // ✅ Open Instagram-style crop UI
    final croppedFile = await _cropImage(File(pickedFile.path));
    
    if (croppedFile != null) {
      setState(() {
        _selectedAvatar = croppedFile;
      });
    }
  }
  
  /// Instagram-style circular crop with zoom/drag
  Future<File?> _cropImage(File imageFile) async {
    final cropped = await ImageCropper().cropImage(
      sourcePath: imageFile.path,
      aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
      compressQuality: 85,
      maxWidth: 512,
      maxHeight: 512,
      uiSettings: [
        IOSUiSettings(
          title: 'Adjust Photo',
          cropStyle: CropStyle.circle,  // ✅ Circular preview like Instagram
          aspectRatioLockEnabled: true,
          rotateButtonsHidden: true,
          resetButtonHidden: false,
          minimumAspectRatio: 1.0,
        ),
        AndroidUiSettings(
          toolbarTitle: 'Adjust Photo',
          toolbarColor: Colors.black,
          toolbarWidgetColor: Colors.white,
          statusBarColor: Colors.black,
          backgroundColor: Colors.black,
          activeControlsWidgetColor: ModernTheme.accentBlue,
          cropStyle: CropStyle.circle,  // ✅ Circular preview like Instagram
          lockAspectRatio: true,
          hideBottomControls: false,
        ),
      ],
    );
    
    if (cropped != null) {
      return File(cropped.path);
    }
    return null;
  }

  
  Future<void> _saveProfile() async {
    final model = context.read<AppModel>();
    final username = _usernameController.text.trim();
    
    if (username.isEmpty) {
      ToastService.showError('Username cannot be empty');
      return;
    }
    
    // Show loading
    ToastService.showInfo('Saving profile...');
    
    // ✅ Upload avatar to server if changed
    String? avatarUrl;
    if (_selectedAvatar != null) {
      print('📤 [ProfileEdit] Uploading avatar to server...');
      
      // Upload to server → get URL back
      final uploadedUrl = await ApiService.uploadImage(_selectedAvatar!);
      
      if (uploadedUrl != null) {
        avatarUrl = uploadedUrl;
        print('✅ [ProfileEdit] Avatar uploaded: $avatarUrl');
      } else {
        print('⚠️ [ProfileEdit] Upload failed, using local path as fallback');
        avatarUrl = _selectedAvatar!.path; // Fallback to local
      }
    }
    
    // Update user profile locally AND on server
    await model.updateUserProfile(
      username: username,
      bio: _bioController.text.trim(),
      avatarPath: avatarUrl, // ← Now this is a URL, not a local path!
    );
    
    print('✅ [ProfileEdit] Profile saved with avatarUrl: $avatarUrl');
    
    if (context.mounted) {
      ToastService.showSuccess('Profile updated!');
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = context.watch<AppModel>();
    
    return Scaffold(
      backgroundColor: ModernTheme.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text('Edit Profile', style: ModernTheme.heading3),
        actions: [
          TextButton(
            onPressed: _saveProfile,
            child: Text('Save', style: ModernTheme.bodyBold.copyWith(color: ModernTheme.accentBlue)),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(ModernTheme.spacing16),
        child: Column(
          children: [
            // Avatar
            GestureDetector(
              onTap: () => _showAvatarPicker(),
              child: Stack(
                children: [
                  Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: ModernTheme.primaryGradient,
                      boxShadow: ModernTheme.shadowMedium,
                    ),
                    child: ClipOval(
                      child: _selectedAvatar != null
                          ? Image.file(_selectedAvatar!, fit: BoxFit.cover)
                          : model.currentUser?.avatarPath != null
                              ? _buildAvatarImage(model.currentUser!.avatarPath!)
                              : Center(
                                  child: Text(
                                    _usernameController.text.isNotEmpty 
                                        ? _usernameController.text[0].toUpperCase()
                                        : 'U',
                                    style: ModernTheme.heading1.copyWith(fontSize: 48),
                                  ),
                                ),
                    ),
                  ),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Container(
                      padding: EdgeInsets.all(ModernTheme.spacing8),
                      decoration: BoxDecoration(
                        gradient: ModernTheme.accentGradient,
                        shape: BoxShape.circle,
                        boxShadow: ModernTheme.shadowSoft,
                      ),
                      child: Icon(Icons.camera_alt, size: 20, color: ModernTheme.textPrimary),
                    ),
                  ),
                ],
              ),
            ),
            
            SizedBox(height: ModernTheme.spacing32),
            
            // Username
            LiquidGlassContainer(
              padding: EdgeInsets.all(ModernTheme.spacing16),
              margin: EdgeInsets.only(bottom: ModernTheme.spacing16),
              child: TextField(
                controller: _usernameController,
                style: ModernTheme.body,
                decoration: InputDecoration(
                  labelText: 'Username',
                  labelStyle: ModernTheme.caption,
                  border: InputBorder.none,
                  prefixIcon: Icon(Icons.person, color: ModernTheme.accentBlue),
                ),
              ),
            ),
            
            // Bio
            LiquidGlassContainer(
              padding: EdgeInsets.all(ModernTheme.spacing16),
              margin: EdgeInsets.only(bottom: ModernTheme.spacing16),
              child: TextField(
                controller: _bioController,
                style: ModernTheme.body,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: 'Bio',
                  labelStyle: ModernTheme.caption,
                  border: InputBorder.none,
                  prefixIcon: Icon(Icons.info_outline, color: ModernTheme.accentBlue),
                ),
              ),
            ),
            
            // User ID (read-only)
            LiquidGlassContainer(
              padding: EdgeInsets.all(ModernTheme.spacing16),
              child: Row(
                children: [
                  Icon(Icons.fingerprint, color: ModernTheme.textTertiary),
                  SizedBox(width: ModernTheme.spacing12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('User ID', style: ModernTheme.caption),
                        Text(
                          model.currentUser?.id ?? '',
                          style: ModernTheme.tiny,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  void _showAvatarPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: ModernTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ModernTheme.radiusXLarge)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: EdgeInsets.all(ModernTheme.spacing16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(Icons.camera_alt, color: ModernTheme.accentBlue),
                title: Text('Take Photo', style: ModernTheme.body),
                onTap: () {
                  Navigator.pop(context);
                  _pickAvatar(ImageSource.camera);
                },
              ),
              ListTile(
                leading: Icon(Icons.photo_library, color: ModernTheme.accentPurple),
                title: Text('Choose from Gallery', style: ModernTheme.body),
                onTap: () {
                  Navigator.pop(context);
                  _pickAvatar(ImageSource.gallery);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  /// Build avatar image widget - handles both URL and local file path
  Widget _buildAvatarImage(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      // It's a URL from server
      return Image.network(
        path,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildPlaceholder(),
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return Center(
            child: CircularProgressIndicator(
              value: loadingProgress.expectedTotalBytes != null
                  ? loadingProgress.cumulativeBytesLoaded / loadingProgress.expectedTotalBytes!
                  : null,
              strokeWidth: 2,
              color: ModernTheme.accentBlue,
            ),
          );
        },
      );
    } else {
      // It's a local file path
      final file = File(path);
      if (file.existsSync()) {
        return Image.file(file, fit: BoxFit.cover);
      }
      return _buildPlaceholder();
    }
  }
  
  Widget _buildPlaceholder() {
    return Center(
      child: Text(
        _usernameController.text.isNotEmpty 
            ? _usernameController.text[0].toUpperCase()
            : 'U',
        style: ModernTheme.heading1.copyWith(fontSize: 48),
      ),
    );
  }
}
