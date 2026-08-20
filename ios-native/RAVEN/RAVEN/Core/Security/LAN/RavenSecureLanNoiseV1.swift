//
//  RavenSecureLanNoiseV1.swift
//  RAVEN
//
//  Library choice: hand-rolled Noise XX (mirrors existing NoiseSession.swift).
//  No third-party Noise package supports Noise_XX_25519_ChaChaPoly_BLAKE2s with
//  injected ephemerals for KAT parity with Rust snow; CryptoKit lacks BLAKE2s.
//  LanBlake2s.swift provides BLAKE2s-256 + HMAC-BLAKE2s only for this primitive.
//
//  Pattern: Noise_XX_25519_ChaChaPoly_BLAKE2s, empty prologue.
//  Static X25519 is HKDF-SHA256 from device signing seed (not the Noise suite hash).
//  Bind domain rvn1/lan-noise/v1 applies to 96-byte ed25519 bind frames only.
//

import CryptoKit
import Foundation

// MARK: - Errors

enum RavenSecureLanNoiseError: Error, Equatable {
    case handshakeFailed
    case transportFailed
    case bindTruncated
    case bindBadSignature
    case bindMismatch
    case keyDeriveFailed
    case plaintextTooLarge
    case malformedMessage
    case wrongMessageOrder
}

// MARK: - Constants

enum RavenSecureLanNoiseV1 {
    static let noisePattern = "Noise_XX_25519_ChaChaPoly_BLAKE2s"
    static let bindDomain = Data("rvn1/lan-noise/v1".utf8)
    static let bindLen = 96
    static let hkdfSalt = Data("rvn1/lan-noise/v1".utf8)
    static let hkdfInfo = Data("static-x25519".utf8)
    static let maxTransportPlaintext = 65_519
    private static let maxNoiseMessage = 65_535

    // MARK: Static key derive

    static func deriveNoiseStatic(deviceSeed: Data) throws -> Data {
        guard deviceSeed.count == 32 else { throw RavenSecureLanNoiseError.keyDeriveFailed }
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: deviceSeed),
            salt: hkdfSalt,
            info: hkdfInfo,
            outputByteCount: 32
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    static func noiseStaticPublic(staticPrivate: Data) throws -> Data {
        guard staticPrivate.count == 32 else { throw RavenSecureLanNoiseError.keyDeriveFailed }
        let key = try agreementPrivateKey(from: staticPrivate)
        return key.publicKey.rawRepresentation
    }

    // MARK: Identity bind

    static func bindSigningBytes(noiseStaticPub: Data) -> Data {
        var out = Data(capacity: bindDomain.count + 32)
        out.append(bindDomain)
        out.append(noiseStaticPub.prefix(32))
        return out
    }

    static func encodeBind(deviceSeed: Data, noiseStaticPub: Data) throws -> Data {
        guard noiseStaticPub.count == 32 else { throw RavenSecureLanNoiseError.keyDeriveFailed }
        let message = bindSigningBytes(noiseStaticPub: noiseStaticPub)
        let edPub = LanDeterministicEd25519.publicKey(seed: deviceSeed)
        let signature = LanDeterministicEd25519.sign(seed: deviceSeed, message: message)
        var out = Data(capacity: bindLen)
        out.append(edPub)
        out.append(signature)
        return out
    }

    static func verifyBind(
        bind: Data,
        noiseStaticPub: Data,
        expectedEd25519: Data? = nil
    ) throws -> Data {
        guard bind.count == bindLen else { throw RavenSecureLanNoiseError.bindTruncated }
        guard noiseStaticPub.count == 32 else { throw RavenSecureLanNoiseError.bindTruncated }
        let edPub = bind.prefix(32)
        let sig = bind.suffix(64)
        let message = bindSigningBytes(noiseStaticPub: noiseStaticPub)
        let verifyingKey = try Curve25519.Signing.PublicKey(rawRepresentation: edPub)
        guard verifyingKey.isValidSignature(sig, for: message) else {
            throw RavenSecureLanNoiseError.bindBadSignature
        }
        if let expected = expectedEd25519, expected.count == 32, edPub != expected {
            throw RavenSecureLanNoiseError.bindMismatch
        }
        return Data(edPub)
    }

    // MARK: Handshake builders

    static func buildInitiator(
        staticPrivate: Data,
        fixedEphemeralPrivate: Data? = nil
    ) throws -> RavenSecureLanNoiseHandshake {
        try RavenSecureLanNoiseHandshake(
            role: .initiator,
            staticPrivate: staticPrivate,
            fixedEphemeralPrivate: fixedEphemeralPrivate
        )
    }

