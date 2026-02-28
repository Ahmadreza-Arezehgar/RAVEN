import Foundation

// MARK: - Seen By User Model (Read Receipts)

/// Represents a user who has seen a specific message in a group chat
struct SeenByUser: Identifiable, Codable, Equatable {
    let userId: String
    let username: String
    let avatarUrl: String?
    let seenAt: Date
    
    var id: String { userId }
    
    var displayName: String {
        username.isEmpty ? "User \(userId.prefix(8))" : username
    }
}
