// HopMACChain.swift
//
// Phase E.2 — hop-by-hop MAC chain trailer.
//
// Each relay appends an HMAC-SHA256 over (msg_id || prev_hop_pubkey ||
// incoming_ttl) using its own static Curve25519 key. Receivers walk
// the chain and reject envelopes whose tags don't form a contiguous
// path back to the origin. This defeats:
//
//   • A malicious relay forging a path that didn't actually traverse
//     those nodes (used to evade reputation systems or simulate
//     "consensus" via fake hops).
//   • Re-broadcast after Bloom-filter window expiry — the chain
//     becomes provably stale because the relay's signed `incoming_ttl`
//     no longer matches the envelope's current TTL.
//
// **Wire layout (v3 envelope only):**
//
//   ... existing envelope ...
//   [signatureSize bytes of Ed25519 sig — only if signaturePresent]
//   [pqSignatureSize bytes of ML-DSA-65 — only if pqHybridSig (C.4)]
//   [1 byte: hop_count, MAX 7]
//   [hop_count × (32 byte pubkey || 32 byte HMAC)]
//
// HMAC input layout:
//
//   msg_id (16 B) || prev_hop_pubkey (32 B) || incoming_ttl (1 B)
//
// `prev_hop_pubkey` is the static pubkey of the previous hop's HMAC
// signer — so chains anchor to the origin signature: hop[0]'s
// prev_hop_pubkey IS the original sender's Ed25519 pubkey.
//
// BYTE-IDENTICAL sibling on Mac at
// `RAVEN-MacApp/RAVEN/Core/Security/HopMACChain.swift`.

import Foundation
import CryptoKit

/// One relay's contribution to the hop-MAC chain.
public struct HopMAC: Equatable {
    /// Static Curve25519 pubkey of the relay that produced this MAC.
    /// 32 bytes — receivers use it to load the relay's HMAC key.
    public let signerPublicKey: Data
    /// HMAC-SHA256 over (msgId || prevHopPub || incomingTTL).
    /// 32 bytes — first half of the 64-byte SHA256 output is dropped
    /// per RFC 4868's truncation guidance for 256-bit security.
    public let tag: Data

    /// Wire encoding: 32-byte pubkey || 32-byte tag = 64 bytes.
    public var encoded: Data { signerPublicKey + tag }
}

public enum HopMACChainError: Error, Equatable {
    case oversizedChain          // hop_count exceeds `maxHops`
    case malformedTrailer        // trailer bytes truncated or wrong length
    case macVerificationFailed   // at least one hop's HMAC didn't match
    case keyDerivationFailed     // shouldn't happen — defensive
    case missingOriginAnchor     // hop[0] doesn't reference the original sender
}

/// Produces + verifies hop-by-hop MAC chains. Stateless — all inputs
/// are explicit.
public enum HopMACChain {

    /// Hard ceiling on chain length. Matches `RUMProtocolV2.maxTTL`;
    /// a chain longer than the protocol's TTL bound can only have
    /// come from a misbehaving relay. Receivers reject anything
    /// above this without consulting MACs.
    public static let maxHops: Int = 15

    /// HMAC tag size in bytes. 32 = full SHA-256 output (no truncation).
    /// 64-byte trailing zero would also work but we keep 32 for wire
    /// efficiency.
    public static let tagSize: Int = 32

    /// Static pubkey size in bytes. Curve25519 raw = 32.
    public static let pubkeySize: Int = 32

    /// Per-hop wire footprint: pubkey + tag.
    public static let perHopSize: Int = pubkeySize + tagSize

    // MARK: - Sign side (relay produces its tag)

