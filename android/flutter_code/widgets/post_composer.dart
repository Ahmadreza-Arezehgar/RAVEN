import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../main.dart';
import '../models/post_model.dart';
import '../services/api_service.dart';
import '../services/toast_service.dart';
import '../theme/ios_design_system.dart';

/// iOS Liquid Glass Post Composer
/// Toolbar sticks to keyboard like Telegram/iMessage
class PostComposerSheet extends StatefulWidget {
  const PostComposerSheet({super.key});

  @override
  State<PostComposerSheet> createState() => _PostComposerSheetState();
  
  /// Show as modal with proper keyboard handling
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,  // ✅ Required for keyboard handling
      useSafeArea: false,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.3),
      builder: (_) => const PostComposerSheet(),
    );
  }
}

class _PostComposerSheetState extends State<PostComposerSheet> 
    with SingleTickerProviderStateMixin {
  final _textController = TextEditingController();
  final _focusNode = FocusNode();
  final _picker = ImagePicker();
  File? _selectedImage;
  bool _isPosting = false;
  static const int _maxCharacters = 280;
  
  late AnimationController _imageAnimController;
  late Animation<double> _imageScaleAnim;
  late Animation<double> _imageOpacityAnim;
  
  bool get _canPost => _textController.text.trim().isNotEmpty || _selectedImage != null;
  int get _characterCount => _textController.text.length;
  bool get _isOverLimit => _characterCount > _maxCharacters;
  bool get _hasImage => _selectedImage != null;
  
  @override
  void initState() {
    super.initState();
    _textController.addListener(() => setState(() {}));
    
    _imageAnimController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _imageScaleAnim = Tween<double>(begin: 0.9, end: 1.0).animate(
      CurvedAnimation(parent: _imageAnimController, curve: Curves.easeOutCubic),
    );
    _imageOpacityAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _imageAnimController, curve: Curves.easeOut),
    );
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }
  
  @override
  void dispose() {
    _textController.dispose();
    _focusNode.dispose();
    _imageAnimController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    HapticFeedback.selectionClick();
    try {
      final pickedFile = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );
      
      if (pickedFile != null) {
        final bytes = await pickedFile.readAsBytes();
        final dir = await getApplicationDocumentsDirectory();
        final fileName = 'post_${DateTime.now().millisecondsSinceEpoch}${p.extension(pickedFile.path)}';
        final savedFile = File(p.join(dir.path, fileName));
        await savedFile.writeAsBytes(bytes, flush: true);
        
        if (mounted) {
          setState(() => _selectedImage = savedFile);
          _imageAnimController.forward();
        }
      }
    } catch (e) {
      print('❌ Error picking image: $e');
      if (mounted) _showError('Failed to pick image');
    }
  }

  void _removeImage() {
    HapticFeedback.lightImpact();
    _imageAnimController.reverse().then((_) {
      if (mounted) setState(() => _selectedImage = null);
    });
  }

  Future<void> _post() async {
    if (!_canPost || _isPosting || _isOverLimit) return;
    
    HapticFeedback.mediumImpact();
    setState(() => _isPosting = true);
    
    // ✅ Get model reference BEFORE any async operations
    final model = context.read<AppModel>();
    
    try {
      final content = _textController.text.trim();
      
      if (model.currentUser == null) {
        _showError('Not logged in');
        return;
      }
      
      // ✅ Allow text, image, or both (Twitter-style)
      final hasText = content.isNotEmpty;
      final hasImage = _selectedImage != null;
      
      if (!hasText && !hasImage) {
        _showError('Post cannot be empty');
        if (mounted) setState(() => _isPosting = false);
        return;
      }
      
      String? imageUrl;
      if (_selectedImage != null) {
        if (!await _selectedImage!.exists()) {
          _showError('Image file not found. Please select again.');
          if (mounted) setState(() => _selectedImage = null);
          return;
        }
        imageUrl = await ApiService.uploadImage(_selectedImage!);
        if (!mounted) return; // ✅ Check mounted after async
        if (imageUrl == null) {
          _showError('Failed to upload image');
          return;
        }
      }

      final post = Post(
        id: const Uuid().v4(),
        authorId: model.currentUser!.id,
        authorName: model.currentUser!.username,
        authorAvatar: model.currentUser!.avatarPath,
        content: content.isNotEmpty ? content : '📷',
        imageUrl: imageUrl,
        timestamp: DateTime.now(),
        isLocal: false,
        sendMethod: PostSendMethod.wifi,
        actualSendMethod: PostSendMethod.wifi,
      );

      await model.createPost(post);
      
      if (mounted) {
        HapticFeedback.heavyImpact();
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) _showError('Error: $e');
    } finally {
      if (mounted) setState(() => _isPosting = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ToastService.showError(message);
  }

  @override
  Widget build(BuildContext context) {
    final model = context.watch<AppModel>();
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final safeTop = MediaQuery.of(context).padding.top;
    final safeBottom = MediaQuery.of(context).padding.bottom;
    
    // ✅ AnimatedPadding pushes entire sheet up with keyboard
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: bottomInset),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
          child: Container(
            // Take up most of screen but not all
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.85,
            ),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.5),
                  Colors.black.withOpacity(0.6),
                ],
              ),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              border: Border(
                top: BorderSide(color: Colors.white.withOpacity(0.15), width: 0.5),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Handle bar
                Container(
                  margin: const EdgeInsets.only(top: 12),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                
                // ─────────────────────────────────────────
                // TOP BAR: Cancel / Post
                // ─────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      GestureDetector(
                        onTap: () {
                          HapticFeedback.lightImpact();
                          Navigator.pop(context);
                        },
                        child: Text(
                          'Cancel',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.9),
                            fontSize: 17,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ),
                      
                      GestureDetector(
                        onTap: _canPost && !_isPosting && !_isOverLimit ? _post : null,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: _canPost && !_isOverLimit
                                ? iOSDesignSystem.accentBlue.withOpacity(0.9)
                                : Colors.white.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: _isPosting
                              ? const SizedBox(
                                  width: 16, height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                              : Text(
                                  'Post',
                                  style: TextStyle(
                                    color: _canPost && !_isOverLimit
                                        ? Colors.white
                                        : Colors.white.withOpacity(0.35),
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
                
                // ─────────────────────────────────────────
                // COMPOSE AREA (scrollable)
                // ─────────────────────────────────────────
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 8),
                        
                        // Avatar + TextField
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildAvatar(
                              model.currentUser?.avatarPath, 
                              model.currentUser?.username ?? 'U',
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextField(
                                controller: _textController,
                                focusNode: _focusNode,
                                maxLines: null,
                                minLines: _hasImage ? 2 : 3,
                                textInputAction: TextInputAction.newline,
                                cursorColor: iOSDesignSystem.accentBlue,
                                style: TextStyle(
                                  fontSize: _hasImage ? 16 : 18,
                                  color: Colors.white,
                                  height: 1.4,
                                ),
                                decoration: InputDecoration(
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  disabledBorder: InputBorder.none,
                                  filled: false,  // ✅ NO FILL - transparent!
                                  fillColor: Colors.transparent,
                                  hintText: _hasImage ? "Add a caption..." : "What's happening?",
                                  hintStyle: TextStyle(
                                    color: Colors.white.withOpacity(0.4),
                                    fontSize: _hasImage ? 16 : 18,
                                  ),
                                  contentPadding: EdgeInsets.zero,
                                  isDense: true,
                                ),
                              ),
                            ),
                          ],
                        ),
                        
                        // Character counter
                        if (_characterCount > 200)
                          Padding(
                            padding: const EdgeInsets.only(top: 8, left: 50),
                            child: Text(
                              '$_characterCount/$_maxCharacters',
                              style: TextStyle(
                                fontSize: 12,
                                color: _isOverLimit
                                    ? iOSDesignSystem.destructive
                                    : Colors.white.withOpacity(0.3),
                              ),
                            ),
                          ),
                        
                        // Image Preview
                        AnimatedSize(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOutCubic,
                          child: _selectedImage != null
                              ? Padding(
                                  padding: const EdgeInsets.only(top: 16),
                                  child: _buildImagePreview(),
                                )
                              : const SizedBox.shrink(),
                        ),
                        
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),
                
                // ─────────────────────────────────────────
                // TOOLBAR: Outside scroll, sticks to bottom
                // ─────────────────────────────────────────
                Container(
                  padding: EdgeInsets.only(
                    left: 16,
                    right: 16,
                    top: 10,
                    bottom: bottomInset > 0 ? 10 : safeBottom + 10,
                  ),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(color: Colors.white.withOpacity(0.1), width: 0.5),
                    ),
                  ),
                  child: Row(
                    children: [
                      // ✅ Only Photo button - removed GIF, Poll, Location
                      _buildToolbarIcon(Icons.photo_library_outlined, _pickImage),
                      const Spacer(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
  
  Widget _buildAvatar(String? avatarPath, String name) {
    // ✅ Determine if avatar is a URL or local file
    ImageProvider? imageProvider;
    if (avatarPath != null && avatarPath.isNotEmpty) {
      if (avatarPath.startsWith('http://') || avatarPath.startsWith('https://')) {
        // Remote URL
        imageProvider = NetworkImage(avatarPath);
      } else if (File(avatarPath).existsSync()) {
        // Local file
        imageProvider = FileImage(File(avatarPath));
      }
    }
    
    return Container(
      padding: const EdgeInsets.all(1.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [
            iOSDesignSystem.accentBlue.withOpacity(0.7),
            const Color(0xFF9B59B6).withOpacity(0.7),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: CircleAvatar(
        radius: 18,
        backgroundColor: Colors.black.withOpacity(0.3),
        backgroundImage: imageProvider,
        onBackgroundImageError: imageProvider != null 
            ? (exception, stackTrace) {
                print('⚠️ [Composer] Avatar load error: $exception');
              }
            : null,
        child: imageProvider == null
            ? Text(
                name.isNotEmpty ? name[0].toUpperCase() : 'U',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500, fontSize: 14),
              )
            : null,
      ),
    );
  }

  
  Widget _buildImagePreview() {
    if (_selectedImage == null || !_selectedImage!.existsSync()) {
      return const SizedBox.shrink();
    }
    
    return FadeTransition(
      opacity: _imageOpacityAnim,
      child: ScaleTransition(
        scale: _imageScaleAnim,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.3),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.file(
                  _selectedImage!,
                  width: double.infinity,
                  height: 180,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) {
                    return Container(
                      height: 180,
                      decoration: BoxDecoration(
                        color: Colors.grey.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Center(
                        child: Icon(Icons.broken_image, color: Colors.white38, size: 40),
                      ),
                    );
                  },
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: GestureDetector(
                  onTap: _removeImage,
                  child: ClipOval(
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.4),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.close_rounded, color: Colors.white70, size: 16),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _buildToolbarIcon(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          // ✅ Transparent background - no dark box
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          icon,
          color: iOSDesignSystem.accentBlue.withOpacity(0.9),
          size: 24,
        ),
      ),
    );
  }
}
