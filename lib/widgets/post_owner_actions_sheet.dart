import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:ui';
import '../theme/ios_design_system.dart';
import '../models/post_model.dart';
import '../services/api_service.dart';
import '../services/toast_service.dart';

/// Post owner actions sheet - Liquid Glass capsule menu for Edit/Delete
class PostOwnerActionsSheet extends StatelessWidget {
  final Post post;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  
  const PostOwnerActionsSheet({
    super.key,
    required this.post,
    this.onEdit,
    this.onDelete,
  });
  
  /// Show the sheet as a modal bottom sheet
  static Future<void> show(
    BuildContext context, {
    required Post post,
    required VoidCallback onEdit,
    required Future<bool> Function() onDeleteConfirmed,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => PostOwnerActionsSheet(
        post: post,
        onEdit: () {
          Navigator.pop(context);
          onEdit();
        },
        onDelete: () async {
          Navigator.pop(context);
          // Show confirmation dialog
          final confirmed = await _showDeleteConfirmation(context);
          if (confirmed == true) {
            final success = await onDeleteConfirmed();
            if (success) {
              ToastService.showSuccess('Post deleted');
            } else {
              ToastService.showError('Failed to delete post');
            }
          }
        },
      ),
    );
  }
  
  static Future<bool?> _showDeleteConfirmation(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: iOSDesignSystem.surfaceCard.withOpacity(0.95),
        title: const Text('Delete Post?'),
        content: const Text('This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              'Cancel',
              style: TextStyle(color: iOSDesignSystem.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () {
              HapticFeedback.mediumImpact();
              Navigator.pop(context, true);
            },
            child: const Text(
              'Delete',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }
  
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: Container(
            decoration: BoxDecoration(
              color: iOSDesignSystem.surfaceElevated.withOpacity(0.85),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: Colors.white.withOpacity(0.15),
                width: 0.5,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Handle bar
                Container(
                  margin: const EdgeInsets.only(top: 12),
                  width: 36,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(2.5),
                  ),
                ),
                
                const SizedBox(height: 16),
                
                // Post preview
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    post.content.length > 100 
                        ? '${post.content.substring(0, 100)}...' 
                        : post.content,
                    style: TextStyle(
                      fontSize: 14,
                      color: iOSDesignSystem.textSecondary,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                
                const SizedBox(height: 16),
                
                // Edit option
                _ActionRow(
                  icon: Icons.edit_outlined,
                  label: 'Edit post',
                  color: iOSDesignSystem.accentBlue,
                  onTap: () {
                    HapticFeedback.lightImpact();
                    onEdit?.call();
                  },
                ),
                
                Divider(
                  color: Colors.white.withOpacity(0.1),
                  height: 1,
                ),
                
                // Delete option
                _ActionRow(
                  icon: Icons.delete_outline,
                  label: 'Delete post',
                  color: Colors.red,
                  onTap: () {
                    HapticFeedback.mediumImpact();
                    onDelete?.call();
                  },
                ),
                
                const SizedBox(height: 16),
                
                // Cancel button
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: SizedBox(
                      width: double.infinity,
                      child: TextButton(
                        onPressed: () => Navigator.pop(context),
                        style: TextButton.styleFrom(
                          backgroundColor: Colors.white.withOpacity(0.1),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                          'Cancel',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: iOSDesignSystem.textPrimary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;
  
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
  });
  
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 14),
            Text(
              label,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
