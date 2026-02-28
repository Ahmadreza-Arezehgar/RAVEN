import 'package:flutter/material.dart';
import '../theme/ios_design_system.dart';
import '../gen_l10n/app_localizations.dart';
import '../services/security_settings_service.dart';
import '../services/biometric_auth_service.dart';
import '../services/toast_service.dart';

/// Passcode Setup Page - Create or change app passcode
class PasscodeSetupPage extends StatefulWidget {
  const PasscodeSetupPage({super.key});

  @override
  State<PasscodeSetupPage> createState() => _PasscodeSetupPageState();
}

class _PasscodeSetupPageState extends State<PasscodeSetupPage> {
  final _securityService = SecuritySettingsService.instance;
  final _biometricService = BiometricAuthService.instance;
  
  bool _hasPasscode = false;
  bool _passcodeEnabled = false;
  bool _biometricEnabled = false;
  bool _biometricAvailable = false;
  String _biometricName = 'Biometric';
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    setState(() => _isLoading = true);
    
    final hasPasscode = await _securityService.hasPasscode();
    final passcodeEnabled = await _securityService.isPasscodeEnabled();
    final biometricEnabled = await _securityService.isBiometricEnabled();
    final biometricAvailable = await _biometricService.isDeviceSupported();
    final biometricName = await _biometricService.getBiometricName();
    
