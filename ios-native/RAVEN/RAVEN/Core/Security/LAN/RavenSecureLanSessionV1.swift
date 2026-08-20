//
//  RavenSecureLanSessionV1.swift
//  RAVEN
//
//  Noise XX + bind + RLB1 session over u32-BE framed I/O.
//  Session order parity with node/crates/raven-node/src/lan_direct.rs.
//
//  Mutation-lease rule: durable receive/ACK materialize may hold G1 lease;
//  dial / read_cipher / write_cipher happen only after lease release.
//

import Foundation
import Network

// MARK: - Errors

enum RavenSecureLanSessionError: Error, Equatable, LocalizedError {
    case labGateClosed
    case dialMalformed
    case dialTimeout
    case connectFailed
    case ioFailed
    case ioTimeout
    case frameLength
    case handshakeFailed
    case bindFailed
    case rlb1Mismatch
    case peerBlocked
    case identityMismatch
    case lifetimeExceeded
    case frameBudgetExceeded

    var errorDescription: String? {
        switch self {
        case .labGateClosed: return "secure LAN session refused: lab gate closed"
        case .dialMalformed: return "lan_dial must be host:port"
        case .dialTimeout: return "lan dial timeout"
        case .connectFailed: return "lan connect failed"
        case .ioFailed: return "lan io failed"
        case .ioTimeout: return "lan io timeout"
        case .frameLength: return "lan frame length"
        case .handshakeFailed: return "noise handshake failed"
        case .bindFailed: return "noise bind failed"
        case .rlb1Mismatch: return "rlb1/noise identity mismatch"
        case .peerBlocked: return "blocked peer"
        case .identityMismatch: return "rlb1 offer identity mismatch"
        case .lifetimeExceeded: return "lan connection lifetime exceeded"
        case .frameBudgetExceeded: return "lan frame budget exceeded"
        }
    }
}

// MARK: - Framing codec

extension RavenSecureLanFrameCodec {
    static func frame(_ payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= maxFrameLen else {
            throw RavenSecureLanSessionError.frameLength
        }
        var out = Data(capacity: 4 + payload.count)
        out.appendUInt32BE(UInt32(payload.count))
        out.append(payload)
        return out
    }
}

// MARK: - Framed channel abstraction

protocol RavenSecureLanFramedChannel: AnyObject {
    func writeRaw(_ bytes: Data) async throws
    func readRaw(timeout: TimeInterval) async throws -> Data
    func close()
}

// MARK: - In-memory duplex (tests)

final class RavenSecureLanMemoryPipe {
    private let lock = NSLock()
    private var leftToRight = Data()
    private var rightToLeft = Data()

    static func connectedPair() -> (left: RavenSecureLanMemoryFramedChannel, right: RavenSecureLanMemoryFramedChannel) {
        let pipe = RavenSecureLanMemoryPipe()
        return (
            RavenSecureLanMemoryFramedChannel(pipe: pipe, isLeft: true),
            RavenSecureLanMemoryFramedChannel(pipe: pipe, isLeft: false)
        )
    }

    fileprivate func write(fromLeft: Bool, data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if fromLeft {
            leftToRight.append(data)
        } else {
            rightToLeft.append(data)
        }
    }

    fileprivate func read(fromLeft: Bool) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let source = fromLeft ? rightToLeft : leftToRight
        guard let parsed = RavenSecureLanFrameCodec.deframe(source) else { return nil }
        if fromLeft {
            rightToLeft = parsed.remainder
        } else {
            leftToRight = parsed.remainder
        }
        return parsed.payload
    }

    fileprivate func pendingBytes(fromLeft: Bool) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return fromLeft ? rightToLeft.count : leftToRight.count
    }
}

final class RavenSecureLanMemoryFramedChannel: RavenSecureLanFramedChannel {
    private let pipe: RavenSecureLanMemoryPipe
    private let isLeft: Bool
    private var closed = false

    init(pipe: RavenSecureLanMemoryPipe, isLeft: Bool) {
        self.pipe = pipe
        self.isLeft = isLeft
    }

    func writeRaw(_ bytes: Data) async throws {
        guard !closed else { throw RavenSecureLanSessionError.ioFailed }
        let framed = try RavenSecureLanFrameCodec.frame(bytes)
        pipe.write(fromLeft: isLeft, data: framed)
    }

    func readRaw(timeout: TimeInterval) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if closed { throw RavenSecureLanSessionError.ioFailed }
            if let payload = pipe.read(fromLeft: isLeft) {
                return payload
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw RavenSecureLanSessionError.ioTimeout
    }

