import Foundation

// MARK: - Chat Group Model

/// Represents a group chat (named ChatGroup to avoid SwiftUI.Group conflict)
struct ChatGroup: Identifiable, Codable {
    let id: String
    let name: String
    let avatarUrl: String?
    let description: String?
    let createdBy: String
    let creatorUsername: String?
    let createdAt: Date
    let memberCount: Int
    var members: [GroupMember]?
    
    // Privacy / Invite
    var visibility: String?        // "public" | "private"
    var linkJoinEnabled: Bool?
    
    // Local sync tracking
    var syncStatus: SyncStatus?
    
    enum SyncStatus: String, Codable {
        case synced
        case pending
        case failed
    }
}

// MARK: - Group Member

struct GroupMember: Identifiable, Codable, Hashable {
    let userId: String
    let username: String
    let avatarUrl: String?
    let role: String  // "admin" or "member"
    let joinedAt: Date
    
    var id: String { userId }
    
    var isAdmin: Bool { role == "admin" }
    
    var displayName: String {
        username.isEmpty ? "User \(userId.prefix(8))" : username
    }
}

// MARK: - API Request/Response

struct CreateGroupRequest: Encodable {
    let name: String
    let memberIds: [String]
    let avatarUrl: String?
    let description: String?
}

struct AddMembersRequest: Encodable {
    let memberIds: [String]
}

struct UpdateGroupRequest: Encodable {
    var name: String?
    var avatarUrl: String?
    var description: String?
    var visibility: String?
    var linkJoinEnabled: Bool?
}

// MARK: - Invite Link

struct InviteLinkResponse: Codable {
    let inviteCode: String
    let groupId: String
    let createdBy: String
    let enabled: Bool
    let useCount: Int
    let maxUses: Int?
    let expiresAt: Date?
}

// MARK: - Mute Settings (per-user, local)

struct MuteSettings: Codable, Equatable {
    var muteUntil: Date?
    var mentionsOnly: Bool
    
    var isMuted: Bool {
        guard let until = muteUntil else { return false }
        return until > Date() || until == .distantFuture
    }
    
    static let unmuted = MuteSettings(muteUntil: nil, mentionsOnly: false)
}

// MARK: - Group Friend Info (for member picker)
/// Used in group member picker to display friends
struct GroupFriendInfo: Identifiable, Codable, Hashable {
    let id: String
    let username: String
    let displayName: String?
    let avatarUrl: String?
    
    var safeDisplayName: String {
        if let d = displayName, !d.isEmpty { return d }
        return username.isEmpty ? "User \(id.prefix(8))" : username
    }
}
