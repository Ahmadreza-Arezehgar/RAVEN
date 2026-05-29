//
//  Echo.swift
//  RAVEN
//
//  Data models for the Echo feature — anonymous broadcast questions
//  with emoji responses via mesh network.
//

import Foundation
import CoreLocation

// MARK: - Echo

/// An anonymous broadcast question sent through the mesh network.
struct Echo: Codable, Identifiable, Hashable {
    let id: String                      // echo_id (UUID)
    let authorPseudonym: String         // 8-char hex from hash(userId + dailySalt)
    let content: String                 // Question text (max 200 chars)
    let h3Cell: String?                 // City-level location (resolution 5, optional)
    let createdAt: Date
    let expiresAt: Date
    let isMine: Bool                    // True if this user authored the echo
    let receivedAt: Date                // When this device received the echo
    
    /// Whether this echo has expired.
    var isExpired: Bool {
        Date() > expiresAt
    }
    
    /// Time remaining as a formatted string.
    var timeRemaining: String {
        let remaining = expiresAt.timeIntervalSince(Date())
        if remaining <= 0 { return "Expired" }
        let hours = Int(remaining / 3600)
        let minutes = Int(remaining.truncatingRemainder(dividingBy: 3600) / 60)
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
    
    /// Echo opacity decreases as it approaches expiry.
    /// Fresh echo: 1.0 — Last hour: 0.4
    var fadeOpacity: Double {
        let totalLife = expiresAt.timeIntervalSince(createdAt)
        guard totalLife > 0 else { return 1.0 }
        let elapsed = Date().timeIntervalSince(createdAt)
        let progress = elapsed / totalLife
        return max(0.4, 1.0 - (progress * 0.6))
    }
    
    /// Map coordinate from H3 cell (city-level, resolution 5).
    var mapCoordinate: CLLocationCoordinate2D? {
        guard let cellStr = h3Cell, let cell = UInt64(cellStr, radix: 16) else { return nil }
        let center = H3Lite.cellToLatLng(cell)
        return CLLocationCoordinate2D(latitude: center.lat, longitude: center.lng)
    }
    
    // MARK: - Hashable
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: Echo, rhs: Echo) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Echo Emoji

/// The 5 allowed emoji responses for echoes.
/// Limited set to encourage quick, anonymous, unambiguous reactions.
enum EchoEmoji: String, CaseIterable, Codable {
    case heart   = "❤️"
    case star    = "⭐"
    case wave    = "👋"
    case sparkle = "✨"
    case moon    = "🌙"
    
    /// Display label for accessibility.
    var label: String {
        switch self {
        case .heart:   return "Love"
        case .star:    return "Star"
        case .wave:    return "Wave"
        case .sparkle: return "Sparkle"
        case .moon:    return "Moon"
        }
    }
}

// MARK: - Echo Response Summary

/// Aggregated response counts for an echo.
struct EchoResponseSummary {
    let echoId: String
    var counts: [EchoEmoji: Int]
    
    var totalCount: Int {
        counts.values.reduce(0, +)
    }
    
    /// Returns sorted emoji-count pairs (highest count first).
    var sortedCounts: [(emoji: EchoEmoji, count: Int)] {
        counts.sorted { $0.value > $1.value }
              .map { (emoji: $0.key, count: $0.value) }
    }
    
    /// Empty summary.
    static func empty(for echoId: String) -> EchoResponseSummary {
        EchoResponseSummary(echoId: echoId, counts: [:])
    }
}

// MARK: - Mesh Payloads

/// Payload for broadcasting a new echo via mesh.
struct EchoBroadcastPayload: Codable {
    let echoId: String
    let authorPseudonym: String
    let content: String                 // max 200 chars
    let h3Cell: String?                 // resolution 5 (city-level), optional
    let createdAt: Int64                // ms since epoch
    let ttlMinutes: Int                 // 60-1440
    let signature: String?              // Ed25519 signature of content hash
}

/// Payload for responding to an echo via mesh.
struct EchoResponsePayload: Codable {
    let echoId: String
    let emoji: String                   // One of the 5 allowed emojis
    let responseNonce: String           // UUID — for dedup (INSERT OR IGNORE)
    let timestamp: Int64                // ms since epoch
    // *** No sender identity — responses are anonymous ***
}

// MARK: - Pseudonym Generation

extension Echo {
    /// Generate a privacy-preserving pseudonym from userId.
    /// Uses a daily-rotating salt so pseudonyms change every 24 hours.
    /// This prevents long-term identity linking while still allowing
    /// per-session dedup of an author's echoes.
    static func generatePseudonym(for userId: String) -> String {
        let calendar = Calendar.current
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: Date()) ?? 0
        let year = calendar.component(.year, from: Date())
        let dailySalt = "raven-echo-salt-\(year)-\(dayOfYear)"
        
        let input = "\(userId)-\(dailySalt)"
        // Simple hash — first 8 hex chars
        var hash: UInt64 = 5381
        for char in input.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(char)
        }
        return String(format: "%08llx", hash)
    }
}

// MARK: - Rate Limiting

/// Tracks echo creation rate to prevent spam.
struct EchoRateLimiter {
    private var creationTimestamps: [Date] = []
    
    static let maxPerHour = 3
    static let maxPerDay = 10
    
    mutating func canCreate() -> Bool {
        let now = Date()
        // Clean up old entries
        creationTimestamps.removeAll { now.timeIntervalSince($0) > 86400 }
        
        // Check daily limit
        if creationTimestamps.count >= Self.maxPerDay { return false }
        
        // Check hourly limit
        let hourAgo = now.addingTimeInterval(-3600)
        let recentCount = creationTimestamps.filter { $0 > hourAgo }.count
        if recentCount >= Self.maxPerHour { return false }
        
        return true
    }
    
    mutating func recordCreation() {
        creationTimestamps.append(Date())
    }
}
