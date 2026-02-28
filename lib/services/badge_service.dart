import 'package:flutter/material.dart';
import 'package:hybrid_messenger/services/knowledge_service.dart';

/// Badge tier for knowledge contributors
enum BadgeTier {
  none,        // 0-4 verified facts
  spark,       // 5+ verified facts
  curious,     // 10+ verified facts
  scholar,     // 50+ verified facts
  expert,      // 100+ verified facts
  master,      // 150+ verified facts
  legend,      // 1000+ verified facts
}

/// Badge information with display properties
class BadgeInfo {
  final BadgeTier tier;
  final String name;
  final String emoji;
  final IconData icon;
  final Color color;
  final int requiredCount;
  final String description;

  const BadgeInfo({
    required this.tier,
    required this.name,
    required this.emoji,
    required this.icon,
    required this.color,
    required this.requiredCount,
    required this.description,
  });
}

/// Service for managing Knowledge badges and points
class BadgeService {
  static final BadgeService _instance = BadgeService._internal();
  factory BadgeService() => _instance;
  BadgeService._internal();

  final KnowledgeService _knowledge = KnowledgeService();

  /// All badge tiers with their requirements
  static const List<BadgeInfo> allBadges = [
    BadgeInfo(
      tier: BadgeTier.spark,
      name: 'Spark',
      emoji: '⚡',
      icon: Icons.flash_on,
      color: Color(0xFFFFB800),
      requiredCount: 5,
      description: 'Created 5 verified facts',
    ),
    BadgeInfo(
      tier: BadgeTier.curious,
      name: 'Curious',
      emoji: '🔍',
      icon: Icons.search,
      color: Color(0xFF4CAF50),
      requiredCount: 10,
      description: 'Created 10 verified facts',
    ),
    BadgeInfo(
      tier: BadgeTier.scholar,
      name: 'Scholar',
      emoji: '📚',
      icon: Icons.menu_book,
      color: Color(0xFF2196F3),
      requiredCount: 50,
      description: 'Created 50 verified facts',
    ),
    BadgeInfo(
      tier: BadgeTier.expert,
      name: 'Expert',
      emoji: '🎓',
      icon: Icons.school,
      color: Color(0xFF9C27B0),
      requiredCount: 100,
      description: 'Created 100 verified facts',
    ),
    BadgeInfo(
      tier: BadgeTier.master,
      name: 'Master',
      emoji: '🏆',
      icon: Icons.emoji_events,
      color: Color(0xFFFF9800),
      requiredCount: 150,
      description: 'Created 150 verified facts',
    ),
    BadgeInfo(
      tier: BadgeTier.legend,
      name: 'Legend',
      emoji: '👑',
      icon: Icons.auto_awesome,
      color: Color(0xFFFFD700),
      requiredCount: 1000,
      description: 'Created 1000 verified facts - Legendary contributor!',
    ),
  ];

  /// Points awarded for different actions
  static const int pointsVerified = 10;
  static const int pointsUnverified = 1;
  static const int pointsRejected = 0;

  /// Get current badge tier for a user
  Future<BadgeTier> getUserBadgeTier(String userId) async {
    final count = await _knowledge.getUserVerifiedCount(userId);
    return getBadgeTierForCount(count);
  }

  /// Get badge tier for a given verified count
  BadgeTier getBadgeTierForCount(int verifiedCount) {
    if (verifiedCount >= 1000) return BadgeTier.legend;
    if (verifiedCount >= 150) return BadgeTier.master;
    if (verifiedCount >= 100) return BadgeTier.expert;
    if (verifiedCount >= 50) return BadgeTier.scholar;
    if (verifiedCount >= 10) return BadgeTier.curious;
    if (verifiedCount >= 5) return BadgeTier.spark;
    return BadgeTier.none;
  }

  /// Get badge info for a tier
  BadgeInfo? getBadgeInfo(BadgeTier tier) {
    if (tier == BadgeTier.none) return null;
    return allBadges.firstWhere((b) => b.tier == tier);
  }

  /// Get user's current badge info
  Future<BadgeInfo?> getUserBadgeInfo(String userId) async {
    final tier = await getUserBadgeTier(userId);
    return getBadgeInfo(tier);
  }

  /// Get next badge target for a user
  Future<BadgeProgress> getUserProgress(String userId) async {
    final count = await _knowledge.getUserVerifiedCount(userId);
    final currentTier = getBadgeTierForCount(count);
    
    // Find next tier
    BadgeInfo? nextBadge;
    for (final badge in allBadges) {
      if (badge.requiredCount > count) {
        nextBadge = badge;
        break;
      }
    }

    return BadgeProgress(
      verifiedCount: count,
      currentTier: currentTier,
      currentBadge: getBadgeInfo(currentTier),
      nextBadge: nextBadge,
      points: count * pointsVerified,
    );
  }

  /// Get all earned badges for a user
  Future<List<BadgeInfo>> getEarnedBadges(String userId) async {
    final count = await _knowledge.getUserVerifiedCount(userId);
    return allBadges.where((b) => b.requiredCount <= count).toList();
  }

  /// Get all unearned badges for a user
  Future<List<BadgeInfo>> getUnearnedBadges(String userId) async {
    final count = await _knowledge.getUserVerifiedCount(userId);
    return allBadges.where((b) => b.requiredCount > count).toList();
  }

  /// Check if user just earned a new badge after verification
  Future<BadgeInfo?> checkNewBadge(String userId, int previousCount) async {
    final newCount = await _knowledge.getUserVerifiedCount(userId);
    
    final oldTier = getBadgeTierForCount(previousCount);
    final newTier = getBadgeTierForCount(newCount);
    
    if (newTier != oldTier && newTier != BadgeTier.none) {
      return getBadgeInfo(newTier);
    }
    
    return null;
  }

  /// Calculate points for a user
  int calculatePoints(int verifiedCount, int unverifiedCount) {
    return (verifiedCount * pointsVerified) + (unverifiedCount * pointsUnverified);
  }
}

/// Progress towards the next badge
class BadgeProgress {
  final int verifiedCount;
  final BadgeTier currentTier;
  final BadgeInfo? currentBadge;
  final BadgeInfo? nextBadge;
  final int points;

  BadgeProgress({
    required this.verifiedCount,
    required this.currentTier,
    this.currentBadge,
    this.nextBadge,
    required this.points,
  });

  /// Progress percentage towards next badge (0.0 - 1.0)
  double get progressToNext {
    if (nextBadge == null) return 1.0; // Max level reached
    
    final previousRequired = currentBadge?.requiredCount ?? 0;
    final nextRequired = nextBadge!.requiredCount;
    final range = nextRequired - previousRequired;
    final progress = verifiedCount - previousRequired;
    
    return (progress / range).clamp(0.0, 1.0);
  }

  /// Facts remaining until next badge
  int get factsToNext {
    if (nextBadge == null) return 0;
    return nextBadge!.requiredCount - verifiedCount;
  }

  /// Display text for progress
  String get progressText {
    if (nextBadge == null) return 'Maximum level reached!';
    return '$verifiedCount / ${nextBadge!.requiredCount} to ${nextBadge!.name}';
  }
}
