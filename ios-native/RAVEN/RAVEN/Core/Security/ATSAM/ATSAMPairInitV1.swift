//
//  ATSAMPairInitV1.swift
//  RAVEN
//
//  Byte-exact, production-disabled Raven PairInit/PairResponse V1 support.
//
//  This file intentionally has no persistence, prekey-consumption, carrier,
//  routing, or UI integration. It exists only to freeze the signed codec,
//  exact trust-record binding, provisional hybrid-root KDF, and deferred root
//  confirmation defined by protocol/RAVEN_PAIR_INIT_V1.md.
//

import CryptoKit
import Foundation

enum ATSAMPairInitV1 {

    // MARK: - Activation tripwire and frozen constants

    /// PairInit live path: Release stays false. DEBUG lab via RAVEN_LAB_TEST_A.
    static var productionEnabled: Bool {
        #if DEBUG
        ATSAMEndpointDurableAdapters.labTestAEnabled
        #else
        false
        #endif
    }

    static let version: UInt8 = 0x01
    static let suite: UInt8 = 0x01
    static let initiatorRole: UInt8 = 0x00
    static let responderRole: UInt8 = 0x01
    static let profileIdentifier = "ATSAM/indexed-session/v1"

    static let initWireLength = 2_788
    static let responseWireLength = 228
    static let initSignedPrefixLength = 2_724
    static let responseSignedPrefixLength = 164

    private static let addressLength = 44
    private static let initMagic = Data([0x52, 0x56, 0x50, 0x49, 0x31, 0, 0, 0])
    private static let responseMagic = Data([0x52, 0x56, 0x50, 0x52, 0x31, 0, 0, 0])
    private static let profile = Data(profileIdentifier.utf8)
    private static let transcriptDomain = Data("ATSAM/v1/transcript".utf8)
    private static let pairInitLabel = Data("ATSAM/v1/pair-init".utf8)
    private static let initSigningDomain = Data("rvn1/pair-init".utf8)
    private static let responseSigningDomain = Data("rvn1/pair-response".utf8)
    private static let deviceCertificateHashDomain = Data("rvn1/pair-devcert".utf8)
    private static let prekeyBundleHashDomain = Data("rvn1/pair-prekey".utf8)
    private static let sessionIDDomain = Data("rvn1/pair-session".utf8)
    private static let confirmationLabel = Data("ATSAM/pair-init/v1/confirm".utf8)
    private static let deviceCertificateDomain = Data("rvn1/devcert".utf8)
    private static let prekeyDomain = Data("rvn1/prekey".utf8)

    private static let initIDLength = 16
    private static let keyLength = 32
    private static let signatureLength = 64
    private static let mlKem768EncapsulationKeyLength = 1_184
    private static let mlKem768CiphertextLength = 1_088
    private static let prekeyClockSkewMs: UInt64 = 5 * 60 * 1_000

    // MARK: - Wire values

    struct PairInit: Equatable {
        let initiatorAddress: String
        let responderAddress: String
        let initID: Data
        let pairingNonce: Data
        let initiatorDeviceEd25519PublicKey: Data
        let responderDeviceEd25519PublicKey: Data
        let initiatorEphemeralX25519PublicKey: Data
        let responderSignedX25519PublicKey: Data
        /// Fixed-width all-zero slot iff `oneTimePrekeyID == 0`.
        let responderOneTimeX25519PublicKey: Data
        let initiatorDeviceCertificateHash: Data
        let responderDeviceCertificateHash: Data
        let responderPrekeyBundleHash: Data
        let signedPrekeyID: UInt32
        let oneTimePrekeyID: UInt32
        let responderMLKem768EncapsulationKey: Data
        let mlKem768Ciphertext: Data
        let createdAtMs: UInt64
        let expiresAtMs: UInt64
        let signature: Data
    }

    struct PairResponse: Equatable {
        let initID: Data
        let initHash: Data
        let responderDeviceEd25519PublicKey: Data
        let createdAtMs: UInt64
        let expiresAtMs: UInt64
        let confirmationTag: Data
        let signature: Data
    }

    /// Exact signed certificate bytes plus the identity key that authorized
    /// them. Verification reparses the canonical record; callers cannot supply
    /// a detached projection of its device, id, or validity fields.
    struct SignedDeviceCertificate: Equatable {
        let identityEd25519PublicKey: Data
        let signingBytes: Data
        let signature: Data
    }