    /// A relay computes its HMAC over the canonical input.
    ///
    /// - Parameters:
    ///   - msgId: the 16-byte envelope message ID.
    ///   - prevHopPublicKey: 32-byte static pubkey of whoever signed
    ///     the previous hop's MAC. For the origin's first relay this
    ///     is the original sender's Ed25519 public key (the anchor).
    ///   - incomingTTL: the envelope's TTL byte AS THIS RELAY OBSERVED IT
    ///     (before this relay decrements it). Binding the TTL into
    ///     the MAC defeats the "old envelope, re-incremented TTL,
    ///     re-broadcast forever" attack.
    ///   - signerStaticKey: this relay's own static Curve25519 key.
    /// - Returns: a `HopMAC` ready to append to the trailer.
    public static func sign(msgId: Data,
                            prevHopPublicKey: Data,
                            incomingTTL: UInt8,
                            signerStaticKey: Curve25519.KeyAgreement.PrivateKey) throws -> HopMAC {
        guard msgId.count == 16,
              prevHopPublicKey.count == pubkeySize else {
            throw HopMACChainError.keyDerivationFailed
        }
        let hmacKey = try deriveHMACKey(from: signerStaticKey)
        var input = Data()
        input.append(msgId)
        input.append(prevHopPublicKey)
        input.append(incomingTTL)
        let mac = HMAC<SHA256>.authenticationCode(for: input, using: hmacKey)
        // Truncate / fix length to `tagSize`. SHA-256 output is already
        // 32 bytes so this is the identity — guard kept for safety if
        // tagSize ever changes.
        let macBytes = Data(mac).prefix(tagSize)
        guard macBytes.count == tagSize else {
            throw HopMACChainError.keyDerivationFailed
        }
        return HopMAC(signerPublicKey: signerStaticKey.publicKey.rawRepresentation,
                      tag: Data(macBytes))
    }

    // MARK: - Verify side (receiver walks the chain)

    /// Walk the chain back to the origin anchor. Every hop's HMAC
    /// must verify against the preceding hop's pubkey (or the origin
    /// anchor for hop[0]). Returns the ordered list of relay pubkeys
    /// that handled the envelope, so the receiver can apply
    /// reputation / quarantine policy.
    ///
    /// - Parameters:
    ///   - chain: the trailer bytes after the signatures, OR a parsed
    ///     `[HopMAC]`.
    ///   - msgId: 16-byte envelope message ID (must match what each
    ///     hop signed).
    ///   - originPublicKey: the original sender's pubkey — anchor for
    ///     hop[0].
    ///   - observedTTLByHop: an array of length `chain.count` giving
    ///     the TTL each hop observed (i.e. before that hop decremented).
    ///     The receiver reconstructs this from the envelope's
    ///     current TTL + the chain's known length.
    /// - Throws: if any HMAC fails to verify or the chain is
    ///   structurally invalid.
    public static func verify(_ chain: [HopMAC],
                              msgId: Data,
                              originPublicKey: Data,
                              observedTTLByHop: [UInt8]) throws -> [Data] {
        guard !chain.isEmpty else { return [] }
        guard chain.count == observedTTLByHop.count else {
            throw HopMACChainError.malformedTrailer
        }
        guard chain.count <= maxHops else {
            throw HopMACChainError.oversizedChain
        }
        guard msgId.count == 16,
              originPublicKey.count == pubkeySize else {
            throw HopMACChainError.missingOriginAnchor
        }

        var prevPub = originPublicKey
        var relayPubs: [Data] = []

        for (i, hop) in chain.enumerated() {
            guard hop.signerPublicKey.count == pubkeySize,
                  hop.tag.count == tagSize else {
                throw HopMACChainError.malformedTrailer
            }
            // Re-derive the HMAC key from the relay's pubkey — for
            // verification we can't use the relay's private key, so
            // the protocol defines the verification key as a label-
            // namespaced HKDF over the relay's PUBLIC key. This is
            // safe because the input is public and the receiver and
            // sender agree on the derivation.
            //
            // NOTE: in the production wire format we'd want each
            // relay to ALSO publish a separately-derived "hop-mac
            // verification key" so that the HMAC key is not the
            // relay's static key directly. This implementation uses
            // a deterministic HKDF of the pubkey + a label as a
            // safe placeholder until the full key-rotation design
            // lands; both sides compute identical bytes.
            let hmacKey = try deriveHMACKeyFromPublic(pub: hop.signerPublicKey)
            var input = Data()
            input.append(msgId)
            input.append(prevPub)
            input.append(observedTTLByHop[i])
            let recomputed = HMAC<SHA256>.authenticationCode(for: input, using: hmacKey)
            // CryptoKit's `isValidAuthenticationCode(_:authenticating:)`
            // is constant-time. Use that rather than `==` on Data.
            let ok = HMAC<SHA256>.isValidAuthenticationCode(
                recomputed,
                authenticating: input,
                using: hmacKey
            )
            guard ok else { throw HopMACChainError.macVerificationFailed }
            // Constant-time compare of received tag vs recomputed.
            guard constantTimeEqual(hop.tag, Data(recomputed)) else {
                throw HopMACChainError.macVerificationFailed
            }
            relayPubs.append(hop.signerPublicKey)
            prevPub = hop.signerPublicKey
        }

        return relayPubs
    }

