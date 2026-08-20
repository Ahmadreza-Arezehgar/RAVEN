//
//  RavenSecureLanDispatchV1.swift
//  RAVEN
//
//  Post-decrypt LAN frame dispatch: RLB1 ephemeral remember vs contact-gated
//  PairInit / message / ACK. Parity with lan_dispatch.rs dispatch_frame.
//

import Foundation

// MARK: - Contact book (injectable for tests)

protocol RavenSecureLanContactBook: AnyObject {
    func isLocalContact(deviceEdPub: Data, userEdPub: Data) -> Bool
    func isBlocked(deviceEdPub: Data, userEdPub: Data, noiseEdPub: Data) -> Bool
}

final class RavenSecureLanMutableContactBook: RavenSecureLanContactBook {
    var trustedKeys: Set<Data> = []
    var blockedKeys: Set<Data> = []

    func isLocalContact(deviceEdPub: Data, userEdPub: Data) -> Bool {
        trustedKeys.contains(deviceEdPub) || trustedKeys.contains(userEdPub)
    }

    func isBlocked(deviceEdPub: Data, userEdPub: Data, noiseEdPub: Data) -> Bool {
        blockedKeys.contains(noiseEdPub)
            || blockedKeys.contains(userEdPub)
            || blockedKeys.contains(deviceEdPub)
    }

    func addContact(_ pub: Data) {
        trustedKeys.insert(pub)
    }

    func removeContact(_ pub: Data) {
        trustedKeys.remove(pub)
    }

    func block(_ pub: Data) {
        blockedKeys.insert(pub)
    }
}

// MARK: - Dispatch errors

enum RavenSecureLanDispatchError: Error, Equatable, LocalizedError {
    case notLocalContact(String)
    case peerBlocked
    case rlb1NoiseIdentityMismatch
    case rlb1DeviceIdentityDrift
    case notEnvelope

    var errorDescription: String? {
        switch self {
        case .notLocalContact(let detail):
            return detail
        case .peerBlocked:
            return "peer blocked"
        case .rlb1NoiseIdentityMismatch:
            return "rlb1/noise identity mismatch"
        case .rlb1DeviceIdentityDrift:
            return "rlb1 device identity drift"
        case .notEnvelope:
            return "lan frame is not RavenEnvelopeV1"
        }
    }
}

// MARK: - Frame classification

enum RavenSecureLanApplicationFrameKind: Equatable {
    case rlb1Offer
    case pairInit
    case pairResponse
    case message
    case ack
    case unknown
}

enum RavenSecureLanDispatchV1 {

    struct Handlers {
        var onPairInit: ((Data) throws -> Void)?
        var onMessage: ((Data) throws -> Void)?
        var onAck: ((Data) throws -> Void)?
    }

    static func preflightSecureEntry() throws {
        try RavenSecureLanSecurePathGuard.enterSecurePath()
    }

    static func classifyFrame(_ frame: Data) -> RavenSecureLanApplicationFrameKind {
        if RavenSecureLanRlb1V1.isRlb1(frame) {
            return .rlb1Offer
        }
        switch RavenPairInitLanOob.classifyPackedEnvelope(frame) {
        case .pairInit:
            return .pairInit
        case .pairResponse:
            return .pairResponse
        case .notPairInitOob:
            break
        }
        guard let env = RavenEnvelopeV1.unpack(frame) else {
            return .unknown
        }
        if env.envType == RavenEnvelopeV1.EnvType.ack.rawValue {
            return .ack
        }
        if env.envType == RavenEnvelopeV1.EnvType.message.rawValue {
            return .message
        }
        return .unknown
    }

    /// Durable peer cache requires user trust (local contact book), not merely PairInit session.
    static func peerIsTrusted(
        _ bundle: RavenSecureLanRlb1V1.LanBundle,
        contactBook: RavenSecureLanContactBook
    ) -> Bool {
        contactBook.isLocalContact(
            deviceEdPub: bundle.cert.deviceEdPub,
            userEdPub: bundle.cert.userEdPub
        )
    }

    static func rlb1MatchesNoiseIdentity(
        _ bundle: RavenSecureLanRlb1V1.LanBundle,
        noiseEdPub: Data
    ) -> Bool {
        guard noiseEdPub.count == 32 else { return false }
        return bundle.cert.deviceEdPub == noiseEdPub || bundle.cert.userEdPub == noiseEdPub
    }

    /// Dispatch one plaintext (already Noise-decrypted) LAN frame.
    ///
    /// `hasConfirmedSession` is intentionally ignored for the contact gate — confirmed
    /// session ≠ contact trust (attackers can self-PairInit).
    static func dispatchDecryptedFrame(
        _ frame: Data,
        peer: RavenSecureLanRlb1V1.LanBundle,
        noiseEdPub: Data,
        contactBook: RavenSecureLanContactBook,
        ephemeralCache: RavenSecureLanEphemeralPeerCache,
        trustedPersistence: RavenSecureLanTrustedPeerPersistence?,
        hasConfirmedSession: Bool,
        handlers: Handlers
    ) throws {
        try preflightSecureEntry()
        _ = hasConfirmedSession

        if RavenSecureLanRlb1V1.isRlb1(frame) {
            let offer = try RavenSecureLanRlb1V1.decodeOffer(frame)
            guard rlb1MatchesNoiseIdentity(offer, noiseEdPub: noiseEdPub) else {
                throw RavenSecureLanDispatchError.rlb1NoiseIdentityMismatch
            }
            guard offer.cert.deviceEdPub == peer.cert.deviceEdPub else {
                throw RavenSecureLanDispatchError.rlb1DeviceIdentityDrift
            }
            try ephemeralCache.cachePeerBundle(
                offer,
                contactBook: contactBook,
                durable: trustedPersistence
            )
            return
        }

        switch RavenPairInitLanOob.classifyPackedEnvelope(frame) {
        case .pairInit(let wire):
            try requireContact(peer: peer, noiseEdPub: noiseEdPub, contactBook: contactBook, kind: "pair init")
            try handlers.onPairInit?(wire)
            return
        case .pairResponse:
            return
        case .notPairInitOob:
            break
        }

        guard let env = RavenEnvelopeV1.unpack(frame) else {
            throw RavenSecureLanDispatchError.notEnvelope
        }

        if env.envType == RavenEnvelopeV1.EnvType.ack.rawValue {
            try requireContact(peer: peer, noiseEdPub: noiseEdPub, contactBook: contactBook, kind: "ack")
            try handlers.onAck?(frame)
            return
        }

        if env.envType == RavenEnvelopeV1.EnvType.message.rawValue {
            try requireContact(peer: peer, noiseEdPub: noiseEdPub, contactBook: contactBook, kind: "message")
            try handlers.onMessage?(frame)
            return
        }
    }

    private static func requireContact(
        peer: RavenSecureLanRlb1V1.LanBundle,
        noiseEdPub: Data,
        contactBook: RavenSecureLanContactBook,
        kind: String
    ) throws {
        if contactBook.isBlocked(
            deviceEdPub: peer.cert.deviceEdPub,
            userEdPub: peer.cert.userEdPub,
            noiseEdPub: noiseEdPub
        ) {
            throw RavenSecureLanDispatchError.peerBlocked
        }
        guard peerIsTrusted(peer, contactBook: contactBook) else {
            throw RavenSecureLanDispatchError.notLocalContact("\(kind) refused: peer is not a local contact")
        }
    }
}