    func close() {
        closed = true
    }
}

// MARK: - NWConnection channel

final class RavenSecureLanNWFramedChannel: RavenSecureLanFramedChannel {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var rxBuffer = Data()
    private let bufferQueue = DispatchQueue(label: "secure-lan-nw-rx-buffer")

    /// - Parameter startConnection: When false, caller must already have started
    ///   the connection (e.g. dialer waits for `.ready` first).
    init(
        connection: NWConnection,
        queue: DispatchQueue = DispatchQueue(label: "secure-lan-nw-framed"),
        startConnection: Bool = true
    ) {
        self.connection = connection
        self.queue = queue
        if startConnection {
            connection.start(queue: queue)
        }
    }

    func writeRaw(_ bytes: Data) async throws {
        let framed = try RavenSecureLanFrameCodec.frame(bytes)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if error != nil {
                    cont.resume(throwing: RavenSecureLanSessionError.ioFailed)
                } else {
                    cont.resume()
                }
            })
        }
    }

    func readRaw(timeout: TimeInterval) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let payload = bufferQueue.sync(execute: drainOneFrame) {
                return payload
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            if let chunk = try await receiveChunk(timeout: min(1.0, remaining)) {
                bufferQueue.sync {
                    rxBuffer.append(chunk)
                }
            }
        }
        throw RavenSecureLanSessionError.ioTimeout
    }

    func close() {
        connection.cancel()
    }

    private func drainOneFrame() -> Data? {
        guard let parsed = RavenSecureLanFrameCodec.deframe(rxBuffer) else { return nil }
        rxBuffer = parsed.remainder
        return parsed.payload
    }

    private func receiveChunk(timeout: TimeInterval) async throws -> Data? {
        guard timeout > 0 else { return nil }
        return try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
                    self.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                        if error != nil {
                            cont.resume(throwing: RavenSecureLanSessionError.ioFailed)
                            return
                        }
                        if let data, !data.isEmpty {
                            cont.resume(returning: data)
                        } else {
                            cont.resume(returning: nil)
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }
}

// MARK: - Session configuration

struct RavenSecureLanSessionConfiguration {
    var deviceSeedProvider: () throws -> Data
    var encodeLocalOffer: () throws -> Data
    var contactBook: RavenSecureLanContactBook
    var ephemeralCache: RavenSecureLanEphemeralPeerCache
    var trustedPersistence: RavenSecureLanTrustedPeerPersistence?
    /// Returns cipher replies for one inbound plaintext frame (dispatch must not hold G1 lease).
    var inboundDispatch: (
        _ frame: Data,
        _ peer: RavenSecureLanRlb1V1.LanBundle,
        _ noiseEdPub: Data
    ) async throws -> [Data]
}

// MARK: - Session identity

enum RavenSecureLanSessionV1 {

    struct Identity {
        let deviceSeed: Data

        var staticPrivate: Data {
            get throws {
                try RavenSecureLanNoiseV1.deriveNoiseStatic(deviceSeed: deviceSeed)
            }
        }

        var staticPublic: Data {
            get throws {
                try RavenSecureLanNoiseV1.noiseStaticPublic(staticPrivate: try staticPrivate)
            }
        }
    }

    static func looksLikeLanDial(_ dial: String) -> Bool {
        let t = dial.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.contains(" ") || t.hasPrefix("rvn1") { return false }
        guard let colon = t.lastIndex(of: ":") else { return false }
        let host = t[..<colon]
        let port = t[t.index(after: colon)...]
        guard !host.isEmpty, let p = UInt16(port), p != 0 else { return false }
        return true
    }

    // MARK: Cipher helpers

    private static func writeCipher(
        channel: RavenSecureLanFramedChannel,
        transport: inout RavenSecureLanNoiseTransport,
        plain: Data,
        timeout: TimeInterval
    ) async throws {
        let ct = try transport.encrypt(plaintext: plain)
        try await channel.writeRaw(ct)
        _ = timeout
    }

    private static func readCipher(
        channel: RavenSecureLanFramedChannel,
        transport: inout RavenSecureLanNoiseTransport,
        timeout: TimeInterval
    ) async throws -> Data {
        let ct = try await channel.readRaw(timeout: timeout)
        return try transport.decrypt(ciphertext: ct)
    }

    // MARK: Initiator session (steps 1–3 partial)

