import Foundation

/// Service for managing audio rooms
@MainActor
class RoomService: ObservableObject {
    static let shared = RoomService()
    
    @Published var liveRooms: [AudioRoom] = []
    @Published var friendsRooms: [AudioRoom] = []
    @Published var currentRoom: AudioRoomDetail?
    @Published var isInRoom = false
    @Published var isLoading = false
    @Published var error: String?
    
    private let network = NetworkService.shared
    
    // MARK: - Room CRUD
    
    /// Create a new audio room
    func createRoom(_ request: CreateRoomRequest) async throws -> AudioRoom {
        isLoading = true
        defer { isLoading = false }
        
        let room: AudioRoom = try await network.post(
            path: "/api/rooms",
            body: request
        )
        
        // Optimistically insert so it appears instantly in the feed
        if request.privacy == "public" {
            liveRooms.insert(room, at: 0)
        } else if request.privacy == "friends" {
            friendsRooms.insert(room, at: 0)
        }
        
        #if DEBUG
        print("🎙️ Created room: \(room.title)")
        #endif
        return room
    }
    
    /// List all live rooms (public only)
    func fetchLiveRooms() async throws {
        isLoading = true
        defer { isLoading = false }
        
        let rooms: [AudioRoom] = try await network.get(
            path: "/api/rooms",
            queryItems: [URLQueryItem(name: "privacy", value: "public")]
        )
        
        liveRooms = rooms
        #if DEBUG
        print("📻 Fetched \(rooms.count) public live rooms")
        #endif
    }
    
    /// List public rooms (for Local tab)
    func fetchPublicRooms() async throws -> [AudioRoom] {
        let rooms: [AudioRoom] = try await network.get(
            path: "/api/rooms",
            queryItems: [URLQueryItem(name: "privacy", value: "public")]
        )
        #if DEBUG
        print("🌍 Fetched \(rooms.count) public rooms")
        #endif
        return rooms
    }
    
    /// List friends-only rooms (for Friends tab)
    func fetchFriendsRooms() async throws -> [AudioRoom] {
        let rooms: [AudioRoom] = try await network.get(path: "/api/rooms/friends/rooms")
        friendsRooms = rooms
        #if DEBUG
        print("👥 Fetched \(rooms.count) friends rooms")
        #endif
        return rooms
    }
    
    /// Generate shareable invite link for invite-only rooms
    func generateInviteLink(roomId: String) async throws -> String {
        struct InviteLinkResponse: Codable {
            let inviteLink: String
            let roomId: String
            
            enum CodingKeys: String, CodingKey {
                case inviteLink = "invite_link"
                case roomId = "room_id"
            }
        }
        
        let response: InviteLinkResponse = try await network.post(
            path: "/api/rooms/\(roomId)/invite-link",
            body: EmptyBody()
        )
        
        #if DEBUG
        print("🔗 Generated invite link: \(response.inviteLink)")
        #endif
        return response.inviteLink
    }
    
    private struct EmptyBody: Codable {}
    
    /// Get room details with participants
    func fetchRoomDetail(roomId: String) async throws -> AudioRoomDetail {
        let detail: AudioRoomDetail = try await network.get(
            path: "/api/rooms/\(roomId)"
        )
        
        currentRoom = detail
        return detail
    }
    
    // MARK: - Join/Leave
    
    /// Join an audio room
    func joinRoom(roomId: String, anonymous: Bool = false) async throws -> AudioRoomParticipant {
        isLoading = true
        defer { isLoading = false }
        
        let request = JoinRoomRequest(anonymous: anonymous)
        let participant: AudioRoomParticipant = try await network.post(
            path: "/api/rooms/\(roomId)/join",
            body: request
        )
        
        isInRoom = true
        #if DEBUG
        print("👤 Joined room as \(anonymous ? "anonymous" : "real") user")
        #endif
        
        // Bug 16 fix: use try? so a detail-fetch failure doesn't crash the join
        // after the user has already successfully joined the room
        _ = try? await fetchRoomDetail(roomId: roomId)
        
        return participant
    }
    
    /// Leave the current room
    func leaveRoom(roomId: String) async throws {
        let _: Empty = try await network.post(
            path: "/api/rooms/\(roomId)/leave",
            body: EmptyBody()
        )
        
        isInRoom = false
        currentRoom = nil
        #if DEBUG
        print("👋 Left room")
        #endif
    }
    
    // MARK: - Raise Hand
    
