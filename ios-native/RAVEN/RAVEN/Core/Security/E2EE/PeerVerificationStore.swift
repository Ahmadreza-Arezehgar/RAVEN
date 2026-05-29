//
//  PeerVerificationStore.swift
//  RAVEN
//
//  The user-facing "Verified" flag for each peer's identity. Stored
//  in UserDefaults (small, per-peer), wiped automatically the moment
//  the peer's identity key changes — that's the security invariant
//  this file exists to enforce.
//
//  Why a dedicated module instead of inline UserDefaults reads
//  ─────────────────────────────────────────────────────────
//  Two reasons:
//
//   1. The SafetyNumberView and any future chat-header badge need
//      consistent "is this peer verified" reads / writes. Centralising
//      means one schema, one bug.
//
//   2. Identity-change detection MUST always wipe the verified flag.
//      Doing this in a single observer here — instead of expecting
//      every UI surface to listen — makes the security guarantee
//      auditable in one place.
//

import Foundation
import os

fileprivate let logger = Logger(subsystem: "app.raven.ios", category: "Security.PeerVerification")

enum PeerVerificationStore {

    private static let prefix = "raven.e2ee.peerVerified."

    private static func key(for peerUserId: String) -> String {
        prefix + peerUserId
    }

    static func isVerified(peerUserId: String) -> Bool {
        UserDefaults.standard.bool(forKey: key(for: peerUserId))
    }

    static func setVerified(_ verified: Bool, peerUserId: String) {
        UserDefaults.standard.set(verified, forKey: key(for: peerUserId))
        NotificationCenter.default.post(
            name: .ravenPeerVerificationChanged,
            object: nil,
            userInfo: [
                "peerUserId": peerUserId,
                "verified": verified,
            ]
        )
    }

    /// Set up the auto-revoke side-effect: every time a peer's
    /// identity key is reported as changed by `PeerIdentityRegistry`,
    /// we wipe their "verified" flag. Call once at app start.
    /// Idempotent — repeat calls are no-ops.
    static func startAutoRevokeOnIdentityChange() {
        guard !didStart else { return }
        didStart = true
        NotificationCenter.default.addObserver(
            forName: .ravenPeerIdentityChanged,
            object: nil,
            queue: .main
        ) { note in
            guard let peerUserId = note.userInfo?["peerUserId"] as? String else { return }
            // Wiping is the cautious default — even if the new key
            // is legitimate (peer reinstalled the app), the user
            // should re-verify out-of-band before we treat the chat
            // as secure again.
            UserDefaults.standard.removeObject(forKey: key(for: peerUserId))
            NotificationCenter.default.post(
                name: .ravenPeerVerificationChanged,
                object: nil,
                userInfo: [
                    "peerUserId": peerUserId,
                    "verified": false,
                    "revokedDueToKeyChange": true,
                ]
            )
            logger.debug("Verification revoked for \(peerUserId, privacy: .private) (peer key changed)")
        }
    }

    private static var didStart = false
}

// MARK: - Notification name

extension Notification.Name {
    /// Fires (on the main queue) whenever the user's verification
    /// state for a peer changes. Listeners (chat header, settings
    /// rows) should refresh.
    ///
    /// userInfo:
    ///   peerUserId            String
    ///   verified              Bool
    ///   revokedDueToKeyChange Bool   (only on automatic revocation)
    static let ravenPeerVerificationChanged = Notification.Name("ravenPeerVerificationChanged")
}