    static func buildResponder(
        staticPrivate: Data,
        fixedEphemeralPrivate: Data? = nil
    ) throws -> RavenSecureLanNoiseHandshake {
        try RavenSecureLanNoiseHandshake(
            role: .responder,
            staticPrivate: staticPrivate,
            fixedEphemeralPrivate: fixedEphemeralPrivate
        )
    }

    // MARK: X25519 helpers

    static func agreementPrivateKey(from scalar: Data) throws -> Curve25519.KeyAgreement.PrivateKey {
        guard scalar.count == 32 else { throw RavenSecureLanNoiseError.keyDeriveFailed }
        var clamped = [UInt8](scalar)
        clampX25519Scalar(&clamped)
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(clamped))
    }

    static func clampX25519Scalar(_ scalar: inout [UInt8]) {
        guard scalar.count == 32 else { return }
        scalar[0] &= 248
        scalar[31] &= 127
        scalar[31] |= 64
    }
}

// MARK: - Noise HKDF (HMAC-BLAKE2s)

private enum LanNoiseHKDF {
    static func n2(chainingKey ck: [UInt8], input: Data) -> ([UInt8], [UInt8]) {
        let prk = LanBlake2s.hmac(key: ck, message: input)
        let t1 = LanBlake2s.hmac(key: prk, message: Data([0x01]))
        var t2Input = Data(t1)
        t2Input.append(0x02)
        let t2 = LanBlake2s.hmac(key: prk, message: t2Input)
        return (t1, t2)
    }
}

// MARK: - Symmetric state (BLAKE2s hash + ChaChaPoly)

private struct LanNoiseSymmetricState {
    var ck: [UInt8]
    var h: [UInt8]
    var k: SymmetricKey?
    var n: UInt64 = 0

    init(protocolName: String) {
        let nameBytes = Array(protocolName.utf8)
        if nameBytes.count == 32 {
            self.h = nameBytes
        } else if nameBytes.count < 32 {
            self.h = nameBytes + [UInt8](repeating: 0, count: 32 - nameBytes.count)
        } else {
            self.h = LanBlake2s.hash(Data(nameBytes))
        }
        self.ck = self.h
    }

    mutating func mixHash(_ data: Data) {
        var buf = Data(h)
        buf.append(data)
        h = LanBlake2s.hash(buf)
    }

    mutating func mixKey(_ input: Data) {
        let (newCK, newK) = LanNoiseHKDF.n2(chainingKey: ck, input: input)
        ck = newCK
        k = SymmetricKey(data: Data(newK))
        n = 0
    }

    private mutating func currentNonce() throws -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 4)
        let leBytes = withUnsafeBytes(of: n.littleEndian) { Array($0) }
        bytes.append(contentsOf: leBytes)
        return try ChaChaPoly.Nonce(data: Data(bytes))
    }

    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        guard let k else {
            mixHash(plaintext)
            return plaintext
        }
        let nonce = try currentNonce()
        let sealed = try ChaChaPoly.seal(plaintext, using: k, nonce: nonce, authenticating: Data(h))
        var ct = Data(sealed.ciphertext)
        ct.append(sealed.tag)
        n &+= 1
        mixHash(ct)
        return ct
    }

    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        guard let k else {
            mixHash(ciphertext)
            return ciphertext
        }
        guard ciphertext.count >= 16 else { throw RavenSecureLanNoiseError.malformedMessage }
        let tag = ciphertext.suffix(16)
        let payload = ciphertext.prefix(ciphertext.count - 16)
        let nonce = try currentNonce()
        let sealed = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: payload, tag: tag)
        let plaintext: Data
        do {
            plaintext = try ChaChaPoly.open(sealed, using: k, authenticating: Data(h))
        } catch {
            throw RavenSecureLanNoiseError.handshakeFailed
        }
        n &+= 1
        mixHash(ciphertext)
        return plaintext
    }
}

// MARK: - Handshake (XX)

final class RavenSecureLanNoiseHandshake {
    enum Role { case initiator, responder }

    private var sym: LanNoiseSymmetricState
    private let role: Role
    private let staticKey: Curve25519.KeyAgreement.PrivateKey
    private var ephemeralKey: Curve25519.KeyAgreement.PrivateKey?
    private var remoteEphemeral: Curve25519.KeyAgreement.PublicKey?
    private(set) var remoteStatic: Data?
    private var msgIndex = 0
    private var pendingEphemeral: Curve25519.KeyAgreement.PrivateKey?

