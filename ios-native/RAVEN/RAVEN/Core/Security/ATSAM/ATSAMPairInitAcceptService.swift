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
        case contactGateClosed
        case trustFailed(String)
        case hybridFailed(String)
        case signFailed
        case cacheFailed(String)
        case claimFailed(String)
        case uplinkFailed(String)
        case identityMissing
        case injectedCrash(String)

        var errorDescription: String? {
            switch self {
            case .gateClosed: return "Lab PairInit gate closed"
            case .decodeFailed: return "Invalid PairInit wire"
            case .contactGateClosed: return "PairInit refused: peer is not a local contact"
            case .trustFailed(let s): return "Trust: \(s)"
            case .hybridFailed(let s): return "Hybrid: \(s)"
            case .signFailed: return "Could not sign PairResponse"
            case .cacheFailed(let s): return "PairResponse cache: \(s)"
            case .claimFailed(let s): return "Claim journal: \(s)"
            case .uplinkFailed(let s): return "PairResponse uplink: \(s)"
            case .identityMissing: return "Local signing key missing"
            case .injectedCrash(let label): return "Injected crash: \(label)"
            }
        }
    }

    struct AcceptTestVectorOverrides {
        let trust: ATSAMPairInitV1.TrustContext
        let root: Data
        let nowMs: UInt64
        let packedResponse: Data
        let responseWire: Data
        var skipContactGate: Bool = true
    }

    #if DEBUG
    enum AcceptFaultPoint: Equatable {
        case afterClaimBeforeCache
        case afterCacheBeforeConfirm
        case afterConfirmBeforeCompleteClaim
    }

    private static var injectedFault: AcceptFaultPoint?
    static var skipUplinkForTesting = false
    static var skipInstallSessionForTesting = false
    static var acceptTestVectorOverrides: AcceptTestVectorOverrides?

    static func injectFault(_ point: AcceptFaultPoint) {
        injectedFault = point
    }

    static func resetAcceptTestHooks() {
        injectedFault = nil
        skipUplinkForTesting = false
        skipInstallSessionForTesting = false
        acceptTestVectorOverrides = nil
    }

    private static func maybeFault(_ point: AcceptFaultPoint) throws {
        guard injectedFault == point else { return }
        injectedFault = nil
        throw AcceptError.injectedCrash(String(describing: point))
    }
    #endif

    /// How the responder returns PairResponse bytes to the initiator.
    enum PairResponseDelivery: Equatable {
        /// Return packed OOB bytes as cipher replies on the inbound Noise session (no new dial).
        case sameConnection
        /// Legacy lab path: uplink via a new secure dial (UI/inbox only).
        case dialUplink
    }

    /// Complete Accept: contact gate → claim → cache → verify → confirm → complete_claim → uplink.
    /// When `delivery` is `.sameConnection`, returns packed PairResponse OOB bytes for inline cipher replies.
    @discardableResult
    static func accept(
        pairInitWire: Data,
        delivery: PairResponseDelivery = .dialUplink
    ) async throws -> Data? {
        guard ATSAMPairInitV1.productionEnabled else { throw AcceptError.gateClosed }
        TestATrace.emit(
            location: "ATSAMPairInitAcceptService.accept",
            message: "TRACE_PAIR_INIT_ACCEPT_BEGIN",
            status: "VERIFYING",
            detail: "wire=\(pairInitWire.count)"
        )

        let initValue = try ATSAMPairInitV1.decodeInit(pairInitWire)
        #if DEBUG
        let testOverrides = acceptTestVectorOverrides
        #else
        let testOverrides: AcceptTestVectorOverrides? = nil
        #endif
        let nowMs = testOverrides?.nowMs ?? UInt64(Date().timeIntervalSince1970 * 1000)
        let localDeviceEd = initValue.responderDeviceEd25519PublicKey

        // §4.9 step 1 — contact gate before claims or lan_pair_response/*
        if testOverrides?.skipContactGate != true {
            guard ATSAMLabTrustStore.peerIsTrusted(deviceEd: initValue.initiatorDeviceEd25519PublicKey) else {
                throw AcceptError.contactGateClosed
            }
        }

        let trust: ATSAMPairInitV1.TrustContext
        let root: Data
        let initiatorCert: ATSAMPairInitV1.SignedDeviceCertificate
        if let overrides = testOverrides {
            trust = overrides.trust
            root = overrides.root
            initiatorCert = overrides.trust.initiatorCertificate
        } else {
            let localCert = try ATSAMLabTrustStore.localCertificate()
            let localPrekey = try ATSAMLabTrustStore.localSignedPrekey()
            let secrets = try ATSAMLabTrustStore.localHybridSecrets()

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

            trust = ATSAMPairInitV1.TrustContext(
                initiatorCertificate: initiatorCert,
                responderCertificate: localCert,
                responderPrekeyBundle: localPrekey
            )
            root = try deriveRoot(initValue: initValue, secrets: secrets)
        }
        do {
            try ATSAMPairInitV1.verifyInit(initValue, trust: trust, nowMs: nowMs)
        } catch {
            throw AcceptError.trustFailed(String(describing: error))
        }
        if let cachedPacked = try? ATSAMPairResponseCache.loadVerified(
            initValue: initValue,
            localDeviceEd: localDeviceEd
        ) {
            return try await replayCachedAccept(
                pairInitWire: pairInitWire,
                initValue: initValue,
                trust: trust,
                initiatorCert: initiatorCert,
                cachedPacked: cachedPacked,
                root: root,
                nowMs: nowMs,
                delivery: delivery
            )
        }

        let claimOutcome: ATSAMPrekeyLifecycleStore.PrekeyClaimOutcome
        do {
            claimOutcome = try ATSAMPrekeyLifecycleStore.shared.claimPairInit(
                pairInitWire: pairInitWire,
                initValue: initValue,
                trust: trust,
                root: root,
                nowMs: nowMs
            )
        } catch {
            throw AcceptError.claimFailed(String(describing: error))
        }

        switch claimOutcome {
        case .duplicateCompleted:
            if let cached = try? ATSAMPairResponseCache.loadVerified(
                initValue: initValue,
                localDeviceEd: localDeviceEd
            ) {
                return try await replayCachedAccept(
                    pairInitWire: pairInitWire,
                    initValue: initValue,
                    trust: trust,
                    initiatorCert: initiatorCert,
                    cachedPacked: cached,
                    root: root,
                    nowMs: nowMs,
                    delivery: delivery
                )
            }
            throw AcceptError.cacheFailed("pair response unavailable for retry")
        case .duplicateAbandoned:
            throw AcceptError.claimFailed("pair init claim abandoned")
        case .accepted(var claim), .duplicatePending(var claim):
            let sessionID = claim.sessionID
            let claimID = claim.claimID
            _ = claim.takeProvisionalRoot()

            #if DEBUG
            try maybeFault(.afterClaimBeforeCache)
            #endif

            let responseWire: Data
            let packed: Data
            #if DEBUG
            if let overrides = testOverrides {
                responseWire = overrides.responseWire
                packed = overrides.packedResponse
            } else {
                (responseWire, packed) = try buildSignedResponse(
                    initValue: initValue,
                    root: root,
                    nowMs: nowMs
                )
            }
            #else
            (responseWire, packed) = try buildSignedResponse(
                initValue: initValue,
                root: root,
                nowMs: nowMs
            )
            #endif

            // Cache BEFORE confirm; re-read+verify before durable session commit.
            do {
                try ATSAMPairResponseCache.store(initID: initValue.initID, packed: packed)
                let verified = try ATSAMPairResponseCache.loadVerified(
                    initValue: initValue,
                    localDeviceEd: localDeviceEd
                )
                guard verified == packed else {
                    throw AcceptError.cacheFailed("cache verify mismatch after store")
                }
            } catch let error as AcceptError {
                throw error
            } catch {
                throw AcceptError.cacheFailed(String(describing: error))
            }

            #if DEBUG
            try maybeFault(.afterCacheBeforeConfirm)
            #endif

            #if DEBUG
            let skipInstallSession = skipInstallSessionForTesting
            #else
            let skipInstallSession = false
            #endif
            if !skipInstallSession {
                try await ATSAMLabEndpointHost.shared.installResponderSession(
                    initValue: initValue,
                    root: root,
                    sessionID: sessionID,
                    initiatorCertificate: initiatorCert,
                    nowMs: nowMs
                )
            }

            #if DEBUG
            try maybeFault(.afterConfirmBeforeCompleteClaim)
            #endif

            do {
                _ = try ATSAMPrekeyLifecycleStore.shared.completeClaim(
                    claimID: claimID,
                    sessionID: sessionID
                )
            } catch {
                throw AcceptError.claimFailed(String(describing: error))
            }

            TestATrace.emit(
                location: "ATSAMPairInitAcceptService.accept",
                message: "TRACE_PAIR_RESPONSE_BUILT",
                status: "SESSION_INSTALLED",
                detail: "sid=\(sessionID.prefix(4).map { String(format: "%02x", $0) }.joined())"
            )

            try await deliverPairResponse(
                packedWire: packed,
                responseWire: responseWire,
                delivery: delivery
            )

            TestATrace.emit(
                location: "ATSAMPairInitAcceptService.accept",
                message: delivery == .sameConnection
                    ? "TRACE_PAIR_RESPONSE_INLINE"
                    : "TRACE_PAIR_RESPONSE_UPLINKED",
                status: "WAITING_FOR_INDEXED_MESSAGE",
                detail: "rvpr1=\(responseWire.count)"
            )
            return delivery == .sameConnection ? packed : nil
        }
        return nil
    }

    // MARK: - Replay path

    private static func replayCachedAccept(
        pairInitWire: Data,
        initValue: ATSAMPairInitV1.PairInit,
        trust: ATSAMPairInitV1.TrustContext,
        initiatorCert: ATSAMPairInitV1.SignedDeviceCertificate,
        cachedPacked: Data,
        root: Data,
        nowMs: UInt64,
        delivery: PairResponseDelivery
    ) async throws -> Data? {
        let sessionID = try ATSAMPairInitV1.sessionID(initValue)

        let claimOutcome = try ATSAMPrekeyLifecycleStore.shared.claimPairInit(
            pairInitWire: pairInitWire,
            initValue: initValue,
            trust: trust,
            root: root,
            nowMs: nowMs
        )

        switch claimOutcome {
        case .accepted(let claim), .duplicatePending(let claim):
            _ = try ATSAMPrekeyLifecycleStore.shared.completeClaim(
                claimID: claim.claimID,
                sessionID: claim.sessionID
            )
        case .duplicateCompleted:
            break
        case .duplicateAbandoned:
            throw AcceptError.claimFailed("pair init claim abandoned")
        }

        #if DEBUG
        let skipInstallSession = skipInstallSessionForTesting
        #else
        let skipInstallSession = false
        #endif
        if !skipInstallSession {
            // Idempotent confirm — install only if not already present.
            try await ATSAMLabEndpointHost.shared.installResponderSession(
                initValue: initValue,
                root: root,
                sessionID: sessionID,
                initiatorCertificate: initiatorCert,
                nowMs: nowMs
            )
        }

        guard case .pairResponse(let responseWire) = RavenPairInitLanOob.classifyPackedEnvelope(cachedPacked) else {
            throw AcceptError.cacheFailed("cached payload is not PairResponse OOB")
        }

        try await deliverPairResponse(
            packedWire: cachedPacked,
            responseWire: responseWire,
            delivery: delivery
        )
        return delivery == .sameConnection ? cachedPacked : nil
    }

    // MARK: - Hybrid + response build

    private static func deriveRoot(
        initValue: ATSAMPairInitV1.PairInit,
        secrets: (xSecret: Data, mlkemSeed: Data)
    ) throws -> Data {
        let selectedXSecret: Data
        if initValue.oneTimePrekeyID != 0 {
            throw AcceptError.hybridFailed("OTP prekeys not supported in lab slice")
        } else {
            selectedXSecret = secrets.xSecret
        }
        let ourX = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: selectedXSecret)
        let peerX = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: initValue.initiatorEphemeralX25519PublicKey
        )
        let shared = try ourX.sharedSecretFromKeyAgreement(with: peerX)
        let zX = shared.withUnsafeBytes { Data($0) }
        guard !zX.allSatisfy({ $0 == 0 }) else {
            throw AcceptError.hybridFailed("non-contributory X25519")
        }
        let zPQ = try ATSAMMLKem.decapsulate(
            ciphertext: initValue.mlKem768Ciphertext,
            privateKey: secrets.mlkemSeed
        )
        return try ATSAMPairInitV1.deriveProvisionalRoot(
            zX: zX,
            zPQ: zPQ,
            pairInit: initValue
        )
    }

    private static func buildSignedResponse(
        initValue: ATSAMPairInitV1.PairInit,
        root: Data,
        nowMs: UInt64
    ) throws -> (responseWire: Data, packed: Data) {
        let initHash = try ATSAMPairInitV1.initHash(initValue)
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
        guard let seed = DeviceIdentityService.shared.deviceSigningSeed else {
            throw AcceptError.identityMissing
        }
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let packed = try RavenPairInitLanOob.wrapOobWire(
            responseWire,
            isPairInit: false,
            signingKey: signingKey
        )
        return (responseWire, packed)
    }

    private static func deliverPairResponse(
        packedWire: Data,
        responseWire: Data,
        delivery: PairResponseDelivery
    ) async throws {
        switch delivery {
        case .sameConnection:
            _ = responseWire
            return
        case .dialUplink:
            try await uplinkPairResponse(packedWire: packedWire, responseWire: responseWire)
        }
    }

    private static func uplinkPairResponse(packedWire: Data, responseWire: Data) async throws {
        #if DEBUG
        if skipUplinkForTesting { return }
        #endif
        guard let lan = RavenServerlessLanConfig.stored else {
            throw AcceptError.uplinkFailed("LAN config missing — Save Mac host/port first")
        }
        guard ATSAMEndpointDurableAdapters.labTestAEnabled else {
            throw AcceptError.uplinkFailed("Secure LAN uplink requires lab gate")
        }
        guard let peerEd = Data(ravenHex: lan.peerPubHex), peerEd.count == 32 else {
            throw AcceptError.uplinkFailed("LAN peer device pub missing")
        }
        do {
            _ = try await RavenSecureLanDialerV1.dialLab(
                host: lan.host,
                port: lan.port,
                expectedDeviceEdPub: peerEd,
                frames: [packedWire]
            )
        } catch {
            throw AcceptError.uplinkFailed(error.localizedDescription)
        }
        _ = responseWire
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
