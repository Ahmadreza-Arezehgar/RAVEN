import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/nickname_service.dart';
import 'nickname_dialog.dart';

/// Show a context menu with Liquid Glass styling at the given position
/// 
/// Returns the selected action or null if dismissed
Future<NicknameContextMenuAction?> showNicknameContextMenu({
  required BuildContext context,
  required Offset position,
  required String peerId,
  required String username,
  String? avatarUrl,
  bool hasNickname = false,
}) async {
  HapticFeedback.lightImpact();
  
  final RenderBox overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  
  return await showMenu<NicknameContextMenuAction>(
    context: context,
    position: RelativeRect.fromLTRB(
      position.dx - 80,
      position.dy - 20,
      overlay.size.width - position.dx - 80,
      overlay.size.height - position.dy,
    ),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
    ),
    color: Colors.transparent,
    elevation: 0,
    items: [
      PopupMenuItem<NicknameContextMenuAction>(
        enabled: false,
        padding: EdgeInsets.zero,
        child: _GlassContextMenu(
          hasNickname: hasNickname,
          onSetNickname: () {
            Navigator.pop(context, NicknameContextMenuAction.setNickname);
          },
          onRemoveNickname: hasNickname
              ? () => Navigator.pop(context, NicknameContextMenuAction.removeNickname)
              : null,
          onViewProfile: () {
            Navigator.pop(context, NicknameContextMenuAction.viewProfile);
          },
        ),
      ),
    ],
  );
}

enum NicknameContextMenuAction {
  setNickname,
  removeNickname,
  viewProfile,
}

/// Handle context menu action
Future<bool> handleNicknameContextMenuAction({
  required BuildContext context,
  required NicknameContextMenuAction action,
  required String peerId,
  required String username,
  String? avatarUrl,
  String? currentNickname,
  VoidCallback? onViewProfile,
}) async {
  switch (action) {
    case NicknameContextMenuAction.setNickname:
      return await showNicknameSheet(
        context: context,
        peerId: peerId,
        username: username,
        avatarUrl: avatarUrl,
        currentNickname: currentNickname,
      );
    
    case NicknameContextMenuAction.removeNickname:
      HapticFeedback.mediumImpact();
      await NicknameService.instance.removeNickname(peerId);
      return true;
    
    case NicknameContextMenuAction.viewProfile:
      onViewProfile?.call();
      return false;
  }
}

class _GlassContextMenu extends StatelessWidget {
  final bool hasNickname;
  final VoidCallback onSetNickname;
  final VoidCallback? onRemoveNickname;
  final VoidCallback onViewProfile;

  const _GlassContextMenu({
    required this.hasNickname,
    required this.onSetNickname,
    this.onRemoveNickname,
    required this.onViewProfile,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
        child: Container(
          width: 220,
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E).withOpacity(0.85),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Colors.white.withOpacity(0.15),
              width: 0.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.3),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _MenuItem(
                icon: Icons.edit_rounded,
                label: hasNickname ? 'Change Nickname' : 'Set Nickname',
                onTap: onSetNickname,
              ),
              if (hasNickname && onRemoveNickname != null) ...[
                _MenuDivider(),
                _MenuItem(
                  icon: Icons.delete_outline_rounded,
                  label: 'Remove Nickname',
                  onTap: onRemoveNickname!,
                  isDestructive: true,
                ),
              ],
              _MenuDivider(),
              _MenuItem(
                icon: Icons.person_outline_rounded,
                label: 'View Profile',
                onTap: onViewProfile,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isDestructive;

  const _MenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isDestructive = false,
  });

  @override
  State<_MenuItem> createState() => _MenuItemState();
}

class _MenuItemState extends State<_MenuItem> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.isDestructive
        ? const Color(0xFFFF453A)
        : Colors.white;

    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) {
        setState(() => _isPressed = false);
        HapticFeedback.selectionClick();
        widget.onTap();
      },
      onTapCancel: () => setState(() => _isPressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: _isPressed
              ? Colors.white.withOpacity(0.1)
              : Colors.transparent,
        ),
        child: Row(
          children: [
            Icon(
              widget.icon,
              size: 20,
              color: color.withOpacity(_isPressed ? 0.7 : 1.0),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                widget.label,
                style: TextStyle(
                  color: color.withOpacity(_isPressed ? 0.7 : 1.0),
                  fontSize: 16,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MenuDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 0.5,
      color: Colors.white.withOpacity(0.1),
    );
  }
}
