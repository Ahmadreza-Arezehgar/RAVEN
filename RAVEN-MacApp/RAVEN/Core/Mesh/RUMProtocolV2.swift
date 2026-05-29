// RUMProtocolV2.swift
//
// RAVEN Universal Mesh — protocol v2 (Mac App Store target).
//
// BYTE-IDENTICAL sibling of:
//   • ios-native/RAVEN/RAVEN/Core/Mesh/RUMProtocolV2.swift (canonical)
//   • RAVEN-Windows/src/Mesh/RumProtocolV2.cs
//   • RAVEN-Android/RumProtocolV2.kt
//
// Any change here MUST land in all four siblings together. This file is
// intentionally a near-direct copy of the iOS one — keeping a verbatim
// duplicate is cheaper than building a shared Swift package, given the
// Mac App Store target's sandbox restrictions force a separate Xcode
// project anyway.
//
// See `docs/MESH_PROTOCOL.md §V2` for the protocol spec, including
// known-good test vectors that all four platforms MUST round-trip.

import Foundation
import CryptoKit
import CoreBluetooth

enum RUMProtocolV2 {

    // MARK: - Wire constants

    static let version: UInt8 = 0x02

    static let serviceUUID = CBUUID(string: "12345678-2345-2345-2345-123456789ABC")
    static let messageCharacteristicUUID = CBUUID(string: "12345678-2345-2345-2345-123456789ABD")
    static let capabilitiesCharacteristicUUID = CBUUID(string: "12345678-2345-2345-2345-123456789ABE")

    // MARK: - Envelope layout

    /// Fixed 60-byte header. Layout:
    /// ```
    ///   0 ..  1  version          uint8 (always 0x02)
    ///   1 ..  2  type             uint8 — see MessageType
    ///   2 ..  3  ttl              uint8 (0–maxTTL; relays decrement)
    ///   3 ..  4  flags            uint8 — see Flags
    ///   4 ..  8  timestamp        uint32 BE — unix seconds
    ///   8 .. 24  msg_id           16 bytes — UUID v4 binary
    ///  24 .. 40  sender_pid       16 bytes — SHA-256(sender_pubkey)[:16]
    ///  40 .. 56  dest_pid         16 bytes — SHA-256(dest_pubkey)[:16]
    ///                              or `broadcastPeerID`
    ///  56 .. 57  hop_count        uint8 — relays increment
    ///  57 .. 58  spray_remaining  uint8 — Spray-and-Wait copy budget
    ///  58 .. 60  payload_len      uint16 BE
    ///  60 ..  N  payload          payload_len bytes
    ///  N .. N+64 signature        Ed25519 (only if flags.signaturePresent)
    ///  N+64 .. M  pq_signature    ML-DSA-65 (3293 B, only if flags.pqHybridSig
    ///                              — reserved for C.4, not emitted today)
    /// ```
    static let headerSize = 60
    static let signatureSize = 64
    /// ML-DSA-65 signature size (FIPS 204 final). Reserved alongside
    /// `Flags.pqHybridSig`; receivers only consume these bytes when the
    /// flag is set, so existing readers ignore them and stay compatible.
    static let pqSignatureSize = 3_293
    static let maxPayloadSize = 32_768
    static let paddingTargets: [Int] = [256, 512, 1024, 2048, 4096, 8192]

    // MARK: - Type discriminator

    enum MessageType: UInt8 {
        case text       = 0
        case image      = 1
        case voice      = 2
        case file       = 3
        case location   = 4
        case system     = 5
        case ack        = 6
        case stop       = 7
        case postShare  = 8
        case ephemeral  = 9
        /// Noise IK handshake message 1 — initiator's ephemeral, encrypted
        /// static, plus an optional payload (typically the chat text for
        /// 1-RTT delivery). Receiver routes the bytes to
        /// `NoiseSessionStore.processInboundHandshake1`.
        case noiseHandshake1 = 10
        /// Noise IK handshake message 2 — responder's ephemeral and an
        /// optional reply payload. Receiver routes the bytes to
        /// `NoiseSessionStore.finishHandshakeAsInitiator`.
        case noiseHandshake2 = 11

