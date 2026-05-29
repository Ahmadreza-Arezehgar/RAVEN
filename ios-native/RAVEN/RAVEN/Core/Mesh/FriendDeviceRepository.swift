//
//  FriendDeviceRepository.swift
//  RAVEN
//
//  Thread-safe repository for managing trusted friend devices in local database.
//  Uses DatabaseService actor methods (execute/query) instead of raw getDB() pointer
//  to prevent SQLite threading errors and data races.
//

import Foundation
import os

fileprivate let logger = Logger(subsystem: "app.raven.ios", category: "Mesh.FriendDeviceRepo")

actor FriendDeviceRepository {
    static let shared = FriendDeviceRepository()
    private let db = DatabaseService.shared
    
    // MARK: - In-Memory Cache
    private var memoryCache: [String: FriendDevice] = [:]
    private var isCacheLoaded = false
    
    private init() {}
    
    // MARK: - Cache Loading
    
    private func loadCacheIfNeeded() async {
        guard !isCacheLoaded else { return }
        do {
            let rows = try await db.query("SELECT * FROM friend_devices")
            for row in rows {
                if let device = parseDevice(row) {
                    memoryCache[device.fingerprint] = device
                }
            }
            isCacheLoaded = true
        } catch {
            logger.debug("Failed to load cache: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    // MARK: - Table Creation
    
    func createTableIfNeeded() async throws {
        // 🔐 BUG FIX (2026-05-10): include `agreement_public_key`
        // directly in the fresh-install schema. Previously this column
        // was added only by Migration 16 in DatabaseService — but
        // migrations run BEFORE this method on first launch, so the
        // ALTER TABLE silently no-op'd (table didn't exist yet) and
        // the recreate path here never re-added the column. Result:
        // ECDH agreement public key permanently absent → E2EE
        // negotiation broken on every fresh install. Adding the
        // column here fixes the fresh-install path; existing
        // installs are still patched by Migration 16.
        let schema = """
            CREATE TABLE IF NOT EXISTS friend_devices (
                id TEXT PRIMARY KEY,
                friend_user_id TEXT NOT NULL,
                fingerprint TEXT NOT NULL UNIQUE,
                public_key BLOB NOT NULL,
                agreement_public_key BLOB,
                trust_state TEXT DEFAULT 'pending',
                verified_at REAL,
                added_at REAL NOT NULL,
                device_name TEXT,
                last_seen_at REAL
            )
        """
        try await db.execute(schema)
        try await db.execute("CREATE INDEX IF NOT EXISTS idx_friend_fingerprint ON friend_devices(fingerprint)")
        try await db.execute("CREATE INDEX IF NOT EXISTS idx_friend_trust ON friend_devices(trust_state)")
        try await db.execute("CREATE INDEX IF NOT EXISTS idx_friend_user ON friend_devices(friend_user_id)")
        logger.debug("Table created/verified")
    }
    
    // MARK: - CRUD Operations (Cache + DB Write-Through)
    
    /// Add or update a friend device
    func upsert(_ device: FriendDevice) async throws {
        await loadCacheIfNeeded()
        memoryCache[device.fingerprint] = device
        
        let sql = """
            INSERT OR REPLACE INTO friend_devices 
            (id, friend_user_id, fingerprint, public_key, agreement_public_key, trust_state, verified_at, added_at, device_name, last_seen_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        try await db.execute(sql, params: [
            device.id,
            device.friendUserId,
            device.fingerprint,
            device.publicKey,
            device.agreementPublicKey ?? NSNull(),
            device.trustState.rawValue,
            device.verifiedAt?.timeIntervalSince1970 ?? NSNull(),
            device.addedAt.timeIntervalSince1970,
            device.deviceName ?? NSNull(),
            device.lastSeenAt?.timeIntervalSince1970 ?? NSNull()
        ])
    }
    
    /// Find device by fingerprint (from cache)
    func findByFingerprint(_ fingerprint: String) async -> FriendDevice? {
        await loadCacheIfNeeded()
        return memoryCache[fingerprint]
    }
    
    /// Get all trusted devices for a friend (from cache)
    func getTrustedDevices(forUser friendUserId: String) async -> [FriendDevice] {
        await loadCacheIfNeeded()
        return memoryCache.values.filter { $0.friendUserId == friendUserId && $0.trustState == .trusted }
    }

    /// Get any device record for a friend regardless of trust state.
    /// Used by the TOFU code path so it can short-circuit when a
    /// `.unverified` row already exists, instead of churning the DB
    /// with a fresh row per incoming message. (RE-AUDIT FIX 2026-05-10).
    func getAnyDevice(forUser friendUserId: String, fingerprint: String) async -> FriendDevice? {
        await loadCacheIfNeeded()
        return memoryCache.values.first { $0.friendUserId == friendUserId && $0.fingerprint == fingerprint }
    }
    
    /// Get all trusted devices (any friend) (from cache)
    func getAllTrustedDevices() async -> [FriendDevice] {
        await loadCacheIfNeeded()
        return memoryCache.values.filter { $0.trustState == .trusted }
    }
    
    /// Update trust state
    func updateTrustState(_ fingerprint: String, state: TrustState) async throws {
        await loadCacheIfNeeded()
        if var device = memoryCache[fingerprint] {
            device.trustState = state
            if state == .trusted { device.verifiedAt = Date() }
            memoryCache[fingerprint] = device
        }
        
        if state == .trusted {
            try await db.execute(
                "UPDATE friend_devices SET trust_state = ?, verified_at = ? WHERE fingerprint = ?",
                params: [state.rawValue, Date().timeIntervalSince1970, fingerprint]
            )
        } else {
            try await db.execute(
                "UPDATE friend_devices SET trust_state = ? WHERE fingerprint = ?",
                params: [state.rawValue, fingerprint]
            )
        }
        logger.debug("Updated trust state: \(fingerprint, privacy: .private) → \(state.rawValue, privacy: .public)")
    }
    
    /// Check if fingerprint is trusted
    func isTrusted(_ fingerprint: String) async -> Bool {
        guard let device = await findByFingerprint(fingerprint) else { return false }
        return device.trustState == .trusted
    }
    
    /// Revoke a device
    func revokeDevice(_ fingerprint: String) async throws {
        try await updateTrustState(fingerprint, state: .revoked)
    }
    
    /// Delete a device
    func deleteDevice(_ fingerprint: String) async throws {
        await loadCacheIfNeeded()
        memoryCache.removeValue(forKey: fingerprint)
        try await db.execute(
            "DELETE FROM friend_devices WHERE fingerprint = ?",
            params: [fingerprint]
        )
        logger.debug("Deleted device: \(fingerprint, privacy: .private)")
    }
    
    // MARK: - Helper
    
    private func parseDevice(_ row: [String: Any]) -> FriendDevice? {
        guard let id = row["id"] as? String,
              let friendUserId = row["friend_user_id"] as? String,
              let fingerprint = row["fingerprint"] as? String,
              let publicKey = row["public_key"] as? Data else {
            return nil
        }
        
        let trustState = TrustState(rawValue: row["trust_state"] as? String ?? "pending") ?? .pending
        let verifiedAt = (row["verified_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let addedAt = Date(timeIntervalSince1970: row["added_at"] as? Double ?? 0)
        let lastSeenAt = (row["last_seen_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        
        return FriendDevice(
            id: id,
            friendUserId: friendUserId,
            fingerprint: fingerprint,
            publicKey: publicKey,
            agreementPublicKey: row["agreement_public_key"] as? Data,
            trustState: trustState,
            verifiedAt: verifiedAt,
            addedAt: addedAt,
            deviceName: row["device_name"] as? String,
            lastSeenAt: lastSeenAt
        )
    }
}

// MARK: - Errors

enum FriendDeviceError: Error {
    case failedToPrepare
    case failedToExecute
}
