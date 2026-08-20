//
//  ATSAMIndexedSessionProfile.swift
//  RAVEN
//
//  Byte-exact reference primitives for ATSAM/indexed-session/v1.
//
//  This profile is intentionally disconnected from production pairing,
//  routing, send, and receive paths. A future signed PairInit must negotiate
//  and transcript-bind this exact profile before it can be activated.
//

import CryptoKit
import Foundation

enum ATSAMIndexedSessionProfile {

    /// Tripwire: Release always false. DEBUG lab via RAVEN_LAB_TEST_A.
    static var productionEnabled: Bool {
        #if DEBUG
        ATSAMLabGate.isEnabled
        #else
        false
        #endif
    }

    static let profileIdentifier = "ATSAM/indexed-session/v1"
    static let rvna1Magic = Data([0x52, 0x56, 0x4E, 0x41, 0x31, 0x00, 0x00, 0x00])
    static let protocolByte: UInt8 = 0x03
    static let suiteByte: UInt8 = 0x01
    static let signedAckLength = 101
    static let sealedAckLength = 143

    enum Direction: UInt8, CaseIterable {
        case initiatorToResponder = 0
        case responderToInitiator = 1
    }

    enum ProfileError: Error, Equatable {
        case invalidRootLength
        case invalidChainKeyLength
        case nonCanonicalAddress
        case sameEndpoint
        case invalidEnvelopeType
        case invalidMessageIdLength
        case invalidAckMessageIdLength
        case invalidAckNonceLength
        case invalidAckSignatureLength
        case invalidAckStatus
        case invalidSignedAckLength
        case invalidSealNonceLength
        case invalidSealedAckLength
        case invalidSealedAckHeader
        case authenticationFailed
    }

    struct SignedAck: Equatable {
        let ackedMessageId: Data
        let status: UInt8
        let ackNonce: Data
        let createdAtMs: UInt64
        let signature: Data
    }

    private static let ackBaseLabel = Data("ATSAM/v1/ack-seal".utf8)
    private static let routeMasterLabel = Data("ATSAM/v1/GhostRoute/recipient-tag".utf8)
    private static let routeDirectionLabel = Data("ATSAM/v1/GhostRoute/rvn1-direction".utf8)
    private static let chainInitLabel = Data("ATSAM/v2/chain-init".utf8)
    private static let chainAdvanceLabel = Data("ATSAM/v2/chain-advance".utf8)
    private static let messageKeyLabel = Data("ATSAM/v2/msg-key".utf8)
    private static let messageSealSalt = Data("ATSAM/v2/msg-seal/salt".utf8)
    private static let aadDomain = Data("ATSAM/v1/msg-seal/aad".utf8)
    private static let routeDomain = Data("rvn1/route".utf8)
    private static let mailboxLabel = Data("rvn1/mailbox".utf8)
    private static let storeDomain = Data("raven/relay-tag/v1".utf8)
    private static let ackSignatureDomain = Data("rvn1/ack".utf8)

    // MARK: - Context and roles