    /// Verified, canonical projection used by the production-disabled endpoint
    /// actor. Callers cannot manufacture this projection without supplying the
    /// exact identity-signed certificate bytes accepted during PairInit.
    struct ValidatedDeviceCertificate: Equatable {
        let identityEd25519PublicKey: Data
        let deviceEd25519PublicKey: Data
        let certificateHash: Data
        let notBeforeMs: UInt64
        let notAfterMs: UInt64

        fileprivate init(
            identityEd25519PublicKey: Data,
            deviceEd25519PublicKey: Data,
            certificateHash: Data,
            notBeforeMs: UInt64,
            notAfterMs: UInt64
        ) {
            self.identityEd25519PublicKey = identityEd25519PublicKey
            self.deviceEd25519PublicKey = deviceEd25519PublicKey
            self.certificateHash = certificateHash
            self.notBeforeMs = notBeforeMs
            self.notAfterMs = notAfterMs
        }
    }

    /// Exact signed RavenPrekeyBundleV1 signing bytes and signature.
    struct SignedPrekeyBundle: Equatable {
        let signingBytes: Data
        let signature: Data
    }

    /// All trust inputs needed to accept one PairInit. Local revocation is
    /// explicit because V1 deliberately has no signed global revocation record.
    struct TrustContext: Equatable {
        let initiatorCertificate: SignedDeviceCertificate
        let responderCertificate: SignedDeviceCertificate
        let responderPrekeyBundle: SignedPrekeyBundle
        let initiatorRevoked: Bool
        let responderRevoked: Bool

        init(
            initiatorCertificate: SignedDeviceCertificate,
            responderCertificate: SignedDeviceCertificate,
            responderPrekeyBundle: SignedPrekeyBundle,
            initiatorRevoked: Bool = false,
            responderRevoked: Bool = false
        ) {
            self.initiatorCertificate = initiatorCertificate
            self.responderCertificate = responderCertificate
            self.responderPrekeyBundle = responderPrekeyBundle
            self.initiatorRevoked = initiatorRevoked
            self.responderRevoked = responderRevoked
        }
    }

    enum PairInitError: Error, Equatable {
        case invalidLength
        case invalidMagic
        case invalidVersion
        case invalidSuite
        case invalidRole
        case invalidProfile
        case invalidAddress
        case sameEndpoint
        case allZeroField
        case invalidOneTimePrekey
        case invalidTime
        case invalidSharedSecretLength
        case nonContributoryX25519
        case identityMismatch
        case certificateMismatch
        case prekeyMismatch
        case revokedDevice
        case trustWindowMismatch
        case notCurrentlyValid
        case badSignature
        case confirmationMismatch
        case trustEncoding
    }

    // MARK: - PairInit codec

    static func initSigningBytes(_ value: PairInit) throws -> Data {
        var result = initSigningDomain
        result.append(try initPrefix(value))
        return result
    }

    static func encodeInit(_ value: PairInit) throws -> Data {
        try validateInit(value, requireSignature: true)
        var result = try initPrefix(value)
        result.append(value.signature)
        guard result.count == initWireLength else { throw PairInitError.invalidLength }
        return result
    }

    static func decodeInit(_ wire: Data) throws -> PairInit {
        guard wire.count == initWireLength else { throw PairInitError.invalidLength }
        guard Data(wire.prefix(8)) == initMagic else { throw PairInitError.invalidMagic }
        guard wire[8] == version else { throw PairInitError.invalidVersion }
        guard wire[9] == suite else { throw PairInitError.invalidSuite }
        guard wire[10] == initiatorRole else { throw PairInitError.invalidRole }
        guard wire[11] == UInt8(profile.count),
              wire.subdata(in: 12..<(12 + profile.count)) == profile else {
            throw PairInitError.invalidProfile
        }

        var reader = WireReader(wire, offset: 12 + profile.count)
        let initiatorAddress = try reader.readASCII(count: addressLength)
        let responderAddress = try reader.readASCII(count: addressLength)
        let value = PairInit(
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            initID: try reader.readData(count: initIDLength),
            pairingNonce: try reader.readData(count: keyLength),
            initiatorDeviceEd25519PublicKey: try reader.readData(count: keyLength),
            responderDeviceEd25519PublicKey: try reader.readData(count: keyLength),
            initiatorEphemeralX25519PublicKey: try reader.readData(count: keyLength),
            responderSignedX25519PublicKey: try reader.readData(count: keyLength),
            responderOneTimeX25519PublicKey: try reader.readData(count: keyLength),
            initiatorDeviceCertificateHash: try reader.readData(count: keyLength),
            responderDeviceCertificateHash: try reader.readData(count: keyLength),
            responderPrekeyBundleHash: try reader.readData(count: keyLength),
            signedPrekeyID: try reader.readUInt32(),
            oneTimePrekeyID: try reader.readUInt32(),
            responderMLKem768EncapsulationKey: try reader.readData(
                count: mlKem768EncapsulationKeyLength
            ),
            mlKem768Ciphertext: try reader.readData(count: mlKem768CiphertextLength),
            createdAtMs: try reader.readUInt64(),
            expiresAtMs: try reader.readUInt64(),
            signature: try reader.readData(count: signatureLength)
        )
        guard reader.isAtEnd else { throw PairInitError.invalidLength }
        try validateInit(value, requireSignature: true)
        return value
    }

