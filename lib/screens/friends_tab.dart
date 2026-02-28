import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../theme/ios_design_system.dart';
import '../screens/chat_page.dart';
import '../models/contact_model.dart';

/// Friends Tab - Shows list of accepted friends
class FriendsTab extends StatefulWidget {
  const FriendsTab({super.key});

  @override
  State<FriendsTab> createState() => _FriendsTabState();
}

class _FriendsTabState extends State<FriendsTab> {
  @override
  void initState() {
    super.initState();
    // Refresh friends list when tab loads
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final model = context.read<AppModel>();
      model.refreshFriendsList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final model = context.watch<AppModel>();
    final friends = model.friends;

    return Scaffold(
      backgroundColor: iOSDesignSystem.baseBackground,
      body: CustomScrollView(
        slivers: [
          // Header
          SliverToBoxAdapter(
            child: Container(
              padding: const EdgeInsets.fromLTRB(20, 60, 20, 20),
              child: Row(
                children: [
                  const Icon(
                    Icons.people,
                    color: iOSDesignSystem.accentBlue,
                    size: 28,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Friends',
                    style: iOSDesignSystem.textTheme.headlineMedium,
                  ),
                  const Spacer(),
                  Text(
                    '${friends.length}',
                    style: iOSDesignSystem.textTheme.bodyLarge?.copyWith(
                      color: iOSDesignSystem.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Friends List
          friends.isEmpty
              ? SliverFillRemaining(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.people_outline,
                          size: 64,
                          color: iOSDesignSystem.textTertiary,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No Friends Yet',
                          style: iOSDesignSystem.textTheme.titleLarge,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Accept friend requests to chat',
                          style: iOSDesignSystem.textTheme.bodyMedium?.copyWith(
                            color: iOSDesignSystem.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final friend = friends[index];
                      return _buildFriendCard(context, friend);
                    },
                    childCount: friends.length,
                  ),
                ),
        ],
      ),
    );
  }

  Widget _buildFriendCard(BuildContext context, Map<String, dynamic> friend) {
    final username = friend['username'] ?? 'Unknown';
    final userId = friend['id'];
    final avatarPath = friend['avatar_path'];

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: iOSDesignSystem.surfaceCard,
        borderRadius: BorderRadius.circular(16.0), // radiusLarge
        border: Border.all(
          color: iOSDesignSystem.glassBorderMedium,
          width: iOSDesignSystem.glassBorderWidth,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16.0), // radiusLarge
          onTap: () => _openChat(context, friend),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                // Avatar
                CircleAvatar(
                  radius: 24,
                  backgroundColor: iOSDesignSystem.accentBlue.withOpacity(0.2),
                  child: avatarPath != null
                      ? ClipOval(
                          child: Image.network(
                            avatarPath,
                            width: 48,
                            height: 48,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => _buildDefaultAvatar(username),
                          ),
                        )
                      : _buildDefaultAvatar(username),
                ),
                const SizedBox(width: 16),

                // Username
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        username,
                        style: iOSDesignSystem.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            Icons.check_circle,
                            size: 14,
                            color: iOSDesignSystem.success,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Friend',
                            style: iOSDesignSystem.textTheme.bodySmall?.copyWith(
                              color: iOSDesignSystem.success,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Message Button
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: iOSDesignSystem.accentBlue,
                    borderRadius: BorderRadius.circular(12.0), // radiusMedium
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.message,
                        color: Colors.white,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Message',
                        style: iOSDesignSystem.textTheme.bodyMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDefaultAvatar(String username) {
    return Text(
      username.isNotEmpty ? username[0].toUpperCase() : '?',
      style: const TextStyle(
        color: iOSDesignSystem.accentBlue,
        fontSize: 20,
        fontWeight: FontWeight.bold,
      ),
    );
  }

  void _openChat(BuildContext context, Map<String, dynamic> friend) {
    final model = context.read<AppModel>();
    final username = friend['username'] ?? 'Unknown';
    final userId = friend['id'];

    // Start chat with this friend
    model.startChatWith(userId, username);
    
    // Navigate to chat page
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const ChatPage(),
      ),
    );
  }
}
