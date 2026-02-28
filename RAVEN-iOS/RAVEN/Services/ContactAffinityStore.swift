// RAVEN - Contact Affinity Store
// Provides ranked contact avatars for post action rows

import Foundation

/// Lightweight store that ranks contacts by affinity for avatar stack display.
/// Phase 1: favorite contacts first, then alphabetical by name.
/// Phase 2 (future): use chat history / interaction frequency.
@MainActor
final class ContactAffinityStore {
    static let shared = ContactAffinityStore()
    
    private init() {}
    
    /// Represents a single contact avatar for display in the stack.
    struct ContactAvatar: Identifiable {
        let id: String       // userId
        let avatarUrl: String?
        let name: String
    }
    
    /// Given a list of user IDs (from server preview), intersects with the user's
    /// local contacts and returns the top N ranked by affinity.
    ///
    /// - Parameters:
    ///   - userIds: Preview user IDs from server (up to 20)
    ///   - contacts: User's local contact list
    ///   - limit: Max avatars to return (default 3)
    /// - Returns: Array of ContactAvatar sorted by affinity (highest first)
    func topContacts(
        from userIds: [String],
        contacts: [Contact],
        limit: Int = 3
    ) -> [ContactAvatar] {
        guard !userIds.isEmpty, !contacts.isEmpty else { return [] }
        
        // Build a lookup map of contacts by userId
        let contactMap = Dictionary(
            contacts.map { ($0.userId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        
        // Intersect preview IDs with contacts
        var matchedContacts: [(contact: Contact, originalIndex: Int)] = []
        for (index, uid) in userIds.enumerated() {
            if let contact = contactMap[uid] {
                matchedContacts.append((contact, index))
            }
        }
        
        guard !matchedContacts.isEmpty else { return [] }
        
        // Sort by affinity: favorites first, then by recency in the preview list
        matchedContacts.sort { a, b in
            if a.contact.isFavorite != b.contact.isFavorite {
                return a.contact.isFavorite  // Favorites come first
            }
            return a.originalIndex < b.originalIndex  // Otherwise maintain server order (most recent)
        }
        
        // Take top N and convert to ContactAvatar
        return matchedContacts.prefix(limit).map { pair in
            ContactAvatar(
                id: pair.contact.userId,
                avatarUrl: pair.contact.avatarUrl,
                name: pair.contact.effectiveName
            )
        }
    }
}
