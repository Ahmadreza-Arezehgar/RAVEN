//
//  RavenSecureLanTransportV1.swift
//  RAVEN
//
//  Secure LAN transport limits, per-IP admission, and legacy-path guards.
//  Parity with node/crates/raven-node/src/lan_direct.rs PRODUCTION_LIMITS.
//

import Foundation
import Network
import UIKit

// MARK: - Errors

enum RavenSecureLanError: Error, Equatable, LocalizedError {
    case legacyLanPathForbidden
    case admissionDenied
    case frameBudgetExceeded
    case connectionLifetimeExceeded

    var errorDescription: String? {
        switch self {
        case .legacyLanPathForbidden:
            return "secure LAN path must not use RavenServerlessLanPath"
        case .admissionDenied:
            return "secure LAN inbound admission denied"
        case .frameBudgetExceeded:
            return "secure LAN frame budget exceeded"
        case .connectionLifetimeExceeded:
            return "secure LAN connection lifetime exceeded"
        }
    }
}

// MARK: - Legacy path guard

enum RavenSecureLanSecurePathGuard {

    /// Entry guard for every secure transport/dispatch API.
    static func enterSecurePath() throws {
        try refuseLegacyDelegation(useLegacyPath: false)
    }

    /// Runtime tripwire when a caller would route through the legacy serverless path.
    static func refuseLegacyDelegation(useLegacyPath: Bool) throws {
        if useLegacyPath {
            throw RavenSecureLanError.legacyLanPathForbidden
        }
    }

    @available(*, unavailable, message: "Secure LAN must not call RavenServerlessLanPath")
    static func forbiddenServerlessLanPathEntry() -> Never {
        fatalError("Secure LAN must not call RavenServerlessLanPath")
    }
}

// MARK: - Production limits (frozen §6.5)

struct RavenSecureLanTransportLimits: Equatable {
    let ioTimeoutSeconds: TimeInterval
    let replyIdleSeconds: TimeInterval
    let maxConcurrentInboundConnections: Int
    let maxConnectionsPerIP: Int
    let maxFramesPerConnection: UInt32
    let connectionLifetimeSeconds: TimeInterval

    static let production = RavenSecureLanTransportLimits(
        ioTimeoutSeconds: 30,
        replyIdleSeconds: 2,
        maxConcurrentInboundConnections: 32,
        maxConnectionsPerIP: 4,
        maxFramesPerConnection: 64,
        connectionLifetimeSeconds: 120
    )
}

// MARK: - Per-IP key (address octets, not string)

/// Canonical per-IP bucket key: IPv4 → 4 bytes, IPv6 → 16 bytes.
/// IPv4-mapped IPv6 stays IPv6 when presented as such (Rust `IpAddr` parity).
struct RavenSecureLanIPKey: Hashable, Equatable, Sendable {
    enum Family: Equatable, Sendable {
        case ipv4
        case ipv6
    }

    let family: Family
    let octets: Data

    var byteCount: Int { octets.count }
}

enum RavenSecureLanIPKeyCodec {

    static func ipv4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> RavenSecureLanIPKey {
        RavenSecureLanIPKey(family: .ipv4, octets: Data([a, b, c, d]))
    }

    static func ipv6Octets(_ octets: Data) -> RavenSecureLanIPKey? {
        guard octets.count == 16 else { return nil }
        return RavenSecureLanIPKey(family: .ipv6, octets: octets)
    }

    static func ipv6Loopback() -> RavenSecureLanIPKey {
        var octets = Data(repeating: 0, count: 16)
        octets[15] = 1
        return RavenSecureLanIPKey(family: .ipv6, octets: octets)
    }

    /// Build from Network.framework host without using debugDescription / zone text.
    static func key(from host: NWEndpoint.Host) -> RavenSecureLanIPKey? {
        switch host {
        case .ipv4(let addr):
            var raw = addr.rawValue
            guard raw.count == 4 else { return nil }
            return RavenSecureLanIPKey(family: .ipv4, octets: raw)
        case .ipv6(let addr):
            var raw = addr.rawValue
            guard raw.count == 16 else { return nil }
            return RavenSecureLanIPKey(family: .ipv6, octets: raw)
        default:
            return nil
        }
    }
}

// MARK: - Admission (pure, unit-testable)

