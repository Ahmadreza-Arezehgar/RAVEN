import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../gen_l10n/app_localizations.dart';
import '../theme/ios_design_system.dart';

/// Language Selector Page
class LanguageSelectorPage extends StatelessWidget {
  const LanguageSelectorPage({super.key});

  static const languages = [
    {'code': 'en', 'name': 'English', 'nativeName': 'English'},
    {'code': 'fa', 'name': 'Persian', 'nativeName': 'فارسی'},
    {'code': 'es', 'name': 'Spanish', 'nativeName': 'Español'},
    {'code': 'de', 'name': 'German', 'nativeName': 'Deutsch'},
    {'code': 'zh', 'name': 'Chinese', 'nativeName': '中文'},
  ];

  @override
  Widget build(BuildContext context) {
    final model = context.watch<AppModel>();
    final currentLocale = model.locale.languageCode;
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: iOSDesignSystem.baseBackground,
      appBar: AppBar(
        title: Text(l10n.language),
        backgroundColor: iOSDesignSystem.baseBackground,
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: languages.length,
        itemBuilder: (context, index) {
          final lang = languages[index];
          final isSelected = currentLocale == lang['code'];

          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: iOSDesignSystem.surfaceCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSelected
                    ? iOSDesignSystem.accentBlue
                    : iOSDesignSystem.glassBorderMedium,
                width: isSelected ? 2 : 1,
              ),
            ),
            child: ListTile(
              title: Text(
                lang['nativeName']!,
                style: iOSDesignSystem.textTheme.bodyLarge?.copyWith(
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
              subtitle: Text(
                lang['name']!,
                style: iOSDesignSystem.textTheme.bodySmall?.copyWith(
                  color: iOSDesignSystem.textSecondary,
                ),
              ),
              trailing: isSelected
                  ? const Icon(
                      Icons.check_circle,
                      color: iOSDesignSystem.accentBlue,
                    )
                  : null,
              onTap: () {
                model.setLocale(Locale(lang['code']!));
                Navigator.pop(context);
              },
            ),
          );
        },
      ),
    );
  }
}
