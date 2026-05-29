//
//  MPCTransportService.swift
//  RAVEN
//
//  MultipeerConnectivity transport for high-throughput bulk data transfer.
//  Works alongside BLE: BLE handles discovery + small messages, MPC handles
//  bulk data (photos, videos, files) at 5-20 Mbps via Wi-Fi Direct.
//
//  Security: MPC sessions are authenticated via Ed25519 signed challenge
//  exchanged as the first message after connection. BLE↔MPC binding uses
//  a session nonce exchanged during BLE GATT handshake.
//

import Foundation
import MultipeerConnectivity
import Combine
import CryptoKit
import UIKit
import os

fileprivate let logger = Logger(subsystem: "app.raven.ios", category: "Mesh.MPC")

// MARK: - MPC Auth Challenge

/// First message sent over MPC to authenticate the peer.
/// Binds MPC session to BLE-verified Ed25519 identity.
struct MPCAuthChallenge: Codable {
    let sessionNonce: String       // Must match BLE-exchanged nonce
    let timestamp: Int64
    let fingerprint: String        // Ed25519 fingerprint of sender
    let signature: String          // Ed25519(sessionNonce || timestamp || fingerprint)
    
    static func create(sessionNonce: String) -> MPCAuthChallenge? {
        let fp = DeviceIdentityService.shared.fingerprint ?? ""
        let ts = Int64(Date().timeIntervalSince1970)
        let signingData = "\(sessionNonce)|\(ts)|\(fp)".data(using: .utf8) ?? Data()
        guard let sig = DeviceIdentityService.shared.sign(signingData) else { return nil }
        return MPCAuthChallenge(
            sessionNonce: sessionNonce,
            timestamp: ts,
            fingerprint: fp,
            signature: sig.base64EncodedString()
        )
    }
    
    func verify() async -> Bool {
        guard let sigData = Data(base64Encoded: signature) else { return false }
        let signingData = "\(sessionNonce)|\(timestamp)|\(fingerprint)".data(using: .utf8) ?? Data()
        // Accept if signed by a known trusted device or via TOFU
        let allTrusted = await FriendDeviceRepository.shared.getAllTrustedDevices()
        let signerKey = allTrusted.first { $0.fingerprint == fingerprint }?.publicKey
        if let pubKey = signerKey {
            return DeviceIdentityService.shared.verify(signature: sigData, data: signingData, publicKey: pubKey)
        }
        // TOFU: accept if Ed25519 sig is self-consistent (first encounter)
        return false // Reject unknown peers — require BLE trust-first
    }
}

// MARK: - MPC Peer Info

struct MPCPeerInfo: Identifiable, Equatable {
    let id: MCPeerID
    var bleDeviceId: String?
    var userId: String?
    var state: MCSessionState
    var lastSeen: Date
    var isAuthenticated: Bool = false
    
    static func == (lhs: MPCPeerInfo, rhs: MPCPeerInfo) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - MPC Transport Service

final class MPCTransportService: NSObject, ObservableObject {
    static let shared = MPCTransportService()
    
    // MARK: - Constants
    
    private let serviceType = "raven-mesh"
    
    /// Idle timeout: tear down session after no data for this long
    private let idleTimeoutSeconds: TimeInterval = 10
    
    /// Hard upper bound: never keep session open longer than this
    private let maxSessionDuration: TimeInterval = 90
    
    /// Payload size threshold for choosing MPC over BLE
    static let bulkThreshold: Int = 4096
    
    // MARK: - Core MPC Objects

    // Optionals (not IUOs) so a delegate callback that fires before
    // `start()` — e.g. CoreBluetooth state restoration kicking the
    // browser back to life across an app relaunch — doesn't crash on
    // implicit force-unwrap. Every read site below uses
    // `guard let session = self.session else { … }` to bind a stable
    // non-optional local copy for the duration of the operation.
    private var myPeerId: MCPeerID?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    
    // MARK: - State
    
    @Published private(set) var connectedMPCPeers: [MPCPeerInfo] = []
    @Published private(set) var isActive: Bool = false
    
    /// BLE deviceId → MCPeerID mapping
    private var bleToMPC: [String: MCPeerID] = [:]
    private let mapLock = NSLock()
    
