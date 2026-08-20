//
//  ATSAMLabPairInitBuilder.swift
//  RAVEN — DEBUG lab initiator PairInit wire builder (Test A only).
//

import CryptoKit
import Foundation

@MainActor
enum ATSAMLabPairInitBuilder {

    enum BuildError: Error, LocalizedError {
        case gateClosed
        case identityMissing
        case peerCertMissing
        case peerPrekeyMissing
        case addressMissing
        case mlkemFailed(String)
        case signFailed

        var errorDescription: String? {
            switch self {
            case .gateClosed: return "Lab PairInit builder gate closed"
            case .identityMissing: return "Local signing key missing"
            case .peerCertMissing: return "Peer device cert missing — import Mac cert JSON"
            case .peerPrekeyMissing: return "Peer prekey missing — paste Mac prekey JSON"
            case .addressMissing: return "Raven address missing"
            case .mlkemFailed(let s): return "ML-KEM: \(s)"
            case .signFailed: return "Could not sign PairInit"
            }
        }
    }

    /// Build PairInit from an in-session RLB1 offer (responder cert + prekey wire).
    static func buildPackedPairInit(
        responderBundle: RavenSecureLanRlb1V1.LanBundle,
        nowMs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000)
    ) throws -> (wire: Data, packed: Data, root: Data) {
        let responderCert = pairInitCertificate(from: responderBundle.cert)
        let responderPrekey = pairInitPrekey(from: responderBundle.prekey)
        let responderFields = ATSAMLabTrustStore.LabCertFields(
            deviceEd: responderBundle.cert.deviceEdPub,
            deviceX: responderBundle.cert.deviceXPub,
            deviceID: responderBundle.cert.deviceID,
            notBefore: responderBundle.cert.notBeforeMs,
            notAfter: responderBundle.cert.notAfterMs,
            capabilities: responderBundle.cert.capabilities
        )
        let prekeyFields = ATSAMLabTrustStore.LabPrekeyFields(
            identity: responderBundle.prekey.identityEd25519Pub,
            deviceID: responderBundle.prekey.deviceID,
            xPub: responderBundle.prekey.x25519Pub,
            mlkemEK: responderBundle.prekey.mlkem768EK,
            signedPrekeyID: responderBundle.prekey.signedPrekeyID,
            oneTimePrekeyID: responderBundle.prekey.oneTimePrekeyID,
            oneTimeX: responderBundle.prekey.oneTimeX25519Pub,
            createdAt: responderBundle.prekey.createdAtMs,
            expiresAt: responderBundle.prekey.expiresAtMs
        )
        return try buildPackedPairInit(
            responderCert: responderCert,
            responderPrekey: responderPrekey,
            responderFields: responderFields,
            prekeyFields: prekeyFields,
            nowMs: nowMs
        )
    }

    /// Build signed RVPI1 wire + packed OOB envelope for secure LAN dial.
    static func buildPackedPairInit(
        peerDeviceEd: Data,
        nowMs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000)
    ) throws -> (wire: Data, packed: Data, root: Data) {
        guard ATSAMPairInitV1.productionEnabled else { throw BuildError.gateClosed }
        let responderCert = try ATSAMLabTrustStore.peerCertificate(forDeviceEd: peerDeviceEd)
        let responderFields = try ATSAMLabTrustStore.labCertFields(responderCert)
        let responderPrekey = try ATSAMLabTrustStore.peerSignedPrekey(forDeviceEd: peerDeviceEd)
        let prekeyFields = try ATSAMLabTrustStore.labPrekeyFields(responderPrekey)
        return try buildPackedPairInit(
            responderCert: responderCert,
            responderPrekey: responderPrekey,
            responderFields: responderFields,
            prekeyFields: prekeyFields,
            nowMs: nowMs
        )
    }

    private static func buildPackedPairInit(
        responderCert: ATSAMPairInitV1.SignedDeviceCertificate,
        responderPrekey: ATSAMPairInitV1.SignedPrekeyBundle,
        responderFields: ATSAMLabTrustStore.LabCertFields,
        prekeyFields: ATSAMLabTrustStore.LabPrekeyFields,
        nowMs: UInt64
    ) throws -> (wire: Data, packed: Data, root: Data) {
        guard ATSAMPairInitV1.productionEnabled else { throw BuildError.gateClosed }
        guard let idPub = DeviceIdentityService.shared.publicKeyData,
              let seed = DeviceIdentityService.shared.deviceSigningSeed else {
            throw BuildError.identityMissing
        }
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let localCert = try ATSAMLabTrustStore.localCertificate()
        let localCertFields = try ATSAMLabTrustStore.labCertFields(localCert)
        let initiatorAddress = try RavenAddressV1.encode(ed25519PublicKey: idPub)
            ?? { throw BuildError.addressMissing }()
        guard let responderAddress = try RavenAddressV1.encode(
            ed25519PublicKey: responderCert.identityEd25519PublicKey
        ) else {
            throw BuildError.addressMissing
        }

        let ephemeralX = Curve25519.KeyAgreement.PrivateKey()
        let encap = try ATSAMMLKem.encapsulate(publicKey: prekeyFields.mlkemEK)

        var initID = Data(count: 16)
        initID.withUnsafeMutableBytes { buf in
            _ = SecRandomCopyBytes(kSecRandomDefault, 16, buf.baseAddress!)
        }
        var pairingNonce = Data(count: 32)
        pairingNonce.withUnsafeMutableBytes { buf in
            _ = SecRandomCopyBytes(kSecRandomDefault, 32, buf.baseAddress!)
        }

        let oneTimeX = prekeyFields.oneTimePrekeyID != 0
            ? (prekeyFields.oneTimeX ?? Data(repeating: 0, count: 32))
            : Data(repeating: 0, count: 32)

        let expiresAtMs = nowMs &+ 24 * 3600 * 1_000
        var unsigned = ATSAMPairInitV1.PairInit(
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            initID: initID,
            pairingNonce: pairingNonce,
            initiatorDeviceEd25519PublicKey: localCertFields.deviceEd,
            responderDeviceEd25519PublicKey: responderFields.deviceEd,
            initiatorEphemeralX25519PublicKey: ephemeralX.publicKey.rawRepresentation,
            responderSignedX25519PublicKey: prekeyFields.xPub,
            responderOneTimeX25519PublicKey: oneTimeX,
            initiatorDeviceCertificateHash: try ATSAMPairInitV1.deviceCertificateHash(localCert),
            responderDeviceCertificateHash: try ATSAMPairInitV1.deviceCertificateHash(responderCert),
            responderPrekeyBundleHash: try ATSAMPairInitV1.prekeyBundleHash(responderPrekey),
            signedPrekeyID: prekeyFields.signedPrekeyID,
            oneTimePrekeyID: prekeyFields.oneTimePrekeyID,
            responderMLKem768EncapsulationKey: prekeyFields.mlkemEK,
            mlKem768Ciphertext: encap.ciphertext,
            createdAtMs: nowMs,
            expiresAtMs: expiresAtMs,
            signature: Data(repeating: 0, count: 64)
        )

        let signingBytes = try ATSAMPairInitV1.initSigningBytes(unsigned)
        let signature = try signingKey.signature(for: signingBytes)
        guard signature.count == 64 else { throw BuildError.signFailed }
        unsigned = ATSAMPairInitV1.PairInit(
            initiatorAddress: unsigned.initiatorAddress,
            responderAddress: unsigned.responderAddress,
            initID: unsigned.initID,
            pairingNonce: unsigned.pairingNonce,
            initiatorDeviceEd25519PublicKey: unsigned.initiatorDeviceEd25519PublicKey,
            responderDeviceEd25519PublicKey: unsigned.responderDeviceEd25519PublicKey,
            initiatorEphemeralX25519PublicKey: unsigned.initiatorEphemeralX25519PublicKey,
            responderSignedX25519PublicKey: unsigned.responderSignedX25519PublicKey,
            responderOneTimeX25519PublicKey: unsigned.responderOneTimeX25519PublicKey,
            initiatorDeviceCertificateHash: unsigned.initiatorDeviceCertificateHash,
            responderDeviceCertificateHash: unsigned.responderDeviceCertificateHash,
            responderPrekeyBundleHash: unsigned.responderPrekeyBundleHash,
            signedPrekeyID: unsigned.signedPrekeyID,
            oneTimePrekeyID: unsigned.oneTimePrekeyID,
            responderMLKem768EncapsulationKey: unsigned.responderMLKem768EncapsulationKey,
            mlKem768Ciphertext: unsigned.mlKem768Ciphertext,
            createdAtMs: unsigned.createdAtMs,
            expiresAtMs: unsigned.expiresAtMs,
            signature: Data(signature)
        )

        let zX = try ephemeralX.sharedSecretFromKeyAgreement(
            with: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: prekeyFields.xPub)
        ).withUnsafeBytes { Data($0) }
        let root = try ATSAMPairInitV1.deriveProvisionalRoot(
            zX: zX,
            zPQ: encap.sharedSecret,
            pairInit: unsigned
        )

        let wire = try ATSAMPairInitV1.encodeInit(unsigned)
        let packed = try RavenPairInitLanOob.wrapOobWire(
            wire,
            isPairInit: true,
            signingKey: signingKey
        )
        return (wire, packed, root)
    }

    static func pairInitCertificate(
        from cert: RavenSecureLanRlb1V1.LanDeviceCertificate
    ) -> ATSAMPairInitV1.SignedDeviceCertificate {
        var signing = Data("rvn1/devcert".utf8)
        signing.appendUInt16BE(UInt16(cert.deviceEdPub.count))
        signing.append(cert.deviceEdPub)
        signing.appendUInt16BE(UInt16(cert.deviceXPub.count))
        signing.append(cert.deviceXPub)
        let idBytes = Data(cert.deviceID.utf8)
        signing.appendUInt16BE(UInt16(idBytes.count))
        signing.append(idBytes)
        signing.appendUInt64BE(cert.notBeforeMs)
        signing.appendUInt64BE(cert.notAfterMs)
        signing.appendUInt64BE(cert.capabilities)
        return ATSAMPairInitV1.SignedDeviceCertificate(
            identityEd25519PublicKey: cert.userEdPub,
            signingBytes: signing,
            signature: cert.signature
        )
    }

    private static func pairInitPrekey(
        from prekey: RavenSecureLanRlb1V1.LanPrekeyBundle
    ) -> ATSAMPairInitV1.SignedPrekeyBundle {
        var signing = Data("rvn1/prekey".utf8)
        signing.append(prekey.version)
        signing.append(prekey.identityEd25519Pub)
        let idBytes = Data(prekey.deviceID.utf8)
        signing.appendUInt16BE(UInt16(idBytes.count))
        signing.append(idBytes)
        signing.append(prekey.x25519Pub)
        signing.append(prekey.mlkem768EK)
        signing.appendUInt32BE(prekey.signedPrekeyID)
        signing.appendUInt32BE(prekey.oneTimePrekeyID)
        if prekey.oneTimePrekeyID != 0, let otp = prekey.oneTimeX25519Pub {
            signing.append(otp)
        }
        signing.appendUInt64BE(prekey.createdAtMs)
        signing.appendUInt64BE(prekey.expiresAtMs)
        return ATSAMPairInitV1.SignedPrekeyBundle(signingBytes: signing, signature: prekey.signature)
    }
}
