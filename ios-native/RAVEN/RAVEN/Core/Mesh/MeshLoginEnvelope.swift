//
//  MeshLoginEnvelope.swift
//  RAVEN
//
//  Bluetooth-mediated desktop-login envelope.
//
//  Why this exists
//  ────────────────
//  The default desktop QR-login flow requires the internet:
//
//      iPhone ── /api/auth/qr-login/scan ──→ server ←── /poll ── macOS
//
//  When neither the phone nor the desktop has a usable network path,
//  the same QR scan can be approved over BLE instead. The phone
//  broadcasts a signed `MeshLoginApprovalEnvelope` on the mesh; the
//  desktop, while its QR sheet is open, listens for envelopes that
//  match the session id it's currently advertising and completes a
//  *mesh-only* local session.
//
//  Honest scope notes
//  ──────────────────
//  • A BLE-only login does NOT issue a real server JWT — the server
//    is unreachable by definition. The desktop ends up with a
//    "bluetooth-limited" session: chat over the mesh works, but no
//    server-bound action (post create, friend request, profile
//    update) succeeds until the next time the desktop is online and
//    completes a deferred `/qr-login/approve` POST that the phone
//    persisted earlier. That deferred path is **Phase 2** — see
//    `docs/BLUETOOTH-LOGIN.md`. This file is the wire-format and
//    signing contract; the deferred upgrade is not yet wired.
//  • The signature is plain Ed25519 over the byte sequence
//    `"raven.login.approval.v1|" + sessionId + "|" + userId + "|" + ts`.
//    The desktop validates it against the phone's identity public key
//    encoded in the QR's `ble.peer` block (so the desktop never needs
//    to ask a server "who is this iPhone?").
//

import Foundation

/// Wire format broadcast over BLE when the phone approves a desktop
/// login through the BLE fallback path.
struct MeshLoginApprovalEnvelope: Codable {
    /// Discriminator — distinguishes from chat / gateway / post frames.
    /// Always `"raven.login.approval.v1"`. Constant string field so
    /// the BLE engine's `jsonDict["k"]` dispatch lights up immediately.
    let kind: String
    /// The session id the desktop advertised in its QR (`sid`).
    let sessionId: String
    /// The phone user that approved this login. The desktop uses
    /// this to seed its local "currentUser" — username + display name
    /// follow on first server reach.
    let userId: String
    /// Phone's display username (best-effort — used only for the
    /// desktop's UI label until server reach restores full profile).
    let username: String
    /// Phone's identity Ed25519 public key, base64 raw 32-byte.
    /// Desktop verifies `signature` against this. Repeating the key
    /// here (it's also in the QR's `ble.peer` block) lets the desktop
    /// validate without holding state across BLE disconnects.
    let phonePublicKey: String
    /// Unix seconds the envelope was generated. Desktop rejects
    /// anything older than 5 minutes to bound replay.
    let timestamp: Int
    /// Ed25519 signature of `signedPayload(for:)` by phone's identity
    /// private key, base64 raw 64-byte.
    let signature: String

    enum CodingKeys: String, CodingKey {
        case kind = "k"
        case sessionId = "s"
        case userId = "u"
        case username = "n"
        case phonePublicKey = "p"
        case timestamp = "t"
        case signature = "g"
    }

    /// The exact byte sequence the phone signs, the desktop verifies.
    /// Pinned to `raven.login.approval.v1` to prevent cross-protocol
    /// signature reuse.
    static func signedPayload(sessionId: String, userId: String, timestamp: Int) -> Data {
        Data("raven.login.approval.v1|\(sessionId)|\(userId)|\(timestamp)".utf8)
    }
}

/// Optional BLE-fallback block embedded in the desktop's QR payload.
/// Lets the phone discover + verify the desktop without server help
/// when the internet path can't be used.
struct DesktopLoginBLEBlock: Codable, Equatable {
    /// Desktop's identity Ed25519 public key, raw 32-byte base64.
    /// Lets the phone trust which desktop the approval is going to.
    let peer: String
    /// Service UUID the desktop is listening on (today: the standard
    /// RAVEN mesh service UUID; carried in the QR for forward-compat
    /// with future per-app UUIDs).
    let svc: String
    /// **Phase 2** — desktop's X25519 (key-agreement) public key, raw
    /// 32-byte base64. Used by the phone for ECDH when it forwards
    /// the server-issued JWT to the desktop via `MeshLoginTokenEnvelope`.
    /// Optional for forward-compat: a desktop that ships only the
    /// Phase-1 fields stays compatible (phone falls back to mesh-
    /// only login).
    let agreement: String?

    enum CodingKeys: String, CodingKey {
        case peer, svc, agreement
    }
}

// MARK: - Phase 2: phone-bridged token forward

/// Wire format the phone broadcasts after a successful internet-path
/// `/scan` + `/approve`, encrypted with the desktop's published
/// X25519 pubkey, so the desktop can complete a **full server-grade
/// login** even when its own connection to the server is broken.
///
/// Crypto contract
/// ───────────────
///   1. Phone generates an ephemeral X25519 keypair `(eph_priv, eph_pub)`.
///   2. `shared = X25519(eph_priv, desktop.agreement_pub)`.
///   3. `key = HKDF<SHA256>(shared, info="raven.login.token.v1",
///                           salt="", outputLength=32)`.
///   4. `ct = AES-GCM(key, nonce, plaintext)` where `plaintext` is
///      the JSON of `MeshLoginTokenPayload`.
///
/// The phone never reuses the ephemeral key (one-shot). Forward
/// secrecy: the desktop's long-term key would have to leak to
/// recover this session's plaintext.
struct MeshLoginTokenEnvelope: Codable {
    /// Discriminator — `"raven.login.token.v1"`. The desktop's BLE
    /// engine peeks this string before its chat-decryption pipeline.
    let kind: String
    /// Session id the phone bridged for. Desktop only acts on
    /// envelopes whose `sid` matches the QR it's currently showing.
    let sessionId: String
    /// Phone's ephemeral X25519 public key, raw 32-byte base64.
    let ephemeralPub: String
    /// AES-GCM nonce, 12-byte base64.
    let nonce: String
    /// AES-GCM ciphertext + 16-byte tag, base64. Plaintext is JSON
    /// of `MeshLoginTokenPayload`.
    let ciphertext: String
    /// Unix seconds. Replay-bound at 5 min same as the approval envelope.
    let timestamp: Int

    enum CodingKeys: String, CodingKey {
        case kind = "k"
        case sessionId = "s"
        case ephemeralPub = "e"
        case nonce = "n"
        case ciphertext = "c"
        case timestamp = "t"
    }
}

/// The plaintext payload encrypted inside `MeshLoginTokenEnvelope.ciphertext`.
/// Identical shape to the `/api/auth/qr-login/poll` server response so
/// the desktop can hand it straight to the existing `completeQrLogin`
/// path with zero extra plumbing.
struct MeshLoginTokenPayload: Codable {
    let token: String
    let refreshToken: String?
    let userId: String
    let username: String

    enum CodingKeys: String, CodingKey {
        case token, refreshToken, userId, username
    }
}
