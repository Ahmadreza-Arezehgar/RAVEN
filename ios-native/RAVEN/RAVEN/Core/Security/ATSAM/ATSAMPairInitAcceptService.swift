//
//  ATSAMPairInitAcceptService.swift
//  RAVEN — PairInit Accept → ML-KEM decap → PairResponse LAN uplink (Test A).
//

import CryptoKit
import Foundation

@MainActor
enum ATSAMPairInitAcceptService {

    enum AcceptError: Error, LocalizedError {
        case gateClosed
        case decodeFailed
        case trustFailed(String)
        case hybridFailed(String)
        case signFailed
        case uplinkFailed(String)
        case identityMissing

        var errorDescription: String? {
            switch self {
            case .gateClosed: return "Lab PairInit gate closed"
            case .decodeFailed: return "Invalid PairInit wire"
            case .trustFailed(let s): return "Trust: \(s)"
            case .hybridFailed(let s): return "Hybrid: \(s)"
            case .signFailed: return "Could not sign PairResponse"
            case .uplinkFailed(let s): return "PairResponse uplink: \(s)"
            case .identityMissing: return "Local signing key missing"
            }
        }
    }

    /// Complete Accept: verify → decap → durable session → signed PairResponse → LAN reverse.
    static func accept(pairInitWire: Data) async throws {
        guard ATSAMPairInitV1.productionEnabled else { throw AcceptError.gateClosed }
        TestATrace.emit(
            location: "ATSAMPairInitAcceptService.accept",
            message: "TRACE_PAIR_INIT_ACCEPT_BEGIN",
            status: "VERIFYING",
            detail: "wire=\(pairInitWire.count)"
        )

        let initValue = try ATSAMPairInitV1.decodeInit(pairInitWire)
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)

        let localCert = try ATSAMLabTrustStore.localCertificate()
        let localPrekey = try ATSAMLabTrustStore.localSignedPrekey()
        let secrets = try ATSAMLabTrustStore.localHybridSecrets()

        // Lab certs bind identity_ed == device_ed; PairInit carries device ed.
        let initiatorCert: ATSAMPairInitV1.SignedDeviceCertificate
        do {
            initiatorCert = try ATSAMLabTrustStore.peerCertificate(
                forDeviceEd: initValue.initiatorDeviceEd25519PublicKey
            )
        } catch {
            do {
                initiatorCert = try ATSAMLabTrustStore.peerCertificate(
                    forIdentityPub: initValue.initiatorDeviceEd25519PublicKey
                )
            } catch {
                throw AcceptError.trustFailed(
                    "import Mac cert JSON first (\(error.localizedDescription))"
                )
            }
        }

        let trust = ATSAMPairInitV1.TrustContext(
            initiatorCertificate: initiatorCert,
            responderCertificate: localCert,
            responderPrekeyBundle: localPrekey
        )
        do {
            try ATSAMPairInitV1.verifyInit(initValue, trust: trust, nowMs: nowMs)
        } catch {
            throw AcceptError.trustFailed(String(describing: error))
        }

