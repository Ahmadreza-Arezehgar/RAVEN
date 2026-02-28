import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hybrid_messenger/models/fact_model.dart';
import 'package:hybrid_messenger/services/knowledge_service.dart';
import 'package:hybrid_messenger/theme/modern_theme.dart';
import 'package:hybrid_messenger/screens/fact_create_page.dart';
import 'package:hybrid_messenger/services/toast_service.dart';

/// View a single fact in detail
class FactDetailPage extends StatefulWidget {
  final Fact fact;

  const FactDetailPage({
    super.key,
    required this.fact,
  });

  @override
  State<FactDetailPage> createState() => _FactDetailPageState();
}

class _FactDetailPageState extends State<FactDetailPage> {
  final KnowledgeService _knowledge = KnowledgeService();
  late Fact _fact;

  @override
  void initState() {
    super.initState();
    _fact = widget.fact;
  }

  Future<void> _refreshFact() async {
    final updated = await _knowledge.getFact(_fact.id);
    if (updated != null) {
      setState(() => _fact = updated);
    }
  }

  void _shareFact() {
    HapticFeedback.lightImpact();
    // Copy to clipboard instead of share (share_plus not installed)
    Clipboard.setData(ClipboardData(
      text: '📚 ${_fact.title}\n\n${_fact.claim}\n\n#Knowledge #Raven',
    ));
    ToastService.showSuccess('Copied to clipboard');
  }

  void _editFact() {
    HapticFeedback.lightImpact();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FactCreatePage(editFact: _fact),
      ),
    ).then((_) => _refreshFact());
  }

  Future<void> _deleteFact() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text(
          'Delete Fact?',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'This action cannot be undone.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _knowledge.deleteFact(_fact.id);
      ToastService.showSuccess('Fact deleted');
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ModernTheme.background,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.share, color: Colors.white),
            onPressed: _shareFact,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            color: const Color(0xFF1A1A2E),
            onSelected: (action) {
              if (action == 'edit') _editFact();
              if (action == 'delete') _deleteFact();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'edit',
                child: Row(
                  children: [
                    Icon(Icons.edit, color: Colors.white70, size: 20),
                    SizedBox(width: 12),
                    Text('Edit', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(Icons.delete, color: Colors.red, size: 20),
                    SizedBox(width: 12),
                    Text('Delete', style: TextStyle(color: Colors.red)),
                  ],
                ),
              ),
            ],
          ),
        ],
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(color: Colors.transparent),
          ),
        ),
      ),
      body: Stack(
        children: [
          // Background
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFF0D0D0D),
                  Color(0xFF1A1A2E),
                  Color(0xFF16213E),
                ],
              ),
            ),
          ),
          
          // Content
          SafeArea(
            child: RefreshIndicator(
              onRefresh: _refreshFact,
              color: Colors.white,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Verify badge
                    _buildVerifyBadge(),
                    
                    const SizedBox(height: 20),
                    
                    // Title
                    Text(
                      _fact.title,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        height: 1.3,
                      ),
                    ),
                    
                    const SizedBox(height: 24),
                    
                    // Main claim
                    _buildGlassCard(
                      child: Text(
                        _fact.claim,
                        style: TextStyle(
                          fontSize: 17,
                          color: Colors.white.withOpacity(0.9),
                          height: 1.7,
                        ),
                      ),
                    ),
                    
                    const SizedBox(height: 24),
                    
                    // Tags
                    if (_fact.tags.isNotEmpty) ...[
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _fact.tags.map((tag) => _buildTag(tag)).toList(),
                      ),
                      const SizedBox(height: 24),
                    ],
                    
                    // Verify reason
                    if (_fact.verifyReason != null && _fact.verifyReason!.isNotEmpty) ...[
                      _buildSection(
                        icon: Icons.psychology,
                        title: 'AI Analysis',
                        child: Text(
                          _fact.verifyReason!,
                          style: TextStyle(
                            fontSize: 15,
                            color: Colors.white.withOpacity(0.8),
                            height: 1.5,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    
                    // Sources
                    if (_fact.sources.isNotEmpty) ...[
                      _buildSection(
                        icon: Icons.link,
                        title: 'Sources',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: _fact.sources.map((src) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: GestureDetector(
                              onTap: () {
                                // TODO: Open URL
                              },
                              child: Text(
                                src,
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: Color(0xFF6366F1),
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                            ),
                          )).toList(),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    
                    // Metadata
                    _buildMetadata(),
                    
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVerifyBadge() {
    final (icon, color, text, bgColor) = switch (_fact.verifyStatus) {
      VerifyStatus.verified => (
        Icons.verified,
        const Color(0xFF4CAF50),
        'Verified',
        const Color(0xFF4CAF50).withOpacity(0.15),
      ),
      VerifyStatus.pending => (
        Icons.hourglass_empty,
        const Color(0xFFFF9800),
        'Pending Verification',
        const Color(0xFFFF9800).withOpacity(0.15),
      ),
      VerifyStatus.needsReview => (
        Icons.help_outline,
        const Color(0xFFFF9800),
        'Needs Review',
        const Color(0xFFFF9800).withOpacity(0.15),
      ),
      VerifyStatus.rejected => (
        Icons.error_outline,
        const Color(0xFFF44336),
        'Disputed',
        const Color(0xFFF44336).withOpacity(0.15),
      ),
      VerifyStatus.unverified => (
        Icons.help_outline,
        Colors.white54,
        'Unverified',
        Colors.white.withOpacity(0.05),
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
          if (_fact.verifyScore > 0) ...[
            const SizedBox(width: 8),
            Text(
              '${_fact.verifyScore}%',
              style: TextStyle(
                fontSize: 13,
                color: color.withOpacity(0.8),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildGlassCard({required Widget child}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.08),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withOpacity(0.12)),
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _buildTag(String tag) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      child: Text(
        '#$tag',
        style: TextStyle(
          fontSize: 14,
          color: Colors.white.withOpacity(0.7),
        ),
      ),
    );
  }

  Widget _buildSection({
    required IconData icon,
    required String title,
    required Widget child,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 18, color: Colors.white54),
                  const SizedBox(width: 8),
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.white.withOpacity(0.7),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              child,
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMetadata() {
    return Row(
      children: [
        // Author
        if (_fact.privacyMode == PrivacyMode.showName && 
            _fact.authorDisplayName != null) ...[
          Icon(
            Icons.person_outline,
            size: 16,
            color: Colors.white.withOpacity(0.4),
          ),
          const SizedBox(width: 6),
          Text(
            _fact.authorDisplayName!,
            style: TextStyle(
              fontSize: 13,
              color: Colors.white.withOpacity(0.5),
            ),
          ),
          const SizedBox(width: 16),
        ],
        
        // Date
        Icon(
          Icons.access_time,
          size: 16,
          color: Colors.white.withOpacity(0.4),
        ),
        const SizedBox(width: 6),
        Text(
          _formatDate(_fact.createdAt),
          style: TextStyle(
            fontSize: 13,
            color: Colors.white.withOpacity(0.5),
          ),
        ),
        
        const Spacer(),
        
        // Language badge
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            _fact.lang.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Colors.white.withOpacity(0.6),
            ),
          ),
        ),
      ],
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inDays == 0) {
      if (diff.inHours == 0) {
        return '${diff.inMinutes}m ago';
      }
      return '${diff.inHours}h ago';
    } else if (diff.inDays < 7) {
      return '${diff.inDays}d ago';
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }
}
