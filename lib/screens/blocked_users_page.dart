import 'package:flutter/material.dart';
import '../theme/ios_design_system.dart';
import '../gen_l10n/app_localizations.dart';
import '../services/database_helper.dart';
import '../services/toast_service.dart';

/// Blocked Users Page - View and manage blocked users
class BlockedUsersPage extends StatefulWidget {
  const BlockedUsersPage({super.key});

  @override
  State<BlockedUsersPage> createState() => _BlockedUsersPageState();
}

class _BlockedUsersPageState extends State<BlockedUsersPage> {
  List<Map<String, dynamic>> _blockedUsers = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadBlockedUsers();
  }

  Future<void> _loadBlockedUsers() async {
    setState(() => _isLoading = true);
    final users = await DatabaseHelper.instance.getBlockedUsers();
    if (mounted) {
      setState(() {
        _blockedUsers = users;
        _isLoading = false;
      });
    }
  }

  Future<void> _unblockUser(String userId, String username) async {
    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context)!.unblockUser),
        content: Text(
          AppLocalizations.of(context)!.unblockUserConfirmation(username),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(AppLocalizations.of(context)!.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppLocalizations.of(context)!.unblock),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await DatabaseHelper.instance.unblockUser(userId);
      _loadBlockedUsers(); // Refresh list
      
      if (mounted) {
        ToastService.showSuccess(AppLocalizations.of(context)!.userUnblocked(username));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: iOSDesignSystem.baseBackground,
      appBar: AppBar(
        title: Text(l10n.blockedUsers),
        backgroundColor: iOSDesignSystem.baseBackground,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _blockedUsers.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.block_outlined,
                        size: 80,
                        color: iOSDesignSystem.textSecondary.withOpacity(0.5),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        l10n.noBlockedUsers,
                        style: iOSDesignSystem.textTheme.bodyLarge?.copyWith(
                          color: iOSDesignSystem.textSecondary,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _blockedUsers.length,
                  itemBuilder: (context, index) {
                    final user = _blockedUsers[index];
                    final userId = user['userId'] as String;
                    final username = user['username'] as String? ?? 'Unknown';

                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: iOSDesignSystem.surfaceCard,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: iOSDesignSystem.glassBorderMedium,
                          width: iOSDesignSystem.glassBorderWidth,
                        ),
                      ),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: iOSDesignSystem.textSecondary.withOpacity(0.2),
                          child: Text(
                            username.isNotEmpty ? username[0].toUpperCase() : '?',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: iOSDesignSystem.textPrimary,
                            ),
                          ),
                        ),
                        title: Text(
                          username,
                          style: iOSDesignSystem.textTheme.bodyLarge,
                        ),
                        subtitle: Text(
                          userId.length > 16 
                              ? '${userId.substring(0, 16)}...'
                              : userId,
                          style: iOSDesignSystem.textTheme.bodySmall?.copyWith(
                            color: iOSDesignSystem.textSecondary,
                          ),
                        ),
                        trailing: TextButton(
                          onPressed: () => _unblockUser(userId, username),
                          child: Text(
                            l10n.unblock,
                            style: const TextStyle(
                              color: iOSDesignSystem.accentBlue,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
