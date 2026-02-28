import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../theme/ios_design_system.dart';
import '../gen_l10n/app_localizations.dart';
import '../models/security_settings_model.dart';
import '../services/security_settings_service.dart';
import '../services/toast_service.dart';

/// Auto-Delete Messages Page
class AutoDeleteMessagesPage extends StatefulWidget {
  const AutoDeleteMessagesPage({super.key});

  @override
  State<AutoDeleteMessagesPage> createState() => _AutoDeleteMessagesPageState();
}

class _AutoDeleteMessagesPageState extends State<AutoDeleteMessagesPage> {
  final _securityService = SecuritySettingsService.instance;
  
  bool _autoDeleteEnabled = false;
  int _autoDeletePeriodHours = 0;
  bool _isLoading = true;

  final List<Map<String, dynamic>> _periodOptions = [
    {'hours': 0, 'labelKey': 'never'},
    {'hours': 24, 'labelKey': 'twentyFourHours'},
    {'hours': 168, 'labelKey': 'sevenDays'},
    {'hours': 720, 'labelKey': 'thirtyDays'},
  ];

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
          _autoDeleteEnabled = settings.autoDeleteEnabled;
          _autoDeletePeriodHours = settings.autoDeletePeriodHours;
          _isLoading = false;
        });
      }
    } else {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _updateSettings(int hours) async {
    final model = context.read<AppModel>();
    final userId = model.currentUser?.id;
    
    if (userId == null) return;

    final settings = await _securityService.getSecuritySettings(userId);
    if (settings != null) {
      final updated = settings.copyWith(
        autoDeleteEnabled: hours > 0,
        autoDeletePeriodHours: hours,
      );
      await _securityService.updateSecuritySettings(updated);
      
      setState(() {
        _autoDeleteEnabled = hours > 0;
        _autoDeletePeriodHours = hours;
      });
      
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ToastService.showSuccess(
          hours > 0 ? l10n.autoDeleteEnabled : l10n.autoDeleteDisabled,
        );
      }
    }
  }

  String _getPeriodLabel(BuildContext context, String labelKey) {
    final l10n = AppLocalizations.of(context)!;
    switch (labelKey) {
      case 'never':
        return l10n.never;
      case 'twentyFourHours':
        return l10n.twentyFourHours;
      case 'sevenDays':
        return l10n.sevenDays;
      case 'thirtyDays':
        return l10n.thirtyDays;
      default:
        return labelKey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: iOSDesignSystem.baseBackground,
      appBar: AppBar(
        title: Text(l10n.autoDeleteMessages),
        backgroundColor: iOSDesignSystem.baseBackground,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // Description
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: iOSDesignSystem.accentBlue.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: iOSDesignSystem.accentBlue.withOpacity(0.3),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline, color: iOSDesignSystem.accentBlue),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          l10n.autoDeleteDescription,
                          style: iOSDesignSystem.textTheme.bodyMedium?.copyWith(
                            color: iOSDesignSystem.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                
                // Period options
                Text(
                  l10n.autoDeletePeriod,
                  style: iOSDesignSystem.textTheme.titleSmall?.copyWith(
                    color: iOSDesignSystem.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                
                ..._periodOptions.map((option) {
                  final hours = option['hours'] as int;
                  final labelKey = option['labelKey'] as String;
                  final isSelected = _autoDeletePeriodHours == hours;
                  
                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? iOSDesignSystem.accentBlue.withOpacity(0.1)
                          : iOSDesignSystem.surfaceCard,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isSelected
                            ? iOSDesignSystem.accentBlue
                            : iOSDesignSystem.glassBorderMedium,
                        width: isSelected ? 2 : 1,
                      ),
                    ),
                    child: ListTile(
                      leading: Icon(
                        hours == 0 ? Icons.do_not_disturb_on_outlined : Icons.timer_outlined,
                        color: isSelected
                            ? iOSDesignSystem.accentBlue
                            : iOSDesignSystem.textSecondary,
                      ),
                      title: Text(
                        _getPeriodLabel(context, labelKey),
                        style: iOSDesignSystem.textTheme.bodyLarge?.copyWith(
                          fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                      subtitle: hours > 0
                          ? Text(
                              l10n.messagesOlderThan(_getPeriodLabel(context, labelKey)),
                              style: iOSDesignSystem.textTheme.bodySmall?.copyWith(
                                color: iOSDesignSystem.textSecondary,
                              ),
                            )
                          : null,
                      trailing: isSelected
                          ? const Icon(Icons.check_circle, color: iOSDesignSystem.accentBlue)
                          : null,
                      onTap: () => _updateSettings(hours),
                    ),
                  );
                }).toList(),
                
                if (_autoDeleteEnabled) ...[
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.orange.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.orange.withOpacity(0.3),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_amber_outlined, color: Colors.orange),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            l10n.autoDeleteWarning,
                            style: iOSDesignSystem.textTheme.bodySmall?.copyWith(
                              color: iOSDesignSystem.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}
