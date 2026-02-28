import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import '../services/toast_service.dart';

/// Group Setup Page - Configure group name, photo, and bio
class GroupSetupPage extends StatefulWidget {
  final List<Map<String, dynamic>> selectedMembers;

  const GroupSetupPage({
    super.key,
    required this.selectedMembers,
  });

  @override
  State<GroupSetupPage> createState() => _GroupSetupPageState();
}

class _GroupSetupPageState extends State<GroupSetupPage> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _bioController = TextEditingController();
  final FocusNode _nameFocus = FocusNode();
  File? _selectedImage;
  bool _isCreating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _nameFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _bioController.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    HapticFeedback.selectionClick();
    
    try {
      final picker = ImagePicker();
      final result = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 80,
        maxWidth: 512,
        maxHeight: 512,
      );
      
      if (result != null) {
        setState(() {
          _selectedImage = File(result.path);
        });
      }
    } catch (e) {
      debugPrint('Error picking image: $e');
    }
  }

  void _createGroup() {
    // Validate name
    final name = _nameController.text.trim();
    if (name.length < 3) {
      HapticFeedback.heavyImpact();
      ToastService.showError('Group name must be at least 3 characters');
      return;
    }

    HapticFeedback.mediumImpact();
    
    setState(() => _isCreating = true);

    // Return group data
    Navigator.pop(context, {
      'name': name,
      'bio': _bioController.text.trim(),
      'imagePath': _selectedImage?.path,
      'memberIds': widget.selectedMembers.map((m) => m['id']).toList(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final safeTop = MediaQuery.of(context).padding.top;
    final safeBottom = MediaQuery.of(context).padding.bottom;
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;

    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: true,
      body: Column(
        children: [
          // ═══════════════════════════════════════════════════════════
          // HEADER
          // ═══════════════════════════════════════════════════════════
          ClipRRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
              child: Container(
                padding: EdgeInsets.only(
                  top: safeTop + 8,
                  left: 8,
                  right: 16,
                  bottom: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.4),
                  border: Border(
                    bottom: BorderSide(
                      color: Colors.white.withOpacity(0.08),
                      width: 0.5,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    // Back button
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios, color: Color(0xFF0A84FF)),
                      onPressed: () {
                        HapticFeedback.selectionClick();
                        Navigator.pop(context);
                      },
                    ),
                    
                    const Spacer(),
                    
                    const Text(
                      'New Group',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    
                    const Spacer(),
                    
                    const SizedBox(width: 48),
                  ],
                ),
              ),
            ),
          ),

          // ═══════════════════════════════════════════════════════════
          // CONTENT
          // ═══════════════════════════════════════════════════════════
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const SizedBox(height: 16),
                  
                  // ═══════════════════════════════════════════════════════════
                  // GROUP PHOTO
                  // ═══════════════════════════════════════════════════════════
                  GestureDetector(
                    onTap: _pickImage,
                    child: Container(
                      width: 100,
                      height: 100,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withOpacity(0.1),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.2),
                          width: 2,
                        ),
                        image: _selectedImage != null
                            ? DecorationImage(
                                image: FileImage(_selectedImage!),
                                fit: BoxFit.cover,
                              )
                            : null,
                      ),
                      child: _selectedImage == null
                          ? Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.camera_alt_outlined,
                                  size: 32,
                                  color: Colors.white.withOpacity(0.5),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Add Photo',
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.5),
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            )
                          : null,
                    ),
                  ),
                  
                  const SizedBox(height: 32),

                  // ═══════════════════════════════════════════════════════════
                  // GROUP NAME
                  // ═══════════════════════════════════════════════════════════
                  _GlassTextField(
                    controller: _nameController,
                    focusNode: _nameFocus,
                    label: 'Group Name',
                    hint: 'Enter group name...',
                    maxLength: 50,
                  ),
                  
                  const SizedBox(height: 16),

                  // ═══════════════════════════════════════════════════════════
                  // GROUP BIO
                  // ═══════════════════════════════════════════════════════════
                  _GlassTextField(
                    controller: _bioController,
                    label: 'Description (optional)',
                    hint: 'What is this group about?',
                    maxLength: 140,
                    maxLines: 3,
                  ),
                  
                  const SizedBox(height: 32),

                  // ═══════════════════════════════════════════════════════════
                  // MEMBERS PREVIEW
                  // ═══════════════════════════════════════════════════════════
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Members (${widget.selectedMembers.length})',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.7),
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: widget.selectedMembers.map((member) {
                      final username = member['username'] as String? ?? 'Unknown';
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.1),
                            width: 0.5,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircleAvatar(
                              radius: 12,
                              backgroundColor: const Color(0xFF0A84FF).withOpacity(0.2),
                              child: Text(
                                username.isNotEmpty ? username[0].toUpperCase() : '?',
                                style: const TextStyle(
                                  color: Color(0xFF0A84FF),
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              username,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          ),

          // ═══════════════════════════════════════════════════════════
          // CREATE BUTTON
          // ═══════════════════════════════════════════════════════════
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 12,
              bottom: keyboardHeight > 0 ? 12 : safeBottom + 12,
            ),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.8),
              border: Border(
                top: BorderSide(
                  color: Colors.white.withOpacity(0.1),
                  width: 0.5,
                ),
              ),
            ),
            child: GestureDetector(
              onTap: _isCreating ? null : _createGroup,
              child: Container(
                height: 52,
                decoration: BoxDecoration(
                  color: const Color(0xFF0A84FF),
                  borderRadius: BorderRadius.circular(26),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF0A84FF).withOpacity(0.3),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Center(
                  child: _isCreating
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Text(
                          'Create Group',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// GLASS TEXT FIELD
// ══════════════════════════════════════════════════════════════════════════
class _GlassTextField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final String label;
  final String hint;
  final int? maxLength;
  final int maxLines;

  const _GlassTextField({
    required this.controller,
    this.focusNode,
    required this.label,
    required this.hint,
    this.maxLength,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withOpacity(0.7),
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Colors.white.withOpacity(0.1),
              width: 0.5,
            ),
          ),
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            style: const TextStyle(color: Colors.white, fontSize: 16),
            maxLength: maxLength,
            maxLines: maxLines,
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.all(16),
              counterStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
            ),
          ),
        ),
      ],
    );
  }
}