        // MARK: Post-quantum hybrid (C.4) — reserved, gated on `pqEnabled`
        //
        // Hybrid IK pattern: classical X25519 chaining mixed with ML-KEM-768
        // KEM output. An attacker has to break BOTH lattice and DH to read
        // anything. The constants are reserved here today (May 2026) so the
        // four code-base copies of this enum stay aligned even though we
        // don't emit these message types until Apple ships ML-KEM in
        // CryptoKit. See `docs/RUM_V2_ROADMAP.md` §C.4.

        /// Hybrid handshake message 1 — initiator side.
        /// Payload layout: `[X25519 ephemeral pubkey | ML-KEM-768 encaps
        /// pubkey | legacy IK message-1 body]`.
        case pqNoiseHandshake1 = 12

        /// Hybrid handshake message 2 — responder side.
        /// Payload layout: `[X25519 ephemeral pubkey | ML-KEM-768 ciphertext
        /// against initiator's ephemeral PQ pubkey | legacy IK message-2
        /// body]`.
        case pqNoiseHandshake2 = 13

        // MARK: Mesh security hardening (Phase E) — reserved, off-by-default
        //
        // See `docs/RUM_V2_ROADMAP.md` §E for the threat model + per-phase
        // design. These constants are reserved here today (May 2026) so the
        // four code-base copies of this enum stay aligned even though we
        // don't emit these types until the matching feature flag in
        // `SecurityConstants` is flipped on per-phase.

        /// Decoy envelope emitted on idle (Phase E.1). Receivers AEAD-verify
        /// then drop silently. The payload is random bytes inside a real
        /// Noise IK ciphertext so passive observers can't distinguish it
        /// from a real frame by size, flag pattern, or signature shape.
        case cover = 14

        /// Announces a peer-ID rotation event (Phase E.4) so peers can
        /// re-derive the expected pseudonym map without waiting for the
        /// next real message. Encrypted inside the Noise transport AEAD.
        case peerIdRotate = 15
    }

    // MARK: - Flag bits

    struct Flags: OptionSet, Sendable {
        let rawValue: UInt8
        static let encrypted        = Flags(rawValue: 1 << 0)
        static let bridged          = Flags(rawValue: 1 << 1)
        static let group            = Flags(rawValue: 1 << 2)
        static let ackRequired      = Flags(rawValue: 1 << 3)
        static let needsForwarding  = Flags(rawValue: 1 << 4)
        static let signaturePresent = Flags(rawValue: 1 << 5)
        /// `payload` is encrypted with a Noise IK transport-mode cipher
        /// (`NoiseSessionStore.encrypt`) instead of the v1
        /// AES-GCM-with-static-ECDH path that the `encrypted` flag
        /// signals. Receivers route the payload to
        /// `NoiseSessionStore.decrypt`.
        static let noiseTransport   = Flags(rawValue: 1 << 6)
        /// Envelope trailer carries an ML-DSA-65 signature in addition to
        /// the Ed25519 sig signalled by `signaturePresent`. Verifiers must
        /// require BOTH to validate — falling back to "either one" defeats
        /// the hybrid guarantee. Reserved for C.4; senders don't set this
        /// until `pqEnabled` flips on.
        static let pqHybridSig      = Flags(rawValue: 1 << 7)
    }

    // MARK: - Capabilities (advertised in capabilities characteristic)

    struct Capabilities: OptionSet, Sendable {
        let rawValue: UInt32
        static let v2Protocol       = Capabilities(rawValue: 1 << 0)
        static let bleTransport     = Capabilities(rawValue: 1 << 1)
        static let wifiAware        = Capabilities(rawValue: 1 << 2)
        static let multipeer        = Capabilities(rawValue: 1 << 3)
        static let wifiDirect       = Capabilities(rawValue: 1 << 4)
        static let serverBridge     = Capabilities(rawValue: 1 << 5)
        static let canBeBridge      = Capabilities(rawValue: 1 << 6)
        /// Peer can run the hybrid X25519 + ML-KEM-768 IK handshake.
        /// Negotiation rule: prefer hybrid iff BOTH sides advertise this.
        /// Reserved for C.4 — senders only assert when `pqEnabled == true`.
        static let pqHybridKEM      = Capabilities(rawValue: 1 << 7)
        /// Peer can verify + emit `Flags.pqHybridSig` (ML-DSA-65 trailer
        /// signature). Independent of `pqHybridKEM` — a platform might
        /// land sig support first (smaller, no handshake-size penalty).
        static let pqHybridSig      = Capabilities(rawValue: 1 << 8)

