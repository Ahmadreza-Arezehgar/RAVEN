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
    case wrongRecipient
    case idMismatch
    case notFound
    case petnameRequired
    case inboxFull
    case senderCap
    case rateLimited
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

    fileprivate static func readLPStringPublic(_ raw: Data, _ off: Int) throws -> (String, Int) {
        try readLPString(raw, off)
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

    static let wireMagic = Data("rvn1/contact-req-wire".utf8)

    /// Full outer object for MessageRouter body (ciphertext remains opaque to Bridge).
    func encodeWire() -> Data {
        var out = Self.wireMagic
        out.append(requestId)
        out.append(Self.lp(Data(recipientRavenId.utf8)))
        out.appendUInt64BE(createdAt)
        out.appendUInt64BE(expiresAt)
        out.append(Self.lp(ciphertext))
        out.append(senderAuthentication)
        out.append(senderPub)
        return out
    }

    static func decodeWire(_ raw: Data) throws -> RavenContactRequestV1 {
        guard raw.count >= wireMagic.count + 16 + 64 + 32 else {
            throw RavenContactRequestError.truncated
        }
        guard raw.prefix(wireMagic.count) == wireMagic else {
            throw RavenContactRequestError.badMagic
        }
        var off = wireMagic.count
        let requestId = raw.subdata(in: off..<(off + 16)); off += 16
        let (recipient, o1) = try ContactRequestInner.readLPStringPublic(raw, off); off = o1
        guard off + 16 <= raw.count else { throw RavenContactRequestError.truncated }
        let created = raw.readUInt64BE(at: off); off += 8
        let expires = raw.readUInt64BE(at: off); off += 8
        guard off + 2 <= raw.count else { throw RavenContactRequestError.truncated }
        let ctLen = Int(raw.readUInt16BE(at: off)); off += 2
        guard off + ctLen + 64 + 32 <= raw.count else { throw RavenContactRequestError.truncated }
        let ciphertext = raw.subdata(in: off..<(off + ctLen)); off += ctLen
        let auth = raw.subdata(in: off..<(off + 64)); off += 64
        let pub = raw.subdata(in: off..<(off + 32))
        return RavenContactRequestV1(
            requestId: requestId,
            recipientRavenId: recipient,
            createdAt: created,
            expiresAt: expires,
            ciphertext: ciphertext,
            senderAuthentication: auth,
            senderPub: pub
        )
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

    static let wireMagic = Data("rvn1/contact-accept-wire".utf8)

    func encodeWire() -> Data {
        var out = Self.wireMagic
        out.append(requestId)
        out.append(RavenContactRequestV1.lp(Data(accepterRavenId.utf8)))
        out.append(RavenContactRequestV1.lp(Data(requesterRavenId.utf8)))
        out.appendUInt64BE(acceptedAt)
        out.append(signature)
        out.append(accepterPub)
        return out
    }

    static func decodeWire(_ raw: Data) throws -> ContactAcceptV1 {
        guard raw.count >= wireMagic.count + 16 + 64 + 32 else {
            throw RavenContactRequestError.truncated
        }
        guard raw.prefix(wireMagic.count) == wireMagic else {
            throw RavenContactRequestError.badMagic
        }
        var off = wireMagic.count
        let requestId = raw.subdata(in: off..<(off + 16)); off += 16
        let (accepter, o1) = try ContactRequestInner.readLPStringPublic(raw, off); off = o1
        let (requester, o2) = try ContactRequestInner.readLPStringPublic(raw, off); off = o2
        guard off + 8 + 64 + 32 <= raw.count else { throw RavenContactRequestError.truncated }
        let acceptedAt = raw.readUInt64BE(at: off); off += 8
        let signature = raw.subdata(in: off..<(off + 64)); off += 64
        let accepterPub = raw.subdata(in: off..<(off + 32))
        return ContactAcceptV1(
            requestId: requestId,
            accepterRavenId: accepter,
            requesterRavenId: requester,
            acceptedAt: acceptedAt,
            signature: signature,
            accepterPub: accepterPub
        )
    }
}

// MARK: - Inbox (Accept / Decline / Block)

struct PendingContactRequest: Equatable, Identifiable {
    var id: String { outer.requestId.ravenHex }
    var outer: RavenContactRequestV1
    var inner: ContactRequestInner
    var receivedAt: UInt64
}

struct ContactBinding: Equatable {
    var ravenId: String
    var pubHex: String
    var petname: String
    var verificationState: VerificationState
}

struct ContactAcceptOutcome: Equatable {
    var accept: ContactAcceptV1
    var binding: ContactBinding
}

/// Recipient-side inbox. Opens sealed requests locally; Bridge never sees plaintext.
struct ContactRequestInbox: Equatable {
    var pending: [PendingContactRequest] = []

    /// Anti-spam caps (mirror raven_core::contact_request).
    static let maxPending = 64
    static let maxPerSender = 3
    static let senderWindowMs: UInt64 = 3_600_000
    static let maxPerSenderWindow = 5

    mutating func ingest(
        outer: RavenContactRequestV1,
        recipientSigningKey: Curve25519.Signing.PrivateKey,
        recipientAddr: String,
        nowMs: UInt64
    ) throws -> ContactRequestInner {
        try outer.verifyOuter(nowMs: nowMs)
        guard outer.recipientRavenId == recipientAddr else {
            throw RavenContactRequestError.wrongRecipient
        }
        let inner = try outer.open(recipientSigningKey: recipientSigningKey)
        guard inner.requestId == outer.requestId else {
            throw RavenContactRequestError.idMismatch
        }
        if pending.contains(where: { $0.outer.requestId == outer.requestId }) {
            return inner
        }
        if pending.count >= Self.maxPending {
            throw RavenContactRequestError.inboxFull
        }
        let fromSender = pending.filter { $0.outer.senderPub == outer.senderPub }
        if fromSender.count >= Self.maxPerSender {
            throw RavenContactRequestError.senderCap
        }
        let inWindow = fromSender.filter {
            nowMs &- $0.receivedAt <= Self.senderWindowMs
        }.count
        if inWindow >= Self.maxPerSenderWindow {
            throw RavenContactRequestError.rateLimited
        }
        pending.append(PendingContactRequest(outer: outer, inner: inner, receivedAt: nowMs))
        return inner
    }

    private mutating func take(_ requestId: Data) throws -> PendingContactRequest {
        guard let i = pending.firstIndex(where: { $0.outer.requestId == requestId }) else {
            throw RavenContactRequestError.notFound
        }
        return pending.remove(at: i)
    }

    mutating func accept(
        requestId: Data,
        accepterKey: Curve25519.Signing.PrivateKey,
        petname: String,
        nowMs: UInt64
    ) throws -> ContactAcceptOutcome {
        let item = try take(requestId)
        let pet = petname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pet.isEmpty else { throw RavenContactRequestError.petnameRequired }
        var accept = ContactAcceptV1(
            requestId: item.outer.requestId,
            accepterRavenId: "",
            requesterRavenId: item.inner.senderRavenId,
            acceptedAt: nowMs,
            signature: Data(),
            accepterPub: Data()
        )
        try accept.sign(with: accepterKey)
        let binding = ContactBinding(
            ravenId: item.inner.senderRavenId,
            pubHex: item.outer.senderPub.ravenHex,
            petname: pet,
            verificationState: .trustedContact
        )
        return ContactAcceptOutcome(accept: accept, binding: binding)
    }

    mutating func decline(requestId: Data) throws {
        _ = try take(requestId)
    }

    /// Local block — no central moderation.
    mutating func block(requestId: Data) throws -> String {
        let item = try take(requestId)
        return item.outer.senderPub.ravenHex
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