    private static func initPrefix(_ value: PairInit) throws -> Data {
        try validateInit(value, requireSignature: false)
        var result = Data(capacity: initSignedPrefixLength)
        result.append(initMagic)
        result.append(version)
        result.append(suite)
        result.append(initiatorRole)
        result.append(UInt8(profile.count))
        result.append(profile)
        result.append(Data(value.initiatorAddress.utf8))
        result.append(Data(value.responderAddress.utf8))
        result.append(value.initID)
        result.append(value.pairingNonce)
        result.append(value.initiatorDeviceEd25519PublicKey)
        result.append(value.responderDeviceEd25519PublicKey)
        result.append(value.initiatorEphemeralX25519PublicKey)
        result.append(value.responderSignedX25519PublicKey)
        result.append(value.responderOneTimeX25519PublicKey)
        result.append(value.initiatorDeviceCertificateHash)
        result.append(value.responderDeviceCertificateHash)
        result.append(value.responderPrekeyBundleHash)
        appendUInt32(value.signedPrekeyID, to: &result)
        appendUInt32(value.oneTimePrekeyID, to: &result)
        result.append(value.responderMLKem768EncapsulationKey)
        result.append(value.mlKem768Ciphertext)
        appendUInt64(value.createdAtMs, to: &result)
        appendUInt64(value.expiresAtMs, to: &result)
        guard result.count == initSignedPrefixLength else { throw PairInitError.invalidLength }
        return result
    }

    private static func validateInit(_ value: PairInit, requireSignature: Bool) throws {
        try validateAddress(value.initiatorAddress)
        try validateAddress(value.responderAddress)
        guard value.initiatorAddress != value.responderAddress else {
            throw PairInitError.sameEndpoint
        }
        try requireLength(value.initID, initIDLength)
        try requireLength(value.pairingNonce, keyLength)
        try requireLength(value.initiatorDeviceEd25519PublicKey, keyLength)
        try requireLength(value.responderDeviceEd25519PublicKey, keyLength)
        try requireLength(value.initiatorEphemeralX25519PublicKey, keyLength)
        try requireLength(value.responderSignedX25519PublicKey, keyLength)
        try requireLength(value.responderOneTimeX25519PublicKey, keyLength)
        try requireLength(value.initiatorDeviceCertificateHash, keyLength)
        try requireLength(value.responderDeviceCertificateHash, keyLength)
        try requireLength(value.responderPrekeyBundleHash, keyLength)
        try requireLength(
            value.responderMLKem768EncapsulationKey,
            mlKem768EncapsulationKeyLength
        )
        try requireLength(value.mlKem768Ciphertext, mlKem768CiphertextLength)

        let requiredNonzero = [
            value.initID,
            value.pairingNonce,
            value.initiatorDeviceEd25519PublicKey,
            value.responderDeviceEd25519PublicKey,
            value.initiatorEphemeralX25519PublicKey,
            value.responderSignedX25519PublicKey,
            value.initiatorDeviceCertificateHash,
            value.responderDeviceCertificateHash,
            value.responderPrekeyBundleHash,
            value.responderMLKem768EncapsulationKey,
            value.mlKem768Ciphertext,
        ]
        guard requiredNonzero.allSatisfy({ !isAllZero($0) }) else {
            throw PairInitError.allZeroField
        }
        guard value.initiatorDeviceEd25519PublicKey
                != value.responderDeviceEd25519PublicKey else {
            throw PairInitError.certificateMismatch
        }
        guard value.signedPrekeyID != 0 else { throw PairInitError.prekeyMismatch }
        if value.oneTimePrekeyID == 0 {
            guard isAllZero(value.responderOneTimeX25519PublicKey) else {
                throw PairInitError.invalidOneTimePrekey
            }
        } else {
            guard !isAllZero(value.responderOneTimeX25519PublicKey) else {
                throw PairInitError.invalidOneTimePrekey
            }
        }
        guard value.expiresAtMs > value.createdAtMs else {
            throw PairInitError.invalidTime
        }
        if requireSignature {
            try requireLength(value.signature, signatureLength)
        }
    }

