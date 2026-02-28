import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../theme/ios_design_system.dart';
import '../services/toast_service.dart';
import '../services/api_service.dart';

/// Liquid Glass Repost Bottom Sheet - Twitter/X style
/// Shows options for Repost and Quote Repost with smooth animations
class RepostSheet extends StatefulWidget {
  final String postId;
  final String authorName;
  final bool isReposted;
  final VoidCallback? onRepostComplete;

  const RepostSheet({
    super.key,
    required this.postId,
    required this.authorName,
    required this.isReposted,
    this.onRepostComplete,
  });

  /// Show the repost sheet as a modal bottom sheet
  static Future<void> show(
    BuildContext context, {
    required String postId,
    required String authorName,
    required bool isReposted,
    VoidCallback? onRepostComplete,
  }) {
    HapticFeedback.lightImpact();
    
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => RepostSheet(
        postId: postId,
        authorName: authorName,
        isReposted: isReposted,
        onRepostComplete: onRepostComplete,
      ),
    );
  }

  @override
  State<RepostSheet> createState() => _RepostSheetState();
}

class _RepostSheetState extends State<RepostSheet>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    
    // Spring-like scale animation
    _scaleAnimation = Tween<double>(begin: 0.9, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.elasticOut,
      ),
    );
    
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeOut,
      ),
    );
    
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleRepost() async {
    if (_isLoading) return;
    
    setState(() => _isLoading = true);
    HapticFeedback.lightImpact();
    
    // ✅ Use AppModel for proper state sync (updates cache + notifies listeners)
    final model = Provider.of<AppModel>(context, listen: false);
    await model.repostPost(widget.postId, widget.isReposted);
    
    if (mounted) {
      Navigator.pop(context);
      
      HapticFeedback.heavyImpact();
      ToastService.showSuccess(
        widget.isReposted ? 'Unreposted' : 'Reposted',
      );
      widget.onRepostComplete?.call();
    }
  }

  void _handleQuoteRepost() {
    HapticFeedback.lightImpact();
    Navigator.pop(context);
    
    // Show quote composer dialog
    _showQuoteComposer(context);
  }

  void _showQuoteComposer(BuildContext context) {
    final controller = TextEditingController();
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: iOSDesignSystem.surfaceCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(
            color: iOSDesignSystem.glassBorderMedium,
            width: 0.5,
          ),
        ),
        title: Text(
          'Quote Repost',
          style: iOSDesignSystem.textTheme.headlineMedium,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              style: iOSDesignSystem.textTheme.bodyLarge,
              maxLines: 4,
              maxLength: 280,
              decoration: InputDecoration(
                hintText: 'Add a comment...',
                hintStyle: TextStyle(color: iOSDesignSystem.textTertiary),
                filled: true,
                fillColor: iOSDesignSystem.surfaceElevated,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Icons.repeat,
                  size: 14,
                  color: iOSDesignSystem.textTertiary,
                ),
                const SizedBox(width: 4),
                Text(
                  'Quoting @${widget.authorName}',
                  style: TextStyle(
                    fontSize: 12,
                    color: iOSDesignSystem.textTertiary,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Cancel',
              style: TextStyle(color: iOSDesignSystem.textSecondary),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: iOSDesignSystem.accentBlue,
            ),
            onPressed: () async {
              final quote = controller.text.trim();
              if (quote.isEmpty) {
                ToastService.showError('Please add a comment');
                return;
              }
              
              Navigator.pop(context);
              
              final response = await ApiService.repost(widget.postId, quote: quote);
              
              if (response != null) {
                HapticFeedback.heavyImpact();
                ToastService.showSuccess('Quote posted');
                widget.onRepostComplete?.call();
              } else {
                ToastService.showError('Failed to quote repost');
              }
            },
            child: const Text('Post'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => FadeTransition(
        opacity: _fadeAnimation,
        child: ScaleTransition(
          scale: _scaleAnimation,
          alignment: Alignment.bottomCenter,
          child: child,
        ),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E).withOpacity(0.85),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              border: const Border(
                top: BorderSide(
                  color: iOSDesignSystem.glassBorderMedium,
                  width: 0.5,
                ),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Handle bar
                    Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    
                    const SizedBox(height: 24),
                    
                    // Repost option
                    _buildOption(
                      icon: Icons.repeat,
                      label: widget.isReposted ? 'Undo Repost' : 'Repost',
                      onTap: _handleRepost,
                      isLoading: _isLoading,
                      color: widget.isReposted ? iOSDesignSystem.accentGreen : null,
                    ),
                    
                    const SizedBox(height: 8),
                    
                    // Quote Repost option
                    if (!widget.isReposted)
                      _buildOption(
                        icon: Icons.edit_outlined,
                        label: 'Quote Repost',
                        onTap: _handleQuoteRepost,
                      ),
                    
                    const SizedBox(height: 16),
                    
                    // Cancel button
                    SizedBox(
                      width: double.infinity,
                      child: TextButton(
                        onPressed: () {
                          HapticFeedback.lightImpact();
                          Navigator.pop(context);
                        },
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: Text(
                          'Cancel',
                          style: TextStyle(
                            color: iOSDesignSystem.textSecondary,
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOption({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool isLoading = false,
    Color? color,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: isLoading ? null : onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Colors.white.withOpacity(0.08),
              width: 0.5,
            ),
          ),
          child: Row(
            children: [
              if (isLoading)
                SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: color ?? Colors.white,
                  ),
                )
              else
                Icon(
                  icon,
                  size: 22,
                  color: color ?? Colors.white,
                ),
              const SizedBox(width: 14),
              Text(
                label,
                style: TextStyle(
                  color: color ?? Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
