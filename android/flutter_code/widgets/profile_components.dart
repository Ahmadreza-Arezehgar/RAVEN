import 'dart:io';
import 'package:flutter/material.dart';
import '../theme/mobile_theme.dart';
import '../widgets/action_components.dart';

/// Profile header component
class ProfileHeader extends StatelessWidget {
  final String username;
  final String? bio;
  final String? avatarPath;
  final int postsCount;
  final int followersCount;
  final int followingCount;
  final FollowStatus followStatus;
  final bool isCurrentUser;
  final VoidCallback? onFollowPressed;
  final VoidCallback? onEditProfile;
  final VoidCallback? onPostsTap;
  final VoidCallback? onFollowersTap;
  final VoidCallback? onFollowingTap;
  
  const ProfileHeader({
    super.key,
    required this.username,
    this.bio,
    this.avatarPath,
    this.postsCount = 0,
    this.followersCount = 0,
    this.followingCount = 0,
    this.followStatus = FollowStatus.notFollowing,
    this.isCurrentUser = false,
    this.onFollowPressed,
    this.onEditProfile,
    this.onPostsTap,
    this.onFollowersTap,
    this.onFollowingTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Container(
      color: isDark ? MobileTheme.darkSurface : MobileTheme.lightSurface,
      padding: const EdgeInsets.all(MobileTheme.spacing16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Avatar and Stats Row
          Row(
            children: [
              // Avatar
              CircleAvatar(
                radius: 40,
                backgroundImage: avatarPath != null
                    ? FileImage(File(avatarPath!))
                    : null,
                child: avatarPath == null
                    ? Text(
                        username.isNotEmpty ? username[0].toUpperCase() : 'U',
                        style: const TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    : null,
              ),
              
              const SizedBox(width: MobileTheme.spacing24),
              
              // Stats
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    StatsWidget(
                      count: postsCount,
                      label: 'Posts',
                      onTap: onPostsTap,
                    ),
                    StatsWidget(
                      count: followersCount,
                      label: 'Followers',
                      onTap: onFollowersTap,
                    ),
                    StatsWidget(
                      count: followingCount,
                      label: 'Following',
                      onTap: onFollowingTap,
                    ),
                  ],
                ),
              ),
            ],
          ),
          
          const SizedBox(height: MobileTheme.spacing16),
          
          // Username
          Text(
            username,
            style: Theme.of(context).textTheme.displaySmall,
          ),
          
          // Bio
          if (bio != null && bio!.isNotEmpty) ...[
            const SizedBox(height: MobileTheme.spacing8),
            Text(
              bio!,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: MobileTheme.textSecondary(isDark),
              ),
            ),
          ],
          
          const SizedBox(height: MobileTheme.spacing16),
          
          // Action Button
          SizedBox(
            width: double.infinity,
            child: isCurrentUser
                ? ElevatedButton(
                    onPressed: onEditProfile,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isDark 
                          ? MobileTheme.darkDivider 
                          : MobileTheme.lightDivider,
                      foregroundColor: MobileTheme.textPrimary(isDark),
                    ),
                    child: const Text('Edit Profile'),
                  )
                : FollowButton(
                    status: followStatus,
                    onPressed: onFollowPressed,
                  ),
          ),
        ],
      ),
    );
  }
}

/// Compact profile tile for lists
class ProfileTile extends StatelessWidget {
  final String username;
  final String? subtitle;
  final String? avatarPath;
  final Widget? trailing;
  final VoidCallback? onTap;
  
  const ProfileTile({
    super.key,
    required this.username,
    this.subtitle,
    this.avatarPath,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: MobileTheme.spacing16,
        vertical: MobileTheme.spacing4,
      ),
      leading: CircleAvatar(
        backgroundImage: avatarPath != null
            ? FileImage(File(avatarPath!))
            : null,
        child: avatarPath == null
            ? Text(
                username.isNotEmpty ? username[0].toUpperCase() : 'U',
                style: const TextStyle(fontWeight: FontWeight.w600),
              )
            : null,
      ),
      title: Text(
        username,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: subtitle != null ? Text(subtitle!) : null,
      trailing: trailing,
    );
  }
}
