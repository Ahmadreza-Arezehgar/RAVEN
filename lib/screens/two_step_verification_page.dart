import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../theme/ios_design_system.dart';
import '../gen_l10n/app_localizations.dart';
import '../models/security_settings_model.dart';
import '../services/security_settings_service.dart';
import '../services/api_service.dart';
import '../services/toast_service.dart';

/// Two-Step Verification Page
class TwoStepVerificationPage extends StatefulWidget {
  const TwoStepVerificationPage({super.key});

  @override
  State<TwoStepVerificationPage> createState() => _TwoStepVerificationPageState();
}

class _TwoStepVerificationPageState extends State<TwoStepVerificationPage> {
  final _securityService = SecuritySettingsService.instance;
  final _apiService =ApiService();
  
  bool _is2FAEnabled = false;
  String? _2FAMethod;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    setState(() => _isLoading = true);
    
    final model = context.read<AppModel>();
    final userId = model.currentUser?.id;
    
    if (userId != null) {
      final settings = await _securityService.getSecuritySettings(userId);
      if (mounted && settings != null) {
        setState(() {
          _is2FAEnabled = settings.twoFactorEnabled;
          _2FAMethod = settings.twoFactorMethod;
          _isLoading = false;
        });
      }
    } else {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _enable2FA() async {
    final model = context.read<AppModel>();
    final userId = model.currentUser?.id;
    final userEmail = model.currentUser?.email;
    
    if (userId == null) return;

    // Choose verification method
    final method = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context)!.chooseVerificationMethod),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.email_outlined),
              title: Text(AppLocalizations.of(context)!.emailVerification),
              subtitle: userEmail != null ? Text(userEmail) : null,
              onTap: () => Navigator.pop(context, 'email'),
            ),
            ListTile(
              leading: const Icon(Icons.sms_outlined),
              title: Text(AppLocalizations.of(context)!.smsVerification),
              subtitle: Text(AppLocalizations.of(context)!.comingSoon),
              enabled: false,
              onTap: () => Navigator.pop(context, 'sms'),
            ),
          ],
        ),
      ),
    );

    if (method == null) return;

    // Show loading
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      // Send verification code via API
      await _apiService.send2FACode(userId, method);
      
      if (!mounted) return;
      Navigator.pop(context); // Close loading dialog

      // Show code input dialog
      final code = await _showCodeInputDialog();
      
      if (code != null) {
        // Verify code
        final verified = await _apiService.verify2FACode(userId, code);
        
        if (verified) {
          // Enable 2FA in database
          final settings = await _securityService.getSecuritySettings(userId);
          if (settings != null) {
            final updated = settings.copyWith(
              twoFactorEnabled: true,
              twoFactorMethod: method,
            );
            await _securityService.updateSecuritySettings(updated);
            _loadSettings();
            
            if (mounted) {
              ToastService.showSuccess(AppLocalizations.of(context)!.twoFactorEnabled);
            }
          }
        } else {
          if (mounted) {
            ToastService.showError(AppLocalizations.of(context)!.invalidCode);
          }
        }
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context); // Close loading dialog
      ToastService.showError('Error: $e');
    }
  }

  Future<String?> _showCodeInputDialog() async {
    final controller = TextEditingController();
    
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context)!.enterVerificationCode),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: AppLocalizations.of(context)!.sixDigitCode,
            border: const OutlineInputBorder(),
          ),
          keyboardType: TextInputType.number,
          maxLength: 6,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocalizations.of(context)!.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(AppLocalizations.of(context)!.verify),
          ),
        ],
      ),
    );
  }

  Future<void> _disable2FA() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context)!.disable2FA),
        content: Text(AppLocalizations.of(context)!.disable2FAConfirmation),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(AppLocalizations.of(context)!.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppLocalizations.of(context)!.disable),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final model = context.read<AppModel>();
      final userId = model.currentUser?.id;
      
      if (userId != null) {
        final settings = await _securityService.getSecuritySettings(userId);
        if (settings != null) {
          final updated = settings.copyWith(
            twoFactorEnabled: false,
            twoFactorMethod: null,
          );
          await _securityService.updateSecuritySettings(updated);
          _loadSettings();
          
          if (mounted) {
            ToastService.showSuccess(AppLocalizations.of(context)!.twoFactorDisabled);
          }
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: iOSDesignSystem.baseBackground,
      appBar: AppBar(
        title: Text(l10n.twoStepVerification),
        backgroundColor: iOSDesignSystem.baseBackground,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: iOSDesignSystem.surfaceCard,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: iOSDesignSystem.glassBorderMedium,
                      width: iOSDesignSystem.glassBorderWidth,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _is2FAEnabled ? Icons.verified_user : Icons.verified_user_outlined,
                            color: _is2FAEnabled ? Colors.green : iOSDesignSystem.textSecondary,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _is2FAEnabled ? l10n.enabled : l10n.disabled,
                                  style: iOSDesignSystem.textTheme.titleMedium?.copyWith(
                                    color: _is2FAEnabled ? Colors.green : iOSDesignSystem.textSecondary,
                                  ),
                                ),
                                if (_is2FAEnabled && _2FAMethod != null)
                                  Text(
                                    l10n.verificationVia(_2FAMethod!),
                                    style: iOSDesignSystem.textTheme.bodySmall?.copyWith(
                                      color: iOSDesignSystem.textSecondary,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        l10n.twoFactorDescription,
                        style: iOSDesignSystem.textTheme.bodyMedium?.copyWith(
                          color: iOSDesignSystem.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _is2FAEnabled ? _disable2FA : _enable2FA,
                          icon: Icon(_is2FAEnabled ? Icons.close : Icons.check),
                          label: Text(_is2FAEnabled ? l10n.disable2FA : l10n.enable2FA),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _is2FAEnabled ? Colors.red : iOSDesignSystem.accentBlue,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
