//
//  MeshGatewayEnvelope.swift
//  RAVEN
//
//  Wire format for the Mesh-to-Internet Gateway feature (v1.6 MVP).
//
//  Two envelope types travel between an offline node and a gateway
//  over BLE GATT:
//
//    1. GatewayBeacon — "I have internet, I can relay for you."
//       Broadcast periodically by every node that has internet AND
//       has opted into Helper Mode. Carries a `score` so neighbours
//       can pick the best gateway when several overlap.
//
//    2. GatewayRelayRequest — "Please push this opaque envelope to
//       the internet on my behalf." The gateway treats the inner
//       payload as opaque ciphertext, stamps it with a server delivery
//       ticket, and POSTs it to /api/gateway/relay. Recipient lookup
//       happens on the server, so the gateway never learns who the
//       message is for at the application level.
//
//  Cryptographic blindness invariant
//  ─────────────────────────────────
//  The gateway only sees:
//
//      • a routing hint (recipient_user_id or recipient_pubkey hash)
//      • an opaque ciphertext blob (already E2EE-sealed by the
//        original sender via Signal X3DH + Double Ratchet)
//      • a per-relay nonce
//
//  It does NOT see:
//      • the plaintext message
//      • who the original sender is (when Sealed Sender ships in v1.6
//        the sender is encrypted to the recipient's identity key too)
//      • any group membership the message might belong to
//
//  This is what makes "I am the gateway for my neighbour" plausibly
//  deniable — the gateway is acting as a router for ciphertext it
//  cannot read, identical to how an ISP forwards TLS bytes.
//

import Foundation
import CryptoKit

// MARK: - Beacon (gateway → neighbours)

/// Broadcast over BLE by a node that's offering itself as a gateway.
/// Neighbours pick the highest-score beacon they see and route their
/// outbound traffic to that gateway's BLE endpoint.
///
/// 🔴 ROUND 26 (2026-05-16) — hacker-audit MESH-MED-7.
///
/// Previously beacons rode the wire unsigned: any attacker could
/// broadcast `{gw: <my-deviceId>, score: 999}` and steal the
/// "preferred gateway" slot in every neighbour's selection (sinkhole-
/// at-the-gateway-tier). They could also forge `gatewayAgreementPub`
/// so relay-requests would be wrap-encrypted to the attacker's key.
///
/// Fix: every outbound beacon is now Ed25519-signed by the gateway's
/// device identity key. Receivers verify the signature against the
/// signer's pubkey AND pin `(gatewayDeviceId → signerPublicKey)` on
/// first sight (TOFU). Subsequent beacons claiming the same
/// gatewayDeviceId with a different signer key are rejected as
/// impersonation. v1.6 receivers see the new fields as unknown JSON
/// keys and ignore them, so the wire is back-compatible.
struct GatewayBeacon: Codable {
    let kind: String
    let gatewayDeviceId: String
    let score: Double
    let advertisedAt: TimeInterval
    /// Public X25519 key of the gateway. Neighbours can wrap their
    /// outbound relay request to this key so even other passive BLE
    /// listeners can't see the routing hint.
    let gatewayAgreementPub: Data

    /// Round 26 — MED-7. Ed25519 signature over the canonical
    /// signing bytes (see `signingData()`). Optional for v1.6
    /// cross-compat; v1.7 senders ALWAYS set it and v1.7 receivers
    /// REJECT beacons without a valid signature once they've seen
    /// at least one signed beacon for the same gatewayDeviceId.
    var signature: Data?
    /// Round 26 — MED-7. Ed25519 public key the receiver verifies
    /// `signature` against. The receiver pins this on first sight
    /// per `gatewayDeviceId`; later beacons must use the same key.
    var signerPublicKey: Data?

    init(
        gatewayDeviceId: String,
        score: Double,
        gatewayAgreementPub: Data,
        advertisedAt: TimeInterval = Date().timeIntervalSince1970,
        signature: Data? = nil,
        signerPublicKey: Data? = nil
    ) {
        self.kind = "raven.gateway.beacon.v1"
        self.gatewayDeviceId = gatewayDeviceId
        self.score = score
        self.advertisedAt = advertisedAt
        self.gatewayAgreementPub = gatewayAgreementPub
        self.signature = signature
        self.signerPublicKey = signerPublicKey
    }

    enum CodingKeys: String, CodingKey {
        case kind = "k"
        case gatewayDeviceId = "g"
        case score = "s"
        case advertisedAt = "a"
        case gatewayAgreementPub = "p"
        // Round 26 — MED-7.
        case signature = "sig"
        case signerPublicKey = "spk"
    }

    /// Canonical signing bytes. ORDER matters — must be stable across
    /// sender/receiver to verify. We don't use Swift's `Codable` here
    /// because JSON key ordering isn't guaranteed; a byte-level
    /// concatenation is deterministic.
    ///
    /// Layout:  kind || 0x00 || gatewayDeviceId || 0x00 ||
    ///          big-endian(score-as-bits) || big-endian(advertisedAt-as-bits) ||
    ///          gatewayAgreementPub
    func signingData() -> Data {
        var out = Data()
        out.append(Data(kind.utf8))
        out.append(0x00)
        out.append(Data(gatewayDeviceId.utf8))
        out.append(0x00)
        var scoreBits = score.bitPattern.bigEndian
        withUnsafeBytes(of: &scoreBits) { out.append(contentsOf: $0) }
        var tsBits = advertisedAt.bitPattern.bigEndian
        withUnsafeBytes(of: &tsBits) { out.append(contentsOf: $0) }
        out.append(gatewayAgreementPub)
        return out
    }

