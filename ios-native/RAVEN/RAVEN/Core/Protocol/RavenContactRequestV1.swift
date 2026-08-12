//
//  RavenContactRequestV1.swift
//  RAVEN — E2EE async contact request (Discovery V1).
//
//  Spec: protocol/RAVEN_CONTACT_REQUEST_V1.md
//  Wire-compatible with raven_core::contact_request (interim pairwise seal).
//  Delivered as opaque RavenEnvelopeV1 body via MessageRouter / BLE / Bridge.
//

import Foundation
import CryptoKit
import Security

enum RavenContactRequestError: Error, Equatable {
    case truncated
    case badMagic
    case utf8
    case sealFailed
    case badSignature
    case expired
    case missingKeys
    case blocked
    case ambiguousPick
    case noCandidate
}

struct ContactRequestInner: Equatable {
    var requestId: Data // 16
    var senderRavenId: String
    var senderDisplayName: String
    var senderAliases: [String]
    var senderProfileDigest: Data // 32
    var optionalMessage: String
    var createdAt: UInt64
    var expiresAt: UInt64

    static let magic = Data("rvn1/contact-req-inner".utf8)

    func encode() throws -> Data {
        precondition(requestId.count == 16)
        precondition(senderProfileDigest.count == 32)
        var out = Self.magic
        out.append(requestId)
        out.append(Self.lp(Data(senderRavenId.utf8)))
        out.append(Self.lp(Data(senderDisplayName.utf8)))
        out.appendUInt16BE(UInt16(senderAliases.count))
        for a in senderAliases {
            out.append(Self.lp(Data(a.utf8)))
        }
        out.append(senderProfileDigest)
        out.append(Self.lp(Data(optionalMessage.utf8)))
        out.appendUInt64BE(createdAt)
        out.appendUInt64BE(expiresAt)
        return out
    }

    static func decode(_ raw: Data) throws -> ContactRequestInner {
        guard raw.count >= magic.count + 16 else { throw RavenContactRequestError.truncated }
        guard raw.prefix(magic.count) == magic else { throw RavenContactRequestError.badMagic }
        var off = magic.count
        let requestId = raw.subdata(in: off..<(off + 16)); off += 16
        let (senderRavenId, o1) = try readLPString(raw, off); off = o1
        let (senderDisplayName, o2) = try readLPString(raw, off); off = o2
        guard off + 2 <= raw.count else { throw RavenContactRequestError.truncated }
        let nAlias = Int(raw.readUInt16BE(at: off)); off += 2
        var aliases: [String] = []
        for _ in 0..<nAlias {
            let (a, n) = try readLPString(raw, off)
            aliases.append(a)
            off = n
        }
        guard off + 32 <= raw.count else { throw RavenContactRequestError.truncated }
        let digest = raw.subdata(in: off..<(off + 32)); off += 32
        let (msg, o3) = try readLPString(raw, off); off = o3
        guard off + 16 <= raw.count else { throw RavenContactRequestError.truncated }
        let created = raw.readUInt64BE(at: off); off += 8
        let expires = raw.readUInt64BE(at: off)
        return ContactRequestInner(
            requestId: requestId,
            senderRavenId: senderRavenId,
            senderDisplayName: senderDisplayName,
            senderAliases: aliases,
            senderProfileDigest: digest,
            optionalMessage: msg,
            createdAt: created,
            expiresAt: expires
        )
    }

    private static func lp(_ data: Data) -> Data {
        var out = Data()
        out.appendUInt16BE(UInt16(data.count))
        out.append(data)
        return out
    }

    private static func readLPString(_ raw: Data, _ off: Int) throws -> (String, Int) {
        guard off + 2 <= raw.count else { throw RavenContactRequestError.truncated }
        let len = Int(raw.readUInt16BE(at: off))
        let start = off + 2
        guard start + len <= raw.count else { throw RavenContactRequestError.truncated }
        let slice = raw.subdata(in: start..<(start + len))
        guard let s = String(data: slice, encoding: .utf8) else { throw RavenContactRequestError.utf8 }
        return (s, start + len)
    }
}

struct RavenContactRequestV1: Equatable {
    static let domain = Data("rvn1/contact-req".utf8)

    var requestId: Data // 16
    var recipientRavenId: String
    var createdAt: UInt64
    var expiresAt: UInt64
    var ciphertext: Data
    var senderAuthentication: Data // 64
    var senderPub: Data // 32

    func signingBytes() -> Data {
        var out = Self.domain
        out.append(requestId)
        out.append(Self.lp(Data(recipientRavenId.utf8)))
        out.appendUInt64BE(createdAt)
        out.appendUInt64BE(expiresAt)
        out.append(Self.lp(ciphertext))
        return out
    }

