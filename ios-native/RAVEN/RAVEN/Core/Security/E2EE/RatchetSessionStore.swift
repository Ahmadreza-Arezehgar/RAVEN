//
//  RatchetSessionStore.swift
//  RAVEN
//
//  SQLite-backed persistence for Double Ratchet sessions and the local
//  pre-key bundle. Storage is encrypted at rest because the underlying
//  database is SQLCipher-encrypted (see DatabaseService.swift).
//
//  Tables:
//    e2ee_sessions       — one row per (peerUserId, peerDeviceId)
//    e2ee_signed_prekeys — our signed pre-keys (current + previous)
//    e2ee_onetime_prekeys— our unused single-use pre-keys
//

import Foundation
import CryptoKit

// MARK: - Codable mirror of RatchetState

/// Wire-format struct for `RatchetState`. CryptoKit types aren't Codable,
/// so we mirror them with raw `Data` and reconstruct on load.
private struct RatchetStateBlob: Codable {
    var DHsPriv: Data
    var DHr: Data?
    var rootKey: Data
    var sendingChainKey: Data?
    var receivingChainKey: Data?
    var Ns: UInt32
    var Nr: UInt32
    var PN: UInt32
    var skippedMessageKeys: [SkippedKeyEntry]

    struct SkippedKeyEntry: Codable {
        var dh: Data
        var n: UInt32
        var key: Data
    }
}

extension RatchetState {
    fileprivate func toBlob() -> RatchetStateBlob {
        let skipped = skippedMessageKeys.map { id, key in
            RatchetStateBlob.SkippedKeyEntry(
                dh: id.dh, n: id.n, key: key.dataRepresentation
            )
        }
        return RatchetStateBlob(
            DHsPriv: DHs.rawRepresentation,
            DHr: DHr,
            rootKey: rootKey.dataRepresentation,
            sendingChainKey: sendingChainKey?.dataRepresentation,
            receivingChainKey: receivingChainKey?.dataRepresentation,
            Ns: Ns,
            Nr: Nr,
            PN: PN,
            skippedMessageKeys: skipped
        )
    }

    fileprivate static func fromBlob(_ b: RatchetStateBlob) throws -> RatchetState {
        var state = RatchetState(
            DHs: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: b.DHsPriv),
            DHr: b.DHr,
            rootKey: SymmetricKey(data: b.rootKey),
            sendingChainKey: b.sendingChainKey.map { SymmetricKey(data: $0) },
            receivingChainKey: b.receivingChainKey.map { SymmetricKey(data: $0) }
        )
        state.Ns = b.Ns
        state.Nr = b.Nr
        state.PN = b.PN
        var dict: [SkippedKeyID: SymmetricKey] = [:]
        for e in b.skippedMessageKeys {
            dict[SkippedKeyID(dh: e.dh, n: e.n)] = SymmetricKey(data: e.key)
        }
        state.skippedMessageKeys = dict
        return state
    }
}

// MARK: - Store