    if (mounted) {
      setState(() {
        _hasPasscode = hasPasscode;
        _passcodeEnabled = passcodeEnabled;
        _biometricEnabled = biometricEnabled;
        _biometricAvailable = biometricAvailable;
        _biometricName = biometricName;
        _isLoading = false;
      });
    }
  }

  Future<void> _setupPasscode() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => const PasscodeInputPage(mode: PasscodeInputMode.setup),
      ),
    );
    
    if (result == true) {
      _loadSettings();
      if (mounted) {
        ToastService.showSuccess(AppLocalizations.of(context)!.passcodeSet);
      }
    }
  }

  Future<void> _changePasscode() async {
    // First verify old passcode
    final verified = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => const PasscodeInputPage(mode: PasscodeInputMode.verify),
      ),
    );
    
    if (verified == true) {
      // Now set new passcode
      _setupPasscode();
    }
  }

  Future<void> _removePasscode() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context)!.removePasscode),
        content: Text(AppLocalizations.of(context)!.removePasscodeConfirmation),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(AppLocalizations.of(context)!.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(AppLocalizations.of(context)!.remove),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _securityService.deletePasscode();
      _loadSettings();
      if (mounted) {
        ToastService.showSuccess(AppLocalizations.of(context)!.passcodeRemoved);
      }
    }
  }

  Future<void> _toggleBiometric(bool value) async {
    if (value && !_hasPasscode) {
      ToastService.showError(AppLocalizations.of(context)!.setupPasscodeFirst);
      return;
    }

    await _securityService.setBiometricEnabled(value);
    setState(() => _biometricEnabled = value);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: iOSDesignSystem.baseBackground,
      appBar: AppBar(
        title: Text(l10n.passcodeAndFaceId),
        backgroundColor: iOSDesignSystem.baseBackground,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // Passcode section
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
                    children: [
                      if (!_hasPasscode)
                        ListTile(
                          leading: const Icon(Icons.lock_outline, color: iOSDesignSystem.accentBlue),
                          title: Text(l10n.setupPasscode, style: iOSDesignSystem.textTheme.bodyLarge),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: _setupPasscode,
                        )
                      else ...[
                        ListTile(
                          leading: const Icon(Icons.lock, color: Colors.green),
                          title: Text(l10n.passcodeEnabled, style: iOSDesignSystem.textTheme.bodyLarge),
                        ),
                        const Divider(),
                        ListTile(
                          leading: const Icon(Icons.edit_outlined, color: iOSDesignSystem.accentBlue),
                          title: Text(l10n.changePasscode, style: iOSDesignSystem.textTheme.bodyLarge),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: _changePasscode,
                        ),
                        const Divider(),
                        ListTile(
                          leading: const Icon(Icons.delete_outline, color: Colors.red),
                          title: Text(
                            l10n.removePasscode,
                            style: iOSDesignSystem.textTheme.bodyLarge?.copyWith(color: Colors.red),
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: _removePasscode,
                        ),
                      ],
                    ],
                  ),
                ),
                
                if (_hasPasscode && _biometricAvailable) ...[
                  const SizedBox(height: 24),
                  // Biometric section
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
                    child: SwitchListTile(
                      secondary: const Icon(Icons.fingerprint, color: iOSDesignSystem.accentBlue),
                      title: Text(l10n.enableBiometric, style: iOSDesignSystem.textTheme.bodyLarge),
                      subtitle: Text(
                        l10n.useBiometricToUnlock(_biometricName),
                        style: iOSDesignSystem.textTheme.bodySmall?.copyWith(
                          color: iOSDesignSystem.textSecondary,
                        ),
                      ),
                      value: _biometricEnabled,
                      onChanged: _toggleBiometric,
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

enum PasscodeInputMode { setup, verify, unlock }

/// Passcode Input Page - Enter and confirm passcode
class PasscodeInputPage extends StatefulWidget {
  final PasscodeInputMode mode;
  
  const PasscodeInputPage({
    super.key,
    required this.mode,
  });

  @override
  State<PasscodeInputPage> createState() => _PasscodeInputPageState();
}

class _PasscodeInputPageState extends State<PasscodeInputPage> {
  final _securityService = SecuritySettingsService.instance;
  String _passcode = '';
  String? _firstPasscode;
  bool _isConfirmingPasscode = false;

  void _onNumberTap(String number) {
    if (_passcode.length < 6) {
      setState(() {
        _passcode += number;
      });

      if (_passcode.length == 6) {
        _handlePasscodeComplete();
      }
    }
  }

  void _onBackspace() {
    if (_passcode.isNotEmpty) {
      setState(() {
        _passcode = _passcode.substring(0, _passcode.length - 1);
      });
    }
  }

  Future<void> _handlePasscodeComplete() async {
    await Future.delayed(const Duration(milliseconds: 200));

    if (widget.mode == PasscodeInputMode.setup) {
      if (!_isConfirmingPasscode) {
        // First entry - ask to confirm
        setState(() {
          _firstPasscode = _passcode;
          _passcode = '';
          _isConfirmingPasscode = true;
        });
      } else {
        // Confirmation entry
        if (_passcode == _firstPasscode) {
          await _securityService.setPasscode(_passcode);
          if (mounted) {
            Navigator.pop(context, true);
          }
        } else {
          if (mounted) {
            ToastService.showError(AppLocalizations.of(context)!.passcodeMismatch);
            setState(() {
              _passcode = '';
              _firstPasscode = null;
              _isConfirmingPasscode = false;
            });
          }
        }
      }
    } else if (widget.mode == PasscodeInputMode.verify || 
               widget.mode == PasscodeInputMode.unlock) {
      final isValid = await _securityService.verifyPasscode(_passcode);
      if (isValid) {
        if (mounted) {
          Navigator.pop(context, true);
        }
      } else {
        if (mounted) {
          ToastService.showError(AppLocalizations.of(context)!.incorrectPasscode);
          setState(() => _passcode = '');
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    String title;
    if (widget.mode == PasscodeInputMode.setup) {
      title = _isConfirmingPasscode ? l10n.confirmPasscode : l10n.enterPasscode;
    } else if (widget.mode == PasscodeInputMode.verify) {
      title = l10n.enterCurrentPasscode;
    } else {
      title = l10n.unlockApp;
    }

    return Scaffold(
      backgroundColor: iOSDesignSystem.baseBackground,
      appBar: widget.mode != PasscodeInputMode.unlock
          ? AppBar(
              title: Text(title),
              backgroundColor: iOSDesignSystem.baseBackground,
            )
          : null,
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (widget.mode == PasscodeInputMode.unlock) ...[
              const Icon(Icons.lock, size: 64, color: iOSDesignSystem.accentBlue),
              const SizedBox(height: 24),
            ],
            Text(
              title,
              style: iOSDesignSystem.textTheme.headlineMedium,
            ),
            const SizedBox(height: 40),
            // Passcode dots
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                6,
                (index) => Container(
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: index < _passcode.length
                        ? iOSDesignSystem.accentBlue
                        : iOSDesignSystem.textSecondary.withOpacity(0.3),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 60),
            // Number pad
            _buildNumberPad(),
          ],
        ),
      ),
    );
  }

  Widget _buildNumberPad() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Column(
        children: [
          _buildNumberRow(['1', '2', '3']),
          const SizedBox(height: 16),
          _buildNumberRow(['4', '5', '6']),
          const SizedBox(height: 16),
          _buildNumberRow(['7', '8', '9']),
          const SizedBox(height: 16),
          _buildNumberRow(['', '0', '⌫']),
        ],
      ),
    );
  }

  Widget _buildNumberRow(List<String> numbers) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: numbers.map((number) {
        if (number.isEmpty) {
          return const SizedBox(width: 80, height: 80);
        }
        
        return InkWell(
          onTap: () {
            if (number == '⌫') {
              _onBackspace();
            } else {
              _onNumberTap(number);
            }
          },
          borderRadius: BorderRadius.circular(40),
          child: Container(
            width: 80,
            height: 80,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: iOSDesignSystem.surfaceCard,
              border: Border.all(
                color: iOSDesignSystem.glassBorderMedium,
                width: 1,
              ),
            ),
            child: Text(
              number,
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w500,
                color: iOSDesignSystem.textPrimary,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