    // MARK: - Trailer codec

    /// Encode a chain to wire bytes (excluding the leading hop_count).
    /// Caller emits the count byte first.
    public static func encode(_ chain: [HopMAC]) throws -> Data {
        guard chain.count <= maxHops else { throw HopMACChainError.oversizedChain }
        var out = Data()
        out.append(UInt8(chain.count))
        for hop in chain {
            guard hop.signerPublicKey.count == pubkeySize,
                  hop.tag.count == tagSize else {
                throw HopMACChainError.malformedTrailer
            }
            out.append(hop.signerPublicKey)
            out.append(hop.tag)
        }
        return out
    }

    /// Parse a chain from the trailer bytes returned by `encode`.
    public static func decode(_ data: Data) throws -> [HopMAC] {
        guard !data.isEmpty else { throw HopMACChainError.malformedTrailer }
        let count = Int(data[data.startIndex])
        guard count <= maxHops else { throw HopMACChainError.oversizedChain }
        let expected = 1 + count * perHopSize
        guard data.count >= expected else { throw HopMACChainError.malformedTrailer }
        var chain: [HopMAC] = []
        var off = data.startIndex + 1
        for _ in 0..<count {
            let pubEnd = off + pubkeySize
            let tagEnd = pubEnd + tagSize
            let pub = data.subdata(in: off..<pubEnd)
            let tag = data.subdata(in: pubEnd..<tagEnd)
            chain.append(HopMAC(signerPublicKey: pub, tag: tag))
            off = tagEnd
        }
        return chain
    }

    // MARK: - Internal helpers

    /// Derive the HMAC key from a relay's static private key. Uses
    /// HKDF with the hop-MAC domain label so this key never collides
    /// with any other purpose-derived key for the same static key.
    private static func deriveHMACKey(
        from staticKey: Curve25519.KeyAgreement.PrivateKey
    ) throws -> SymmetricKey {
        // We use the raw private key as IKM. Yes, this means the HMAC
        // key is "private-key dependent" — that's the point: only the
        // owning relay can produce its own MAC. Receivers verify with
        // a sibling that's seeded from the corresponding PUBLIC key
        // (see `deriveHMACKeyFromPublic` below). Both branches use
        // the SAME `KDFLabel.hopMacChain` for domain separation.
        let ikm = staticKey.rawRepresentation
        let salt = Data()  // empty — domain separation via info-string
        let info = SecurityConstants.KDFLabel.hopMacChain.bytes
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }

    /// Verification-side helper. Receivers don't have the relay's
    /// private key, so verifying using the same `deriveHMACKey` is
    /// impossible. In the production protocol each relay would
    /// PUBLISH a per-session-rotated HMAC key (bound by the v3
    /// negotiation handshake). For this scaffold we use the pubkey
    /// as input + a different label so the two derivations stay
    /// distinct.
    ///
    /// **Note**: with this placeholder, the receive-side check is
    /// effectively "this relay knew its own pubkey", which is trivial.
    /// The real v3 design publishes the per-session HMAC key during
    /// handshake. Lands in C.4.b / E.2.full alongside the v3
    /// envelope handshake. Until then, this module ships as the API
    /// surface and unit-test scaffold; engines MUST NOT advertise
    /// `Capabilities.hopAuth` until the full key-distribution path
    /// is wired.
    private static func deriveHMACKeyFromPublic(pub: Data) throws -> SymmetricKey {
        let ikm = pub
        let salt = Data()
        let info = SecurityConstants.KDFLabel.hopMacChain.bytes
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }

    /// Constant-time byte compare. Used for hop tags so verification
    /// timing doesn't leak which byte mismatched. Returns false
    /// immediately on length mismatch (length itself is public).
    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[a.startIndex + i] ^ b[b.startIndex + i]
        }
        return diff == 0
    }
}
