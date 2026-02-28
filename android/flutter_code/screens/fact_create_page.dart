import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:hybrid_messenger/main.dart';
import 'package:hybrid_messenger/models/fact_model.dart';
import 'package:hybrid_messenger/services/knowledge_service.dart';
import 'package:hybrid_messenger/services/verify_service.dart';
import 'package:hybrid_messenger/services/fact_sync_service.dart';
import 'package:hybrid_messenger/theme/modern_theme.dart';
import 'package:hybrid_messenger/services/toast_service.dart';

/// Create or edit a Fact
class FactCreatePage extends StatefulWidget {
  final String? initialTitle;
  final Fact? editFact;

  const FactCreatePage({
    super.key,
    this.initialTitle,
    this.editFact,
  });

  @override
  State<FactCreatePage> createState() => _FactCreatePageState();
}

class _FactCreatePageState extends State<FactCreatePage> {
  final KnowledgeService _knowledge = KnowledgeService();
  final VerifyService _verify = VerifyService();
  final FactSyncService _sync = FactSyncService();
  
  final _titleController = TextEditingController();
  final _claimController = TextEditingController();
  final _tagsController = TextEditingController();
  
  final _formKey = GlobalKey<FormState>();
  
  int _currentStep = 0;
  bool _showName = true;
  bool _isSubmitting = false;
  String _lang = 'en';

  @override
  void initState() {
    super.initState();
    _knowledge.init();
    
    if (widget.initialTitle != null) {
      _titleController.text = widget.initialTitle!;
    }
    
    if (widget.editFact != null) {
      _titleController.text = widget.editFact!.title;
      _claimController.text = widget.editFact!.claim;
      _tagsController.text = widget.editFact!.tags.join(', ');
      _showName = widget.editFact!.privacyMode == PrivacyMode.showName;
      _lang = widget.editFact!.lang;
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _claimController.dispose();
    _tagsController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    
    setState(() => _isSubmitting = true);
    HapticFeedback.mediumImpact();
    
    try {
      final model = context.read<AppModel>();
      final userId = model.currentUser?.id;
      final displayName = model.currentUser?.username;
      
      // Parse tags
      final tags = _tagsController.text
          .split(',')
          .map((t) => t.trim().toLowerCase().replaceAll('#', ''))
          .where((t) => t.isNotEmpty)
          .toList();
      
      // Create fact
      final fact = Fact(
        id: widget.editFact?.id,
        title: _titleController.text.trim(),
        claim: _claimController.text.trim(),
        tags: tags,
        lang: _lang,
        authorId: userId,
        authorDisplayName: displayName,
        privacyMode: _showName ? PrivacyMode.showName : PrivacyMode.anonymous,
        verifyStatus: VerifyStatus.pending,
      );
      
      // Save to database
      if (widget.editFact != null) {
        await _knowledge.updateFact(fact);
      } else {
        await _knowledge.createFact(fact);
      }
      
      ToastService.showSuccess('Saved locally ✓');
      
      // Start verification in background
      _verify.verifyFact(fact.id, authorId: userId);
      
      // Sync to server or mesh (automatically chooses based on connectivity)
      _sync.syncFact(fact);
      
      Navigator.pop(context);
      ToastService.showInfo('Verifying fact...');
      
    } catch (e) {
      print('❌ [FactCreate] Error: $e');
      ToastService.showError('Failed to save');
    } finally {
      setState(() => _isSubmitting = false);
    }
  }

  void _nextStep() {
    if (_currentStep == 0) {
      if (_titleController.text.trim().isEmpty) {
        ToastService.showError('Please enter a title');
        return;
      }
      if (_claimController.text.trim().isEmpty) {
        ToastService.showError('Please enter the fact');
        return;
      }
    }
    
    HapticFeedback.selectionClick();
    setState(() => _currentStep++);
  }

  void _prevStep() {
    HapticFeedback.selectionClick();
    setState(() => _currentStep--);
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
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          widget.editFact != null ? 'Edit Fact' : 'Create Fact',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
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
            child: Form(
              key: _formKey,
              child: Column(
                children: [
                  // Step indicator
                  _buildStepIndicator(),
                  
                  // Form content
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: _currentStep == 0
                          ? _buildStep1()
                          : _buildStep2(),
                    ),
                  ),
                  
                  // Actions
                  _buildActions(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepIndicator() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
      child: Row(
        children: [
          _buildStepDot(0, 'Content'),
          Expanded(
            child: Container(
              height: 2,
              color: _currentStep >= 1
                  ? const Color(0xFF6366F1)
                  : Colors.white.withOpacity(0.2),
            ),
          ),
          _buildStepDot(1, 'Settings'),
        ],
      ),
    );
  }

  Widget _buildStepDot(int step, String label) {
    final isActive = _currentStep >= step;
    return Column(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isActive
                ? const Color(0xFF6366F1)
                : Colors.white.withOpacity(0.1),
            border: Border.all(
              color: isActive
                  ? const Color(0xFF6366F1)
                  : Colors.white.withOpacity(0.3),
              width: 2,
            ),
          ),
          child: Center(
            child: isActive && _currentStep > step
                ? const Icon(Icons.check, size: 18, color: Colors.white)
                : Text(
                    '${step + 1}',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isActive ? Colors.white : Colors.white54,
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: isActive ? Colors.white : Colors.white54,
          ),
        ),
      ],
    );
  }