    static func runInitiatorSession(
        channel: RavenSecureLanFramedChannel,
        identity: Identity,
        expectedDeviceEd: Data,
        localOffer: Data,
        limits: RavenSecureLanTransportLimits = .production
    ) async throws -> (
        transport: RavenSecureLanNoiseTransport,
        peer: RavenSecureLanRlb1V1.LanBundle,
        peerOfferWire: Data
    ) {
        let staticPriv = try identity.staticPrivate
        let staticPub = try identity.staticPublic
        var hs = try RavenSecureLanNoiseV1.buildInitiator(staticPrivate: staticPriv)
        let m1 = try hs.writeMessage()
        try await channel.writeRaw(m1)
        let m2 = try await channel.readRaw(timeout: limits.ioTimeoutSeconds)
        _ = try hs.readMessage(m2)
        let m3 = try hs.writeMessage()
        try await channel.writeRaw(m3)
        guard let remoteStatic = hs.remoteStatic else { throw RavenSecureLanSessionError.handshakeFailed }
        var transport = try hs.intoTransport()
        let bind = try RavenSecureLanNoiseV1.encodeBind(deviceSeed: identity.deviceSeed, noiseStaticPub: staticPub)
        try await writeCipher(channel: channel, transport: &transport, plain: bind, timeout: limits.ioTimeoutSeconds)
        let peerBind = try await readCipher(
            channel: channel,
            transport: &transport,
            timeout: limits.ioTimeoutSeconds
        )
        _ = try RavenSecureLanNoiseV1.verifyBind(
            bind: peerBind,
            noiseStaticPub: remoteStatic,
            expectedEd25519: expectedDeviceEd
        )
        try await writeCipher(
            channel: channel,
            transport: &transport,
            plain: localOffer,
            timeout: limits.ioTimeoutSeconds
        )
        let peerOfferWire = try await readCipher(
            channel: channel,
            transport: &transport,
            timeout: limits.ioTimeoutSeconds
        )
        let peer = try RavenSecureLanRlb1V1.decodeOffer(peerOfferWire)
        guard peer.cert.deviceEdPub == expectedDeviceEd || peer.cert.userEdPub == expectedDeviceEd else {
            throw RavenSecureLanSessionError.identityMismatch
        }
        return (transport, peer, peerOfferWire)
    }

    // MARK: Responder session (steps 1–5)

    static func runResponderSession(
        channel: RavenSecureLanFramedChannel,
        identity: Identity,
        localOffer: Data,
        contactBook: RavenSecureLanContactBook,
        ephemeralCache: RavenSecureLanEphemeralPeerCache,
        trustedPersistence: RavenSecureLanTrustedPeerPersistence?,
        limits: RavenSecureLanTransportLimits = .production
    ) async throws -> (
        transport: RavenSecureLanNoiseTransport,
        remoteDeviceEd: Data,
        peer: RavenSecureLanRlb1V1.LanBundle
    ) {
        let staticPriv = try identity.staticPrivate
        let staticPub = try identity.staticPublic
        var hs = try RavenSecureLanNoiseV1.buildResponder(staticPrivate: staticPriv)
        let m1 = try await channel.readRaw(timeout: limits.ioTimeoutSeconds)
        _ = try hs.readMessage(m1)
        let m2 = try hs.writeMessage()
        try await channel.writeRaw(m2)
        let m3 = try await channel.readRaw(timeout: limits.ioTimeoutSeconds)
        _ = try hs.readMessage(m3)
        guard let remoteStatic = hs.remoteStatic else { throw RavenSecureLanSessionError.handshakeFailed }
        var transport = try hs.intoTransport()
        let peerBind = try await readCipher(
            channel: channel,
            transport: &transport,
            timeout: limits.ioTimeoutSeconds
        )
        let remoteEd = try RavenSecureLanNoiseV1.verifyBind(
            bind: peerBind,
            noiseStaticPub: remoteStatic,
            expectedEd25519: nil
        )
        let localBind = try RavenSecureLanNoiseV1.encodeBind(
            deviceSeed: identity.deviceSeed,
            noiseStaticPub: staticPub
        )
        try await writeCipher(
            channel: channel,
            transport: &transport,
            plain: localBind,
            timeout: limits.ioTimeoutSeconds
        )
        let peerOfferWire = try await readCipher(
            channel: channel,
            transport: &transport,
            timeout: limits.ioTimeoutSeconds
        )
        let peer = try RavenSecureLanRlb1V1.decodeOffer(peerOfferWire)
        guard RavenSecureLanDispatchV1.rlb1MatchesNoiseIdentity(peer, noiseEdPub: remoteEd) else {
            throw RavenSecureLanSessionError.rlb1Mismatch
        }
        if contactBook.isBlocked(
            deviceEdPub: peer.cert.deviceEdPub,
            userEdPub: peer.cert.userEdPub,
            noiseEdPub: remoteEd
        ) {
            throw RavenSecureLanSessionError.peerBlocked
        }
        try ephemeralCache.cachePeerBundle(
            peer,
            contactBook: contactBook,
            durable: trustedPersistence
        )
        try await writeCipher(
            channel: channel,
            transport: &transport,
            plain: localOffer,
            timeout: limits.ioTimeoutSeconds
        )
        return (transport, remoteEd, peer)
    }

