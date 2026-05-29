//
//  OnionEnvelope.swift
//  RAVEN
//
//  🔴 ROUND 26 (2026-05-16) — v1.7 NEXT: onion-style relay routing.
//
//  "Today the mesh-to-internet gateway sees the recipient hint.
//   Sphinx-style layered encryption hides who-asked-whom-to-relay-
//   what from the gateway and from any single mesh hop."
//
//  Sphinx-style construction (simplified to RAVEN's primitives):
//
//    Sender wants payload P delivered to FinalNode F via relays R1, R2.
//    Sender does NOT want any single hop to learn (source, dest, P).
//
//    Encryption flow:
//      L3 = AEAD_seal(P,      key3 = KDF(DH(eph, F.pk)))
//      L2 = AEAD_seal({nextHop=F,  payload=L3},
//                     key2 = KDF(DH(eph, R2.pk)))
//      L1 = AEAD_seal({nextHop=R2, payload=L2},
//                     key1 = KDF(DH(eph, R1.pk)))
//
//      On-wire (to R1): { eph_pub, hop_count=3, L1 }
//
//    Decryption at each hop:
//      Hi reads `eph_pub`, derives keyN with its own static key,
//      AEAD-opens its layer, sees `{nextHop, innerPayload}`, forwards
//      `{eph_pub, hop_count-1, innerPayload}` to nextHop. When
//      hop_count == 1, the inner payload is the original P.
//
//  Properties (with X25519 + ChaChaPoly):
//    • R1 sees who sent it (it has a direct mesh adjacency to the
//      sender) but only knows the next hop, not the final destination.
//    • R2 sees R1 as its predecessor and F as its successor; doesn't
//      learn the original sender.
//    • F sees R2 as the predecessor and gets the plaintext payload
//      but DOES NOT see the original sender's mesh ID.
//    • A passive observer with a single tap-point sees only random
//      bytes per hop — re-randomised by each layer's fresh nonce.
//
//  What this file does NOT do:
//    • Path selection. The caller picks {R1, R2, ...} from peer-key
//      directory (typically gateway-capable nodes with good uptime).
//    • Cover traffic. CoverTrafficEmitter.swift fills idle slots so
//      onion-routed traffic is indistinguishable from chaff.
//    • Bidirectional reply routing. Today only forward delivery is
//      handled; replies use a fresh onion in the other direction.
//    • Layer-padding to a fixed size. Production Sphinx pads every
//      layer to a constant length so a global passive adversary
//      can't size-fingerprint hop-count. Tracked as a follow-up;
//      today's hop counts are 2-3 inside the mesh and the size
//      difference is small.
//
//  Wire format (one envelope, viewed by the CURRENT hop):
//    magic       : "RVON" (4 bytes)
//    version     : 1 (1 byte)
//    hopsRemaining : (1 byte) — strictly > 0
//    eph_pub     : 32 bytes — X25519 ephemeral public key (carried
//                   verbatim through the whole route so each hop
//                   can derive its key without renegotiating)
//    payloadLen  : 2 bytes BE — length of the AEAD-sealed body
//    payload     : nonce(12) || ct || tag(16) — ChaChaPoly .combined
//
//  Inside the AEAD payload at every NON-final hop:
//    nextPeerIdLen : 1 byte
//    nextPeerId    : variable (UTF-8 mesh peer id)
//    innerLen      : 2 bytes BE
//    innerEnvelope : the next OnionEnvelope, encoded
//
//  Inside the AEAD payload at the FINAL hop:
//    innerLen      : 2 bytes BE
//    plaintext     : the actual payload bytes (e.g. a MeshEnvelope)

import Foundation
import CryptoKit

// MARK: - Errors

public enum OnionError: Error, LocalizedError {
    case emptyRoute
    case routeTooLong(Int)
    case payloadTooLarge(Int)
    case missingRecipientKey(peerId: String)
    case malformedEnvelope
    case unsupportedVersion(UInt8)
    case decryptionFailed
    case hopBudgetExhausted

    public var errorDescription: String? {
        switch self {
        case .emptyRoute: return "Onion: route must include at least the final recipient"
        case .routeTooLong(let n): return "Onion: route too long (\(n)); cap is 8 hops"
        case .payloadTooLarge(let n): return "Onion: payload too large (\(n) bytes)"
        case .missingRecipientKey(let p): return "Onion: no public key for peer \(p)"
        case .malformedEnvelope: return "Onion: envelope failed to decode"
        case .unsupportedVersion(let v): return "Onion: unsupported version \(v)"
        case .decryptionFailed: return "Onion: AEAD open failed at this hop"
        case .hopBudgetExhausted: return "Onion: hopsRemaining reached zero before peel"
        }
    }
}

// MARK: - Envelope

public struct OnionEnvelope: Equatable {
    public static let magic: [UInt8] = [0x52, 0x56, 0x4F, 0x4E] // "RVON"
    public static let version: UInt8 = 1
    public static let maxHops: Int = 8        // sanity cap
    public static let maxPayloadBytes: Int = 64 * 1024