        // MARK: Phase E — Mesh security hardening
        //
        // See `docs/RUM_V2_ROADMAP.md` §E. Each bit advertises that this
        // peer supports a specific hardening sub-phase. Engines must NEVER
        // assert a bit whose feature flag in `SecurityConstants` is off —
        // that'd cause peers to expect behaviour we don't actually deliver.

        /// Peer emits cover-traffic frames (`MessageType.cover`) during
        /// idle periods (Phase E.1). Informational — receivers always
        /// accept cover frames regardless of this bit.
        static let coverTraffic     = Capabilities(rawValue: 1 << 9)

        /// Peer can produce + verify the hop-by-hop HMAC chain trailer
        /// (Phase E.2). Requires v3 envelope. Two peers both with this
        /// bit negotiate envelope v3; otherwise stay on v2.
        static let hopAuth          = Capabilities(rawValue: 1 << 10)

        /// Peer binds + checks a monotonic message counter inside the
        /// Noise transport AEAD's associated data (Phase E.3). Receivers
        /// drop messages whose counter doesn't strictly increase per
        /// session. Invisible on the wire — needs the bit because the
        /// drop is a hard reject and old peers don't bind the counter
        /// into AD.
        static let monotonicCounter = Capabilities(rawValue: 1 << 11)

        /// Peer derives + recognises rotating pseudonymous peer IDs
        /// (Phase E.4). Requires v3 envelope. Two peers both with this
        /// bit negotiate v3 + rotating IDs; otherwise the connection
        /// falls back to stable IDs and accepts the metadata leak.
        static let rotatingPeerId   = Capabilities(rawValue: 1 << 12)

        // MARK: Phase F — Double Ratchet
        //
        // See `docs/RUM_V2_ROADMAP.md` §F. Peer can bootstrap a
        // Double Ratchet from the Noise IK `split()` output and route
        // transport-mode traffic through it for post-compromise
        // security.

        /// Peer supports Double Ratchet transport-mode encryption.
        /// Negotiation rule: prefer DR iff BOTH sides advertise.
        static let doubleRatchet    = Capabilities(rawValue: 1 << 13)
    }

    // MARK: - Routing constants

    static let defaultSprayCopies: UInt8 = 4
    static let defaultTTL: UInt8 = 7
    static let maxTTL: UInt8 = 15

    // MARK: - Sender feature flags (C.1.f)

    /// When true, senders that already share a Noise session with the
    /// peer skip the legacy AES-GCM-with-static-ECDH inner layer and
    /// hand a signed `MeshEnvelope` JSON straight to the Noise
    /// transport-mode AEAD. Saves ~20–30 B per envelope and avoids
    /// the constant-HKDF-salt forward-secrecy gap. Receivers gate on
    /// `flags.noiseTransport` AND the absence of `flags.encrypted`,
    /// so a flip back to `false` here won't break in-flight peers.
    /// Default `true` once C.1.e has been live across the fleet.
    static let preferNoiseNativeTransport: Bool = true

    /// Master switch for post-quantum hybrid mode (C.4).
    ///
    /// When `false` (today, May 2026): the protocol module reserves bits +
    /// message types but no client emits `pqHybrid*` capabilities or PQ
    /// handshake frames. Engines must NEVER advertise the PQ caps with
    /// this flag off — that'd cause peers to try a hybrid handshake we
    /// can't complete.
    ///
    /// Flip to `true` once `PQNoiseSession.isAvailable == true` on enough
    /// platforms (Apple's CryptoKit ML-KEM ship, Android API 35 rollout,
    /// .NET 10 release). The flip is one-way per release — downgrade rolls
    /// are handled by the negotiation table, not by toggling this off.
    static let pqEnabled: Bool = false

    // MARK: - Peer ID helpers

    static func peerID(fromPublicKey publicKey: Data) -> Data {
        let hash = SHA256.hash(data: publicKey)
        return Data(hash.prefix(16))
    }

    static let broadcastPeerID = Data(repeating: 0xFF, count: 16)

    // MARK: - Codec errors

    enum CodecError: Error, Equatable {
        case versionMismatch(UInt8)
        case truncated
        case invalidType(UInt8)
        case payloadTooLarge(Int)
        case wrongIDLength
    }