final class RavenSecureLanAdmissionController {
    private(set) var globalActive: Int = 0
    private(set) var perIP: [RavenSecureLanIPKey: Int] = [:]

    let limits: RavenSecureLanTransportLimits

    init(limits: RavenSecureLanTransportLimits = .production) {
        self.limits = limits
    }

    /// Mirror Rust `try_admit_connection`: global cap first, then per-IP cap.
    @discardableResult
    func tryAdmit(ip: RavenSecureLanIPKey) -> Bool {
        guard globalActive < limits.maxConcurrentInboundConnections else { return false }
        let current = perIP[ip, default: 0]
        guard current < limits.maxConnectionsPerIP else { return false }
        globalActive += 1
        perIP[ip] = current + 1
        return true
    }

    /// Mirror Rust `release_ip_slot`.
    func release(ip: RavenSecureLanIPKey) {
        globalActive = max(0, globalActive - 1)
        guard var count = perIP[ip] else { return }
        count -= 1
        if count <= 0 {
            perIP.removeValue(forKey: ip)
        } else {
            perIP[ip] = count
        }
    }
}

// MARK: - Frame budget

struct RavenSecureLanFrameBudget {
    private(set) var framesSeen: UInt32 = 0

    /// Mirror Rust `frame_budget_allows`.
    mutating func consumeFrame(maxFrames: UInt32) -> Bool {
        framesSeen &+= 1
        return framesSeen <= maxFrames
    }
}

// MARK: - Connection lifetime tracker

struct RavenSecureLanConnectionLifetime {
    let openedAt: Date
    let lifetimeSeconds: TimeInterval

    init(openedAt: Date, lifetimeSeconds: TimeInterval = RavenSecureLanTransportLimits.production.connectionLifetimeSeconds) {
        self.openedAt = openedAt
        self.lifetimeSeconds = lifetimeSeconds
    }

    func isExpired(at now: Date) -> Bool {
        now.timeIntervalSince(openedAt) >= lifetimeSeconds
    }
}

// MARK: - u32 BE framing (secure path only — never RavenServerlessLanPath)

enum RavenSecureLanFrameCodec {
    static let maxFrameLen = 1_048_576

    static func deframe(_ buffer: Data) -> (payload: Data, remainder: Data)? {
        guard buffer.count >= 4 else { return nil }
        let len = Int(buffer.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        guard len > 0, len <= maxFrameLen, buffer.count >= 4 + len else { return nil }
        let payload = buffer.subdata(in: 4..<(4 + len))
        let rest = buffer.subdata(in: (4 + len)..<buffer.count)
        return (payload, rest)
    }
}

// MARK: - Foreground-only lab listener

enum RavenSecureLanListenError: Error, Equatable, LocalizedError {
    case labGateClosed
    case notForeground
    case bindFailed

    var errorDescription: String? {
        switch self {
        case .labGateClosed: return "secure LAN listen refused: lab gate closed"
        case .notForeground: return "secure LAN listen refused: app not foreground"
        case .bindFailed: return "secure LAN listen bind failed"
        }
    }
}

@MainActor
final class RavenSecureLanLabListenerController {
    static let shared = RavenSecureLanLabListenerController()

    private(set) var isListening = false
    private(set) var isForeground = true
    private(set) var configuredPort: UInt16 = 0

    private var listener: NWListener?
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private let admission = RavenSecureLanAdmissionController()
    private let contactBook = RavenSecureLanLabTrustContactBook()
    private let ephemeralCache = RavenSecureLanEphemeralPeerCache()
    private(set) var sessionConfiguration: RavenSecureLanSessionConfiguration?

    private init() {}

    func setSessionConfiguration(_ configuration: RavenSecureLanSessionConfiguration?) {
        sessionConfiguration = configuration
    }

