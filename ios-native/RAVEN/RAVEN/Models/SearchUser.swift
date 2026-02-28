import Foundation

// MARK: - Search User Model (lightweight for search results)
struct SearchUser: Identifiable, Codable {
    let id: String
    let username: String
    let displayName: String?
    let avatarUrl: String?  // ✅ FIX Bug 4: Renamed from avatarPath to match server's avatar_url key
    let isMutual: Bool?
    
    // Badge fields — fallback keys for server inconsistency
    var isVerified: Bool? = false
    var verified: Bool? = false
    var isPremium: Bool? = false
    var premium: Bool? = false
    var badgeType: String? = nil
    var subscriptionTier: String? = nil
    
    // Computed helpers — coalesce all server naming variants
    var verifiedStatus: Bool {
        isVerified == true || verified == true || badgeType == "verified" || badgeType == "brand" || badgeType == "org"
    }
    
    var premiumStatus: Bool {
        isPremium == true || premium == true || subscriptionTier == "premium" || subscriptionTier == "raven_plus" || subscriptionTier == "raven+"
    }
    
    // Discovery suggestion fields (populated by /api/discovery/suggested)
    var source: String? = nil           // "contacts" or "algorithm"
    var reason: String? = nil           // "From your contacts", "3 mutual friends", etc.
    var mutualFriendsCount: Int? = nil  // Number of mutual friends
    
    // Note: CodingKeys removed - NetworkService uses .convertFromSnakeCase automatically
}

