//
//  VaultLock.swift
//  RAVEN
//
//  Embeddable vault lock for posts and messages.
//  When attached, content is encrypted with a location-derived key
//  and only unlocks when the viewer is at the specified H3 cell.
//

import Foundation

// MARK: - Vault Lock

/// Embeddable location-lock that can be attached to any post or message.
struct VaultLock: Codable, Hashable {
    /// H3 cells where this content can be unlocked.
    let targetH3Cells: [String]
    
    /// H3 resolution used for key derivation (7 ≈ 1.2km).
    let resolution: Int
    
    /// Required unlock distance in meters.
    let unlockDistanceMeters: Int
    
    /// When the lock expires (after this, content is visible to all).
    let expiresAt: Date?
    
    /// Whether this is a burnable lock (auto-delete after first unlock).
    let isBurnable: Bool
    
    /// Has the current user unlocked this content?
    var isUnlocked: Bool
    
    // MARK: - Convenience
    
    /// Whether the lock has expired (if set).
    var isExpired: Bool {
        guard let expires = expiresAt else { return false }
        return Date() > expires
    }
    
    /// Whether content should be visible (unlocked OR expired).
    var isContentVisible: Bool {
        isUnlocked || isExpired
    }
    
    /// Create a vault lock for the current location.
    @MainActor
    static func atCurrentLocation(
        resolution: Int = 7,
        unlockDistanceMeters: Int = 1200,
        expiresAt: Date? = nil,
        isBurnable: Bool = false
    ) -> VaultLock? {
        guard let cell = LocationPrivacyService.shared.currentH3Cell(resolution: resolution) else { return nil }
        let neighbors = H3Lite.gridDisk(origin: cell, k: 1).map { H3Lite.cellToString($0) }
        
        return VaultLock(
            targetH3Cells: neighbors,
            resolution: resolution,
            unlockDistanceMeters: unlockDistanceMeters,
            expiresAt: expiresAt,
            isBurnable: isBurnable,
            isUnlocked: false
        )
    }
}
