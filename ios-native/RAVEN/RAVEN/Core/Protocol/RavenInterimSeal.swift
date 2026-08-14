//
//  RavenInterimSeal.swift
//  RAVEN — Phase B LAN interim seal (matches Rust raven-core::seal).
//
//  Protocol byte 0x7F under RVNA1 magic. NOT shipping ATSAM v1/v2.
//  When FeatureFlag.ravenEnvelopeV1 is on, iOS may use this for localhost
//  smoke against raven-node, OR nest real ATSAM (proto 0x01/0x02) as opaque
//  message_ciphertext (node ACKs without decrypt). See
//  protocol/ATSAM_PRIMITIVE_MAPPING_V1.md and docs/HYBRID_TRANSPORT_V1.md.
//

import Foundation
import CryptoKit
import Security

/// Byte-compatible with `node/crates/raven-core/src/seal.rs` interim path.
public enum RavenInterimSeal {
    public static let magic = Data([0x52, 0x56, 0x4E, 0x41, 0x31, 0x00, 0x00, 0x00]) // RVNA1
    public static let stubProto: UInt8 = 0x7F
    public static let atsamProtoV1: UInt8 = 0x01
    public static let atsamProtoV2: UInt8 = 0x02
    public static let suite: UInt8 = 0x01

    private static let info = Data("raven/rvn1/interim-seal/v0".utf8)
    private static let pskDomain = Data("raven/rvn1/interim-psk".utf8)
    private static let aadDomain = Data("raven/rvn1/interim-seal/aad".utf8)

    public enum SealClass: Equatable {
        case interimStub
        case opaqueAtsam(proto: UInt8)
        case other
    }

    public static func classify(_ wire: Data) -> SealClass {
        guard wire.count >= 10, wire.prefix(8).elementsEqual(magic) else { return .other }
        switch wire[8] {
        case stubProto: return .interimStub
        case atsamProtoV1, atsamProtoV2: return .opaqueAtsam(proto: wire[8])
        default: return .other
        }
    }

    /// Demo pairwise key — SHA-256(pskDomain ‖ sort(pubA,pubB)) then HKDF-Expand(info).
    public static func derivePairwiseKey(localPub: Data, peerPub: Data) -> SymmetricKey {
        precondition(localPub.count == 32 && peerPub.count == 32)
        let (a, b) = localPub.lexicographicallyPrecedes(peerPub)
            ? (localPub, peerPub) : (peerPub, localPub)
        var ikm = Data()
        ikm.append(pskDomain)
        ikm.append(a)
        ikm.append(0x7C) // '|'
        ikm.append(b)
        let hash = Data(SHA256.hash(data: ikm))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: hash),
            info: info,
            outputByteCount: 32
        )
    }

    public static func seal(
        key: SymmetricKey,
        plaintext: Data,
        senderAddr: String,
        recipientAddr: String,
        messageId: Data
    ) throws -> Data {
        #if !DEBUG
        throw SealError.unsafeInterimDisabled
        #endif
        precondition(messageId.count == 16)
        let aad = buildAAD(sender: senderAddr, recipient: recipientAddr, messageId: messageId)
        var nonce = Data(count: 12)
        nonce.withUnsafeMutableBytes { buf in
            _ = SecRandomCopyBytes(kSecRandomDefault, 12, buf.baseAddress!)
        }
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: key,
            nonce: ChaChaPoly.Nonce(data: nonce),
            authenticating: aad
        )
        var wire = Data(capacity: 8 + 2 + 12 + sealed.ciphertext.count + sealed.tag.count)
        wire.append(magic)
        wire.append(stubProto)
        wire.append(suite)
        wire.append(Data(sealed.nonce))
        wire.append(sealed.ciphertext)
        wire.append(sealed.tag)
        return wire
    }

    public static func unseal(
        key: SymmetricKey,
        wire: Data,
        senderAddr: String,
        recipientAddr: String,
        messageId: Data
    ) throws -> Data {
        #if !DEBUG
        throw SealError.unsafeInterimDisabled
        #endif
        guard wire.count >= 8 + 2 + 12 + 16 else {
            throw SealError.truncated
        }
        guard classify(wire) == .interimStub, wire[9] == suite else {
            throw SealError.unsupported
        }
        let nonce = try ChaChaPoly.Nonce(data: wire.subdata(in: 10..<22))
        let ctAndTag = wire.subdata(in: 22..<wire.count)
        guard ctAndTag.count >= 16 else { throw SealError.truncated }
        let tag = ctAndTag.suffix(16)
        let ct = ctAndTag.prefix(ctAndTag.count - 16)
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        let aad = buildAAD(sender: senderAddr, recipient: recipientAddr, messageId: messageId)
        return try ChaChaPoly.open(box, using: key, authenticating: aad)
    }

    private static func buildAAD(sender: String, recipient: String, messageId: Data) -> Data {
        var h = SHA256()
        h.update(data: aadDomain)
        h.update(data: Data([0]))
        h.update(data: Data(sender.utf8))
        h.update(data: Data([0]))
        h.update(data: Data(recipient.utf8))
        h.update(data: Data([0]))
        h.update(data: messageId)
        return Data(h.finalize())
    }

    public enum SealError: Error {
        case unsafeInterimDisabled
        case truncated
        case unsupported
    }
}
