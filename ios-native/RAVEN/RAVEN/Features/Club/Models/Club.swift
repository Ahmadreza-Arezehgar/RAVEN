//
//  Club.swift
//  RAVEN
//
//  Data models for Club Mode — group movement tracking via mesh network.
//  Enables concert/festival/hiking groups to track each other's proximity
//  with configurable drop-detection alerts.
//

import Foundation

// MARK: - Club

/// A proximity-tracking group session.
struct Club: Codable, Identifiable, Hashable {
    let id: String                      // club_id (UUID)
    let name: String                    // User-provided name (max 40 chars)
    let inviteCode: String              // 6-char alphanumeric code for joining
    let creatorId: String               // User who created the club
    let createdAt: Date
    let expiresAt: Date                 // Auto-expire (1-24h from creation)
    let dropThresholdMeters: Int        // Alert if member drifts beyond this (50-500m)
    let maxMembers: Int                 // Default 20
    
    // Profile fields (optional — added post-creation or during creation)
    var clubDescription: String?        // What the club is about (max 200 chars)
    var contactEmail: String?           // Creator's optional email for contact
    var externalLink: String?           // External group/channel URL (Telegram, WhatsApp, etc.)
    var ravenGroupId: String?           // In-app RAVEN group chat ID (if created)
    var locationPrecision: LocationPrecision  // GPS display mode on map
    var locationSource: LocationSource         // How location is acquired
    
    /// GPS display precision for member locations on the map.
    enum LocationPrecision: String, Codable, CaseIterable {
        case exact = "exact"            // Show real H3 cell center
        case approximate = "approximate" // Jitter by ~500m for privacy
        
        var label: String {
            switch self {
            case .exact: return "Precise"
            case .approximate: return "Approximate"
            }
        }
        
        var icon: String {
            switch self {
            case .exact: return "scope"
            case .approximate: return "circle.dashed"
            }
        }
        
        var subtitle: String {
            switch self {
            case .exact: return "~150m accuracy"
            case .approximate: return "~500m area"
            }
        }
        
        var description: String {
            switch self {
            case .exact: return "Members see precise positions (~150m accuracy)"
            case .approximate: return "Members see approximate area (~500m jitter for privacy)"
            }
        }
    }
    
    /// Location data source strategy.
    enum LocationSource: String, Codable, CaseIterable {
        case meshOnly = "mesh"          // BLE mesh only — fully offline
        case internetOnly = "internet"  // GPS via internet — most accurate
        case hybrid = "hybrid"          // Internet primary, mesh fallback
        
        var label: String {
            switch self {
            case .meshOnly: return "Mesh Only"
            case .internetOnly: return "Internet"
            case .hybrid: return "Hybrid"
            }
        }
        
        var icon: String {
            switch self {
            case .meshOnly: return "antenna.radiowaves.left.and.right"
            case .internetOnly: return "wifi"
            case .hybrid: return "arrow.triangle.2.circlepath"
            }
        }
        
        var subtitle: String {
            switch self {
            case .meshOnly: return "Bluetooth only · Private"
            case .internetOnly: return "GPS via network · Best accuracy"
            case .hybrid: return "Internet + mesh fallback"
            }
        }
    }
    
    /// Whether this club is still active.
    var isActive: Bool {
        Date() < expiresAt
    }
    
    /// Time remaining as formatted string.
    var timeRemaining: String {
        let remaining = expiresAt.timeIntervalSince(Date())
        if remaining <= 0 { return "Expired" }
        let hours = Int(remaining / 3600)
        let minutes = Int(remaining.truncatingRemainder(dividingBy: 3600) / 60)
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
    
    // MARK: - Hashable
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: Club, rhs: Club) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Club Member

/// A member of a club with their last known H3 cell.
struct ClubMember: Codable, Identifiable, Hashable {
    let id: String                      // member record ID
    let clubId: String
    let userId: String
    let displayName: String
    var avatarURL: String?              // Profile image URL for map pin
    var h3Cell: UInt64?                 // Resolution 9 (~150m) — last known position
    var preciseLat: Double?             // Exact GPS latitude (only in 'exact' precision mode)
    var preciseLng: Double?             // Exact GPS longitude (only in 'exact' precision mode)
    var lastSeenAt: Date
    var isMe: Bool
    
    /// Status based on last seen time.
    var status: MemberStatus {
        let elapsed = Date().timeIntervalSince(lastSeenAt)
        if elapsed < 30 { return .active }
        if elapsed < 60 { return .stale }
        return .dropped
    }
    
    enum MemberStatus: String {
        case active  = "active"     // < 30s — green
        case stale   = "stale"      // 30-60s — orange
        case dropped = "dropped"    // > 60s — red (alert!)
        
        var color: String {
            switch self {
            case .active:  return "green"
            case .stale:   return "orange"
            case .dropped: return "red"
            }
        }
        
        var icon: String {
            switch self {
            case .active:  return "checkmark.circle.fill"
            case .stale:   return "exclamationmark.circle.fill"
            case .dropped: return "xmark.circle.fill"
            }
        }
    }
    
    // MARK: - Hashable
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: ClubMember, rhs: ClubMember) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Mesh Payloads

/// Payload for periodic location ping within a club.
struct ClubPingPayload: Codable {
    let clubId: String
    let userId: String
    let displayName: String
    let h3Cell: UInt64                  // Resolution 9 (~150m)
    let timestamp: Int64                // ms since epoch
    let batteryLevel: Int               // 0-100 (for adaptive ping interval)
    let preciseLat: Double?             // Exact latitude (only in 'exact' mode)
    let preciseLng: Double?             // Exact longitude (only in 'exact' mode)
}

/// Payload for joining a club.
struct ClubJoinPayload: Codable {
    let clubId: String
    let userId: String
    let displayName: String
    let inviteCode: String
    let timestamp: Int64
}

/// Payload for leaving a club.
struct ClubLeavePayload: Codable {
    let clubId: String
    let userId: String
    let timestamp: Int64
}

// MARK: - Invite Code Generation

extension Club {
    /// Generate a 6-character alphanumeric invite code.
    static func generateInviteCode() -> String {
        let chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" // Exclude ambiguous: I/1, O/0
        return String((0..<6).map { _ in chars.randomElement()! })
    }
}
