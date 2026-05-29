//
//  PeerIdentityRegistry.swift
//  RAVEN
//
//  Trust-On-First-Use (TOFU) registry for peer identity keys, with
//  detection of subsequent changes — the security primitive that
//  catches the most likely real-world attack on a Double-Ratchet
//  setup: a server-side MITM swapping a peer's key during the very
//  first bundle fetch (or a later re-fetch).
//
//  How this works
//  ──────────────
//  Every time we fetch a peer's pre-key bundle, we hand it to this
//  registry along with the (userId, deviceId) pair. The registry:
//
//    1. If we've never seen this peer's identity key before, record
//       it. (Trust-on-first-use — same model Signal uses.)
//
//    2. If we've seen it before AND the bytes match, record nothing
//       new and return `.unchanged`.
//
//    3. If we've seen it before AND the bytes don't match, return
//       `.changed` with the previous fingerprint. The caller must
//       surface a UI warning, revoke any prior "Verified" badge,
//       and force the user to re-verify before treating new
//       messages as authentic.
//
//  Storage: the SQLCipher-encrypted app DB. Identity keys are public
//  bytes so the encryption is defence-in-depth, not strictly needed.
//
//  Integration points
//  ──────────────────
//  • `E2EENetworkProvider.fetchBundle` — calls `recordOrCheck` on
//    every bundle pulled from the server.
//  • `SafetyNumberView` — listens to `peerIdentityChanged` notifs to
//    revoke its UserDefaults verified-flag.
//  • Chat header / details (next iteration) — surfaces a banner when
//    the registry signals a change.
//

import Foundation
import CryptoKit