    /// Sign in place with the device's Ed25519 identity. Caller is
    /// the gateway about to broadcast. After this call, `signature`
    /// and `signerPublicKey` are populated.
    mutating func sign() {
        let toSign = signingData()
        guard let sig = DeviceIdentityService.shared.sign(toSign) else { return }
        self.signature = sig
        if let pubB64 = DeviceIdentityService.shared.publicKeyBase64,
           let pubData = Data(base64Encoded: pubB64) {
            self.signerPublicKey = pubData
        }
    }

    /// Verify the signature. Returns false for missing-signature,
    /// wrong-key, or tampered fields. Callers should additionally
    /// check that `signerPublicKey` matches the pinned key for
    /// `gatewayDeviceId` (TOFU on first sight; mismatch later = reject).
    func verifySignature() -> Bool {
        guard let sig = signature,
              let pub = signerPublicKey else { return false }
        return DeviceIdentityService.shared.verify(
            signature: sig,
            data: signingData(),
            publicKey: pub
        )
    }
}

// MARK: - Outbound relay request (offline node → gateway → server)

/// Sent over BLE from an offline node to a gateway. The gateway's
/// only job is to push `payload` to /api/gateway/relay using its own
/// authenticated session. Payload is end-to-end ciphertext from the
/// original sender; the gateway never learns its plaintext.
struct GatewayRelayRequest: Codable {
    let kind: String
    /// Recipient hint — the gateway needs *something* to tell the
    /// server who to deliver to. Today this is the recipient's user
    /// ID hash; once Sealed Sender ships, this will be the server-
    /// issued blinded delivery token instead.
    let recipientHint: String
    /// Opaque ciphertext (E2EE-sealed by the original sender).
    let payload: Data
    /// Per-request nonce for dedup at the gateway and server.
    let nonce: Data
    /// Time the offline node generated this request. Limits replay
    /// windows when paired with the gateway's seen-nonce cache.
    let createdAt: TimeInterval

    init(
        recipientHint: String,
        payload: Data,
        nonce: Data = GatewayRelayRequest.randomNonce(),
        createdAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.kind = "raven.gateway.relay.v1"
        self.recipientHint = recipientHint
        self.payload = payload
        self.nonce = nonce
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case kind = "k"
        case recipientHint = "r"
        case payload = "p"
        case nonce = "n"
        case createdAt = "t"
    }

    static func randomNonce() -> Data {
        var b = [UInt8](repeating: 0, count: 16)
        let r = SecRandomCopyBytes(kSecRandomDefault, 16, &b)
        precondition(r == errSecSuccess)
        return Data(b)
    }
}

// MARK: - Inbound delivery (server → gateway → offline node)

/// Server-to-gateway envelope: the gateway pulls these from
/// /api/gateway/pending and re-broadcasts them over BLE so the
/// offline recipient can pick them up. Same opaque-payload contract.
struct GatewayInboundEnvelope: Codable {
    let kind: String
    let recipientHint: String
    let payload: Data
    let serverNonce: Data
    let queuedAt: TimeInterval

    init(
        recipientHint: String,
        payload: Data,
        serverNonce: Data,
        queuedAt: TimeInterval
    ) {
        self.kind = "raven.gateway.inbound.v1"
        self.recipientHint = recipientHint
        self.payload = payload
        self.serverNonce = serverNonce
        self.queuedAt = queuedAt
    }

    enum CodingKeys: String, CodingKey {
        case kind = "k"
        case recipientHint = "r"
        case payload = "p"
        case serverNonce = "n"
        case queuedAt = "t"
    }
}

// MARK: - Decoder helper

enum GatewayWire {
    /// Try to decode any of the gateway envelope types from a raw
    /// BLE payload. Returns nil if the payload isn't a gateway frame.
    static func decode(_ data: Data) -> Decoded? {
        let dec = JSONDecoder()
        // Peek at the kind discriminator first — cheap to fail.
        struct KindOnly: Decodable { let k: String }
        guard let kindOnly = try? dec.decode(KindOnly.self, from: data) else { return nil }
        switch kindOnly.k {
        case "raven.gateway.beacon.v1":
            return (try? dec.decode(GatewayBeacon.self, from: data)).map(Decoded.beacon)
        case "raven.gateway.relay.v1":
            return (try? dec.decode(GatewayRelayRequest.self, from: data)).map(Decoded.relayRequest)
        case "raven.gateway.inbound.v1":
            return (try? dec.decode(GatewayInboundEnvelope.self, from: data)).map(Decoded.inbound)
        default:
            return nil
        }
    }

    enum Decoded {
        case beacon(GatewayBeacon)
        case relayRequest(GatewayRelayRequest)
        case inbound(GatewayInboundEnvelope)
    }
}
