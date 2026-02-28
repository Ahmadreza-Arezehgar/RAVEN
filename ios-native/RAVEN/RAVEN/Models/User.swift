import Foundation

// MARK: - Auth Method
enum AuthMethod: String, Codable {
    case password
    case google
    case apple
}

// MARK: - Friendship Status
struct FriendshipStatus: Codable {
    let status: String?  // "sent", "received", "friends", nil
    let requestId: String?
    let createdAt: Date?
    
    var alreadySent: Bool {
        status == "sent"
    }
    
    var alreadyFriends: Bool {
        status == "friends"
    }
    
    var pendingReceived: Bool {
        status == "received"
    }
}

// MARK: - User Model
struct User: Identifiable, Codable {
    let id: String
    let username: String?
    let email: String?
    let phone: String?
    let firstName: String?
    let lastName: String?
    let bio: String?
    var avatarPath: String?
    let tags: [String]?
    let birthday: Date?  // تاریخ تولد
    let publicKey: String?
    let createdAt: Date?
    let emailVerified: Bool
    let phoneVerified: Bool
    let isVerified: Bool  // Identity verified badge (blue tick)
    var isPremium: Bool    // RAVEN+ subscriber badge
    let authMethod: AuthMethod?
    let friendship: FriendshipStatus?
    
    // Explicit CodingKeys matching stored properties (for Encodable synthesis)
    enum CodingKeys: String, CodingKey {
        case id, username, email, phone, firstName, lastName, bio, avatarPath
        case tags, birthday, publicKey, createdAt, emailVerified, phoneVerified
        case isVerified, isPremium
        case authMethod, friendship
    }
    
    // Separate keys for server inconsistencies (decoding only)
    // ✅ Bug 4 fix: Removed explicit snake_case raw values (e.g. "badge_type")
    // because NetworkService.decoder uses .convertFromSnakeCase, which auto-converts
    // badge_type → badgeType BEFORE matching CodingKeys. An explicit "badge_type"
    // would look for a literally-named "badge_type" key after conversion, never matching.
    private enum FallbackKeys: String, CodingKey {
        case verified, premium
        case badgeType
        case subscriptionTier
    }
    
    // Custom decoding to handle null/missing fields from API
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = try decoder.container(keyedBy: FallbackKeys.self)
        
        id = try container.decode(String.self, forKey: .id)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        phone = try container.decodeIfPresent(String.self, forKey: .phone)
        firstName = try container.decodeIfPresent(String.self, forKey: .firstName)
        lastName = try container.decodeIfPresent(String.self, forKey: .lastName)
        bio = try container.decodeIfPresent(String.self, forKey: .bio)
        avatarPath = try container.decodeIfPresent(String.self, forKey: .avatarPath)
        
        tags = try container.decodeIfPresent([String].self, forKey: .tags)
        
        // Parse birthday from ISO8601 string
        if let birthdayString = try container.decodeIfPresent(String.self, forKey: .birthday) {
            birthday = PerformanceConstants.iso8601.date(from: birthdayString) ?? 
                       DateFormatter.iso8601WithoutZ.date(from: birthdayString)
        } else {
            birthday = nil
        }
        
        publicKey = try container.decodeIfPresent(String.self, forKey: .publicKey)
        
        // Parse createdAt from ISO8601 string
        if let createdAtString = try container.decodeIfPresent(String.self, forKey: .createdAt) {
            createdAt = PerformanceConstants.iso8601.date(from: createdAtString) ??
                        DateFormatter.iso8601WithoutZ.date(from: createdAtString)
        } else {
            createdAt = nil
        }
        
        // Default to false if null/missing - critical for OTP gate
        emailVerified = (try? container.decodeIfPresent(Bool.self, forKey: .emailVerified)) ?? false
        phoneVerified = (try? container.decodeIfPresent(Bool.self, forKey: .phoneVerified)) ?? false
        
        // Robust badge decoding: Handle Int (1/0), String ("true"/"false"), and missing keys
        let isVerBool = try? container.decodeIfPresent(Bool.self, forKey: .isVerified)
        let isVerInt = try? container.decodeIfPresent(Int.self, forKey: .isVerified)
        let isVerStr = try? container.decodeIfPresent(String.self, forKey: .isVerified)
        let isVer = isVerBool == true || isVerInt == 1 || isVerStr?.lowercased() == "true" || isVerStr == "1"
        
        let verBool = try? fallback.decodeIfPresent(Bool.self, forKey: .verified)
        let verInt = try? fallback.decodeIfPresent(Int.self, forKey: .verified)
        let verStr = try? fallback.decodeIfPresent(String.self, forKey: .verified)
        let ver = verBool == true || verInt == 1 || verStr?.lowercased() == "true" || verStr == "1"
        
        let badgeType = try? fallback.decodeIfPresent(String.self, forKey: .badgeType)
        let isBadgeVerified = badgeType == "verified" || badgeType == "brand" || badgeType == "org"
        
        isVerified = isVer || ver || isBadgeVerified
        
        let isPremBool = try? container.decodeIfPresent(Bool.self, forKey: .isPremium)
        let isPremInt = try? container.decodeIfPresent(Int.self, forKey: .isPremium)
        let isPremStr = try? container.decodeIfPresent(String.self, forKey: .isPremium)
        let isPrem = isPremBool == true || isPremInt == 1 || isPremStr?.lowercased() == "true" || isPremStr == "1"
        
        let premBool = try? fallback.decodeIfPresent(Bool.self, forKey: .premium)
        let premInt = try? fallback.decodeIfPresent(Int.self, forKey: .premium)
        let premStr = try? fallback.decodeIfPresent(String.self, forKey: .premium)
        let prem = premBool == true || premInt == 1 || premStr?.lowercased() == "true" || premStr == "1"
        
        let subTier = try? fallback.decodeIfPresent(String.self, forKey: .subscriptionTier)
        let isTierPremium = subTier == "premium" || subTier == "raven_plus" || subTier == "raven+"
        
        isPremium = isPrem || prem || isTierPremium
        
        authMethod = try? container.decodeIfPresent(AuthMethod.self, forKey: .authMethod)
        friendship = try? container.decodeIfPresent(FriendshipStatus.self, forKey: .friendship)
    }
    
    var displayName: String {
        if let first = firstName, let last = lastName, !first.isEmpty {
            return "\(first) \(last)".trimmingCharacters(in: .whitespaces)
        }
        return username ?? "User"
    }
    
    var initials: String {
        let first = firstName?.first.map(String.init) ?? ""
        let last = lastName?.first.map(String.init) ?? ""
        if !first.isEmpty || !last.isEmpty {
            return "\(first)\(last)".uppercased()
        }
        return username?.prefix(2).uppercased() ?? "?"
    }
}

// MARK: - Auth Responses
struct TokenResponse: Codable {
    let userId: String
    let username: String?
    let token: String
    let refreshToken: String?  // ✅ Refresh token for persistent sessions
    let tokenType: String
    let emailVerified: Bool?
    let tokenScope: String?
    let requiresUsername: Bool?
    let authMethod: String?
}

struct VerifyCodeResponse: Codable {
    let success: Bool
    let emailVerified: Bool?
    let fullAccessToken: String?
    let tokenScope: String?
}

// MARK: - DateFormatter Extension
extension DateFormatter {
    /// ISO8601 date formatter without 'Z' suffix (e.g., "1999-02-03T17:20:00")
    static let iso8601WithoutZ: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