    init(
        role: Role,
        staticPrivate: Data,
        fixedEphemeralPrivate: Data? = nil,
        prologue: Data = Data()
    ) throws {
        self.role = role
        self.staticKey = try RavenSecureLanNoiseV1.agreementPrivateKey(from: staticPrivate)
        self.sym = LanNoiseSymmetricState(protocolName: RavenSecureLanNoiseV1.noisePattern)
        sym.mixHash(prologue)
        if let fixed = fixedEphemeralPrivate {
            pendingEphemeral = try RavenSecureLanNoiseV1.agreementPrivateKey(from: fixed)
        }
    }

    var handshakeHash: Data { Data(sym.h) }

    func writeMessage(payload: Data = Data()) throws -> Data {
        switch (role, msgIndex) {
        case (.initiator, 0):
            return try writeInitiatorMessage1(payload: payload)
        case (.responder, 1):
            return try writeResponderMessage2(payload: payload)
        case (.initiator, 2):
            return try writeInitiatorMessage3(payload: payload)
        default:
            throw RavenSecureLanNoiseError.wrongMessageOrder
        }
    }

    func readMessage(_ message: Data) throws -> Data {
        switch (role, msgIndex) {
        case (.responder, 0):
            return try readInitiatorMessage1(message)
        case (.initiator, 1):
            return try readResponderMessage2(message)
        case (.responder, 2):
            return try readInitiatorMessage3(message)
        default:
            throw RavenSecureLanNoiseError.wrongMessageOrder
        }
    }

    func intoTransport() throws -> RavenSecureLanNoiseTransport {
        guard msgIndex == 3 else { throw RavenSecureLanNoiseError.wrongMessageOrder }
        let (k1, k2) = LanNoiseHKDF.n2(chainingKey: sym.ck, input: Data())
        switch role {
        case .initiator:
            return RavenSecureLanNoiseTransport(
                sendKey: SymmetricKey(data: Data(k1)),
                receiveKey: SymmetricKey(data: Data(k2))
            )
        case .responder:
            return RavenSecureLanNoiseTransport(
                sendKey: SymmetricKey(data: Data(k2)),
                receiveKey: SymmetricKey(data: Data(k1))
            )
        }
    }

    // -> e
    private func writeInitiatorMessage1(payload: Data) throws -> Data {
        let e = try takeEphemeralKey()
        ephemeralKey = e
        sym.mixHash(e.publicKey.rawRepresentation)
        let encryptedPayload = try sym.encryptAndHash(payload)
        var out = Data()
        out.append(e.publicKey.rawRepresentation)
        out.append(encryptedPayload)
        msgIndex = 1
        return out
    }

