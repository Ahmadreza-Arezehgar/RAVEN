import Foundation

// MARK: - Nickname Service (Local Storage)
/// Stores and retrieves nicknames for contacts, stored locally on the device only.
actor NicknameService {
    static let shared = NicknameService()
    
    private let userDefaults = UserDefaults.standard
    private let nicknameKey = "contact_nicknames"
    
    private var cache: [String: String] = [:]
    private var isLoaded = false
    
    private init() {}
    
    // MARK: - Public API
    
    /// Set a nickname for a user. Pass nil to remove the nickname.
    func setNickname(_ nickname: String?, for userId: String) async {
        await loadIfNeeded()
        
        if let nickname = nickname, !nickname.isEmpty {
            cache[userId] = nickname
        } else {
            cache.removeValue(forKey: userId)
        }
        
        await save()
    }
    
    /// Get the nickname for a user, if one exists.
    func getNickname(for userId: String) async -> String? {
        await loadIfNeeded()
        return cache[userId]
    }
    
    /// Get all nicknames (for search/display purposes).
    func getAllNicknames() async -> [String: String] {
        await loadIfNeeded()
        return cache
    }
    
    /// Check if a user has a custom nickname.
    func hasNickname(for userId: String) async -> Bool {
        await loadIfNeeded()
        return cache[userId] != nil
    }
    
    // MARK: - Persistence
    
    private func loadIfNeeded() async {
        guard !isLoaded else { return }
        
        if let data = userDefaults.data(forKey: nicknameKey),
           let nicknames = try? JSONDecoder().decode([String: String].self, from: data) {
            cache = nicknames
        }
        
        isLoaded = true
    }
    
    private func save() async {
        if let data = try? JSONEncoder().encode(cache) {
            userDefaults.set(data, forKey: nicknameKey)
        }
    }
}

// MARK: - Extension for Conversation.Peer
extension Conversation.Peer {
    /// Returns the display name with nickname priority:
    /// nickname > firstName lastName > username
    func displayNameWithNickname() async -> String {
        if let nickname = await NicknameService.shared.getNickname(for: userId) {
            return nickname
        }
        return displayName
    }
}