/// Actor-isolated persistence for E2EE sessions and pre-keys. Wraps
/// the singleton `DatabaseService`.
actor RatchetSessionStore {
    static let shared = RatchetSessionStore()

    private let db = DatabaseService.shared
    private var didMigrate = false

    // MARK: - Schema

    private static let schema = [
        """
        CREATE TABLE IF NOT EXISTS e2ee_sessions (
            peer_user_id    TEXT NOT NULL,
            peer_device_id  TEXT NOT NULL,
            state_blob      BLOB NOT NULL,
            updated_at      REAL NOT NULL,
            PRIMARY KEY (peer_user_id, peer_device_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS e2ee_signed_prekeys (
            id          INTEGER PRIMARY KEY,
            private_key BLOB NOT NULL,
            public_key  BLOB NOT NULL,
            signature   BLOB NOT NULL,
            created_at  REAL NOT NULL,
            is_active   INTEGER NOT NULL DEFAULT 1
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS e2ee_onetime_prekeys (
            id          INTEGER PRIMARY KEY,
            private_key BLOB NOT NULL,
            public_key  BLOB NOT NULL,
            consumed    INTEGER NOT NULL DEFAULT 0
        )
        """
    ]

    private func ensureMigrated() async throws {
        if didMigrate { return }
        for stmt in Self.schema {
            try await db.execute(stmt, params: [])
        }
        didMigrate = true
    }

    // MARK: - Sessions

    /// Persist (or replace) a session. Idempotent — call after every
    /// successful encrypt/decrypt to capture the latest ratchet state.
    func saveSession(
        peerUserId: String,
        peerDeviceId: String,
        state: RatchetState
    ) async throws {
        try await ensureMigrated()
        let blob = try JSONEncoder().encode(state.toBlob())
        try await db.execute(
            """
            INSERT INTO e2ee_sessions (peer_user_id, peer_device_id, state_blob, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(peer_user_id, peer_device_id) DO UPDATE SET
                state_blob = excluded.state_blob,
                updated_at = excluded.updated_at
            """,
            params: [peerUserId, peerDeviceId, blob, Date().timeIntervalSince1970]
        )
    }

    /// Load an existing session, or nil if none.
    func loadSession(
        peerUserId: String,
        peerDeviceId: String
    ) async throws -> RatchetState? {
        try await ensureMigrated()
        let rows = try await db.query(
            "SELECT state_blob FROM e2ee_sessions WHERE peer_user_id = ? AND peer_device_id = ? LIMIT 1",
            params: [peerUserId, peerDeviceId]
        )
        guard let row = rows.first, let data = row["state_blob"] as? Data else {
            return nil
        }
        let blob = try JSONDecoder().decode(RatchetStateBlob.self, from: data)
        return try RatchetState.fromBlob(blob)
    }

    /// Delete a session — useful when the peer wipes their device or
    /// we explicitly want to force a fresh X3DH.
    func deleteSession(
        peerUserId: String,
        peerDeviceId: String
    ) async throws {
        try await ensureMigrated()
        try await db.execute(
            "DELETE FROM e2ee_sessions WHERE peer_user_id = ? AND peer_device_id = ?",
            params: [peerUserId, peerDeviceId]
        )
    }

    // MARK: - Signed pre-keys

    /// Generate a fresh signed pre-key, sign it with the device's
    /// Ed25519 identity key, persist it, and mark the previous one
    /// inactive (we keep it around for the rotation grace window so
    /// in-flight session-init messages still decrypt).
    @discardableResult
    func rotateSignedPreKey() async throws -> SignedPreKeyPrivate {
        try await ensureMigrated()
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let pub  = priv.publicKey.rawRepresentation
        guard let signature = DeviceIdentityService.shared.sign(pub) else {
            throw RatchetError.bundleVerificationFailed
        }

        // Mark every prior signed pre-key inactive.
        try await db.execute(
            "UPDATE e2ee_signed_prekeys SET is_active = 0 WHERE is_active = 1",
            params: []
        )

        let now = Date().timeIntervalSince1970
        try await db.execute(
            """
            INSERT INTO e2ee_signed_prekeys (private_key, public_key, signature, created_at, is_active)
            VALUES (?, ?, ?, ?, 1)
            """,
            params: [priv.rawRepresentation, pub, signature, now]
        )

        // Look up the rowid we just inserted.
        let rows = try await db.query(
            "SELECT id FROM e2ee_signed_prekeys WHERE is_active = 1 ORDER BY id DESC LIMIT 1",
            params: []
        )
        let id = (rows.first?["id"] as? Int64).map { UInt32(truncatingIfNeeded: $0) } ?? 0

        return SignedPreKeyPrivate(
            id: id,
            privateKey: priv.rawRepresentation,
            publicKey: pub,
            signature: signature,
            createdAt: now
        )
    }

    /// The currently-active signed pre-key, or nil before first rotation.
    func currentSignedPreKey() async throws -> SignedPreKeyPrivate? {
        try await ensureMigrated()
        let rows = try await db.query(
            "SELECT id, private_key, public_key, signature, created_at FROM e2ee_signed_prekeys WHERE is_active = 1 LIMIT 1",
            params: []
        )
        return rows.first.flatMap(Self.toSignedPreKey)
    }

    /// Look up any signed pre-key by id (active OR inactive). Used by
    /// the responder when an X3DH initial message references an SPK
    /// that we've since rotated out of active.
    func signedPreKey(id: UInt32) async throws -> SignedPreKeyPrivate? {
        try await ensureMigrated()
        let rows = try await db.query(
            "SELECT id, private_key, public_key, signature, created_at FROM e2ee_signed_prekeys WHERE id = ? LIMIT 1",
            params: [Int64(id)]
        )
        return rows.first.flatMap(Self.toSignedPreKey)
    }

    private static func toSignedPreKey(_ row: [String: Any]) -> SignedPreKeyPrivate? {
        guard let id = row["id"] as? Int64,
              let priv = row["private_key"] as? Data,
              let pub  = row["public_key"]  as? Data,
              let sig  = row["signature"]   as? Data,
              let ts   = row["created_at"]  as? Double else {
            return nil
        }
        return SignedPreKeyPrivate(
            id: UInt32(truncatingIfNeeded: id),
            privateKey: priv,
            publicKey: pub,
            signature: sig,
            createdAt: ts
        )
    }

    // MARK: - One-time pre-keys

    /// Generate `count` fresh one-time pre-keys. Call this when the
    /// pool runs low. Server upload happens at a higher layer.
    func generateOneTimePreKeys(count: Int) async throws -> [OneTimePreKeyPrivate] {
        try await ensureMigrated()
        var generated: [OneTimePreKeyPrivate] = []
        try await db.executeInTransaction { db in
            for _ in 0..<count {
                let priv = Curve25519.KeyAgreement.PrivateKey()
                let pub  = priv.publicKey.rawRepresentation
                try db.execute(
                    "INSERT INTO e2ee_onetime_prekeys (private_key, public_key, consumed) VALUES (?, ?, 0)",
                    params: [priv.rawRepresentation, pub]
                )
            }
        }
        // Pull back what we inserted (last `count` rows). We do this
        // outside the transaction because this actor's `execute` is
        // already serialised.
        let rows = try await db.query(
            "SELECT id, private_key, public_key FROM e2ee_onetime_prekeys WHERE consumed = 0 ORDER BY id DESC LIMIT ?",
            params: [count]
        )
        for row in rows.reversed() {
            guard let id = row["id"] as? Int64,
                  let priv = row["private_key"] as? Data,
                  let pub  = row["public_key"]  as? Data else { continue }
            generated.append(OneTimePreKeyPrivate(
                id: UInt32(truncatingIfNeeded: id),
                privateKey: priv,
                publicKey: pub
            ))
        }
        return generated
    }

    /// Pop one unused one-time pre-key. Atomic via UPDATE … RETURNING
    /// pattern (well, two-step here since SQLite RETURNING is recent).
    func consumeOneTimePreKey(id: UInt32) async throws -> OneTimePreKeyPrivate? {
        try await ensureMigrated()
        let rows = try await db.query(
            "SELECT id, private_key, public_key FROM e2ee_onetime_prekeys WHERE id = ? AND consumed = 0 LIMIT 1",
            params: [Int64(id)]
        )
        guard let row = rows.first,
              let rid = row["id"] as? Int64,
              let priv = row["private_key"] as? Data,
              let pub  = row["public_key"]  as? Data else {
            return nil
        }
        try await db.execute(
            "UPDATE e2ee_onetime_prekeys SET consumed = 1 WHERE id = ?",
            params: [rid]
        )
        return OneTimePreKeyPrivate(
            id: UInt32(truncatingIfNeeded: rid),
            privateKey: priv,
            publicKey: pub
        )
    }

    /// Number of unused one-time pre-keys remaining. The replenisher
    /// uses this to decide when to mint a new batch.
    func unusedOneTimePreKeyCount() async throws -> Int {
        try await ensureMigrated()
        let rows = try await db.query(
            "SELECT COUNT(*) AS c FROM e2ee_onetime_prekeys WHERE consumed = 0",
            params: []
        )
        return (rows.first?["c"] as? Int64).map(Int.init) ?? 0
    }
}