    private func readInitiatorMessage1(_ message: Data) throws -> Data {
        guard message.count >= 32 else { throw RavenSecureLanNoiseError.malformedMessage }
        let ePubData = message.prefix(32)
        remoteEphemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ePubData)
        sym.mixHash(Data(ePubData))
        let payload = try sym.decryptAndHash(message.dropFirst(32))
        msgIndex = 1
        return payload
    }

    // <- e, ee, s, es
    private func writeResponderMessage2(payload: Data) throws -> Data {
        guard let re = remoteEphemeral else { throw RavenSecureLanNoiseError.handshakeFailed }
        let e = try takeEphemeralKey()
        ephemeralKey = e
        sym.mixHash(e.publicKey.rawRepresentation)
        let ee = try e.sharedSecretFromKeyAgreement(with: re)
        ee.withUnsafeBytes { sym.mixKey(Data($0)) }
        let encryptedStatic = try sym.encryptAndHash(staticKey.publicKey.rawRepresentation)
        let es = try staticKey.sharedSecretFromKeyAgreement(with: re)
        es.withUnsafeBytes { sym.mixKey(Data($0)) }
        let encryptedPayload = try sym.encryptAndHash(payload)
        var out = Data()
        out.append(e.publicKey.rawRepresentation)
        out.append(encryptedStatic)
        out.append(encryptedPayload)
        msgIndex = 2
        return out
    }

    private func readResponderMessage2(_ message: Data) throws -> Data {
        guard let e = ephemeralKey else { throw RavenSecureLanNoiseError.handshakeFailed }
        guard message.count >= 32 + 48 else { throw RavenSecureLanNoiseError.malformedMessage }
        let ePubData = message.prefix(32)
        remoteEphemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ePubData)
        sym.mixHash(Data(ePubData))
        let ee = try e.sharedSecretFromKeyAgreement(with: remoteEphemeral!)
        ee.withUnsafeBytes { sym.mixKey(Data($0)) }
        let encryptedStatic = message.subdata(in: 32..<(32 + 48))
        let staticPub = try sym.decryptAndHash(encryptedStatic)
        guard staticPub.count == 32 else { throw RavenSecureLanNoiseError.malformedMessage }
        remoteStatic = staticPub
        let rs = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: staticPub)
        let es = try e.sharedSecretFromKeyAgreement(with: rs)
        es.withUnsafeBytes { sym.mixKey(Data($0)) }
        let payload = try sym.decryptAndHash(message.dropFirst(32 + 48))
        msgIndex = 2
        return payload
    }

    // -> s, se
    private func writeInitiatorMessage3(payload: Data) throws -> Data {
        guard let re = remoteEphemeral else { throw RavenSecureLanNoiseError.handshakeFailed }
        let encryptedStatic = try sym.encryptAndHash(staticKey.publicKey.rawRepresentation)
        let se = try staticKey.sharedSecretFromKeyAgreement(with: re)
        se.withUnsafeBytes { sym.mixKey(Data($0)) }
        let encryptedPayload = try sym.encryptAndHash(payload)
        var out = Data()
        out.append(encryptedStatic)
        out.append(encryptedPayload)
        msgIndex = 3
        return out
    }

    private func readInitiatorMessage3(_ message: Data) throws -> Data {
        guard message.count >= 48 else { throw RavenSecureLanNoiseError.malformedMessage }
        guard let localE = ephemeralKey else { throw RavenSecureLanNoiseError.handshakeFailed }
        let encryptedStatic = message.prefix(48)
        let staticPub = try sym.decryptAndHash(Data(encryptedStatic))
        guard staticPub.count == 32 else { throw RavenSecureLanNoiseError.malformedMessage }
        remoteStatic = staticPub
        // SE on receive: DH(local ephemeral, remote static) — same secret as initiator's DH(static, remote e).
        let rs = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: staticPub)
        let se = try localE.sharedSecretFromKeyAgreement(with: rs)
        se.withUnsafeBytes { sym.mixKey(Data($0)) }
        let payload = try sym.decryptAndHash(message.dropFirst(48))
        msgIndex = 3
        return payload
    }

    private func takeEphemeralKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        if let pending = pendingEphemeral {
            pendingEphemeral = nil
            return pending
        }
        return Curve25519.KeyAgreement.PrivateKey()
    }
}

// MARK: - Transport

final class RavenSecureLanNoiseTransport {
    private var sendKey: SymmetricKey
    private var receiveKey: SymmetricKey
    private var sendNonce: UInt64 = 0
    private var receiveNonce: UInt64 = 0

    init(sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.sendKey = sendKey
        self.receiveKey = receiveKey
    }

    func encrypt(plaintext: Data) throws -> Data {
        guard plaintext.count <= RavenSecureLanNoiseV1.maxTransportPlaintext else {
            throw RavenSecureLanNoiseError.plaintextTooLarge
        }
        let ct = try seal(plaintext: plaintext, key: sendKey, nonce: sendNonce, ad: Data())
        sendNonce &+= 1
        return ct
    }

    func decrypt(ciphertext: Data) throws -> Data {
        let pt = try open(ciphertext: ciphertext, key: receiveKey, nonce: receiveNonce, ad: Data())
        receiveNonce &+= 1
        return pt
    }

    private func seal(plaintext: Data, key: SymmetricKey, nonce: UInt64, ad: Data) throws -> Data {
        let boxNonce = try transportNonce(nonce)
        let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: boxNonce, authenticating: ad)
        var ct = Data(sealed.ciphertext)
        ct.append(sealed.tag)
        return ct
    }

    private func open(ciphertext: Data, key: SymmetricKey, nonce: UInt64, ad: Data) throws -> Data {
        guard ciphertext.count >= 16 else { throw RavenSecureLanNoiseError.transportFailed }
        let tag = ciphertext.suffix(16)
        let payload = ciphertext.prefix(ciphertext.count - 16)
        let boxNonce = try transportNonce(nonce)
        let sealed = try ChaChaPoly.SealedBox(nonce: boxNonce, ciphertext: payload, tag: tag)
        do {
            return try ChaChaPoly.open(sealed, using: key, authenticating: ad)
        } catch {
            throw RavenSecureLanNoiseError.transportFailed
        }
    }

    private func transportNonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 4)
        let leBytes = withUnsafeBytes(of: counter.littleEndian) { Array($0) }
        bytes.append(contentsOf: leBytes)
        return try ChaChaPoly.Nonce(data: Data(bytes))
    }
}