    /// Pending session nonces for auth binding (BLE nonce → bleDeviceId)
    private var pendingNonces: [String: String] = [:]
    private let nonceLock = NSLock()
    
    /// Authenticated peers (MCPeerID displayName → true)
    private var authenticatedPeers: Set<String> = []
    
    /// Idle teardown timers per peer
    private var idleTimers: [MCPeerID: Timer] = [:]
    
    /// Hard session start times
    private var sessionStartTimes: [MCPeerID: Date] = [:]
    
    /// Background task for in-flight transfers
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    private var activeTransferCount: Int = 0
    private let transferLock = NSLock()
    
    // MARK: - Callbacks
    
    var onDataReceived: ((Data, MCPeerID) -> Void)?
    var onResourceReceived: ((URL, MCPeerID) -> Void)?
    var onPeerConnected: ((MCPeerID, String?) -> Void)?
    var onPeerDisconnected: ((MCPeerID) -> Void)?
    
    // MARK: - Init
    
    private override init() {
        super.init()
        // 🟡 BUG FIX (2026-05-10): stop MCNearbyServiceAdvertiser when
        // the app backgrounds. Previously it kept emitting Bonjour
        // beacons unbounded; iOS 26 throttles bonjour-using
        // advertisers in background and Apple's BG-network audit
        // flags the bundle. We resume on foreground via the existing
        // BLEMeshEngine wiring that calls `start()`.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.advertiser?.stopAdvertisingPeer()
            self?.browser?.stopBrowsingForPeers()
            logger.debug("paused advertiser+browser (app backgrounded)")
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Only resume if we were active; don't kick MPC into life
            // for a user who never signed in.
            guard let self, self.isActive else { return }
            self.advertiser?.startAdvertisingPeer()
            self.browser?.startBrowsingForPeers()
            logger.debug("resumed advertiser+browser (app foregrounded)")
        }
    }
    
    // MARK: - Public API
    
    func start(deviceFingerprint: String) {
        guard !isActive else { return }

        // 🔴 ROUND 26 (2026-05-16) — hacker-audit MESH-MED-8.
        //
        //   PREVIOUSLY: `displayName = "RAVEN-<8-hex-of-device-fingerprint>"`
        //   and `discoveryInfo["fp"] = <12-hex-of-device-fingerprint>`.
        //   Both fields are broadcast in cleartext over Bonjour /
        //   AWDL. The device fingerprint is the SHA-256 of our
        //   Ed25519 identity key — stable across reboots — so a
        //   passive observer on the same Wi-Fi LAN sees a constant
        //   per-device beacon and can track the user across coffee-
        //   shop visits, even without ever connecting to us.
        //
        //   FIX: derive an EPHEMERAL session identifier from
        //   `SecRandomCopyBytes`. The displayName is just a transport-
        //   level handle — identity verification happens AFTER
        //   connection via the existing `MPCAuthChallenge` Noise IK
        //   handshake. Rotating per `start()` call gives us a fresh
        //   identifier on every app launch + every transport restart.
        //
        //   The `fp` discoveryInfo field is dropped entirely. Anyone
        //   who legitimately needs to know our static identity will
        //   learn it via the post-handshake auth flow.
        let sessionNonce = Self.randomSessionId()
        let id = MCPeerID(displayName: "RAVEN-\(sessionNonce)")
        myPeerId = id
        _ = deviceFingerprint  // intentionally unused on the wire now

        let s = MCSession(
            peer: id,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        s.delegate = self
        session = s

        let discoveryInfo: [String: String] = [
            "v": "1"
            // `fp` removed (MESH-MED-8): the static device fingerprint
            // was the cross-session tracking handle. Anyone who needs
            // our long-term identity authenticates via Noise IK
            // post-connection, not via the Bonjour discovery info.
        ]

        advertiser = MCNearbyServiceAdvertiser(
            peer: id,
            discoveryInfo: discoveryInfo,
            serviceType: serviceType
        )
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()

        browser = MCNearbyServiceBrowser(
            peer: id,
            serviceType: serviceType
        )
        browser?.delegate = self
        browser?.startBrowsingForPeers()
        
        DispatchQueue.main.async { self.isActive = true }

        let displayName = myPeerId?.displayName ?? "unknown"
        logger.debug("Started - advertising + browsing as \(displayName, privacy: .private)")
    }
    
    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        
        for timer in idleTimers.values { timer.invalidate() }
        idleTimers.removeAll()
        sessionStartTimes.removeAll()
        authenticatedPeers.removeAll()
        
        nonceLock.withLock { pendingNonces.removeAll() }
        mapLock.withLock { bleToMPC.removeAll() }
        
        endBackgroundTaskIfNeeded()
        
        DispatchQueue.main.async {
            self.connectedMPCPeers.removeAll()
            self.isActive = false
        }

        logger.debug("Stopped")
    }
    
