//
//  FriendQRPayload.swift
//  RAVEN
//
//  Round 24 (2026-05-16).
//
//  The friend-QR payload was previously just `raven://friend?user_id=UUID`.
//  Scanning it FORCED the scanner to hit `/api/users/{id}` to fetch
//  the display name, and to call `/api/users/friend-request/{id}/send`
//  to record the friendship — both of which need an internet
//  connection. That broke the user's reasonable expectation that
//  "scan a QR code to add a friend" should work offline.
//
//  v2 payload format
//  ─────────────────
//
//    raven://friend?v=2&d=<urlsafe-base64(json-blob)>
//
//  JSON blob:
//    {
//      "u": "<userId>",                      // required
//      "n": "<display name>",                // optional
//      "h": "<@username>",                   // optional
//      "p": "<base64 X25519 agreement pub>", // 32 bytes when present
//      "i": "<base64 Ed25519 identity pub>", // 32 bytes when present
//      "f": "<safety fingerprint>"           // optional, for double-checks
//    }
//
//  With `p` (agreement key) inline, the scanner can populate
//  `PeerKeyDirectory.setAgreementKey(...)` immediately — no
//  network needed. The first message to this contact will seal
//  RVNS1 even on the cold path because the directory already
//  has the verified key.
//
//  v1 back-compat: `raven://friend?user_id=UUID` is still
//  accepted by the scanner. v1 scans fall through the old
//  network-dependent code path.

import Foundation
import CryptoKit

struct FriendQRPayload: Codable {
    let userId: String
    let displayName: String?
    let username: String?
    /// Base64-encoded X25519 agreement public key (32 bytes raw).
    let agreementPubBase64: String?
    /// Base64-encoded Ed25519 identity public key (32 bytes raw).
    let identityPubBase64: String?
    let fingerprint: String?

    /// 🔴 ROUND 70 — Unix timestamp (seconds) when the QR was generated.
    /// Verifiers reject QRs older than `maxAgeSeconds`. Defaults to nil
    /// for back-compat with v2 senders pre-round-70; new generators
    /// always populate.
    let issuedAt: TimeInterval?

    /// 🔴 ROUND 70 — Ed25519 signature by the identity key over the
    /// canonical transcript:
    ///   "qr-v2:{userId}:{agreementPubBase64}:{identityPubBase64}:{issuedAt}"
    /// Verifier rebuilds and checks against `identityPubBase64`.
    /// Without this, anyone who photographed an older QR could replay
    /// it indefinitely AND pin a stale (or attacker-substituted)
    /// agreement key, since the round-24 v2 format had no integrity
    /// binding at all.
    let signatureB64: String?

    enum CodingKeys: String, CodingKey {
        case userId = "u"
        case displayName = "n"
        case username = "h"
        case agreementPubBase64 = "p"
        case identityPubBase64 = "i"
        case fingerprint = "f"
        case issuedAt = "t"
        case signatureB64 = "s"
    }

    /// QR max-age. Photographs of QRs lose any abuse value after this
    /// window. 24h is the sweet spot: longer than a normal "scan-now"
    /// session (event, meet-up) but short enough that a leaked
    /// screenshot from yesterday is dead by today.
    static let maxAgeSeconds: TimeInterval = 24 * 60 * 60

    /// Canonical signed transcript. Stable across rounds — append-only.
    static func canonicalTranscript(
        userId: String,
        agreementPubBase64: String?,
        identityPubBase64: String?,
        issuedAt: TimeInterval?
    ) -> Data {
        let ts = issuedAt.map { String(Int($0)) } ?? ""
        let s = "qr-v2:\(userId):\(agreementPubBase64 ?? ""):\(identityPubBase64 ?? ""):\(ts)"
        return Data(s.utf8)
    }

    /// Build a v2 deep-link string from a payload. Caller is
    /// responsible for setting `issuedAt` + `signatureB64` before
    /// calling — see `MyQRCodeView.generateQRCode` (Round 70).
    func toQRString() -> String? {
        guard let json = try? JSONEncoder().encode(self) else { return nil }
        let b64 = json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "raven://friend?v=2&d=\(b64)"
    }