    // MARK: - PairResponse codec

    static func responseSigningBytes(_ value: PairResponse) throws -> Data {
        var result = responseSigningDomain
        result.append(try responsePrefix(value))
        return result
    }

    static func encodeResponse(_ value: PairResponse) throws -> Data {
        try validateResponse(value, requireSignature: true)
        var result = try responsePrefix(value)
        result.append(value.signature)
        guard result.count == responseWireLength else { throw PairInitError.invalidLength }
        return result
    }

    static func decodeResponse(_ wire: Data) throws -> PairResponse {
        guard wire.count == responseWireLength else { throw PairInitError.invalidLength }
        guard Data(wire.prefix(8)) == responseMagic else { throw PairInitError.invalidMagic }
        guard wire[8] == version else { throw PairInitError.invalidVersion }
        guard wire[9] == suite else { throw PairInitError.invalidSuite }
        guard wire[10] == responderRole else { throw PairInitError.invalidRole }
        guard wire[11] == UInt8(profile.count),
              wire.subdata(in: 12..<(12 + profile.count)) == profile else {
            throw PairInitError.invalidProfile
        }

        var reader = WireReader(wire, offset: 12 + profile.count)
        let value = PairResponse(
            initID: try reader.readData(count: initIDLength),
            initHash: try reader.readData(count: keyLength),
            responderDeviceEd25519PublicKey: try reader.readData(count: keyLength),
            createdAtMs: try reader.readUInt64(),
            expiresAtMs: try reader.readUInt64(),
            confirmationTag: try reader.readData(count: keyLength),
            signature: try reader.readData(count: signatureLength)
        )
        guard reader.isAtEnd else { throw PairInitError.invalidLength }
        try validateResponse(value, requireSignature: true)
        return value
    }

    private static func responsePrefix(_ value: PairResponse) throws -> Data {
        try validateResponse(value, requireSignature: false)
        var result = Data(capacity: responseSignedPrefixLength)
        result.append(responseMagic)
        result.append(version)
        result.append(suite)
        result.append(responderRole)
        result.append(UInt8(profile.count))
        result.append(profile)
        result.append(value.initID)
        result.append(value.initHash)
        result.append(value.responderDeviceEd25519PublicKey)
        appendUInt64(value.createdAtMs, to: &result)
        appendUInt64(value.expiresAtMs, to: &result)
        result.append(value.confirmationTag)
        guard result.count == responseSignedPrefixLength else {
            throw PairInitError.invalidLength
        }
        return result
    }

    private static func validateResponse(_ value: PairResponse, requireSignature: Bool) throws {
        try requireLength(value.initID, initIDLength)
        try requireLength(value.initHash, keyLength)
        try requireLength(value.responderDeviceEd25519PublicKey, keyLength)
        try requireLength(value.confirmationTag, keyLength)
        guard !isAllZero(value.initID),
              !isAllZero(value.initHash),
              !isAllZero(value.responderDeviceEd25519PublicKey),
              !isAllZero(value.confirmationTag) else {
            throw PairInitError.allZeroField
        }
        guard value.expiresAtMs > value.createdAtMs else {
            throw PairInitError.invalidTime
        }
        if requireSignature {
            try requireLength(value.signature, signatureLength)
        }
    }

    // MARK: - Transcript hashes and provisional root

    static func initHash(_ value: PairInit) throws -> Data {
        sha256(parts: [initSigningDomain, try encodeInit(value)])
    }

    static func sessionID(_ value: PairInit) throws -> Data {
        sessionID(initHash: try initHash(value))
    }

    static func sessionID(initHash: Data) -> Data {
        sha256(parts: [sessionIDDomain, initHash])
    }