    func installLifecycleObserversIfNeeded() {
        guard backgroundObserver == nil else { return }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleDidEnterBackground()
            }
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleDidBecomeActive()
            }
        }
    }

    func removeLifecycleObservers() {
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
            self.backgroundObserver = nil
        }
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
            self.foregroundObserver = nil
        }
    }

    /// Start or refresh the secure listener when lab gate is open and app is foreground.
    func configureLabListenIfEnabled(port: UInt16) throws {
        try RavenSecureLanTransportV1.preflightSecureEntry()
        guard ATSAMLabGate.isEnabled else {
            stopLabListen()
            throw RavenSecureLanListenError.labGateClosed
        }
        configuredPort = port
        guard isForeground else {
            stopLabListen()
            throw RavenSecureLanListenError.notForeground
        }
        try startListener(port: port)
    }

    func stopLabListen() {
        listener?.cancel()
        listener = nil
        isListening = false
    }

    func handleDidEnterBackground() {
        isForeground = false
        stopLabListen()
        #if DEBUG
        print("🕊️ [SecureLanTransport] stopped listen (background)")
        #endif
    }

    func handleDidBecomeActive() {
        isForeground = true
        guard configuredPort > 0, ATSAMLabGate.isEnabled else { return }
        try? startListener(port: configuredPort)
    }

    /// Test/lab harness hook — force foreground lifecycle without UIKit events.
    /// Available in Release so `ios_lan_kat.sh` Release verification compiles.
    func setForegroundForTesting(_ foreground: Bool) {
        isForeground = foreground
        if foreground {
            handleDidBecomeActive()
        } else {
            handleDidEnterBackground()
        }
    }

    private func startListener(port: UInt16) throws {
        if isListening, configuredPort == port { return }
        stopLabListen()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw RavenSecureLanListenError.bindFailed
        }
        let lw = try NWListener(using: .tcp, on: nwPort)
        lw.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in
                self?.handleInboundConnection(conn)
            }
        }
        lw.stateUpdateHandler = { state in
            #if DEBUG
            if case .failed(let err) = state {
                print("🕊️ [SecureLanTransport] listen failed: \(err)")
            }
            #endif
        }
        lw.start(queue: .global(qos: .utility))
        listener = lw
        isListening = true
        #if DEBUG
        print("🕊️ [SecureLanTransport] secure listen :\(port) (foreground-only, no legacy fallback)")
        #endif
    }

    private func handleInboundConnection(_ conn: NWConnection) {
        guard ATSAMLabGate.isEnabled, isForeground else {
            conn.cancel()
            return
        }
        guard case let .hostPort(host, _) = conn.endpoint,
              let ipKey = RavenSecureLanIPKeyCodec.key(from: host),
              admission.tryAdmit(ip: ipKey) else {
            conn.cancel()
            return
        }
        guard let sessionConfiguration else {
            admission.release(ip: ipKey)
            conn.cancel()
            return
        }
        let openedAt = Date()
        let limits = RavenSecureLanTransportV1.limits
        let channel = RavenSecureLanNWFramedChannel(connection: conn)
        Task {
            defer {
                Task { @MainActor in
                    self.admission.release(ip: ipKey)
                }
                channel.close()
            }
            do {
                try await RavenSecureLanSessionV1.serveInboundConnection(
                    channel: channel,
                    configuration: sessionConfiguration,
                    limits: limits
                )
            } catch {
                #if DEBUG
                if !(error is RavenSecureLanSessionError) {
                    print("🕊️ [SecureLanTransport] inbound session: \(error)")
                }
                #endif
            }
            _ = openedAt
        }
    }
}

extension Notification.Name {
    static let ravenSecureLanLabFrameReceived = Notification.Name("ravenSecureLanLabFrameReceived")
}

// MARK: - Transport entry (thin; listen wiring lab-gated)

enum RavenSecureLanTransportV1 {

    static let limits = RavenSecureLanTransportLimits.production

    static func preflightSecureEntry() throws {
        try RavenSecureLanSecurePathGuard.enterSecurePath()
    }

    /// Install session dependencies for inbound Noise+RLB1 handling.
    @MainActor
    static func configureLabSession(_ configuration: RavenSecureLanSessionConfiguration?) {
        RavenSecureLanLabListenerController.shared.setSessionConfiguration(configuration)
    }

    /// Lab-gated foreground-only secure listener (§6.5 / design non-goal: background LAN).
    @MainActor
    static func configureLabListenIfEnabled(port: UInt16) throws {
        try RavenSecureLanLabListenerController.shared.configureLabListenIfEnabled(port: port)
    }

    @MainActor
    static func stopLabListen() {
        RavenSecureLanLabListenerController.shared.stopLabListen()
    }
}