    // MARK: Inbound application loop (responder step 6)

    static func runInboundApplicationLoop(
        channel: RavenSecureLanFramedChannel,
        transport: inout RavenSecureLanNoiseTransport,
        peer: RavenSecureLanRlb1V1.LanBundle,
        remoteDeviceEd: Data,
        configuration: RavenSecureLanSessionConfiguration,
        openedAt: Date = Date(),
        limits: RavenSecureLanTransportLimits = .production
    ) async throws {
        var frameBudget = RavenSecureLanFrameBudget()
        while true {
            if RavenSecureLanConnectionLifetime(openedAt: openedAt, lifetimeSeconds: limits.connectionLifetimeSeconds)
                .isExpired(at: Date()) {
                throw RavenSecureLanSessionError.lifetimeExceeded
            }
            let frame: Data
            do {
                frame = try await readCipher(
                    channel: channel,
                    transport: &transport,
                    timeout: limits.ioTimeoutSeconds
                )
            } catch RavenSecureLanSessionError.ioTimeout {
                break
            } catch {
                break
            }
            guard frameBudget.consumeFrame(maxFrames: limits.maxFramesPerConnection) else {
                throw RavenSecureLanSessionError.frameBudgetExceeded
            }
            if configuration.contactBook.isBlocked(
                deviceEdPub: peer.cert.deviceEdPub,
                userEdPub: peer.cert.userEdPub,
                noiseEdPub: remoteDeviceEd
            ) {
                throw RavenSecureLanSessionError.peerBlocked
            }
            let replies = try await configuration.inboundDispatch(frame, peer, remoteDeviceEd)
            for reply in replies {
                try await writeCipher(
                    channel: channel,
                    transport: &transport,
                    plain: reply,
                    timeout: limits.ioTimeoutSeconds
                )
            }
        }
    }

    // MARK: Initiator dial tail (write frames + read replies)

    static func runInitiatorApplicationExchange(
        channel: RavenSecureLanFramedChannel,
        transport: inout RavenSecureLanNoiseTransport,
        frames: [Data],
        initialReplies: [Data] = [],
        limits: RavenSecureLanTransportLimits = .production
    ) async throws -> [Data] {
        var replies = initialReplies
        for frame in frames {
            try await writeCipher(
                channel: channel,
                transport: &transport,
                plain: frame,
                timeout: limits.ioTimeoutSeconds
            )
        }
        guard !frames.isEmpty else { return replies }
        do {
            let first = try await readCipher(
                channel: channel,
                transport: &transport,
                timeout: limits.ioTimeoutSeconds
            )
            replies.append(first)
        } catch {
            return replies
        }
        while true {
            do {
                let next = try await readCipher(
                    channel: channel,
                    transport: &transport,
                    timeout: limits.replyIdleSeconds
                )
                replies.append(next)
            } catch {
                break
            }
        }
        return replies
    }

    /// Full responder path on an established framed channel.
    static func serveInboundConnection(
        channel: RavenSecureLanFramedChannel,
        configuration: RavenSecureLanSessionConfiguration,
        limits: RavenSecureLanTransportLimits = .production
    ) async throws {
        try RavenSecureLanTransportV1.preflightSecureEntry()
        guard ATSAMLabGate.isEnabled else { throw RavenSecureLanSessionError.labGateClosed }
        let identity = Identity(deviceSeed: try configuration.deviceSeedProvider())
        let localOffer = try configuration.encodeLocalOffer()
        let openedAt = Date()
        var transport: RavenSecureLanNoiseTransport
        let remoteEd: Data
        let peer: RavenSecureLanRlb1V1.LanBundle
        (transport, remoteEd, peer) = try await runResponderSession(
            channel: channel,
            identity: identity,
            localOffer: localOffer,
            contactBook: configuration.contactBook,
            ephemeralCache: configuration.ephemeralCache,
            trustedPersistence: configuration.trustedPersistence,
            limits: limits
        )
        try await runInboundApplicationLoop(
            channel: channel,
            transport: &transport,
            peer: peer,
            remoteDeviceEd: remoteEd,
            configuration: configuration,
            openedAt: openedAt,
            limits: limits
        )
    }
}