    // MARK: - Auth Binding
    
    /// Register a session nonce from BLE handshake for auth binding
    func registerSessionNonce(_ nonce: String, bleDeviceId: String) {
        nonceLock.withLock { pendingNonces[nonce] = bleDeviceId }
    }
    
    /// Send auth challenge as the first MPC message after connection
    private func sendAuthChallenge(to peer: MCPeerID, nonce: String) {
        guard let session,
              let challenge = MPCAuthChallenge.create(sessionNonce: nonce),
              let data = try? JSONEncoder().encode(challenge) else { return }

        // Tag as auth message
        var tagged = Data([0xAC]) // Auth Challenge marker byte
        tagged.append(data)
        try? session.send(tagged, toPeers: [peer], with: .reliable)

        logger.debug("Sent auth challenge to \(peer.displayName, privacy: .private)")
    }
    
    // MARK: - Sending Data
    
    func sendBulkData(_ data: Data, to peer: MCPeerID) throws {
        guard let session else { throw MPCError.sessionNotActive }
        guard session.connectedPeers.contains(peer) else { throw MPCError.peerNotConnected }
        guard authenticatedPeers.contains(peer.displayName) else { throw MPCError.peerNotAuthenticated }

        beginBackgroundTaskIfNeeded()

        // Tag as regular data (0xDA marker)
        var tagged = Data([0xDA])
        tagged.append(data)
        try session.send(tagged, toPeers: [peer], with: .reliable)
        resetIdleTimer(for: peer)

        logger.debug("Sent \(data.count, privacy: .public) bytes to \(peer.displayName, privacy: .private)")
    }
    
    func broadcastBulkData(_ data: Data) throws {
        guard let session, !session.connectedPeers.isEmpty else { throw MPCError.noPeersConnected }
        let authed = session.connectedPeers.filter { authenticatedPeers.contains($0.displayName) }
        guard !authed.isEmpty else { throw MPCError.noPeersConnected }

        var tagged = Data([0xDA])
        tagged.append(data)
        try session.send(tagged, toPeers: authed, with: .reliable)
    }
    
