//
//  E2EEMessagePipeline.swift
//  RAVEN
//
//  Two tiny static helpers that bolt the Double-Ratchet gateway onto
//  the existing send/receive hot paths with the minimum possible
//  source changes — call sites in MessageStore and ConversationStore
//  add ONE line each.
//
//  Wire format
//  ───────────
//  An encrypted message's `text` field carries:
//
//      "e2ee:v1:" + base64( JSON(E2EEWirePacket) )
//
//  The magic prefix is the receiver's signal to decrypt. Plaintext
//  messages flow through unchanged — receivers that don't recognise
//  the prefix just render whatever text they get, exactly as today.
//
//  Why a magic prefix instead of a new schema field
//  ───────────────────────────────────────────────
//  ChatMessage already crosses many storage / serialisation
//  boundaries. Threading a new `payload_kind` column through
//  REST DTOs, SQLite migrations, MeshEnvelope, and Windows interop
//  is a lot of surface area. A reserved string prefix keeps the
//  schema untouched and is trivially reversible if E2EE is rolled
//  back.
//
//  Group / channel messages
//  ────────────────────────
//  Phase 1 only wraps 1-on-1 messages. Pairwise Double Ratchet for
//  groups would mean N copies per send; that path is reserved for
//  Phase 3 (Sender Keys or MLS). Until then, group messages flow
//  through unwrapped.
//

import Foundation
import os

fileprivate let logger = Logger(subsystem: "app.raven.ios", category: "Security.E2EEPipeline")

enum E2EEMessagePipeline {

    /// Marker that lets receivers detect an encrypted body.
    static let wirePrefix = "e2ee:v1:"

    // MARK: - Outgoing

    /// Wrap plaintext for outbound transport, IF every guard passes:
    ///   • feature flag is on
    ///   • this is a 1-on-1 chat (not group / channel)
    ///   • we have a recipient user id
    ///   • the gateway successfully establishes a session
    ///
    /// On any failure we fall back to plaintext — encryption is best-
    /// effort during the phase-1 rollout. Once the rollout is solid,
    /// the caller can flip a stricter mode that throws instead.
    ///
    /// The returned string is what the caller should assign to
    /// `ChatMessage.text` before transport. It's either the original
    /// plaintext (passthrough) or the wirePrefix-tagged ciphertext.
    static func wrapOutgoing(
        plaintext: String,
        recipientUserId: String,
        recipientDeviceId: String? = nil,
        messageId: String,
        isGroup: Bool
    ) async -> String {

        guard !isGroup else { return plaintext }
        guard E2EEMessageGateway.isEnabled else { return plaintext }
        guard !recipientUserId.isEmpty else { return plaintext }

        // Phase 1: ChatMessage carries no recipient deviceId yet, so
        // we tag the session with a stable per-user pseudo-device.
        // When multi-device lands, the caller should pass the real
        // peer device fingerprint here.
        let peer = PeerAddress(
            userId: recipientUserId,
            deviceId: recipientDeviceId ?? "primary"
        )

        do {
            let wireBase64 = try await E2EEMessageGateway.shared.wrapOutgoing(
                plaintext: plaintext,
                to: peer,
                messageId: messageId
            )
            return wirePrefix + wireBase64
        } catch {
            logger.debug("wrap failed for \(messageId, privacy: .private): \(error.localizedDescription, privacy: .public) — sending plaintext")
            return plaintext
        }
    }

    // MARK: - Incoming

    /// Inverse of `wrapOutgoing`. Detects the magic prefix and
    /// decrypts; passes plaintext through untouched. Failure to
    /// decrypt returns the original (still-prefixed) text — that
    /// way the message is preserved for diagnostics rather than
    /// silently dropped, but the prefix makes it obvious in the UI
    /// that something went wrong.
    static func unwrapIncoming(
        text: String,
        senderUserId: String,
        senderDeviceId: String? = nil,
        messageId: String
    ) async -> String {

        guard text.hasPrefix(wirePrefix) else { return text }
        guard !senderUserId.isEmpty else { return text }

        let wireBase64 = String(text.dropFirst(wirePrefix.count))
        let peer = PeerAddress(
            userId: senderUserId,
            deviceId: senderDeviceId ?? "primary"
        )

        do {
            return try await E2EEMessageGateway.shared.unwrapIncoming(
                wireBase64: wireBase64,
                from: peer,
                messageId: messageId
            )
        } catch {
            logger.debug("unwrap failed for \(messageId, privacy: .private): \(error.localizedDescription, privacy: .public)")
            return text
        }
    }

    /// Quick check used by UI / logging — does this body look encrypted?
    static func isEncrypted(_ text: String) -> Bool {
        text.hasPrefix(wirePrefix)
    }

    /// 🟥 ROUND 36 (2026-05-17) — pre-flight session existence check.
    ///
    /// Lets the send-side decide whether `wrapOutgoing` would need
    /// a server round-trip (X3DH bundle fetch) BEFORE actually
    /// invoking it.  Use case: we're offline and want to skip the
    /// wrap entirely instead of having it fail with NSURLErrorDomain
    /// -1009 and silently fall back to plaintext (visible in user
    /// log as "wrap failed for X: ... sending plaintext").
    ///
    /// Returns true iff a Double-Ratchet session for the given
    /// recipient already exists in the local store.  When true,
    /// `wrapOutgoing` can succeed offline (the encrypt is purely
    /// local — no bundle fetch needed).  When false AND offline,
    /// the caller should skip wrap and let the inner NoiseIK seal
    /// layer handle encryption (it also works offline IF the
    /// recipient pubkey is cached in PeerKeyDirectory /
    /// FriendDeviceRepository).
    static func hasSession(
        recipientUserId: String,
        recipientDeviceId: String? = nil
    ) async -> Bool {
        guard E2EEMessageGateway.isEnabled,
              !recipientUserId.isEmpty else {
            return false
        }
        do {
            let state = try await RatchetSessionStore.shared.loadSession(
                peerUserId: recipientUserId,
                peerDeviceId: recipientDeviceId ?? "primary"
            )
            return state != nil
        } catch {
            return false
        }
    }
}