    static func transcriptMaterial(_ value: PairInit) throws -> Data {
        var material = initSigningDomain
        material.append(try encodeInit(value))
        return material
    }

    static func transcriptHash(_ value: PairInit) throws -> Data {
        sha256(parts: [transcriptDomain, try transcriptMaterial(value)])
    }

    /// Derives only after the complete signed PairInit exists. The actual
    /// X25519/ML-KEM operations and secret lifetimes remain outside this
    /// production-disabled codec slice.
    static func deriveProvisionalRoot(
        zX: Data,
        zPQ: Data,
        pairInit: PairInit
    ) throws -> Data {
        guard zX.count == keyLength, zPQ.count == keyLength else {
            throw PairInitError.invalidSharedSecretLength
        }
        guard !isAllZero(zX) else { throw PairInitError.nonContributoryX25519 }
        let digest = try transcriptHash(pairInit)
        var ikm = zX
        ikm.append(zPQ)
        var info = pairInitLabel
        info.append(digest)
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: digest,
            info: info,
            outputByteCount: keyLength
        )
        return key.withUnsafeBytes { Data($0) }
    }

    // MARK: - Exact trust-record binding and PairInit verification

    static func deviceCertificateHash(_ certificate: SignedDeviceCertificate) throws -> Data {
        guard certificate.identityEd25519PublicKey.count == keyLength,
              !certificate.signingBytes.isEmpty,
              certificate.signature.count == signatureLength else {
            throw PairInitError.trustEncoding
        }
        return sha256(parts: [
            deviceCertificateHashDomain,
            certificate.identityEd25519PublicKey,
            certificate.signingBytes,
            certificate.signature,
        ])
    }

    /// Re-verifies an exact PairInit-bound certificate at endpoint receive
    /// time. This prevents detached caller-supplied device/digest projections
    /// from bypassing the identity signature or certificate validity window.
    static func verifyBoundDeviceCertificate(
        _ certificate: SignedDeviceCertificate,
        expectedCertificateHash: Data,
        expectedDeviceEd25519PublicKey: Data,
        expectedIdentityAddress: String,
        nowMs: UInt64
    ) throws -> ValidatedDeviceCertificate {
        let parsed = try validatedCertificate(certificate, nowMs: nowMs)
        let actualHash = try deviceCertificateHash(certificate)
        guard expectedCertificateHash.count == keyLength,
              expectedDeviceEd25519PublicKey.count == keyLength,
              actualHash == expectedCertificateHash,
              parsed.deviceEd25519PublicKey == expectedDeviceEd25519PublicKey else {
            throw PairInitError.certificateMismatch
        }
        guard RavenAddressV1.encode(
            ed25519PublicKey: certificate.identityEd25519PublicKey
        ) == expectedIdentityAddress else {
            throw PairInitError.identityMismatch
        }
        return ValidatedDeviceCertificate(
            identityEd25519PublicKey: certificate.identityEd25519PublicKey,
            deviceEd25519PublicKey: parsed.deviceEd25519PublicKey,
            certificateHash: actualHash,
            notBeforeMs: parsed.notBeforeMs,
            notAfterMs: parsed.notAfterMs
        )
    }

    static func prekeyBundleHash(_ bundle: SignedPrekeyBundle) throws -> Data {
        guard !bundle.signingBytes.isEmpty,
              bundle.signature.count == signatureLength else {
            throw PairInitError.trustEncoding
        }
        return sha256(parts: [prekeyBundleHashDomain, bundle.signingBytes, bundle.signature])
    }

    static func verifyInit(
        _ value: PairInit,
        trust: TrustContext,
        nowMs: UInt64
    ) throws {
        try validateInit(value, requireSignature: true)
        guard !trust.initiatorRevoked, !trust.responderRevoked else {
            throw PairInitError.revokedDevice
        }

        let initiatorCertificate: ParsedDeviceCertificate
        let responderCertificate: ParsedDeviceCertificate
        do {
            initiatorCertificate = try validatedCertificate(
                trust.initiatorCertificate,
                nowMs: nowMs
            )
            responderCertificate = try validatedCertificate(
                trust.responderCertificate,
                nowMs: nowMs
            )
        } catch {
            throw PairInitError.certificateMismatch
        }

        let responderPrekey: ParsedPrekeyBundle
        do {
            responderPrekey = try validatedPrekeyBundle(
                trust.responderPrekeyBundle,
                nowMs: nowMs
            )
        } catch {
            throw PairInitError.prekeyMismatch
        }

        guard RavenAddressV1.encode(
            ed25519PublicKey: trust.initiatorCertificate.identityEd25519PublicKey
        ) == value.initiatorAddress,
        RavenAddressV1.encode(
            ed25519PublicKey: trust.responderCertificate.identityEd25519PublicKey
        ) == value.responderAddress else {
            throw PairInitError.identityMismatch
        }

        guard initiatorCertificate.deviceEd25519PublicKey
                == value.initiatorDeviceEd25519PublicKey,
              responderCertificate.deviceEd25519PublicKey
                == value.responderDeviceEd25519PublicKey,
              try deviceCertificateHash(trust.initiatorCertificate)
                == value.initiatorDeviceCertificateHash,
              try deviceCertificateHash(trust.responderCertificate)
                == value.responderDeviceCertificateHash else {
            throw PairInitError.certificateMismatch
        }

        let expectedOneTimeKey = responderPrekey.oneTimeX25519PublicKey
            ?? Data(repeating: 0, count: keyLength)
        guard responderPrekey.identityEd25519PublicKey
                == trust.responderCertificate.identityEd25519PublicKey,
              responderPrekey.deviceID == responderCertificate.deviceID,
              responderPrekey.signedX25519PublicKey
                == value.responderSignedX25519PublicKey,
              responderPrekey.signedPrekeyID == value.signedPrekeyID,
              responderPrekey.oneTimePrekeyID == value.oneTimePrekeyID,
              expectedOneTimeKey == value.responderOneTimeX25519PublicKey,
              responderPrekey.mlKem768EncapsulationKey
                == value.responderMLKem768EncapsulationKey,
              try prekeyBundleHash(trust.responderPrekeyBundle)
                == value.responderPrekeyBundleHash else {
            throw PairInitError.prekeyMismatch
        }

        let trustNotBefore = max(
            initiatorCertificate.notBeforeMs,
            responderCertificate.notBeforeMs,
            responderPrekey.createdAtMs
        )
        let trustNotAfter = min(
            initiatorCertificate.notAfterMs,
            responderCertificate.notAfterMs,
            responderPrekey.expiresAtMs
        )
        guard value.createdAtMs >= trustNotBefore,
              value.expiresAtMs <= trustNotAfter else {
            throw PairInitError.trustWindowMismatch
        }
        guard nowMs >= value.createdAtMs, nowMs < value.expiresAtMs else {
            throw PairInitError.notCurrentlyValid
        }
        guard verifyEd25519(
            signature: value.signature,
            message: try initSigningBytes(value),
            publicKey: value.initiatorDeviceEd25519PublicKey
        ) else {
            throw PairInitError.badSignature
        }
    }

    // MARK: - Deferred confirmation

    static func confirmationTag(root: Data, initHash: Data) throws -> Data {
        guard root.count == keyLength, initHash.count == keyLength else {
            throw PairInitError.invalidSharedSecretLength
        }
        var material = confirmationLabel
        material.append(0)
        material.append(initHash)
        return Data(HMAC<SHA256>.authenticationCode(
            for: material,
            using: SymmetricKey(data: root)
        ))
    }

    static func verifyResponse(
        _ value: PairResponse,
        acceptedInit: PairInit,
        root: Data,
        nowMs: UInt64
    ) throws {
        try validateResponse(value, requireSignature: true)
        guard root.count == keyLength else { throw PairInitError.invalidSharedSecretLength }
        let digest = try initHash(acceptedInit)
        guard value.initID == acceptedInit.initID,
              value.initHash == digest,
              value.responderDeviceEd25519PublicKey
                == acceptedInit.responderDeviceEd25519PublicKey,
              value.createdAtMs >= acceptedInit.createdAtMs,
              value.createdAtMs < acceptedInit.expiresAtMs,
              value.expiresAtMs <= acceptedInit.expiresAtMs,
              nowMs >= value.createdAtMs,
              nowMs < value.expiresAtMs else {
            throw PairInitError.confirmationMismatch
        }

        var confirmationMaterial = confirmationLabel
        confirmationMaterial.append(0)
        confirmationMaterial.append(digest)
        guard HMAC<SHA256>.isValidAuthenticationCode(
            value.confirmationTag,
            authenticating: confirmationMaterial,
            using: SymmetricKey(data: root)
        ) else {
            throw PairInitError.confirmationMismatch
        }
        guard verifyEd25519(
            signature: value.signature,
            message: try responseSigningBytes(value),
            publicKey: value.responderDeviceEd25519PublicKey
        ) else {
            throw PairInitError.badSignature
        }
    }

    // MARK: - Canonical trust-record parsing

    private struct ParsedDeviceCertificate {
        let deviceEd25519PublicKey: Data
        let deviceX25519PublicKey: Data
        let deviceID: String
        let notBeforeMs: UInt64
        let notAfterMs: UInt64
        let capabilities: UInt64
    }

    private struct ParsedPrekeyBundle {
        let identityEd25519PublicKey: Data
        let deviceID: String
        let signedX25519PublicKey: Data
        let mlKem768EncapsulationKey: Data
        let signedPrekeyID: UInt32
        let oneTimePrekeyID: UInt32
        let oneTimeX25519PublicKey: Data?
        let createdAtMs: UInt64
        let expiresAtMs: UInt64
    }

    private static func validatedCertificate(
        _ certificate: SignedDeviceCertificate,
        nowMs: UInt64
    ) throws -> ParsedDeviceCertificate {
        guard certificate.identityEd25519PublicKey.count == keyLength,
              certificate.signature.count == signatureLength else {
            throw PairInitError.trustEncoding
        }
        let parsed = try parseDeviceCertificate(certificate.signingBytes)
        guard nowMs >= parsed.notBeforeMs, nowMs <= parsed.notAfterMs else {
            throw PairInitError.invalidTime
        }
        guard verifyEd25519(
            signature: certificate.signature,
            message: certificate.signingBytes,
            publicKey: certificate.identityEd25519PublicKey
        ) else {
            throw PairInitError.badSignature
        }
        return parsed
    }

    private static func parseDeviceCertificate(_ signingBytes: Data) throws
        -> ParsedDeviceCertificate {
        var reader = WireReader(signingBytes)
        guard try reader.readData(count: deviceCertificateDomain.count)
                == deviceCertificateDomain else {
            throw PairInitError.trustEncoding
        }
        guard try reader.readUInt16() == UInt16(keyLength) else {
            throw PairInitError.trustEncoding
        }
        let deviceEd = try reader.readData(count: keyLength)
        guard try reader.readUInt16() == UInt16(keyLength) else {
            throw PairInitError.trustEncoding
        }
        let deviceX = try reader.readData(count: keyLength)
        let deviceIDLength = Int(try reader.readUInt16())
        guard deviceIDLength > 0 else { throw PairInitError.trustEncoding }
        let deviceID = try reader.readUTF8(count: deviceIDLength)
        let notBefore = try reader.readUInt64()
        let notAfter = try reader.readUInt64()
        let capabilities = try reader.readUInt64()
        guard reader.isAtEnd, notAfter >= notBefore else {
            throw PairInitError.trustEncoding
        }
        return ParsedDeviceCertificate(
            deviceEd25519PublicKey: deviceEd,
            deviceX25519PublicKey: deviceX,
            deviceID: deviceID,
            notBeforeMs: notBefore,
            notAfterMs: notAfter,
            capabilities: capabilities
        )
    }

    private static func validatedPrekeyBundle(
        _ bundle: SignedPrekeyBundle,
        nowMs: UInt64
    ) throws -> ParsedPrekeyBundle {
        guard bundle.signature.count == signatureLength else {
            throw PairInitError.trustEncoding
        }
        let parsed = try parsePrekeyBundle(bundle.signingBytes)
        guard parsed.expiresAtMs > parsed.createdAtMs else {
            throw PairInitError.invalidTime
        }
        guard saturatingAdd(nowMs, prekeyClockSkewMs) >= parsed.createdAtMs,
              nowMs <= saturatingAdd(parsed.expiresAtMs, prekeyClockSkewMs),
              !isAllZero(parsed.mlKem768EncapsulationKey) else {
            throw PairInitError.invalidTime
        }
        guard verifyEd25519(
            signature: bundle.signature,
            message: bundle.signingBytes,
            publicKey: parsed.identityEd25519PublicKey
        ) else {
            throw PairInitError.badSignature
        }
        return parsed
    }

    private static func parsePrekeyBundle(_ signingBytes: Data) throws -> ParsedPrekeyBundle {
        var reader = WireReader(signingBytes)
        guard try reader.readData(count: prekeyDomain.count) == prekeyDomain,
              try reader.readUInt8() == version else {
            throw PairInitError.trustEncoding
        }
        let identity = try reader.readData(count: keyLength)
        let deviceIDLength = Int(try reader.readUInt16())
        guard (1...64).contains(deviceIDLength) else {
            throw PairInitError.trustEncoding
        }
        let deviceID = try reader.readUTF8(count: deviceIDLength)
        let signedX = try reader.readData(count: keyLength)
        let mlKemKey = try reader.readData(count: mlKem768EncapsulationKeyLength)
        let signedPrekeyID = try reader.readUInt32()
        let oneTimePrekeyID = try reader.readUInt32()
        let oneTimeKey = oneTimePrekeyID == 0
            ? nil
            : try reader.readData(count: keyLength)
        let createdAt = try reader.readUInt64()
        let expiresAt = try reader.readUInt64()
        guard reader.isAtEnd else { throw PairInitError.trustEncoding }
        return ParsedPrekeyBundle(
            identityEd25519PublicKey: identity,
            deviceID: deviceID,
            signedX25519PublicKey: signedX,
            mlKem768EncapsulationKey: mlKemKey,
            signedPrekeyID: signedPrekeyID,
            oneTimePrekeyID: oneTimePrekeyID,
            oneTimeX25519PublicKey: oneTimeKey,
            createdAtMs: createdAt,
            expiresAtMs: expiresAt
        )
    }

    // MARK: - Small byte helpers

    private struct WireReader {
        private let data: Data
        private(set) var offset: Int

        init(_ data: Data, offset: Int = 0) {
            self.data = data
            self.offset = offset
        }

        var isAtEnd: Bool { offset == data.count }

        mutating func readData(count: Int) throws -> Data {
            guard count >= 0, offset >= 0, offset <= data.count,
                  count <= data.count - offset else {
                throw PairInitError.invalidLength
            }
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }

        mutating func readASCII(count: Int) throws -> String {
            let raw = try readData(count: count)
            guard raw.allSatisfy({ $0 < 0x80 }),
                  let value = String(data: raw, encoding: .ascii),
                  Data(value.utf8) == raw else {
                throw PairInitError.invalidAddress
            }
            return value
        }

        mutating func readUTF8(count: Int) throws -> String {
            let raw = try readData(count: count)
            guard let value = String(data: raw, encoding: .utf8),
                  Data(value.utf8) == raw else {
                throw PairInitError.trustEncoding
            }
            return value
        }

        mutating func readUInt8() throws -> UInt8 {
            try readData(count: 1)[0]
        }

        mutating func readUInt16() throws -> UInt16 {
            var value: UInt16 = 0
            for byte in try readData(count: 2) {
                value = (value << 8) | UInt16(byte)
            }
            return value
        }

        mutating func readUInt32() throws -> UInt32 {
            var value: UInt32 = 0
            for byte in try readData(count: 4) {
                value = (value << 8) | UInt32(byte)
            }
            return value
        }

        mutating func readUInt64() throws -> UInt64 {
            var value: UInt64 = 0
            for byte in try readData(count: 8) {
                value = (value << 8) | UInt64(byte)
            }
            return value
        }
    }

    private static func validateAddress(_ value: String) throws {
        guard value.utf8.count == addressLength,
              value.utf8.allSatisfy({ $0 < 0x80 }) else {
            throw PairInitError.invalidAddress
        }
        do {
            _ = try ATSAMIndexedSessionProfile.requireCanonicalAddress(value)
        } catch {
            throw PairInitError.invalidAddress
        }
    }

    private static func requireLength(_ value: Data, _ expected: Int) throws {
        guard value.count == expected else { throw PairInitError.invalidLength }
    }

    private static func isAllZero(_ value: Data) -> Bool {
        value.allSatisfy { $0 == 0 }
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }

    private static func sha256(parts: [Data]) -> Data {
        var hasher = SHA256()
        for part in parts { hasher.update(data: part) }
        return Data(hasher.finalize())
    }

    private static func verifyEd25519(
        signature: Data,
        message: Data,
        publicKey: Data
    ) -> Bool {
        guard signature.count == signatureLength,
              publicKey.count == keyLength,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            return false
        }
        return key.isValidSignature(signature, for: message)
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }
}
