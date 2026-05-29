//
//  RavenShotItem.swift
//  RAVEN
//
//  Unified model for map annotations in Raven Shot.
//  Wraps Post, Echo, or Club data into a common format.
//

import Foundation
import CoreLocation

// MARK: - Raven Shot Content Type

enum RavenShotContentType: String, Codable {
    case post = "post"
    case echo = "echo"
    case club = "club"
    
    var label: String {
        switch self {
        case .post: return "Post"
        case .echo: return "Echo"
        case .club: return "Club"
        }
    }
    
    var icon: String {
        switch self {
        case .post: return "text.bubble.fill"
        case .echo: return "waveform.circle.fill"
        case .club: return "person.3.fill"
        }
    }
    
    var accentColorName: String {
        switch self {
        case .post: return "blue"
        case .echo: return "purple"
        case .club: return "green"
        }
    }
}

// MARK: - Raven Shot Item

/// Unified map annotation model for the social map.
/// Encapsulates content from Posts, Echoes, and Clubs into a single
/// coordinate-aware format for map display.
struct RavenShotItem: Identifiable, Hashable {
    let id: String
    let contentType: RavenShotContentType
    let coordinate: CLLocationCoordinate2D
    let authorName: String
    let authorUsername: String?
    let authorAvatar: String?
    let contentPreview: String
    let timestamp: Date
    let visibility: String?         // "public", "friends", "local"
    let mediaPreviewUrl: String?    // First image URL for preview
    let sourceId: String            // Original Post/Echo/Club ID for navigation
    
    // MARK: - Hashable
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: RavenShotItem, rhs: RavenShotItem) -> Bool {
        lhs.id == rhs.id
    }
    
    // MARK: - Factory Methods
    
    /// Create a RavenShotItem from a Post with location.
    static func from(post: Post) -> RavenShotItem? {
        guard let lat = post.latitude, let lng = post.longitude else { return nil }
        guard post.showOnRavenShot == true else { return nil }
        
        return RavenShotItem(
            id: "post-\(post.id)",
            contentType: .post,
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
            authorName: post.authorUsername,
            authorUsername: post.authorUsername,
            authorAvatar: post.authorAvatar,
            contentPreview: String(post.content.prefix(120)),
            timestamp: post.timestamp,
            visibility: post.visibility,
            mediaPreviewUrl: post.allMediaUrls.first,
            sourceId: post.id
        )
    }
    
    /// Create a RavenShotItem from an Echo with H3 cell location.
    static func from(echo: Echo) -> RavenShotItem? {
        guard let coord = echo.mapCoordinate else { return nil }
        guard !echo.isExpired else { return nil }
        
        return RavenShotItem(
            id: "echo-\(echo.id)",
            contentType: .echo,
            coordinate: coord,
            authorName: String(echo.authorPseudonym.prefix(8)),
            authorUsername: nil,
            authorAvatar: nil,
            contentPreview: String(echo.content.prefix(120)),
            timestamp: echo.createdAt,
            visibility: "public",   // Echoes are broadcast-level
            mediaPreviewUrl: nil,
            sourceId: echo.id
        )
    }
    
    /// Create a RavenShotItem from a Club with creator location.
    static func from(club: Club, creatorLocation: CLLocationCoordinate2D, creatorName: String, creatorAvatar: String?) -> RavenShotItem? {
        guard club.isActive else { return nil }
        
        return RavenShotItem(
            id: "club-\(club.id)",
            contentType: .club,
            coordinate: creatorLocation,
            authorName: creatorName,
            authorUsername: nil,
            authorAvatar: creatorAvatar,
            contentPreview: club.name,
            timestamp: club.createdAt,
            visibility: "public",
            mediaPreviewUrl: nil,
            sourceId: club.id
        )
    }
    
    /// Whether this item was posted in the last hour. Used to tint the
    /// pin distinctly from older content.
    var isRecent: Bool {
        Date().timeIntervalSince(timestamp) < 3600
    }

    /// Whether this item is "happening now" (< 5 min old). Drives the
    /// stronger pulse animation and the LIVE badge on the marker.
    var isLive: Bool {
        Date().timeIntervalSince(timestamp) < 300
    }
    
    /// Relative timestamp (e.g., "2h ago").
    var relativeTime: String {
        let elapsed = Date().timeIntervalSince(timestamp)
        if elapsed < 60 { return "Just now" }
        if elapsed < 3600 {
            let mins = Int(elapsed / 60)
            return "\(mins)m ago"
        }
        if elapsed < 86400 {
            let hours = Int(elapsed / 3600)
            return "\(hours)h ago"
        }
        let days = Int(elapsed / 86400)
        return "\(days)d ago"
    }
}
