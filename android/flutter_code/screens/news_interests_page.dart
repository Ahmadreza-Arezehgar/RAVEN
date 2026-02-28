import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/ios_design_system.dart';
import '../services/news_service.dart';
import '../services/toast_service.dart';

/// News Interests Page - Select news categories
class NewsInterestsPage extends StatefulWidget {
  const NewsInterestsPage({super.key});

  @override
  State<NewsInterestsPage> createState() => _NewsInterestsPageState();
}

class _NewsInterestsPageState extends State<NewsInterestsPage> {
  final Set<String> _selectedInterests = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadInterests();
  }

  Future<void> _loadInterests() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('news_interests') ?? ['general'];
    
    setState(() {
      _selectedInterests.addAll(saved);
      _isLoading = false;
    });
  }

  Future<void> _saveInterests() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('news_interests', _selectedInterests.toList());
    
    if (mounted) {
      ToastService.showSuccess('Interests saved');
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: iOSDesignSystem.baseBackground,
      appBar: AppBar(
        title: const Text('News Interests'),
        backgroundColor: iOSDesignSystem.baseBackground,
        actions: [
          TextButton(
            onPressed: _saveInterests,
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Select topics you\'re interested in',
            style: iOSDesignSystem.textTheme.titleLarge,
          ),
          const SizedBox(height: 20),
          ...NewsService.categories.map((category) {
            final isSelected = _selectedInterests.contains(category);
            return _buildCategoryTile(category, isSelected);
          }),
        ],
      ),
    );
  }

  Widget _buildCategoryTile(String category, bool isSelected) {
    final icon = _getCategoryIcon(category);
    
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
      child: CheckboxListTile(
        value: isSelected,
        onChanged: (value) {
          setState(() {
            if (value == true) {
              _selectedInterests.add(category);
            } else {
              _selectedInterests.remove(category);
            }
          });
        },
        title: Row(
          children: [
            Icon(icon, color: iOSDesignSystem.accentBlue),
            const SizedBox(width: 12),
            Text(
              category[0].toUpperCase() + category.substring(1),
              style: iOSDesignSystem.textTheme.bodyLarge?.copyWith(
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
        activeColor: iOSDesignSystem.accentBlue,
      ),
    );
  }

  IconData _getCategoryIcon(String category) {
    switch (category) {
      case 'business':
        return Icons.business;
      case 'technology':
        return Icons.computer;
      case 'science':
        return Icons.science;
      case 'health':
        return Icons.favorite;
      case 'sports':
        return Icons.sports_soccer;
      case 'entertainment':
        return Icons.movie;
      default:
        return Icons.public;
    }
  }
}