    /// Raise or lower hand to request speaking
    func raiseHand(roomId: String, raised: Bool) async throws {
        struct RaiseRequest: Codable { let raised: Bool }
        
        let _: Empty = try await network.post(
            path: "/api/rooms/\(roomId)/raise-hand",
            body: RaiseRequest(raised: raised)
        )
        
        #if DEBUG
        print(raised ? "✋ Hand raised" : "✋ Hand lowered")
        #endif
    }
    
    /// Get pending raise hand requests (host only)
    func getRequests(roomId: String) async throws -> [RaiseHandRequest] {
        let requests: [RaiseHandRequest] = try await network.get(
            path: "/api/rooms/\(roomId)/requests"
        )
        
        return requests
    }
    
    /// Accept a raise hand request
    func acceptRequest(roomId: String, userId: String) async throws {
        let _: Empty = try await network.post(
            path: "/api/rooms/\(roomId)/requests/\(userId)/accept",
            body: EmptyBody()
        )
        
        #if DEBUG
        print("✅ Accepted request from \(userId)")
        #endif
    }
    
    /// Decline a raise hand request
    func declineRequest(roomId: String, userId: String) async throws {
        let _: Empty = try await network.post(
            path: "/api/rooms/\(roomId)/requests/\(userId)/decline",
            body: EmptyBody()
        )
        
        #if DEBUG
        print("❌ Declined request from \(userId)")
        #endif
    }
    
    // MARK: - Host Controls
    
    /// Change participant's role
    func changeRole(roomId: String, userId: String, role: ParticipantRole) async throws {
        struct RoleRequest: Codable { let role: String }
        
        let _: Empty = try await network.post(
            path: "/api/rooms/\(roomId)/role/\(userId)",
            body: RoleRequest(role: role.rawValue)
        )
        
        #if DEBUG
        print("🔄 Changed role of \(userId) to \(role)")
        #endif
    }
    
    /// Mute or unmute a participant
    func muteParticipant(roomId: String, userId: String, muted: Bool) async throws {
        struct MuteBody: Codable { let muted: Bool }
        
        let _: Empty = try await network.post(
            path: "/api/rooms/\(roomId)/mute/\(userId)",
            body: MuteBody(muted: muted)
        )
        
        #if DEBUG
        print(muted ? "🔇 Muted \(userId)" : "🔊 Unmuted \(userId)")
        #endif
    }
    
    /// Mute all speakers in the room
    func muteAll(roomId: String) async throws {
        let _: Empty = try await network.post(
            path: "/api/rooms/\(roomId)/mute-all",
            body: EmptyBody()
        )
        
        #if DEBUG
        print("🔇 Muted all speakers")
        #endif
    }
    
    /// Kick a participant from the room
    func kickParticipant(roomId: String, userId: String) async throws {
        let _: Empty = try await network.post(
            path: "/api/rooms/\(roomId)/kick/\(userId)",
            body: EmptyBody()
        )
        
        #if DEBUG
        print("👢 Kicked \(userId)")
        #endif
    }
    
    /// Update a room setting (lock, allow_raise_hand, allow_anonymous, etc.)
    func updateSettings(roomId: String, key: String, value: Bool) async throws {
        struct SettingRequest: Codable { let key: String; let value: Bool }
        let _: Empty = try await network.post(
            path: "/api/rooms/\(roomId)/settings",
            body: SettingRequest(key: key, value: value)
        )
        #if DEBUG
        print("⚙️ Room \(roomId) setting updated: \(key) = \(value)")
        #endif
    }
    
    /// End the room (host only)
    func endRoom(roomId: String) async throws {
        let _: Empty = try await network.post(
            path: "/api/rooms/\(roomId)/end",
            body: EmptyBody()
        )
        
        isInRoom = false
        currentRoom = nil
        #if DEBUG
        print("🔴 Room ended")
        #endif
    }
    
    // MARK: - Assets
    
    /// Activate a presentation asset
    func activateAsset(roomId: String, assetId: String) async throws {
        let _: Empty = try await network.post(
            path: "/api/rooms/\(roomId)/assets/\(assetId)/activate",
            body: EmptyBody()
        )
        
        #if DEBUG
        print("📄 Asset activated")
        #endif
    }
    
    /// Delete an asset
    func deleteAsset(roomId: String, assetId: String) async throws {
        try await network.delete(
            path: "/api/rooms/\(roomId)/assets/\(assetId)"
        )
        
        #if DEBUG
        print("🗑️ Asset deleted")
        #endif
    }

}