    // MARK: - Envelope

    struct Envelope: Equatable {
        var type: MessageType
        var ttl: UInt8
        var flags: Flags
        var timestamp: UInt32
        var msgID: Data
        var senderPID: Data
        var destPID: Data
        var hopCount: UInt8
        var sprayRemaining: UInt8
        var payload: Data
        var signature: Data?
    }

    // MARK: - Encode

    static func encode(_ envelope: Envelope) throws -> Data {
        guard envelope.msgID.count == 16,
              envelope.senderPID.count == 16,
              envelope.destPID.count == 16
        else { throw CodecError.wrongIDLength }
        guard envelope.payload.count <= maxPayloadSize else {
            throw CodecError.payloadTooLarge(envelope.payload.count)
        }
        if envelope.flags.contains(.signaturePresent) {
            precondition(
                envelope.signature?.count == signatureSize,
                "signaturePresent flag set but signature is missing or wrong length"
            )
        }

        var out = Data(capacity: headerSize + envelope.payload.count + signatureSize)
        out.append(version)
        out.append(envelope.type.rawValue)
        out.append(envelope.ttl)
        out.append(envelope.flags.rawValue)

        var tsBE = envelope.timestamp.bigEndian
        withUnsafeBytes(of: &tsBE) { out.append(contentsOf: $0) }

        out.append(envelope.msgID)
        out.append(envelope.senderPID)
        out.append(envelope.destPID)

        out.append(envelope.hopCount)
        out.append(envelope.sprayRemaining)

        var lenBE = UInt16(envelope.payload.count).bigEndian
        withUnsafeBytes(of: &lenBE) { out.append(contentsOf: $0) }

        out.append(envelope.payload)

        if let sig = envelope.signature, envelope.flags.contains(.signaturePresent) {
            out.append(sig)
        }

        return out
    }

    // MARK: - Decode

    static func decode(_ bytes: Data) throws -> Envelope {
        guard bytes.count >= headerSize else { throw CodecError.truncated }
        let base = bytes.startIndex

        let v = bytes[base]
        guard v == version else { throw CodecError.versionMismatch(v) }

        let typeRaw = bytes[base + 1]
        guard let type = MessageType(rawValue: typeRaw) else {
            throw CodecError.invalidType(typeRaw)
        }
        let ttl = bytes[base + 2]
        let flags = Flags(rawValue: bytes[base + 3])

        let timestamp = readUInt32BE(bytes, at: base + 4)

        let msgID    = bytes.subdata(in: (base +  8)..<(base + 24))
        let senderID = bytes.subdata(in: (base + 24)..<(base + 40))
        let destID   = bytes.subdata(in: (base + 40)..<(base + 56))

        let hopCount = bytes[base + 56]
        let sprayRem = bytes[base + 57]

        let payloadLen = Int(readUInt16BE(bytes, at: base + 58))
        let payloadStart = base + headerSize
        let payloadEnd = payloadStart + payloadLen
        guard bytes.count >= (payloadEnd - base) else { throw CodecError.truncated }
        let payload = bytes.subdata(in: payloadStart..<payloadEnd)

        var signature: Data? = nil
        if flags.contains(.signaturePresent) {
            let sigEnd = payloadEnd + signatureSize
            guard bytes.count >= (sigEnd - base) else { throw CodecError.truncated }
            signature = bytes.subdata(in: payloadEnd..<sigEnd)
        }

        return Envelope(
            type: type, ttl: ttl, flags: flags, timestamp: timestamp,
            msgID: msgID, senderPID: senderID, destPID: destID,
            hopCount: hopCount, sprayRemaining: sprayRem,
            payload: payload, signature: signature
        )
    }

    // MARK: - Padding

    static func pad(_ encoded: Data) -> Data {
        let target = paddingTargets.first(where: { $0 >= encoded.count }) ?? encoded.count
        if target == encoded.count { return encoded }
        var padded = encoded
        padded.append(Data(count: target - encoded.count))
        return padded
    }

    // MARK: - Helpers (internal)

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    private static func readUInt16BE(_ data: Data, at offset: Int) -> UInt16 {
        let b0 = UInt16(data[offset])
        let b1 = UInt16(data[offset + 1])
        return (b0 << 8) | b1
    }
}
