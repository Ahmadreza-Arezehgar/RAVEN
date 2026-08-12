//
//  RavenEnvelopeSenderResolver.swift
//  RAVEN — map RavenEnvelopeV1 auth → senderUserId for ChatWire unseal.
//
//  Envelope carries Ed25519 signature only (no embedded pubkey). Destination
//  resolves sender by verifying against known identity pubs:
//    1) explicit hint / LAN peerPubHex
//    2) PeerKeyDirectory pinned identity keys (reverse lookup)
//    3) serverless fingerprint(identityKey) when verification succeeds
//  BridgeSubsystem stays key-free; this runs at endpoint ingest only.
//

import Foundation
import CryptoKit

public enum RavenEnvelopeSenderResolver {

    public struct Resolution: Equatable, Sendable {
        public let senderUserId: String
        public let identityPub: Data
        public let via: String
    }

    /// Pure: verify envelope against a candidate Ed25519 public key.
    public static func verify(env: RavenEnvelopeV1, identityPub: Data) -> Bool {
        guard identityPub.count == 32 else { return false }
        guard let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: identityPub) else {
            return false
        }
        return env.verify(publicKey: pk)
    }

    /// Resolve senderUserId for destination unseal/display.
    public static func resolve(
        env: RavenEnvelopeV1,
        candidatePubs: [(userId: String, pub: Data, via: String)]
    ) -> Resolution? {
        for c in candidatePubs {
            if verify(env: env, identityPub: c.pub) {
                let uid = c.userId.isEmpty
                    ? DeviceIdentityService.deriveFingerprint(from: c.pub)
                    : c.userId
                return Resolution(senderUserId: uid, identityPub: c.pub, via: c.via)
            }
        }
        return nil
    }

    /// Hex decode 64-char pubkey.
    public static func pubFromHex(_ hex: String) -> Data? {
        let h = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard h.count == 64, h.allSatisfy(\.isHexDigit) else { return nil }
        var out = Data(capacity: 32)
        var i = h.startIndex
        while i < h.endIndex {
            let j = h.index(i, offsetBy: 2)
            guard let b = UInt8(h[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }
}

// identityCandidates lives on PeerKeyDirectory actor (see PeerKeyDirectory.swift).
