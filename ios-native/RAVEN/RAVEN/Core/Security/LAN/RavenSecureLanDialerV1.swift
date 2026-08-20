//
//  RavenSecureLanDialerV1.swift
//  RAVEN
//
//  Secure LAN dialer: Noise XX initiator session + RLB1 + application frames.
//  Parity with lan_direct.rs dial(). Never delegates to RavenServerlessLanPath.
//

import Foundation
import Network

enum RavenSecureLanDialerV1 {

    /// Lab-gated secure dial using stored identity material.
    @MainActor
    static func dialLab(
        host: String,
        port: UInt16,
        expectedDeviceEdPub: Data,
        frames: [Data],
        limits: RavenSecureLanTransportLimits = .production
    ) async throws -> [Data] {
        try RavenSecureLanTransportV1.preflightSecureEntry()
        guard ATSAMLabGate.isEnabled else {
            throw RavenSecureLanSessionError.labGateClosed
        }
        guard let seed = DeviceIdentityService.shared.deviceSigningSeed else {
            throw RavenSecureLanSessionError.ioFailed
        }
        let identity = RavenSecureLanSessionV1.Identity(deviceSeed: seed)
        let localOffer = try ATSAMLabTrustStore.encodeLocalRlb1Offer()
        return try await dial(
            host: host,
            port: port,
            expectedDeviceEdPub: expectedDeviceEdPub,
            frames: frames,
            identity: identity,
            localOffer: localOffer,
            limits: limits
        )
    }

    /// Lab dial: Noise+RLB1, then PairInit built from the live peer RLB1 offer on the same TCP session.
    @MainActor
    static func dialLabPairInit(
        host: String,
        port: UInt16,
        expectedDeviceEdPub: Data,
        limits: RavenSecureLanTransportLimits = .production
    ) async throws -> [Data] {
        try RavenSecureLanTransportV1.preflightSecureEntry()
        guard ATSAMLabGate.isEnabled else {
            throw RavenSecureLanSessionError.labGateClosed
        }
        guard let seed = DeviceIdentityService.shared.deviceSigningSeed else {
            throw RavenSecureLanSessionError.ioFailed
        }
        let identity = RavenSecureLanSessionV1.Identity(deviceSeed: seed)
        let localOffer = try ATSAMLabTrustStore.encodeLocalRlb1Offer()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw RavenSecureLanSessionError.dialMalformed
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: .tcp
        )
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            let queue = DispatchQueue(label: "secure-lan-dial-pairinit-ready")
            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    cont.resume()
                case .failed, .cancelled:
                    resumed = true
                    cont.resume(throwing: RavenSecureLanSessionError.connectFailed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + limits.ioTimeoutSeconds) {
                guard !resumed else { return }
                resumed = true
                connection.cancel()
                cont.resume(throwing: RavenSecureLanSessionError.dialTimeout)
            }
        }
        let channel = RavenSecureLanNWFramedChannel(connection: connection, startConnection: false)
        defer { channel.close() }

        var (transport, _, peerOfferWire) = try await RavenSecureLanSessionV1.runInitiatorSession(
            channel: channel,
            identity: identity,
            expectedDeviceEd: expectedDeviceEdPub,
            localOffer: localOffer,
            limits: limits
        )
        let peer = try RavenSecureLanRlb1V1.decodeOffer(peerOfferWire)
        guard peer.cert.deviceEdPub == expectedDeviceEdPub || peer.cert.userEdPub == expectedDeviceEdPub else {
            throw RavenSecureLanSessionError.identityMismatch
        }
        let built = try ATSAMLabPairInitBuilder.buildPackedPairInit(responderBundle: peer)
        return try await RavenSecureLanSessionV1.runInitiatorApplicationExchange(
            channel: channel,
            transport: &transport,
            frames: [built.packed],
            initialReplies: [peerOfferWire],
            limits: limits
        )
    }

    /// Secure dial with explicit identity (tests / vectors).
    static func dial(
        host: String,
        port: UInt16,
        expectedDeviceEdPub: Data,
        frames: [Data],
        identity: RavenSecureLanSessionV1.Identity,
        localOffer: Data,
        limits: RavenSecureLanTransportLimits = .production
    ) async throws -> [Data] {
        try RavenSecureLanTransportV1.preflightSecureEntry()
        guard ATSAMLabGate.isEnabled else { throw RavenSecureLanSessionError.labGateClosed }
        let dial = "\(host):\(port)"
        guard RavenSecureLanSessionV1.looksLikeLanDial(dial) else {
            throw RavenSecureLanSessionError.dialMalformed
        }
        guard expectedDeviceEdPub.count == 32 else {
            throw RavenSecureLanSessionError.identityMismatch
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw RavenSecureLanSessionError.dialMalformed
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: .tcp
        )
        // Wait for `.ready` *before* handing the connection to the framed
        // channel — starting first and attaching the handler later races and
        // can hang until IO timeout.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            let queue = DispatchQueue(label: "secure-lan-dial-ready")
            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    cont.resume()
                case .failed, .cancelled:
                    resumed = true
                    cont.resume(throwing: RavenSecureLanSessionError.connectFailed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + limits.ioTimeoutSeconds) {
                guard !resumed else { return }
                resumed = true
                connection.cancel()
                cont.resume(throwing: RavenSecureLanSessionError.dialTimeout)
            }
        }
        let channel = RavenSecureLanNWFramedChannel(connection: connection, startConnection: false)
        defer { channel.close() }

        var (transport, _, peerOfferWire) = try await RavenSecureLanSessionV1.runInitiatorSession(
            channel: channel,
            identity: identity,
            expectedDeviceEd: expectedDeviceEdPub,
            localOffer: localOffer,
            limits: limits
        )

        return try await RavenSecureLanSessionV1.runInitiatorApplicationExchange(
            channel: channel,
            transport: &transport,
            frames: frames,
            initialReplies: [peerOfferWire],
            limits: limits
        )
    }

    /// In-memory duplex dial (integration tests without real TCP).
    static func dialMemory(
        clientChannel: RavenSecureLanFramedChannel,
        expectedDeviceEdPub: Data,
        frames: [Data],
        identity: RavenSecureLanSessionV1.Identity,
        localOffer: Data,
        limits: RavenSecureLanTransportLimits = .production
    ) async throws -> [Data] {
        try RavenSecureLanTransportV1.preflightSecureEntry()
        guard ATSAMLabGate.isEnabled else { throw RavenSecureLanSessionError.labGateClosed }
        var (transport, _, peerOfferWire) = try await RavenSecureLanSessionV1.runInitiatorSession(
            channel: clientChannel,
            identity: identity,
            expectedDeviceEd: expectedDeviceEdPub,
            localOffer: localOffer,
            limits: limits
        )
        return try await RavenSecureLanSessionV1.runInitiatorApplicationExchange(
            channel: clientChannel,
            transport: &transport,
            frames: frames,
            initialReplies: [peerOfferWire],
            limits: limits
        )
    }
}
