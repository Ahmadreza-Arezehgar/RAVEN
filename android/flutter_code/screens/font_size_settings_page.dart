import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../theme/ios_design_system.dart';

/// Font Size Settings Page
/// Allows users to adjust text size throughout the app
class FontSizeSettingsPage extends StatelessWidget {
  const FontSizeSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final model = context.watch<AppModel>();
    
    return Scaffold(
      backgroundColor: iOSDesignSystem.baseBackground,
      appBar: AppBar(
        backgroundColor: iOSDesignSystem.baseBackground,
        elevation: 0,
        title: const Text('Font Size'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Description
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Text(
              'Adjust the text size for the entire app. All UI elements will scale accordingly.',
              style: iOSDesignSystem.textTheme.bodyMedium?.copyWith(
                color: iOSDesignSystem.textSecondary,
              ),
            ),
          ),
          
          const SizedBox(height: 24),
          
          // Size Selector with Slider
          Container(
            decoration: BoxDecoration(
              color: iOSDesignSystem.surfaceCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: iOSDesignSystem.glassBorderMedium,
                width: iOSDesignSystem.glassBorderWidth,
              ),
            ),
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Current size label
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Text Size',
                      style: iOSDesignSystem.textTheme.headlineMedium,
                    ),
                    Text(
                      _getSizeLabel(model.fontScale),
                      style: iOSDesignSystem.textTheme.bodyMedium?.copyWith(
                        color: iOSDesignSystem.accentBlue,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                
                const SizedBox(height: 20),
                
                // Slider
                SliderTheme(
                  data: SliderThemeData(
                    activeTrackColor: iOSDesignSystem.accentBlue,
                    inactiveTrackColor: iOSDesignSystem.surfaceElevated,
                    thumbColor: iOSDesignSystem.accentBlue,
                    overlayColor: iOSDesignSystem.accentBlue.withOpacity(0.2),
                    trackHeight: 4,
                  ),
                  child: Slider(
                    value: model.fontScale,
                    min: 0.85,
                    max: 1.3,
                    divisions: 3,
                    label: _getSizeLabel(model.fontScale),
                    onChanged: (value) {
                      model.setFontScale(value);
                    },
                  ),
                ),
                
                // Size markers
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Small',
                        style: iOSDesignSystem.textTheme.bodySmall?.copyWith(
                          color: iOSDesignSystem.textTertiary,
                        ),
                      ),
                      Text(
                        'Medium',
                        style: iOSDesignSystem.textTheme.bodySmall?.copyWith(
                          color: iOSDesignSystem.textTertiary,
                        ),
                      ),
                      Text(
                        'Large',
                        style: iOSDesignSystem.textTheme.bodySmall?.copyWith(
                          color: iOSDesignSystem.textTertiary,
                        ),
                      ),
                      Text(
                        'XL',
                        style: iOSDesignSystem.textTheme.bodySmall?.copyWith(
                          color: iOSDesignSystem.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 32),
          
          // Preview Section
          Container(
            decoration: BoxDecoration(
              color: iOSDesignSystem.surfaceCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: iOSDesignSystem.glassBorderMedium,
                width: iOSDesignSystem.glassBorderWidth,
              ),
            ),
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Preview',
                  style: iOSDesignSystem.textTheme.headlineMedium,
                ),
                
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 16),
                
                // Sample post preview
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 20,
                          backgroundColor: iOSDesignSystem.accentBlue.withOpacity(0.2),
                          child: const Icon(
                            Icons.person,
                            color: iOSDesignSystem.accentBlue,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Username',
                              style: iOSDesignSystem.textTheme.bodyLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              '2m ago',
                              style: iOSDesignSystem.textTheme.bodySmall?.copyWith(
                                color: iOSDesignSystem.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'This is a sample post to show how text will appear in the app with your selected font size.',
                      style: iOSDesignSystem.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Icon(
                          Icons.favorite_border,
                          size: 20,
                          color: iOSDesignSystem.textSecondary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '0',
                          style: iOSDesignSystem.textTheme.bodySmall?.copyWith(
                            color: iOSDesignSystem.textSecondary,
                          ),
                        ),
                        const SizedBox(width: 20),
                        Icon(
                          Icons.chat_bubble_outline,
                          size: 20,
                          color: iOSDesignSystem.textSecondary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '0',
                          style: iOSDesignSystem.textTheme.bodySmall?.copyWith(
                            color: iOSDesignSystem.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 24),
          
          // Reset Button
          OutlinedButton.icon(
            onPressed: () {
              model.setFontScale(1.0);
            },
            icon: const Icon(Icons.refresh),
            label: const Text('Reset to Default'),
            style: OutlinedButton.styleFrom(
              foregroundColor: iOSDesignSystem.textPrimary,
              side: BorderSide(
                color: iOSDesignSystem.glassBorderMedium,
              ),
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ],
      ),
    );
  }
  
  String _getSizeLabel(double scale) {
    if (scale <= 0.85) return 'Small';
    if (scale <= 1.0) return 'Medium';
    if (scale <= 1.15) return 'Large';
    return 'Extra Large';
  }
}