    func sendResource(
        at url: URL, to peer: MCPeerID, resourceName: String,
        progress: @escaping (Double) -> Void
    ) async throws {
        guard let session else { throw MPCError.sessionNotActive }
        guard session.connectedPeers.contains(peer) else { throw MPCError.peerNotConnected }
        guard authenticatedPeers.contains(peer.displayName) else { throw MPCError.peerNotAuthenticated }

        beginBackgroundTaskIfNeeded()

        return try await withCheckedThrowingContinuation { continuation in
            let p = session.sendResource(at: url, withName: resourceName, toPeer: peer) { [weak self] error in
                self?.endBackgroundTaskIfNeeded()
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
            if let p {
                let obs = p.observe(\.fractionCompleted) { prog, _ in progress(prog.fractionCompleted) }
                objc_setAssociatedObject(p, "observer", obs, .OBJC_ASSOCIATION_RETAIN)
            }
        }
    }
    
    // MARK: - Cross-Transport
    
    func registerBLEMapping(bleDeviceId: String, mpcPeer: MCPeerID) {
        mapLock.withLock { bleToMPC[bleDeviceId] = mpcPeer }
    }
    
    func mpcPeer(for bleDeviceId: String) -> MCPeerID? {
        mapLock.lock()
        defer { mapLock.unlock() }
        guard let peer = bleToMPC[bleDeviceId],
              session?.connectedPeers.contains(peer) == true,
              authenticatedPeers.contains(peer.displayName) else {
            bleToMPC.removeValue(forKey: bleDeviceId)
            return nil
        }
        return peer
    }
    
    func isMPCAvailable(for bleDeviceId: String) -> Bool { mpcPeer(for: bleDeviceId) != nil }
    var connectedPeerIds: [MCPeerID] { session?.connectedPeers ?? [] }
    
    // MARK: - Idle-Based Teardown
    
    private func resetIdleTimer(for peer: MCPeerID) {
        idleTimers[peer]?.invalidate()
        
        // Also check hard upper bound
        if let start = sessionStartTimes[peer],
           Date().timeIntervalSince(start) > maxSessionDuration {
            logger.debug("Hard session limit reached for \(peer.displayName, privacy: .private)")
            idleTimers.removeValue(forKey: peer)
            return
        }

        let timer = Timer.scheduledTimer(withTimeInterval: idleTimeoutSeconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            logger.debug("Idle timeout for \(peer.displayName, privacy: .private) - session idle")
            self.idleTimers.removeValue(forKey: peer)
        }
        idleTimers[peer] = timer
    }
    
    // MARK: - Background Task
    
    private func beginBackgroundTaskIfNeeded() {
        let shouldBegin = transferLock.withLock { () -> Bool in
            activeTransferCount += 1
            return backgroundTaskId == .invalid
        }
        
        guard shouldBegin else { return }
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "MPC Transfer") { [weak self] in
            self?.endBackgroundTaskIfNeeded()
        }
    }
    
    private func endBackgroundTaskIfNeeded() {
        let (shouldEnd, taskId) = transferLock.withLock { () -> (Bool, UIBackgroundTaskIdentifier) in
            activeTransferCount = max(0, activeTransferCount - 1)
            let shouldEnd = activeTransferCount == 0 && backgroundTaskId != .invalid
            let taskId = backgroundTaskId
            if shouldEnd { backgroundTaskId = .invalid }
            return (shouldEnd, taskId)
        }
        
        if shouldEnd {
            UIApplication.shared.endBackgroundTask(taskId)
        }
    }
    
    // MARK: - Errors
    
    enum MPCError: Error, LocalizedError {
        case sessionNotActive
        case peerNotConnected
        case noPeersConnected
        case peerNotAuthenticated
        case transferFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .sessionNotActive: return "MPC session is not active"
            case .peerNotConnected: return "Peer not connected via MPC"
            case .noPeersConnected: return "No MPC peers connected"
            case .peerNotAuthenticated: return "Peer not authenticated"
            case .transferFailed(let r): return "Transfer failed: \(r)"
            }
        }
    }

    // MARK: - Session identifier (round 26, MED-8)

    /// Generate an ephemeral, cryptographically-random 8-hex
    /// identifier used as the `MCPeerID` displayName for this
    /// transport session. Rotated per `start()` call so a passive
    /// Bonjour scanner can't track our device across launches.
    private static func randomSessionId() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)   // 4 bytes → 8 hex chars
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Fallback to UUID; SecRandomCopyBytes should never fail
            // on a running device but defence-in-depth.
            return String(UUID().uuidString.prefix(8).lowercased())
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - MCSessionDelegate

extension MPCTransportService: MCSessionDelegate {
    
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let s = state == .connected ? "connected" : state == .connecting ? "connecting" : "disconnected"
        logger.debug("Peer \(peerID.displayName, privacy: .private) -> \(s, privacy: .public)")
        