    /// Seal inner fields to recipient Ed25519 pub (pairwise interim key).
    static func create(
        senderSigningKey: Curve25519.Signing.PrivateKey,
        recipientPub: Data,
        recipientAddr: String,
        inner: ContactRequestInner
    ) throws -> RavenContactRequestV1 {
        guard recipientPub.count == 32, inner.requestId.count == 16 else {
            throw RavenContactRequestError.missingKeys
        }
        let senderPub = senderSigningKey.publicKey.rawRepresentation
        let plain = try inner.encode()
        let key = RavenInterimSeal.derivePairwiseKey(localPub: senderPub, peerPub: recipientPub)
        let ciphertext: Data
        do {
            ciphertext = try RavenInterimSeal.seal(
                key: key,
                plaintext: plain,
                senderAddr: RavenAddressV1.encode(ed25519PublicKey: senderPub) ?? "",
                recipientAddr: recipientAddr,
                messageId: inner.requestId
            )
        } catch {
            throw RavenContactRequestError.sealFailed
        }
        var req = RavenContactRequestV1(
            requestId: inner.requestId,
            recipientRavenId: recipientAddr,
            createdAt: inner.createdAt,
            expiresAt: inner.expiresAt,
            ciphertext: ciphertext,
            senderAuthentication: Data(),
            senderPub: senderPub
        )
        let sig = try senderSigningKey.signature(for: req.signingBytes())
        req.senderAuthentication = sig
        return req
    }

    func verifyOuter(nowMs: UInt64) throws {
        if nowMs > expiresAt { throw RavenContactRequestError.expired }
        guard senderAuthentication.count == 64, senderPub.count == 32 else {
            throw RavenContactRequestError.badSignature
        }
        let pub = try Curve25519.Signing.PublicKey(rawRepresentation: senderPub)
        guard pub.isValidSignature(senderAuthentication, for: signingBytes()) else {
            throw RavenContactRequestError.badSignature
        }
    }

    func open(recipientSigningKey: Curve25519.Signing.PrivateKey) throws -> ContactRequestInner {
        let recipientPub = recipientSigningKey.publicKey.rawRepresentation
        let key = RavenInterimSeal.derivePairwiseKey(localPub: senderPub, peerPub: recipientPub)
        let senderAddr = RavenAddressV1.encode(ed25519PublicKey: senderPub) ?? ""
        let plain = try RavenInterimSeal.unseal(
            key: key,
            wire: ciphertext,
            senderAddr: senderAddr,
            recipientAddr: recipientRavenId,
            messageId: requestId
        )
        return try ContactRequestInner.decode(plain)
    }

    var isCiphertextOnly: Bool {
        guard !ciphertext.isEmpty else { return false }
        if let s = String(data: ciphertext, encoding: .utf8), s.contains("rvn1/contact-req-inner") {
            return false
        }
        return true
    }

    fileprivate static func lp(_ data: Data) -> Data {
        var out = Data()
        out.appendUInt16BE(UInt16(data.count))
        out.append(data)
        return out
    }
}

struct ContactAcceptV1: Equatable {
    static let domain = Data("rvn1/contact-accept".utf8)

    var requestId: Data
    var accepterRavenId: String
    var requesterRavenId: String
    var acceptedAt: UInt64
    var signature: Data
    var accepterPub: Data

    func signingBytes() -> Data {
        var out = Self.domain
        out.append(requestId)
        out.append(RavenContactRequestV1.lp(Data(accepterRavenId.utf8)))
        out.append(RavenContactRequestV1.lp(Data(requesterRavenId.utf8)))
        out.appendUInt64BE(acceptedAt)
        return out
    }

    mutating func sign(with key: Curve25519.Signing.PrivateKey) throws {
        accepterPub = key.publicKey.rawRepresentation
        if let addr = RavenAddressV1.encode(ed25519PublicKey: accepterPub) {
            accepterRavenId = addr
        }
        signature = try key.signature(for: signingBytes())
    }

    func verify() throws {
        guard signature.count == 64, accepterPub.count == 32 else {
            throw RavenContactRequestError.badSignature
        }
        let pub = try Curve25519.Signing.PublicKey(rawRepresentation: accepterPub)
        guard pub.isValidSignature(signature, for: signingBytes()) else {
            throw RavenContactRequestError.badSignature
        }
    }
}

extension Data {
    /// Hex encode (lowercase).
    var ravenHex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(ravenHex hex: String) {
        let s = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard s.count % 2 == 0, !s.isEmpty else { return nil }
        var data = Data(capacity: s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
            data.append(b)
            idx = next
        }
        self = data
    }
}