actor PeerIdentityRegistry {
    static let shared = PeerIdentityRegistry()

    private let db = DatabaseService.shared
    private var didMigrate = false

    // MARK: - Schema

    private static let schema = [
        """
        CREATE TABLE IF NOT EXISTS e2ee_peer_identities (
            peer_user_id     TEXT NOT NULL,
            peer_device_id   TEXT NOT NULL,
            identity_key     BLOB NOT NULL,
            identity_sha256  BLOB NOT NULL,
            first_seen_at    REAL NOT NULL,
            last_seen_at     REAL NOT NULL,
            PRIMARY KEY (peer_user_id, peer_device_id)
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

    // MARK: - Result

    enum Outcome {
        /// First time we've seen this peer device — recorded fresh.
        case firstSeen(fingerprint: String)
        /// Same identity key as last time. Nothing to do.
        case unchanged(fingerprint: String)
        /// Peer's identity key has changed. Includes both
        /// fingerprints so the UI can show "old → new".
        case changed(previousFingerprint: String, newFingerprint: String)
    }

    // MARK: - API

    /// Record or check a peer's identity key. Idempotent. Safe to
    /// call on every bundle fetch.
    @discardableResult
    func recordOrCheck(
        peerUserId: String,
        peerDeviceId: String,
        identityKey: Data
    ) async throws -> Outcome {
        try await ensureMigrated()
        let now = Date().timeIntervalSince1970
        let newHash = Data(SHA256.hash(data: identityKey))

        let rows = try await db.query(
            """
            SELECT identity_key, identity_sha256
            FROM e2ee_peer_identities
            WHERE peer_user_id = ? AND peer_device_id = ?
            LIMIT 1
            """,
            params: [peerUserId, peerDeviceId]
        )

        if let existing = rows.first,
           let oldKey = existing["identity_key"] as? Data {
            if oldKey == identityKey {
                // Bump last_seen_at — useful for liveness diagnostics.
                try await db.execute(
                    """
                    UPDATE e2ee_peer_identities
                    SET last_seen_at = ?
                    WHERE peer_user_id = ? AND peer_device_id = ?
                    """,
                    params: [now, peerUserId, peerDeviceId]
                )
                return .unchanged(fingerprint: Self.fingerprint(of: identityKey))
            } else {
                // Replace and broadcast the change.
                try await db.execute(
                    """
                    UPDATE e2ee_peer_identities
                    SET identity_key = ?, identity_sha256 = ?, last_seen_at = ?
                    WHERE peer_user_id = ? AND peer_device_id = ?
                    """,
                    params: [identityKey, newHash, now, peerUserId, peerDeviceId]
                )
                let oldFp = Self.fingerprint(of: oldKey)
                let newFp = Self.fingerprint(of: identityKey)
                await broadcastChange(
                    peerUserId: peerUserId,
                    peerDeviceId: peerDeviceId,
                    oldFingerprint: oldFp,
                    newFingerprint: newFp
                )
                return .changed(previousFingerprint: oldFp, newFingerprint: newFp)
            }
        } else {
            // Never seen — insert.
            try await db.execute(
                """
                INSERT INTO e2ee_peer_identities
                (peer_user_id, peer_device_id, identity_key, identity_sha256, first_seen_at, last_seen_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                params: [peerUserId, peerDeviceId, identityKey, newHash, now, now]
            )
            return .firstSeen(fingerprint: Self.fingerprint(of: identityKey))
        }
    }

    /// Fetch the currently-recorded identity key for a peer. Returns
    /// nil if we've never seen them.
    func currentIdentityKey(peerUserId: String, peerDeviceId: String) async throws -> Data? {
        try await ensureMigrated()
        let rows = try await db.query(
            "SELECT identity_key FROM e2ee_peer_identities WHERE peer_user_id = ? AND peer_device_id = ? LIMIT 1",
            params: [peerUserId, peerDeviceId]
        )
        return rows.first?["identity_key"] as? Data
    }

    /// Drop the stored identity for a peer. Used in test harnesses
    /// or after a user explicitly resets a chat. Forces the next
    /// bundle fetch back into TOFU mode.
    func forget(peerUserId: String, peerDeviceId: String) async throws {
        try await ensureMigrated()
        try await db.execute(
            "DELETE FROM e2ee_peer_identities WHERE peer_user_id = ? AND peer_device_id = ?",
            params: [peerUserId, peerDeviceId]
        )
    }

    // MARK: - Helpers

    /// Short, human-readable fingerprint of an identity key — first
    /// 9 bytes of SHA-256 in base64, formatted "XXXX-XXXX-XXXX".
    /// Matches the format `DeviceIdentityService.fingerprint` uses
    /// for the device's own key, so users see consistent visuals.
    static func fingerprint(of identityKey: Data) -> String {
        let hash = Data(SHA256.hash(data: identityKey))
        let b64 = hash.prefix(9).base64EncodedString()
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "/", with: "")
            .prefix(12)
        return String(b64).enumerated().map { i, c in
            (i > 0 && i % 4 == 0) ? "-\(c)" : "\(c)"
        }.joined()
    }

    private func broadcastChange(
        peerUserId: String,
        peerDeviceId: String,
        oldFingerprint: String,
        newFingerprint: String
    ) async {
        // Side-effect on a non-isolated bus so any view can observe.
        await MainActor.run {
            NotificationCenter.default.post(
                name: .ravenPeerIdentityChanged,
                object: nil,
                userInfo: [
                    "peerUserId": peerUserId,
                    "peerDeviceId": peerDeviceId,
                    "oldFingerprint": oldFingerprint,
                    "newFingerprint": newFingerprint,
                ]
            )
        }
    }
}

// MARK: - Notification name

extension Notification.Name {
    /// Fires (on the main queue) when a peer's identity key fingerprint
    /// changes. UserInfo carries:
    ///   peerUserId       String
    ///   peerDeviceId     String
    ///   oldFingerprint   String  ("XXXX-XXXX-XXXX")
    ///   newFingerprint   String
    static let ravenPeerIdentityChanged = Notification.Name("ravenPeerIdentityChanged")
}