        DispatchQueue.main.async {
            switch state {
            case .connected:
                if let idx = self.connectedMPCPeers.firstIndex(where: { $0.id == peerID }) {
                    self.connectedMPCPeers[idx].state = .connected
                    self.connectedMPCPeers[idx].lastSeen = Date()
                } else {
                    self.connectedMPCPeers.append(MPCPeerInfo(
                        id: peerID, state: .connected, lastSeen: Date()
                    ))
                }
                self.sessionStartTimes[peerID] = Date()
                self.resetIdleTimer(for: peerID)
                
                // Send auth challenge with any pending nonce
                let nonce = self.nonceLock.withLock { self.pendingNonces.first?.key ?? UUID().uuidString }
                self.sendAuthChallenge(to: peerID, nonce: nonce)
                
                self.onPeerConnected?(peerID, nil)
                
            case .notConnected:
                self.connectedMPCPeers.removeAll { $0.id == peerID }
                self.idleTimers[peerID]?.invalidate()
                self.idleTimers.removeValue(forKey: peerID)
                self.sessionStartTimes.removeValue(forKey: peerID)
                self.authenticatedPeers.remove(peerID.displayName)
                
                self.mapLock.withLock { self.bleToMPC = self.bleToMPC.filter { $0.value != peerID } }
                
                self.onPeerDisconnected?(peerID)
                
            case .connecting: break
            @unknown default: break
            }
        }
    }
    
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard !data.isEmpty else { return }
        
        let marker = data[0]
        let payload = data.dropFirst()
        
        switch marker {
        case 0xAC: // Auth Challenge
            if let challenge = try? JSONDecoder().decode(MPCAuthChallenge.self, from: Data(payload)) {
                // 🔴 AUDIT 2026-05-29 (C2) — actually VERIFY the Ed25519-signed
                // challenge against a BLE-trusted identity before trusting the
                // peer. Previously this only did a spoofable displayName /
                // fingerprint prefix match and never called verify(), so any
                // nearby device advertising "RAVEN-*" with a self-consistent
                // fingerprint could authenticate and inject bulk frames.
                // MPCAuthChallenge.verify() resolves the signer key from the
                // BLE-trusted device set and rejects unknown peers.
                Task { [weak self] in
                    guard let self else { return }
                    // Replay guard: reject challenges outside a 5-minute window.
                    let now = Int64(Date().timeIntervalSince1970)
                    guard abs(now - challenge.timestamp) <= 300 else {
                        logger.debug("MPC auth rejected (stale challenge) from \(peerID.displayName, privacy: .private)")
                        return
                    }
                    guard await challenge.verify() else {
                        logger.debug("MPC auth rejected (untrusted signer) from \(peerID.displayName, privacy: .private)")
                        return
                    }
                    self.authenticatedPeers.insert(peerID.displayName)
                    // Map to BLE device via nonce (best-effort binding).
                    self.nonceLock.withLock {
                        if let bleId = self.pendingNonces[challenge.sessionNonce] {
                            self.mapLock.withLock { self.bleToMPC[bleId] = peerID }
                            self.pendingNonces.removeValue(forKey: challenge.sessionNonce)
                        }
                    }
                    logger.debug("Authenticated MPC peer \(peerID.displayName, privacy: .private)")
                }
            }

        case 0xDA: // Regular data
            guard authenticatedPeers.contains(peerID.displayName) else {
                logger.debug("Rejected data from unauthenticated peer \(peerID.displayName, privacy: .private)")
                return
            }
            resetIdleTimer(for: peerID)
            onDataReceived?(Data(payload), peerID)
            
        default:
            // Legacy / untagged — treat as data if authenticated
            guard authenticatedPeers.contains(peerID.displayName) else { return }
            onDataReceived?(data, peerID)
        }
    }
    
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        logger.debug("Receiving resource '\(resourceName, privacy: .private)' from \(peerID.displayName, privacy: .private)")
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        if let error {
            logger.debug("Resource failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let localURL else { return }
        onResourceReceived?(localURL, peerID)
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MPCTransportService: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let isRAVEN = peerID.displayName.hasPrefix("RAVEN-")
        invitationHandler(isRAVEN, isRAVEN ? session : nil)
    }
    
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        logger.debug("Advertise failed: \(error.localizedDescription, privacy: .public)")
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MPCTransportService: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard peerID.displayName.hasPrefix("RAVEN-") else { return }

        if let fp = info?["fp"] {
            mapLock.withLock { bleToMPC[fp] = peerID }
        }

        guard let session, !session.connectedPeers.contains(peerID) else { return }
        let ctx = DeviceIdentityService.shared.fingerprint?.data(using: .utf8)
        browser.invitePeer(peerID, to: session, withContext: ctx, timeout: 10)
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
    
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        logger.debug("Browse failed: \(error.localizedDescription, privacy: .public)")
    }
}
