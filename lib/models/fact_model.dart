import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

/// Verification status for a Fact
enum VerifyStatus {
  unverified,   // Not yet checked
  pending,      // Being verified
  verified,     // AI confirmed as accurate
  rejected,     // AI flagged as inaccurate
  needsReview,  // Uncertain, needs human review
}

/// Privacy mode for author attribution
enum PrivacyMode {
  anonymous,    // Don't show author name
  showName,     // Show author name on the fact
}

/// A single knowledge fact that can be shared on mesh
class Fact {
  final String id;
  final String title;
  final String claim;
  final List<String> tags;
  final String lang;
  final DateTime createdAt;
  final DateTime updatedAt;
  
  // Author (optional based on privacy)
  final String? authorId;
  final String? authorDisplayName;
  final PrivacyMode privacyMode;
  
  // Sources/citations
  final List<String> sources;
  
  // Verification
  final VerifyStatus verifyStatus;
  final int verifyScore;          // 0-100
  final String? verifyReason;
  
  // Integrity
  final String hash;
  final int? ttl;                 // Optional expiry in seconds
  
  // Mesh sync
  final int syncCount;            // How many times synced
  final DateTime? lastSyncAt;

  Fact({
    String? id,
    required this.title,
    required this.claim,
    this.tags = const [],
    this.lang = 'en',
    DateTime? createdAt,
    DateTime? updatedAt,
    this.authorId,
    this.authorDisplayName,
    this.privacyMode = PrivacyMode.showName,
    this.sources = const [],
    this.verifyStatus = VerifyStatus.unverified,
    this.verifyScore = 0,
    this.verifyReason,
    String? hash,
    this.ttl,
    this.syncCount = 0,
    this.lastSyncAt,
  }) : id = id ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now(),
       hash = hash ?? _generateHash(title, claim);

  /// Generate SHA256 hash of title + claim for integrity
  static String _generateHash(String title, String claim) {
    final content = '$title|$claim';
    return sha256.convert(utf8.encode(content)).toString().substring(0, 16);
  }

  /// Create a copy with updated fields
  Fact copyWith({
    String? id,
    String? title,
    String? claim,
    List<String>? tags,
    String? lang,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? authorId,
    String? authorDisplayName,
    PrivacyMode? privacyMode,
    List<String>? sources,
    VerifyStatus? verifyStatus,
    int? verifyScore,
    String? verifyReason,
    String? hash,
    int? ttl,
    int? syncCount,
    DateTime? lastSyncAt,
  }) {
    return Fact(
      id: id ?? this.id,
      title: title ?? this.title,
      claim: claim ?? this.claim,
      tags: tags ?? this.tags,
      lang: lang ?? this.lang,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
      authorId: authorId ?? this.authorId,
      authorDisplayName: authorDisplayName ?? this.authorDisplayName,
      privacyMode: privacyMode ?? this.privacyMode,
      sources: sources ?? this.sources,
      verifyStatus: verifyStatus ?? this.verifyStatus,
      verifyScore: verifyScore ?? this.verifyScore,
      verifyReason: verifyReason ?? this.verifyReason,
      hash: hash ?? (title != null || claim != null 
          ? _generateHash(title ?? this.title, claim ?? this.claim) 
          : this.hash),
      ttl: ttl ?? this.ttl,
      syncCount: syncCount ?? this.syncCount,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    );
  }

  /// Convert to JSON for storage/mesh
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'claim': claim,
      'tags': tags,
      'lang': lang,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'authorId': authorId,
      'authorDisplayName': authorDisplayName,
      'privacyMode': privacyMode.name,
      'sources': sources,
      'verifyStatus': verifyStatus.name,
      'verifyScore': verifyScore,
      'verifyReason': verifyReason,
      'hash': hash,
      'ttl': ttl,
      'syncCount': syncCount,
      'lastSyncAt': lastSyncAt?.toIso8601String(),
    };
  }

  /// Create from JSON
  factory Fact.fromJson(Map<String, dynamic> json) {
    return Fact(
      id: json['id'] as String,
      title: json['title'] as String,
      claim: json['claim'] as String,
      tags: (json['tags'] as List<dynamic>?)?.cast<String>() ?? [],
      lang: json['lang'] as String? ?? 'en',
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      authorId: json['authorId'] as String?,
      authorDisplayName: json['authorDisplayName'] as String?,
      privacyMode: PrivacyMode.values.firstWhere(
        (e) => e.name == json['privacyMode'],
        orElse: () => PrivacyMode.showName,
      ),
      sources: (json['sources'] as List<dynamic>?)?.cast<String>() ?? [],
      verifyStatus: VerifyStatus.values.firstWhere(
        (e) => e.name == json['verifyStatus'],
        orElse: () => VerifyStatus.unverified,
      ),
      verifyScore: json['verifyScore'] as int? ?? 0,
      verifyReason: json['verifyReason'] as String?,
      hash: json['hash'] as String,
      ttl: json['ttl'] as int?,
      syncCount: json['syncCount'] as int? ?? 0,
      lastSyncAt: json['lastSyncAt'] != null 
          ? DateTime.parse(json['lastSyncAt'] as String) 
          : null,
    );
  }

  /// Check if fact is expired
  bool get isExpired {
    if (ttl == null) return false;
    return DateTime.now().difference(createdAt).inSeconds > ttl!;
  }

  /// Get verification badge text
  String get verifyBadgeText {
    switch (verifyStatus) {
      case VerifyStatus.verified:
        return 'Verified ✓';
      case VerifyStatus.pending:
        return 'Verifying...';
      case VerifyStatus.rejected:
        return 'Disputed';
      case VerifyStatus.needsReview:
        return 'Needs Review';
      case VerifyStatus.unverified:
        return 'Unverified';
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Fact && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Fact($id: $title, status: ${verifyStatus.name})';
}