  Widget _buildStep1() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'What do you know?',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Share a fact, insight, or piece of knowledge.',
          style: TextStyle(
            fontSize: 15,
            color: Colors.white.withOpacity(0.6),
          ),
        ),
        const SizedBox(height: 32),
        
        // Title field
        _buildLabel('Title'),
        const SizedBox(height: 8),
        _buildTextField(
          controller: _titleController,
          hint: 'e.g., Honey never spoils',
          maxLines: 1,
          maxLength: 100,
        ),
        
        const SizedBox(height: 24),
        
        // Claim field
        _buildLabel('Fact / Claim'),
        const SizedBox(height: 8),
        _buildTextField(
          controller: _claimController,
          hint: 'Archaeologists have found 3,000-year-old honey in Egyptian tombs that was still perfectly edible...',
          maxLines: 6,
          maxLength: 1000,
        ),
      ],
    );
  }

  Widget _buildStep2() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Settings',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Configure how your fact appears.',
          style: TextStyle(
            fontSize: 15,
            color: Colors.white.withOpacity(0.6),
          ),
        ),
        const SizedBox(height: 32),
        
        // Tags field
        _buildLabel('Tags (optional)'),
        const SizedBox(height: 8),
        _buildTextField(
          controller: _tagsController,
          hint: 'science, history, food',
          maxLines: 1,
        ),
        Text(
          'Separate tags with commas',
          style: TextStyle(
            fontSize: 12,
            color: Colors.white.withOpacity(0.4),
          ),
        ),
        
        const SizedBox(height: 32),
        
        // Language selector
        _buildLabel('Language'),
        const SizedBox(height: 8),
        _buildGlassContainer(
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _lang,
              isExpanded: true,
              dropdownColor: const Color(0xFF1A1A2E),
              style: const TextStyle(color: Colors.white, fontSize: 16),
              items: const [
                DropdownMenuItem(value: 'en', child: Text('English')),
                DropdownMenuItem(value: 'fa', child: Text('فارسی')),
                DropdownMenuItem(value: 'ar', child: Text('العربية')),
                DropdownMenuItem(value: 'de', child: Text('Deutsch')),
                DropdownMenuItem(value: 'fr', child: Text('Français')),
              ],
              onChanged: (v) => setState(() => _lang = v!),
            ),
          ),
        ),
        
        const SizedBox(height: 24),
        
        // Privacy toggle
        _buildGlassContainer(
          child: Row(
            children: [
              Icon(
                _showName ? Icons.person : Icons.person_off,
                color: Colors.white.withOpacity(0.7),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Show my name',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      _showName
                          ? 'Your name will appear on this fact'
                          : 'Publish anonymously',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.white.withOpacity(0.5),
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: _showName,
                onChanged: (v) => setState(() => _showName = v),
                activeColor: const Color(0xFF6366F1),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLabel(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: Colors.white.withOpacity(0.8),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hint,
    int maxLines = 1,
    int? maxLength,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            // ✅ شیشه‌ای - نه سیاه
            color: Colors.white.withOpacity(0.08),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: Colors.white.withOpacity(0.16),
              width: 1,
            ),
          ),
          child: TextField(
            controller: controller,
            maxLines: maxLines,
            maxLength: maxLength,
            style: const TextStyle(color: Colors.white, fontSize: 16),
            decoration: InputDecoration(
              // ✅ مهم: هیچ fill تیره‌ای ندهد
              filled: false,
              fillColor: Colors.transparent,
              hintText: hint,
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.4)),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.all(16),
              counterStyle: TextStyle(color: Colors.white.withOpacity(0.4)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGlassContainer({required Widget child}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withOpacity(0.10),
                Colors.white.withOpacity(0.05),
              ],
            ),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: Colors.white.withOpacity(0.14),
              width: 1,
            ),
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _buildActions() {
    return Container(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        16 + MediaQuery.of(context).padding.bottom,
      ),
      child: Row(
        children: [
          if (_currentStep > 0)
            Expanded(
              child: GestureDetector(
                onTap: _prevStep,
                child: Container(
                  height: 56,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Center(
                    child: Text(
                      'Back',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (_currentStep > 0) const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: GestureDetector(
              onTap: _isSubmitting
                  ? null
                  : (_currentStep == 1 ? _submit : _nextStep),
              child: Container(
                height: 56,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF6366F1).withOpacity(0.4),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Center(
                  child: _isSubmitting
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          _currentStep == 1 ? 'Submit' : 'Next',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
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
