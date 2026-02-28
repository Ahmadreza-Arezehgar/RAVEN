import Foundation

// MARK: - Audio Room Models

/// Audio room for live voice conversations (Clubhouse-like)
struct AudioRoom: Codable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let hostUserId: String
    let hostName: String?
    let hostAvatar: String?
    let roomImageUrl: String?
    let privacy: RoomPrivacy
    let allowAnonymous: Bool
    let allowRaiseHand: Bool
    let isLocked: Bool?
    let isLive: Bool
    let participantCount: Int
    let maxParticipants: Int
    let createdAt: Date
    let shareSlug: String?
    
    // No CodingKeys needed - NetworkService uses .convertFromSnakeCase
}

/// Room privacy level
enum RoomPrivacy: String, Codable {
    case `public` = "public"
    case friends = "friends"
    case invite = "invite"
}

/// Participant in an audio room
struct AudioRoomParticipant: Codable, Identifiable {
    let id: String
    let userId: String
    let displayName: String
    let avatarUrl: String?
    let displayMode: DisplayMode
    let role: ParticipantRole
    let isMuted: Bool
    let isHandRaised: Bool
    let joinedAt: Date
    
    // No CodingKeys needed - NetworkService uses .convertFromSnakeCase
    
    /// Safe display name with proper fallback logic
    /// Filters out encrypted blobs (gAAAA...) and invalid values (None None)
    var safeDisplayName: String {
        // Check for encrypted blob using centralized detection
        if displayName.looksEncrypted {
            return anonymousFallback
        }
        
        // Check for None None or empty
        let trimmed = displayName.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "None None" || trimmed == "None" || trimmed == "null null" {
            return anonymousFallback
        }
        
        return displayName
    }
    
    /// Fallback name for anonymous/invalid users
    private var anonymousFallback: String {
        if displayMode == .anonymous {
            return "Anonymous"
        }
        // Use short ID as fallback: "User • abc123"
        let shortId = String(id.prefix(6))
        return "User • \(shortId)"
    }
    
    /// First letter for avatar placeholder
    var avatarInitial: String {
        String(safeDisplayName.prefix(1)).uppercased()
    }
}

/// How participant identity is displayed
enum DisplayMode: String, Codable {
    case real = "real"
    case anonymous = "anonymous"
}

/// Participant role in room
enum ParticipantRole: String, Codable {
    case host = "host"
    case cohost = "cohost"
    case speaker = "speaker"
    case listener = "listener"
    
    var canSpeak: Bool {
        self == .host || self == .cohost || self == .speaker
    }
    
    var canModerate: Bool {
        self == .host || self == .cohost
    }
}

/// Detailed room response with participants
struct AudioRoomDetail: Codable {
    let room: AudioRoom
    let participants: [AudioRoomParticipant]
    let pendingRequests: Int
    let activeAsset: AudioRoomAsset?
    
    // No CodingKeys needed - NetworkService uses .convertFromSnakeCase
}

/// Presentation asset (PDF/Image) in room
struct AudioRoomAsset: Codable, Identifiable {
    let id: String
    let type: AssetType
    let url: String
    let fileName: String?
    
    // No CodingKeys needed - NetworkService uses .convertFromSnakeCase
}

/// Type of presentation asset
enum AssetType: String, Codable {
    case image = "image"
    case pdf = "pdf"
}

/// Raise hand request
struct RaiseHandRequest: Codable {
    let requestId: String
    let userId: String
    let displayName: String
    let createdAt: String
    
    // No CodingKeys needed - NetworkService uses .convertFromSnakeCase
}

// MARK: - Request Models

struct CreateRoomRequest: Codable {
    let title: String
    let description: String?
    let roomImageUrl: String?
    let privacy: String
    let allowAnonymous: Bool
    let allowRaiseHand: Bool
    let maxParticipants: Int
    
    // No CodingKeys needed - NetworkService uses .convertToSnakeCase for encoding
    
    init(
        title: String,
        description: String? = nil,
        roomImageUrl: String? = nil,
        privacy: RoomPrivacy = .public,
        allowAnonymous: Bool = true,
        allowRaiseHand: Bool = true,
        maxParticipants: Int = 100
    ) {
        self.title = title
        self.description = description
        self.roomImageUrl = roomImageUrl
        self.privacy = privacy.rawValue
        self.allowAnonymous = allowAnonymous
        self.allowRaiseHand = allowRaiseHand
        self.maxParticipants = maxParticipants
    }
}

struct JoinRoomRequest: Codable {
    let anonymous: Bool
}

// MARK: - Anonymous Animals

enum AnonymousAnimal: String, CaseIterable {
    case fox = "Fox"
    case owl = "Owl"
    case bear = "Bear"
    case wolf = "Wolf"
    case penguin = "Penguin"
    case rabbit = "Rabbit"
    case koala = "Koala"
    case panda = "Panda"
    case tiger = "Tiger"
    case eagle = "Eagle"
    case dolphin = "Dolphin"
    case phoenix = "Phoenix"
    case dragon = "Dragon"
    case falcon = "Falcon"
    case raven = "Raven"
    case lion = "Lion"
    case leopard = "Leopard"
    case hawk = "Hawk"
    case panther = "Panther"
    case lynx = "Lynx"
    
    var emoji: String {
        switch self {
        case .fox: return "🦊"
        case .owl: return "🦉"
        case .bear: return "🐻"
        case .wolf: return "🐺"
        case .penguin: return "🐧"
        case .rabbit: return "🐰"
        case .koala: return "🐨"
        case .panda: return "🐼"
        case .tiger: return "🐯"
        case .eagle: return "🦅"
        case .dolphin: return "🐬"
        case .phoenix: return "🔥"
        case .dragon: return "🐉"
        case .falcon: return "🦅"
        case .raven: return "🪶"
        case .lion: return "🦁"
        case .leopard: return "🐆"
        case .hawk: return "🦅"
        case .panther: return "🐆"
        case .lynx: return "🐱"
        }
    }
}