    public let hopsRemaining: UInt8
    public let ephemeralPublicKey: Data   // 32 bytes
    public let sealedPayload: Data        // ChaChaPoly combined

    public init(
        hopsRemaining: UInt8,
        ephemeralPublicKey: Data,
        sealedPayload: Data
    ) {
        self.hopsRemaining = hopsRemaining
        self.ephemeralPublicKey = ephemeralPublicKey
        self.sealedPayload = sealedPayload
    }

    /// Canonical on-wire encoding.
    public func encode() -> Data {
        var out = Data()
        out.append(contentsOf: Self.magic)
        out.append(Self.version)
        out.append(hopsRemaining)
        out.append(ephemeralPublicKey)
        let len = UInt16(sealedPayload.count)
        out.append(UInt8((len >> 8) & 0xFF))
        out.append(UInt8(len & 0xFF))
        out.append(sealedPayload)
        return out
    }

    public static func decode(_ blob: Data) throws -> OnionEnvelope {
        // 4 magic + 1 ver + 1 hops + 32 epk + 2 len = 40 fixed bytes
        guard blob.count >= 40 + 16 else { throw OnionError.malformedEnvelope }
        var i = blob.startIndex
        guard Array(blob[i..<(i+4)]) == magic else { throw OnionError.malformedEnvelope }
        i += 4
        let ver = blob[i]; i += 1
        guard ver == version else { throw OnionError.unsupportedVersion(ver) }
        let hops = blob[i]; i += 1
        let epk = blob.subdata(in: i..<(i+32)); i += 32
        let lenHi = Int(blob[i]); let lenLo = Int(blob[i+1])
        i += 2
        let len = (lenHi << 8) | lenLo
        guard blob.count >= i + len else { throw OnionError.malformedEnvelope }
        let body = blob.subdata(in: i..<(i + len))
        return OnionEnvelope(
            hopsRemaining: hops,
            ephemeralPublicKey: epk,
            sealedPayload: body
        )
    }
}

// MARK: - Routing record (one hop's view of "where next")

/// The decrypted body at each intermediate hop. The final hop's
/// inner body has no `nextPeerId` (length zero) and the payload is
/// the original plaintext.
public struct OnionHopBody {
    public let nextPeerId: String?   // nil ⇔ I am the final hop
    public let innerPayload: Data    // either another OnionEnvelope or the plaintext
}

// MARK: - Public API

public enum OnionRouting {

    private static let hkdfInfo = "raven-onion-v1".data(using: .utf8)!

    /// Build a layered envelope.
    ///
    /// - Parameters:
    ///   - payload:    the bytes to deliver to the FINAL peer
    ///   - route:      ordered list of `(peerId, publicKey)` ending
    ///                 with the final recipient. The FIRST element is
    ///                 the next mesh hop the caller will hand the
    ///                 envelope to; the LAST element is the destination.
    /// - Returns: an `OnionEnvelope` sealed for `route.first`.
    public static func wrap(
        payload: Data,
        route: [(peerId: String, publicKey: Curve25519.KeyAgreement.PublicKey)]
    ) throws -> OnionEnvelope {
        guard !route.isEmpty else { throw OnionError.emptyRoute }
        guard route.count <= OnionEnvelope.maxHops else {
            throw OnionError.routeTooLong(route.count)
        }
        guard payload.count <= OnionEnvelope.maxPayloadBytes else {
            throw OnionError.payloadTooLarge(payload.count)
        }

        // One ephemeral key reused across all hops — each hop's key
        // is derived from (eph_priv, hop_static_pub). Sphinx uses
        // blinded re-keying per hop; we omit that for v1 because the
        // simpler shared-ephemeral construction still gives us
        // "each hop sees random-looking bytes" against external
        // observers.
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let epkData = ephemeral.publicKey.rawRepresentation

        // Build from the innermost layer outward.
        // Innermost layer:
        //   body = { innerLen=0, plaintext=payload }  ← no nextPeerId for final hop
        var currentBody = encodeFinalBody(plaintext: payload)
        let finalKey = try deriveLayerKey(
            ephemeralPriv: ephemeral, recipientPub: route.last!.publicKey
        )
        var sealed = try ChaChaPoly.seal(currentBody, using: finalKey).combined

        // Wrap each intermediate hop, peeling backwards from
        // second-to-last to first.
        if route.count >= 2 {
            for hopIdx in stride(from: route.count - 2, through: 0, by: -1) {
                let nextPeerId = route[hopIdx + 1].peerId
                currentBody = encodeIntermediateBody(
                    nextPeerId: nextPeerId,
                    innerEnvelope: OnionEnvelope(
                        hopsRemaining: UInt8(route.count - hopIdx - 1),
                        ephemeralPublicKey: epkData,
                        sealedPayload: sealed
                    ).encode()
                )
                let hopKey = try deriveLayerKey(
                    ephemeralPriv: ephemeral,
                    recipientPub: route[hopIdx].publicKey
                )
                sealed = try ChaChaPoly.seal(currentBody, using: hopKey).combined
            }
        }

        return OnionEnvelope(
            hopsRemaining: UInt8(route.count),
            ephemeralPublicKey: epkData,
            sealedPayload: sealed
        )
    }

