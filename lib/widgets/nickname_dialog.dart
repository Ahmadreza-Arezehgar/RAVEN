import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/nickname_service.dart';
import '../services/toast_service.dart';

/// Shows the Liquid Glass nickname editor sheet
/// 
/// Returns true if nickname was changed, false otherwise
Future<bool> showNicknameSheet({
  required BuildContext context,
  required String peerId,
  required String username,
  String? avatarUrl,
  String? currentNickname,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withOpacity(0.5),
    builder: (ctx) => _NicknameEditorSheet(
      peerId: peerId,
      username: username,
      avatarUrl: avatarUrl,
      currentNickname: currentNickname,
    ),
  );
  return result ?? false;
}

class _NicknameEditorSheet extends StatefulWidget {
  final String peerId;
  final String username;
  final String? avatarUrl;
  final String? currentNickname;

  const _NicknameEditorSheet({
    required this.peerId,
    required this.username,
    this.avatarUrl,
    this.currentNickname,
  });

  @override
  State<_NicknameEditorSheet> createState() => _NicknameEditorSheetState();
}

class _NicknameEditorSheetState extends State<_NicknameEditorSheet> {
  late TextEditingController _controller;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentNickname ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _saveNickname() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);

    final nickname = _controller.text.trim();
    
    try {
      if (nickname.isEmpty) {
        await NicknameService.instance.removeNickname(widget.peerId);
        HapticFeedback.mediumImpact();
        ToastService.showSuccess('Nickname removed');
      } else {
        await NicknameService.instance.setNickname(widget.peerId, nickname);
        HapticFeedback.selectionClick();
        ToastService.showSuccess('Nickname saved');
      }
      
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      debugPrint('❌ Error saving nickname: $e');
      ToastService.showError('Failed to save nickname');
      setState(() => _isSaving = false);
    }
  }

  Future<void> _removeNickname() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);

    try {
      await NicknameService.instance.removeNickname(widget.peerId);
      HapticFeedback.mediumImpact();
      ToastService.showSuccess('Nickname removed');
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      debugPrint('❌ Error removing nickname: $e');
      ToastService.showError('Failed to remove nickname');
      setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).viewInsets.bottom;
    final hasNickname = widget.currentNickname != null && 
                        widget.currentNickname!.isNotEmpty;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomPadding),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E).withOpacity(0.85),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              border: Border.all(
                color: Colors.white.withOpacity(0.15),
                width: 0.5,
              ),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Drag handle
                  Container(
                    margin: const EdgeInsets.only(top: 12),
                    width: 36,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Avatar + Original Name
                  CircleAvatar(
                    radius: 40,
                    backgroundColor: const Color(0xFF0A84FF).withOpacity(0.2),
                    backgroundImage: widget.avatarUrl != null && 
                                     widget.avatarUrl!.isNotEmpty
                        ? NetworkImage(widget.avatarUrl!)
                        : null,
                    child: widget.avatarUrl == null || widget.avatarUrl!.isEmpty
                        ? Text(
                            widget.username.isNotEmpty 
                                ? widget.username[0].toUpperCase() 
                                : '?',
                            style: const TextStyle(
                              color: Color(0xFF0A84FF),
                              fontSize: 32,
                              fontWeight: FontWeight.w600,
                            ),
                          )
                        : null,
                  ),

                  const SizedBox(height: 12),

                  Text(
                    widget.username,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.6),
                      fontSize: 14,
                    ),
                  ),

                  const SizedBox(height: 28),

                  // Nickname Input Field
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.1),
                              width: 0.5,
                            ),
                          ),
                          child: TextField(
                            controller: _controller,
                            autofocus: true,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                            ),
                            textAlign: TextAlign.center,
                            decoration: InputDecoration(
                              hintText: 'Add a nickname...',
                              hintStyle: TextStyle(
                                color: Colors.white.withOpacity(0.35),
                              ),
                              border: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 16,
                              ),
                            ),
                            onChanged: (_) => setState(() {}),
                            onSubmitted: (_) => _saveNickname(),
                          ),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 28),

                  // Action Buttons
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      children: [
                        // Save Button
                        GestureDetector(
                          onTap: _isSaving ? null : _saveNickname,
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0A84FF),
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF0A84FF).withOpacity(0.3),
                                  blurRadius: 12,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Center(
                              child: _isSaving
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor: AlwaysStoppedAnimation(Colors.white),
                                      ),
                                    )
                                  : const Text(
                                      'Save',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 17,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                            ),
                          ),
                        ),

                        // Remove Button (only if has nickname)
                        if (hasNickname) ...[
                          const SizedBox(height: 12),
                          GestureDetector(
                            onTap: _isSaving ? null : _removeNickname,
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.08),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: Colors.white.withOpacity(0.1),
                                  width: 0.5,
                                ),
                              ),
                              child: const Center(
                                child: Text(
                                  'Remove Nickname',
                                  style: TextStyle(
                                    color: Color(0xFFFF453A),
                                    fontSize: 17,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// LEGACY: Keep old dialog for backward compatibility
// ═══════════════════════════════════════════════════════════════════════════
class NicknameDialog extends StatefulWidget {
  final String contactId;
  final String currentNickname;
  final String username;
  
  const NicknameDialog({
    super.key,
    required this.contactId,
    required this.currentNickname,
    required this.username,
  });

  @override
  State<NicknameDialog> createState() => _NicknameDialogState();
}

class _NicknameDialogState extends State<NicknameDialog> {
  late TextEditingController _controller;
  
  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentNickname);
  }
  
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Redirect to new sheet
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Navigator.pop(context);
      showNicknameSheet(
        context: context,
        peerId: widget.contactId,
        username: widget.username,
        currentNickname: widget.currentNickname,
      );
    });
    
    return const SizedBox.shrink();
  }
}