        // Hybrid respond: X25519(sk_prekey, eph_pub) + ML-KEM.Decap(ct)
        let selectedXSecret: Data
        if initValue.oneTimePrekeyID != 0 {
            throw AcceptError.hybridFailed("OTP prekeys not supported in lab slice")
        } else {
            selectedXSecret = secrets.xSecret
        }
        let zX: Data
        let zPQ: Data
        do {
            let ourX = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: selectedXSecret)
            let peerX = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: initValue.initiatorEphemeralX25519PublicKey
            )
            let shared = try ourX.sharedSecretFromKeyAgreement(with: peerX)
            zX = shared.withUnsafeBytes { Data($0) }
            guard !zX.allSatisfy({ $0 == 0 }) else {
                throw AcceptError.hybridFailed("non-contributory X25519")
            }
            zPQ = try ATSAMMLKem.decapsulate(
                ciphertext: initValue.mlKem768Ciphertext,
                privateKey: secrets.mlkemSeed
            )
        } catch let e as AcceptError {
            throw e
        } catch {
            throw AcceptError.hybridFailed(String(describing: error))
        }

        let root = try ATSAMPairInitV1.deriveProvisionalRoot(
            zX: zX,
            zPQ: zPQ,
            pairInit: initValue
        )
        let initHash = try ATSAMPairInitV1.initHash(initValue)
        let sessionID = try ATSAMPairInitV1.sessionID(initValue)
        let confirm = try ATSAMPairInitV1.confirmationTag(root: root, initHash: initHash)

        let response = ATSAMPairInitV1.PairResponse(
            initID: initValue.initID,
            initHash: initHash,
            responderDeviceEd25519PublicKey: initValue.responderDeviceEd25519PublicKey,
            createdAtMs: nowMs,
            expiresAtMs: min(initValue.expiresAtMs, nowMs &+ 24 * 3600 * 1_000),
            confirmationTag: confirm,
            signature: Data(repeating: 0, count: 64)
        )
        let signingBytes = try ATSAMPairInitV1.responseSigningBytes(response)
        guard let signature = DeviceIdentityService.shared.sign(signingBytes),
              signature.count == 64 else {
            throw AcceptError.signFailed
        }
        let signedResponse = ATSAMPairInitV1.PairResponse(
            initID: response.initID,
            initHash: response.initHash,
            responderDeviceEd25519PublicKey: response.responderDeviceEd25519PublicKey,
            createdAtMs: response.createdAtMs,
            expiresAtMs: response.expiresAtMs,
            confirmationTag: response.confirmationTag,
            signature: signature
        )
        try ATSAMPairInitV1.verifyResponse(
            signedResponse,
            acceptedInit: initValue,
            root: root,
            nowMs: nowMs &+ 1
        )
        let responseWire = try ATSAMPairInitV1.encodeResponse(signedResponse)

        // Durable session commit BEFORE UI / uplink.
        try await ATSAMLabEndpointHost.shared.installResponderSession(
            initValue: initValue,
            root: root,
            sessionID: sessionID,
            initiatorCertificate: initiatorCert,
            nowMs: nowMs
        )

        TestATrace.emit(
            location: "ATSAMPairInitAcceptService.accept",
            message: "TRACE_PAIR_RESPONSE_BUILT",
            status: "SESSION_INSTALLED",
            detail: "sid=\(sessionID.prefix(4).map { String(format: "%02x", $0) }.joined())"
        )

        try await uplinkPairResponse(responseWire: responseWire)

        TestATrace.emit(
            location: "ATSAMPairInitAcceptService.accept",
            message: "TRACE_PAIR_RESPONSE_UPLINKED",
            status: "WAITING_FOR_INDEXED_MESSAGE",
            detail: "rvpr1=\(responseWire.count)"
        )
    }

    private static func uplinkPairResponse(responseWire: Data) async throws {
        guard let seed = DeviceIdentityService.shared.deviceSigningSeed else {
            throw AcceptError.identityMissing
        }
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let packed = try RavenPairInitLanOob.wrapOobWire(
            responseWire,
            isPairInit: false,
            signingKey: signingKey
        )
        guard let lan = RavenServerlessLanConfig.stored else {
            throw AcceptError.uplinkFailed("LAN config missing — Save Mac host/port first")
        }
        do {
            try await RavenServerlessLanPath.sendPackedFireAndForget(
                packed,
                host: lan.host,
                port: lan.port
            )
        } catch {
            throw AcceptError.uplinkFailed(error.localizedDescription)
        }
    }

    }

enum TestATrace {
    static func emit(
        location: String,
        message: String,
        status: String,
        detail: String?
    ) {
        #if DEBUG
        var data: [String: Any] = [
            "status": status,
        ]
        if let detail { data["detail"] = detail }
        let payload: [String: Any] = [
            "sessionId": "532d3b",
            "runId": "test-a-accept",
            "hypothesisId": "TRACE",
            "location": location,
            "message": message,
            "data": data,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        ]
        if let raw = try? JSONSerialization.data(withJSONObject: payload),
           let line = String(data: raw, encoding: .utf8) {
            print(line)
        }
        #endif
    }
}