    static func requireCanonicalAddress(_ value: String) throws -> String {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ $0 < 0x80 }),
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value == value.lowercased(),
              let decoded = Bech32m.decode(value),
              decoded.0 == RavenAddressV1.hrp,
              decoded.1.count == 21,
              decoded.1.first == RavenAddressV1.version else {
            throw ProfileError.nonCanonicalAddress
        }
        return value
    }

    static func sessionContext(initiatorAddress: String, responderAddress: String) throws -> Data {
        let initiator = try requireCanonicalAddress(initiatorAddress)
        let responder = try requireCanonicalAddress(responderAddress)
        guard initiator != responder else { throw ProfileError.sameEndpoint }

        var result = Data(profileIdentifier.utf8)
        result.append(0)
        result.append(Data(initiator.utf8))
        result.append(0)
        result.append(Data(responder.utf8))
        return result
    }

    static func endpoints(
        initiatorAddress: String,
        responderAddress: String,
        direction: Direction
    ) throws -> (sender: String, recipient: String) {
        _ = try sessionContext(
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress
        )
        switch direction {
        case .initiatorToResponder:
            return (initiatorAddress, responderAddress)
        case .responderToInitiator:
            return (responderAddress, initiatorAddress)
        }
    }

    // MARK: - Message and ACK lanes

    static func initialChainKey(root: Data, sender: String, recipient: String) throws -> Data {
        guard root.count == 32 else { throw ProfileError.invalidRootLength }
        let sender = try requireCanonicalAddress(sender)
        let recipient = try requireCanonicalAddress(recipient)
        guard sender != recipient else { throw ProfileError.sameEndpoint }

        var info = chainInitLabel
        info.append(0)
        info.append(Data(sender.utf8))
        info.append(0)
        info.append(Data(recipient.utf8))
        return hkdf32(inputKeyMaterial: root, info: info)
    }

    static func advanceChainKey(_ chainKey: Data) throws -> Data {
        guard chainKey.count == 32 else { throw ProfileError.invalidChainKeyLength }
        return hkdf32(inputKeyMaterial: chainKey, info: chainAdvanceLabel)
    }

    static func laneMessageKey(chainKey: Data, sender: String, recipient: String) throws -> Data {
        guard chainKey.count == 32 else { throw ProfileError.invalidChainKeyLength }
        let sender = try requireCanonicalAddress(sender)
        let recipient = try requireCanonicalAddress(recipient)

        var info = messageKeyLabel
        info.append(0)
        info.append(Data(sender.utf8))
        info.append(0)
        info.append(Data(recipient.utf8))
        return hkdf32(inputKeyMaterial: chainKey, salt: messageSealSalt, info: info)
    }

    static func messageChainKeyAtIndex(
        root: Data,
        initiatorAddress: String,
        responderAddress: String,
        direction: Direction,
        index: UInt32
    ) throws -> Data {
        let pair = try endpoints(
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            direction: direction
        )
        return try chainKeyAtIndex(
            root: root,
            sender: pair.sender,
            recipient: pair.recipient,
            index: index
        )
    }

    static func messageKeyAtIndex(
        root: Data,
        initiatorAddress: String,
        responderAddress: String,
        direction: Direction,
        index: UInt32
    ) throws -> Data {
        let pair = try endpoints(
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            direction: direction
        )
        let chainKey = try messageChainKeyAtIndex(
            root: root,
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            direction: direction,
            index: index
        )
        return try laneMessageKey(
            chainKey: chainKey,
            sender: pair.sender,
            recipient: pair.recipient
        )
    }

    static func ackBaseKey(root: Data) throws -> Data {
        guard root.count == 32 else { throw ProfileError.invalidRootLength }
        return hkdf32(inputKeyMaterial: root, info: ackBaseLabel)
    }

    static func ackChainKeyAtIndex(
        root: Data,
        initiatorAddress: String,
        responderAddress: String,
        direction: Direction,
        index: UInt32
    ) throws -> Data {
        let pair = try endpoints(
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            direction: direction
        )
        return try chainKeyAtIndex(
            root: ackBaseKey(root: root),
            sender: pair.sender,
            recipient: pair.recipient,
            index: index
        )
    }

    static func ackKeyAtIndex(
        root: Data,
        initiatorAddress: String,
        responderAddress: String,
        direction: Direction,
        index: UInt32
    ) throws -> Data {
        let pair = try endpoints(
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            direction: direction
        )
        let chainKey = try ackChainKeyAtIndex(
            root: root,
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            direction: direction,
            index: index
        )
        return try laneMessageKey(
            chainKey: chainKey,
            sender: pair.sender,
            recipient: pair.recipient
        )
    }

    // MARK: - Route and mailbox lanes

    static func routeMasterKey(root: Data) throws -> Data {
        guard root.count == 32 else { throw ProfileError.invalidRootLength }
        return hkdf32(inputKeyMaterial: root, info: routeMasterLabel)
    }

    static func routeDirectionKey(root: Data, direction: Direction) throws -> Data {
        var info = routeDirectionLabel
        info.append(0)
        info.append(direction.rawValue)
        return hkdf32(inputKeyMaterial: try routeMasterKey(root: root), info: info)
    }

    static func routeCoordinates(
        createdAtMs: UInt64,
        index: UInt32,
        envelopeType: UInt8,
        direction: Direction
    ) throws -> (epoch: UInt64, counter: UInt64) {
        guard (1...4).contains(envelopeType) else {
            throw ProfileError.invalidEnvelopeType
        }
        let epoch = createdAtMs / 1_000
        let counter = (UInt64(index) << 3)
            | (UInt64(envelopeType - 1) << 1)
            | UInt64(direction.rawValue)
        return (epoch, counter)
    }

    static func deriveRouteTag(
        root: Data,
        createdAtMs: UInt64,
        index: UInt32,
        envelopeType: UInt8,
        direction: Direction
    ) throws -> Data {
        let coordinates = try routeCoordinates(
            createdAtMs: createdAtMs,
            index: index,
            envelopeType: envelopeType,
            direction: direction
        )
        let key = try routeDirectionKey(root: root, direction: direction)
        var input = routeDomain
        input.appendUInt64BE(coordinates.epoch)
        input.appendUInt64BE(coordinates.counter)
        return truncatedHMAC16(key: key, input: input)
    }

    static func mailboxCoordinates(
        unixMs: UInt64,
        direction: Direction
    ) -> (dayEpoch: UInt64, slot: UInt64) {
        (unixMs / 86_400_000, UInt64(direction.rawValue))
    }

    static func deriveMailboxTags(
        root: Data,
        unixMs: UInt64,
        direction: Direction
    ) throws -> (mailboxTag: Data, storeTag: Data) {
        let coordinates = mailboxCoordinates(unixMs: unixMs, direction: direction)
        var input = mailboxLabel
        input.appendUInt64BE(coordinates.dayEpoch)
        input.appendUInt64BE(coordinates.slot)
        let mailbox = truncatedHMAC16(
            key: try routeDirectionKey(root: root, direction: direction),
            input: input
        )
        var storeInput = storeDomain
        storeInput.append(mailbox)
        return (mailbox, Data(SHA256.hash(data: storeInput).prefix(16)))
    }

    // MARK: - UUID AAD

    static func uuidText(messageId: Data) throws -> String {
        guard messageId.count == 16 else { throw ProfileError.invalidMessageIdLength }
        let value = messageId.map { String(format: "%02X", $0) }.joined()
        return "\(value.prefix(8))-\(value.dropFirst(8).prefix(4))-"
            + "\(value.dropFirst(12).prefix(4))-\(value.dropFirst(16).prefix(4))-"
            + "\(value.dropFirst(20))"
    }

    static func buildAAD(
        index: UInt32,
        sender: String,
        recipient: String,
        outerMessageId: Data
    ) throws -> Data {
        let sender = try requireCanonicalAddress(sender)
        let recipient = try requireCanonicalAddress(recipient)

        var input = aadDomain
        input.append(0)
        input.append(protocolByte)
        input.append(suiteByte)
        input.appendUInt32BE(index)
        input.append(0)
        input.append(Data(sender.utf8))
        input.append(0)
        input.append(Data(recipient.utf8))
        input.append(0)
        input.append(Data(try uuidText(messageId: outerMessageId).utf8))
        return Data(SHA256.hash(data: input))
    }

    // MARK: - Signed ACK codec

    static func ackSigningBytes(_ value: SignedAck) throws -> Data {
        try validateAck(value)
        var result = ackSignatureDomain
        result.append(value.ackedMessageId)
        result.append(value.status)
        result.append(value.ackNonce)
        result.appendUInt64BE(value.createdAtMs)
        return result
    }

    static func encodeSignedAck(_ value: SignedAck) throws -> Data {
        try validateAck(value)
        var result = Data(capacity: signedAckLength)
        result.append(value.ackedMessageId)
        result.append(value.status)
        result.append(value.ackNonce)
        result.appendUInt64BE(value.createdAtMs)
        result.append(value.signature)
        precondition(result.count == signedAckLength)
        return result
    }

    static func decodeSignedAck(_ data: Data) throws -> SignedAck {
        guard data.count == signedAckLength else {
            throw ProfileError.invalidSignedAckLength
        }
        let value = SignedAck(
            ackedMessageId: data.subdata(in: 0..<16),
            status: data[16],
            ackNonce: data.subdata(in: 17..<29),
            createdAtMs: readUInt64BE(data, at: 29),
            signature: data.subdata(in: 37..<101)
        )
        try validateAck(value)
        return value
    }

    // MARK: - RVNA1 proto 0x03 sealed ACK

    /// Explicit nonces exist solely for deterministic interop fixtures. A live
    /// sender must never reuse a nonce with the same derived ACK-lane key.
    static func sealAck(
        root: Data,
        initiatorAddress: String,
        responderAddress: String,
        direction: Direction,
        index: UInt32,
        outerMessageId: Data,
        plaintext: Data,
        nonce: Data
    ) throws -> Data {
        guard plaintext.count == signedAckLength else {
            throw ProfileError.invalidSignedAckLength
        }
        _ = try decodeSignedAck(plaintext)
        guard nonce.count == 12 else { throw ProfileError.invalidSealNonceLength }

        let pair = try endpoints(
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            direction: direction
        )
        let key = try ackKeyAtIndex(
            root: root,
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            direction: direction,
            index: index
        )
        let aad = try buildAAD(
            index: index,
            sender: pair.sender,
            recipient: pair.recipient,
            outerMessageId: outerMessageId
        )

        let box: ChaChaPoly.SealedBox
        do {
            box = try ChaChaPoly.seal(
                plaintext,
                using: SymmetricKey(data: key),
                nonce: ChaChaPoly.Nonce(data: nonce),
                authenticating: aad
            )
        } catch {
            throw ProfileError.authenticationFailed
        }

        var wire = rvna1Magic
        wire.append(protocolByte)
        wire.append(suiteByte)
        wire.appendUInt32BE(index)
        wire.append(nonce)
        wire.append(box.ciphertext)
        wire.append(box.tag)
        precondition(wire.count == sealedAckLength)
        return wire
    }

    static func openAck(
        root: Data,
        initiatorAddress: String,
        responderAddress: String,
        direction: Direction,
        outerMessageId: Data,
        wire: Data
    ) throws -> Data {
        guard wire.count == sealedAckLength else {
            throw ProfileError.invalidSealedAckLength
        }
        guard wire.prefix(8) == rvna1Magic,
              wire[8] == protocolByte,
              wire[9] == suiteByte else {
            throw ProfileError.invalidSealedAckHeader
        }

        let index = readUInt32BE(wire, at: 10)
        let nonce = wire.subdata(in: 14..<26)
        let ciphertext = wire.subdata(in: 26..<127)
        let tag = wire.subdata(in: 127..<143)
        let pair = try endpoints(
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            direction: direction
        )
        let key = try ackKeyAtIndex(
            root: root,
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            direction: direction,
            index: index
        )
        let aad = try buildAAD(
            index: index,
            sender: pair.sender,
            recipient: pair.recipient,
            outerMessageId: outerMessageId
        )

        let plaintext: Data
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: ChaChaPoly.Nonce(data: nonce),
                ciphertext: ciphertext,
                tag: tag
            )
            plaintext = try ChaChaPoly.open(
                box,
                using: SymmetricKey(data: key),
                authenticating: aad
            )
        } catch {
            throw ProfileError.authenticationFailed
        }
        guard plaintext.count == signedAckLength else {
            throw ProfileError.invalidSignedAckLength
        }
        _ = try decodeSignedAck(plaintext)
        return plaintext
    }

    // MARK: - Internal primitives

    private static func chainKeyAtIndex(
        root: Data,
        sender: String,
        recipient: String,
        index: UInt32
    ) throws -> Data {
        var chainKey = try initialChainKey(root: root, sender: sender, recipient: recipient)
        for _ in 0..<index {
            chainKey = try advanceChainKey(chainKey)
        }
        return chainKey
    }

    private static func hkdf32(
        inputKeyMaterial: Data,
        salt: Data? = nil,
        info: Data
    ) -> Data {
        let key: SymmetricKey
        if let salt {
            key = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: inputKeyMaterial),
                salt: salt,
                info: info,
                outputByteCount: 32
            )
        } else {
            key = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: inputKeyMaterial),
                info: info,
                outputByteCount: 32
            )
        }
        return key.withUnsafeBytes { Data($0) }
    }

    private static func truncatedHMAC16(key: Data, input: Data) -> Data {
        let code = HMAC<SHA256>.authenticationCode(
            for: input,
            using: SymmetricKey(data: key)
        )
        return Data(code.prefix(16))
    }

    private static func validateAck(_ value: SignedAck) throws {
        guard value.ackedMessageId.count == 16 else {
            throw ProfileError.invalidAckMessageIdLength
        }
        guard value.status == 1 || value.status == 2 else {
            throw ProfileError.invalidAckStatus
        }
        guard value.ackNonce.count == 12 else {
            throw ProfileError.invalidAckNonceLength
        }
        guard value.signature.count == 64 else {
            throw ProfileError.invalidAckSignatureLength
        }
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func readUInt64BE(_ data: Data, at offset: Int) -> UInt64 {
        var result: UInt64 = 0
        for index in 0..<8 {
            result = (result << 8) | UInt64(data[offset + index])
        }
        return result
    }
}
