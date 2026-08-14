//
//  RavenContactRequestV1.swift
//  RAVEN — E2EE async contact request (Discovery V1).
//
//  Spec: protocol/RAVEN_CONTACT_REQUEST_V1.md
//  Wire-compatible with raven_core::contact_request (authenticated ATSAM root).
//  Product transport is held until durable indexed-session state is integrated.
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
    case oversized
    /// Contact-request confidentiality is unavailable until an authenticated
    /// ATSAM root and durable chain state exist for this peer.
    case sessionRequired
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
        guard requestId.count == 16, senderProfileDigest.count == 32 else {
            throw RavenContactRequestError.missingKeys
        }
        let encodedAliases = senderAliases.map { Data($0.utf8) }
        guard senderAliases.count <= Int(UInt16.max),
              Data(senderRavenId.utf8).count <= Int(UInt16.max),
              Data(senderDisplayName.utf8).count <= Int(UInt16.max),
              Data(optionalMessage.utf8).count <= Int(UInt16.max),
              encodedAliases.allSatisfy({ $0.count <= Int(UInt16.max) }) else {
            throw RavenContactRequestError.oversized
        }
        var out = Self.magic
        out.append(requestId)
        out.append(Self.lp(Data(senderRavenId.utf8)))
        out.append(Self.lp(Data(senderDisplayName.utf8)))
        out.appendUInt16BE(UInt16(senderAliases.count))
        for alias in encodedAliases {
            out.append(Self.lp(alias))
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
        let expires = raw.readUInt64BE(at: off); off += 8
        guard off == raw.count else { throw RavenContactRequestError.truncated }
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

    /// Rootless compatibility entry point. Public Ed25519 keys are not secret,
    /// so this path always fails closed in both Debug and Release builds.
    static func create(
        senderSigningKey: Curve25519.Signing.PrivateKey,
        recipientPub: Data,
        recipientAddr: String,
        inner: ContactRequestInner
    ) throws -> RavenContactRequestV1 {
        _ = (senderSigningKey, recipientPub, recipientAddr, inner)
        throw RavenContactRequestError.sessionRequired
    }

    /// Seal under a root established by an authenticated ATSAM pairing.
    /// Session establishment and crash-safe, monotonic index allocation remain
    /// the caller's responsibility; the contact UI deliberately does not call
    /// this until that durable session boundary is integrated.
    static func createWithATSAMRoot(
        senderSigningKey: Curve25519.Signing.PrivateKey,
        recipientPub: Data,
        recipientAddr: String,
        inner: ContactRequestInner,
        root: ATSAMRootKey,
        chainIndex: UInt32,
        nonce: Data
    ) throws -> RavenContactRequestV1 {
        guard recipientPub.count == 32, inner.requestId.count == 16 else {
            throw RavenContactRequestError.missingKeys
        }
        let senderPub = senderSigningKey.publicKey.rawRepresentation
        let senderAddr = RavenAddressV1.encode(ed25519PublicKey: senderPub) ?? ""
        guard !senderAddr.isEmpty,
              RavenAddressV1.encode(ed25519PublicKey: recipientPub) == recipientAddr,
              inner.senderRavenId == senderAddr,
              inner.expiresAt > inner.createdAt else {
            throw RavenContactRequestError.idMismatch
        }
        let plain = try inner.encode()
        let ciphertext = try RavenContactRequestATSAMSeal.seal(
            root: root,
            senderAddr: senderAddr,
            recipientAddr: recipientAddr,
            messageId: inner.requestId.ravenHex,
            chainIndex: chainIndex,
            nonce: nonce,
            plaintext: plain
        )
        guard ciphertext.count <= Int(UInt16.max) else {
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
        guard expiresAt > createdAt else { throw RavenContactRequestError.idMismatch }
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
        _ = recipientSigningKey
        throw RavenContactRequestError.sessionRequired
    }

    /// Open with the authenticated ATSAM root paired with the outer sender.
    func openWithATSAMRoot(
        recipientSigningKey: Curve25519.Signing.PrivateKey,
        root: ATSAMRootKey
    ) throws -> ContactRequestInner {
        guard requestId.count == 16, senderPub.count == 32 else {
            throw RavenContactRequestError.missingKeys
        }
        let recipientPub = recipientSigningKey.publicKey.rawRepresentation
        guard RavenAddressV1.encode(ed25519PublicKey: recipientPub) == recipientRavenId else {
            throw RavenContactRequestError.wrongRecipient
        }
        let senderAddr = RavenAddressV1.encode(ed25519PublicKey: senderPub) ?? ""
        guard !senderAddr.isEmpty else { throw RavenContactRequestError.badSignature }
        let plain = try RavenContactRequestATSAMSeal.open(
            root: root,
            wire: ciphertext,
            senderAddr: senderAddr,
            recipientAddr: recipientRavenId,
            messageId: requestId.ravenHex
        )
        let inner = try ContactRequestInner.decode(plain)
        guard inner.requestId == requestId,
              inner.senderRavenId == senderAddr,
              inner.createdAt == createdAt,
              inner.expiresAt == expiresAt,
              inner.expiresAt > inner.createdAt else {
            throw RavenContactRequestError.idMismatch
        }
        return inner
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
        guard off + ctLen + 64 + 32 == raw.count else { throw RavenContactRequestError.truncated }
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

/// Pure RVNA1-v2 primitive used only when the caller already owns an
/// authenticated ATSAM root and a durably reserved chain index. Keeping this
/// helper local prevents the contact UI from silently establishing or
/// synthesising session state.
private enum RavenContactRequestATSAMSeal {
    private static let magic = Data([0x52, 0x56, 0x4E, 0x41, 0x31, 0x00, 0x00, 0x00])
    private static let proto: UInt8 = 0x02
    private static let suite: UInt8 = 0x01
    private static let aadDomain = Data("ATSAM/v1/msg-seal/aad".utf8)
    private static let headerBytes = 8 + 2 + 4 + 12
    /// This helper derives from CK0 and is O(index). Product receive paths must
    /// use persisted ratchet state; cap stateless work to prevent hostile
    /// headers from forcing billions of HKDF operations.
    private static let maximumPortableChainIndex: UInt32 = 4_096

    static func seal(
        root: ATSAMRootKey,
        senderAddr: String,
        recipientAddr: String,
        messageId: String,
        chainIndex: UInt32,
        nonce: Data,
        plaintext: Data
    ) throws -> Data {
        guard validIdentifier(senderAddr), validIdentifier(recipientAddr),
              validIdentifier(messageId), nonce.count == 12,
              chainIndex <= maximumPortableChainIndex else {
            throw RavenContactRequestError.sealFailed
        }
        let key = keyAtIndex(
            root: root,
            senderAddr: senderAddr,
            recipientAddr: recipientAddr,
            chainIndex: chainIndex
        )
        let aad = buildAAD(
            senderAddr: senderAddr,
            recipientAddr: recipientAddr,
            messageId: messageId,
            chainIndex: chainIndex
        )
        do {
            let nonceValue = try ChaChaPoly.Nonce(data: nonce)
            let sealed = try ChaChaPoly.seal(
                plaintext,
                using: key,
                nonce: nonceValue,
                authenticating: aad
            )
            var wire = Data()
            wire.append(magic)
            wire.append(proto)
            wire.append(suite)
            wire.appendUInt32BE(chainIndex)
            wire.append(nonce)
            wire.append(sealed.ciphertext)
            wire.append(sealed.tag)
            return wire
        } catch {
            throw RavenContactRequestError.sealFailed
        }
    }

    static func open(
        root: ATSAMRootKey,
        wire: Data,
        senderAddr: String,
        recipientAddr: String,
        messageId: String
    ) throws -> Data {
        guard validIdentifier(senderAddr), validIdentifier(recipientAddr),
              validIdentifier(messageId) else {
            throw RavenContactRequestError.sealFailed
        }
        guard wire.count >= headerBytes + 16 else {
            throw RavenContactRequestError.truncated
        }
        guard wire.prefix(magic.count) == magic,
              wire[8] == proto, wire[9] == suite else {
            throw RavenContactRequestError.badMagic
        }
        let chainIndex = wire.readUInt32BE(at: 10)
        guard chainIndex <= maximumPortableChainIndex else {
            throw RavenContactRequestError.sealFailed
        }
        let nonceBytes = wire.subdata(in: 14..<26)
        let tagStart = wire.count - 16
        let ciphertext = wire.subdata(in: 26..<tagStart)
        let tag = wire.subdata(in: tagStart..<wire.count)
        let key = keyAtIndex(
            root: root,
            senderAddr: senderAddr,
            recipientAddr: recipientAddr,
            chainIndex: chainIndex
        )
        let aad = buildAAD(
            senderAddr: senderAddr,
            recipientAddr: recipientAddr,
            messageId: messageId,
            chainIndex: chainIndex
        )
        do {
            let nonce = try ChaChaPoly.Nonce(data: nonceBytes)
            let box = try ChaChaPoly.SealedBox(
                nonce: nonce,
                ciphertext: ciphertext,
                tag: tag
            )
            return try ChaChaPoly.open(box, using: key, authenticating: aad)
        } catch {
            throw RavenContactRequestError.sealFailed
        }
    }

    private static func keyAtIndex(
        root: ATSAMRootKey,
        senderAddr: String,
        recipientAddr: String,
        chainIndex: UInt32
    ) -> SymmetricKey {
        var chainKey = ATSAMChainRatchet.initialChainKey(
            root: root,
            senderUserId: senderAddr,
            recipientUserId: recipientAddr
        )
        for _ in 0..<chainIndex {
            chainKey = ATSAMChainRatchet.advanceChainKey(chainKey)
        }
        return ATSAMChainRatchet.messageKey(
            chainKey: chainKey,
            senderUserId: senderAddr,
            recipientUserId: recipientAddr
        )
    }

    private static func buildAAD(
        senderAddr: String,
        recipientAddr: String,
        messageId: String,
        chainIndex: UInt32
    ) -> Data {
        var hasher = SHA256()
        hasher.update(data: aadDomain)
        hasher.update(data: Data([0x00, proto, suite]))
        var be = chainIndex.bigEndian
        withUnsafeBytes(of: &be) { hasher.update(data: Data($0)) }
        hasher.update(data: Data([0x00]))
        hasher.update(data: Data(senderAddr.utf8))
        hasher.update(data: Data([0x00]))
        hasher.update(data: Data(recipientAddr.utf8))
        hasher.update(data: Data([0x00]))
        hasher.update(data: Data(messageId.utf8))
        return Data(hasher.finalize())
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("\0")
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

    /// Authenticated session-root variant. Decryption and all identity/time
    /// bindings complete before the request ID enters the pending set.
    mutating func ingestWithATSAMRoot(
        outer: RavenContactRequestV1,
        recipientSigningKey: Curve25519.Signing.PrivateKey,
        recipientAddr: String,
        root: ATSAMRootKey,
        nowMs: UInt64
    ) throws -> ContactRequestInner {
        try outer.verifyOuter(nowMs: nowMs)
        guard outer.recipientRavenId == recipientAddr else {
            throw RavenContactRequestError.wrongRecipient
        }
        let inner = try outer.openWithATSAMRoot(
            recipientSigningKey: recipientSigningKey,
            root: root
        )
        return try ingestOpened(outer: outer, inner: inner, nowMs: nowMs)
    }

    private mutating func ingestOpened(
        outer: RavenContactRequestV1,
        inner: ContactRequestInner,
        nowMs: UInt64
    ) throws -> ContactRequestInner {
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