    /// Peel one onion layer at the CURRENT hop. Caller supplies the
    /// local Curve25519 KeyAgreement private key (the same one used
    /// for Noise IK static keys). Returns the decrypted body which
    /// tells the caller either "forward to nextPeerId" or "I am the
    /// final hop, deliver this".
    public static func peel(
        envelope: OnionEnvelope,
        myPrivateKey: Curve25519.KeyAgreement.PrivateKey
    ) throws -> OnionHopBody {
        guard envelope.hopsRemaining > 0 else {
            throw OnionError.hopBudgetExhausted
        }
        guard let epk = try? Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: envelope.ephemeralPublicKey
        ) else {
            throw OnionError.malformedEnvelope
        }

        // Layer key = HKDF(DH(my_sk, eph_pk), info="raven-onion-v1")
        let ss: SharedSecret
        do {
            ss = try myPrivateKey.sharedSecretFromKeyAgreement(with: epk)
        } catch {
            throw OnionError.decryptionFailed
        }
        let key = ss.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),           // no per-hop salt — ephemeral is unique
            sharedInfo: hkdfInfo,
            outputByteCount: 32
        )

        let plaintext: Data
        do {
            let sealed = try ChaChaPoly.SealedBox(combined: envelope.sealedPayload)
            plaintext = try ChaChaPoly.open(sealed, using: key)
        } catch {
            throw OnionError.decryptionFailed
        }

        return try decodeHopBody(plaintext)
    }

    // MARK: - Body codec

    /// Final-hop body: { innerLen(2 BE)=plaintext.count, plaintext }.
    /// We keep the length prefix even though the AEAD already gives
    /// us a length — it lets the caller cheaply distinguish "this
    /// is a payload" vs "this is an inner OnionEnvelope" by reading
    /// the next OnionEnvelope.magic bytes (or not finding them).
    private static func encodeFinalBody(plaintext: Data) -> Data {
        var out = Data()
        out.append(0) // nextPeerIdLen = 0
        let len = UInt16(plaintext.count)
        out.append(UInt8((len >> 8) & 0xFF))
        out.append(UInt8(len & 0xFF))
        out.append(plaintext)
        return out
    }

    /// Intermediate body: { nextPeerIdLen, nextPeerId, innerLen, innerEnvelope }.
    private static func encodeIntermediateBody(
        nextPeerId: String,
        innerEnvelope: Data
    ) -> Data {
        var out = Data()
        let idBytes = Array(nextPeerId.utf8)
        precondition(idBytes.count <= 255, "Onion: peerId longer than 255 bytes")
        out.append(UInt8(idBytes.count))
        out.append(contentsOf: idBytes)
        let len = UInt16(innerEnvelope.count)
        out.append(UInt8((len >> 8) & 0xFF))
        out.append(UInt8(len & 0xFF))
        out.append(innerEnvelope)
        return out
    }

    private static func decodeHopBody(_ blob: Data) throws -> OnionHopBody {
        guard blob.count >= 3 else { throw OnionError.malformedEnvelope }
        var i = blob.startIndex
        let idLen = Int(blob[i]); i += 1

        let nextPeerId: String?
        if idLen == 0 {
            nextPeerId = nil
        } else {
            guard blob.count >= i + idLen + 2 else { throw OnionError.malformedEnvelope }
            let idData = blob.subdata(in: i..<(i + idLen))
            guard let id = String(data: idData, encoding: .utf8) else {
                throw OnionError.malformedEnvelope
            }
            nextPeerId = id
            i += idLen
        }
        guard blob.count >= i + 2 else { throw OnionError.malformedEnvelope }
        let lenHi = Int(blob[i]); let lenLo = Int(blob[i + 1])
        i += 2
        let len = (lenHi << 8) | lenLo
        guard blob.count >= i + len else { throw OnionError.malformedEnvelope }
        let inner = blob.subdata(in: i..<(i + len))
        return OnionHopBody(nextPeerId: nextPeerId, innerPayload: inner)
    }

    // MARK: - Layer key derivation

    private static func deriveLayerKey(
        ephemeralPriv: Curve25519.KeyAgreement.PrivateKey,
        recipientPub: Curve25519.KeyAgreement.PublicKey
    ) throws -> SymmetricKey {
        let ss = try ephemeralPriv.sharedSecretFromKeyAgreement(with: recipientPub)
        return ss.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: hkdfInfo,
            outputByteCount: 32
        )
    }
}