    /// Parse a scanned QR string. Accepts v1 (`raven://friend?user_id=`)
    /// AND v2 (`raven://friend?v=2&d=...`). Returns nil if it isn't a
    /// friend payload at all.
    ///
    /// 🔴 ROUND 70 — does NOT verify the signature here (no CryptoKit
    /// import in this file). Use `parseAndVerify` if you need the
    /// integrity + freshness check. Both `ScanQRCodeView` and the
    /// mesh receiver are updated to call `parseAndVerify`.
    static func parse(_ code: String) -> FriendQRPayload? {
        // v1 fall-through — payload only carries userId.
        if code.hasPrefix("raven://friend?user_id=") {
            let userId = String(code.dropFirst("raven://friend?user_id=".count))
            guard !userId.isEmpty else { return nil }
            return FriendQRPayload(
                userId: userId,
                displayName: nil,
                username: nil,
                agreementPubBase64: nil,
                identityPubBase64: nil,
                fingerprint: nil,
                issuedAt: nil,
                signatureB64: nil
            )
        }
        // v2 — base64-encoded JSON blob.
        guard let url = URL(string: code),
              url.scheme == "raven",
              url.host == "friend" else {
            return nil
        }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard comps?.queryItems?.first(where: { $0.name == "v" })?.value == "2",
              let dataParam = comps?.queryItems?.first(where: { $0.name == "d" })?.value
        else {
            return nil
        }
        // Decode URL-safe base64 → JSON.
        var b64 = dataParam
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        guard let raw = Data(base64Encoded: b64),
              let payload = try? JSONDecoder().decode(FriendQRPayload.self, from: raw),
              !payload.userId.isEmpty
        else {
            return nil
        }
        return payload
    }

    /// 🔴 ROUND 70 — verifying parser. Rejects:
    ///   • v1 payloads (no integrity, no freshness)
    ///   • v2 payloads missing `issuedAt` or `signatureB64`
    ///   • v2 payloads older than `maxAgeSeconds`
    ///   • v2 payloads whose signature doesn't verify against the
    ///     embedded identityPubBase64
    /// Returns the validated payload on success, nil on any failure.
    static func parseAndVerify(_ code: String) -> FriendQRPayload? {
        guard let payload = parse(code) else { return nil }
        guard let sigB64 = payload.signatureB64,
              let issuedAt = payload.issuedAt,
              let identityB64 = payload.identityPubBase64,
              let sig = Data(base64Encoded: sigB64),
              let identityRaw = Data(base64Encoded: identityB64)
        else {
            #if DEBUG
            print("🟡 [FriendQR] rejected — missing required signature/timestamp/identity fields (post-round-70 QRs only)")
            #endif
            return nil
        }
        // Freshness check.
        let now = Date().timeIntervalSince1970
        if abs(now - issuedAt) > Self.maxAgeSeconds {
            #if DEBUG
            print("🟡 [FriendQR] rejected — QR older than \(Int(Self.maxAgeSeconds))s (age=\(Int(now - issuedAt))s)")
            #endif
            return nil
        }
        // Signature check.
        do {
            let pubKey = try Curve25519.Signing.PublicKey(rawRepresentation: identityRaw)
            let transcript = canonicalTranscript(
                userId: payload.userId,
                agreementPubBase64: payload.agreementPubBase64,
                identityPubBase64: payload.identityPubBase64,
                issuedAt: payload.issuedAt
            )
            guard pubKey.isValidSignature(sig, for: transcript) else {
                #if DEBUG
                print("🟡 [FriendQR] rejected — Ed25519 signature INVALID")
                #endif
                return nil
            }

            // 🔴 SERVERLESS IDENTITY BINDING (SEC-CRIT). A valid signature only
            // proves the QR's maker controls `identityPubBase64` — NOT that they
            // are `userId`. In the serverless model a user's id IS the
            // fingerprint of their identity key, so REQUIRE
            // userId == deriveFingerprint(identityKey). Without this an attacker
            // self-signs a QR carrying VICTIM's userId + their OWN keys (a valid
            // self-signature over their own key) and the scanner would pin the
            // attacker's keys as a trusted device under the victim's userId —
            // full MITM of every future DM addressed to the victim.
            let derivedId = DeviceIdentityService.deriveFingerprint(from: identityRaw)
            guard payload.userId == derivedId else {
                #if DEBUG
                print("🟡 [FriendQR] rejected — userId does not match identity-key fingerprint (claimed=\(payload.userId.prefix(8)) derived=\(derivedId.prefix(8))). Possible impersonation QR.")
                #endif
                return nil
            }
        } catch {
            #if DEBUG
            print("🟡 [FriendQR] rejected — could not load identity key: \(error.localizedDescription)")
            #endif
            return nil
        }
        return payload
    }
}
