import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../gen_l10n/app_localizations.dart';
import '../services/toast_service.dart';
import '../theme/ios_design_system.dart';

/// Edit Bio Page
class EditBioPage extends StatefulWidget {
  const EditBioPage({super.key});

  @override
  State<EditBioPage> createState() => _EditBioPageState();
}

class _EditBioPageState extends State<EditBioPage> {
  final _bioController = TextEditingController();
  final int _maxLength = 150;
  bool _isLoading = false;

  bool _initialized = false;
  
  @override
  void initState() {
    super.initState();
  }
  
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // ✅ Use didChangeDependencies instead of initState for context.read
    if (!_initialized) {
      _initialized = true;
      final model = context.read<AppModel>();
      _bioController.text = model.currentUser?.bio ?? '';
    }
  }

  @override
  void dispose() {
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _saveBio() async {
    setState(() => _isLoading = true);

    try {
      final model = context.read<AppModel>();
      await model.updateUserProfile(bio: _bioController.text);
      
      if (mounted) {
        ToastService.showSuccess('Bio updated successfully');
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ToastService.showError('Error: $e');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    return Scaffold(
      backgroundColor: iOSDesignSystem.baseBackground,
      appBar: AppBar(
        title: Text(l10n.editBio),
        backgroundColor: iOSDesignSystem.baseBackground,
        actions: [
          TextButton(
            onPressed: _isLoading ? null : _saveBio,
            child: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.save),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            TextField(
              controller: _bioController,
              maxLines: 5,
              maxLength: _maxLength,
              decoration: const InputDecoration(
                hintText: 'Tell us about yourself...',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            Text(
              '${_bioController.text.length}/$_maxLength characters',
              style: iOSDesignSystem.textTheme.bodySmall?.copyWith(
                color: iOSDesignSystem.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
