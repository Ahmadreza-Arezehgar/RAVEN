//
//  BLEMeshEngine.swift
//  RAVEN
//
//  DTN Mesh Implementation - BLE Mesh Engine
//  Handles peer discovery, connection, and message relay
//

@preconcurrency import CoreBluetooth
import Foundation
import Combine
import UIKit
import os
import CryptoKit

// MARK: - Mesh Peer

/// Represents a discovered/connected BLE peer
struct MeshPeer: Identifiable, Equatable {
    let id: UUID
    let deviceId: String
    var userId: String?
    let displayName: String?
    let peripheral: CBPeripheral
    var rssi: Int
    
    // Cryptographic identity
    var fingerprint: String?
    var publicKey: Data?
    var isTrusted: Bool = false
    
    static func == (lhs: MeshPeer, rhs: MeshPeer) -> Bool {
        lhs.deviceId == rhs.deviceId
    }
}

// MARK: - Stop Command

/// Command to stop message propagation in mesh
/// SECURITY: Now includes Ed25519 signature to prevent forged stop commands
struct StopCommand: Codable {
    /// Constant tag baked into the wire format. Declared as `var` only so
    /// Codable's synthesized init(from:) can populate it on decode (a `let`
    /// with a default value is silently skipped, which would let a peer
    /// forge a STOP that the decoder then rebrands).
    var type: String = "STOP"
    let messageId: String
    let timestamp: TimeInterval
    var signature: String?       // Ed25519 signature (base64)
    var signerPublicKey: String? // Signer's public key (base64)

    init(messageId: String, timestamp: TimeInterval) {
        self.messageId = messageId
        self.timestamp = timestamp
    }
    
    /// Data used for signing: type + messageId + timestamp (delimited to prevent canonicalization attacks)
    func signingData() -> Data {
        var data = Data()
        data.append("STOP".data(using: .utf8) ?? Data())
        data.append(Data("|".utf8))
        data.append(messageId.data(using: .utf8) ?? Data())
        data.append(Data("|".utf8))
        // Fix: Use Int64 millis with round() to avoid floating-point drift after JSON round-trip
        let tsString = String(Int64(round(timestamp * 1000)))
        data.append(tsString.data(using: .utf8) ?? Data())
        return data
    }
    
    /// Sign this stop command with device identity
    mutating func sign() {
        let data = signingData()
        if let sig = DeviceIdentityService.shared.sign(data) {
            signature = sig.base64EncodedString()
            signerPublicKey = DeviceIdentityService.shared.publicKeyBase64
        }
    }
    
    /// Verify the signature on this stop command
    func isSignatureValid() -> Bool {
        guard let sigBase64 = signature,
              let sig = Data(base64Encoded: sigBase64),
              let pubKeyBase64 = signerPublicKey,
              let pubKey = Data(base64Encoded: pubKeyBase64) else {
            return false
        }
        return DeviceIdentityService.shared.verify(
            signature: sig,
            data: signingData(),
            publicKey: pubKey
        )
    }
}

// MARK: - Serial Packet Processor (Bug 1 fix)

/// Actor that guarantees serial processing of inbound mesh packets.
/// Replaces the broken GCD-queue + Task{} pattern that allowed parallel execution.
actor MeshPacketProcessor {
    func processPacket(_ data: Data, from deviceId: String, engine: BLEMeshEngine) async {
        let allowed = await MeshCryptoService.shared.checkRateLimit(for: deviceId)
        guard allowed else {
            #if DEBUG
            print("🚫 [BLE] Rate limited peer \(deviceId.prefix(8)) - dropping message")
            #endif
            return
        }
        await engine.processIncomingDataSecure(data, from: deviceId)
    }
}

// MARK: - BLE Mesh Engine

/// Core BLE engine for mesh networking
/// Implements dual-role (Central + Peripheral) for symmetric P2P mesh
///
/// Marked `@unchecked Sendable` because all cross-thread state is guarded by
/// explicit `NSLock`s (`readyContinuationsLock`, `centralReadyLock`,
/// `relayQueueLock`, `processedLock`, `sessionsLock`, …). The `@Published`
/// outputs are only mutated on `MainActor` (every assignment is wrapped in
/// `Task { @MainActor in … }` or its equivalent), so SwiftUI bindings stay
/// safe. Without this annotation, the global-queue safety-timeout closures
/// at the bottom of `waitForPeripheralReady` / `waitForCentralReady` can't
/// capture `self`.
final class BLEMeshEngine: NSObject, ObservableObject, MeshTransportProtocol, @unchecked Sendable {
    static let shared = BLEMeshEngine()
    
    private enum RuntimeProfile: String {
        case foreground
        case backgroundBridge
    }
    
    // MARK: - Published State
    
    @Published private(set) var connectedPeers: [MeshPeer] = []
    @Published private(set) var discoveredPeers: [MeshPeer] = []
    @Published private(set) var isAdvertising: Bool = false
    private var isServiceAdded = false
    /// UI-facing scan state. **Read only from MainActor.** Off-main code
    /// (CBCentralManagerDelegate callbacks, BLE queues) MUST use
    /// `isScanningInternal` / `setScanning(_:)` instead — see helpers below.
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var bluetoothState: CBManagerState = .unknown

    // ──────────────────────────────────────────────────────────────────
    // Thread-safe scan-state mirror.
    //
    // `isScanning` is `@Published` and therefore property-wrapper-backed;
    // mutating @Published off the main thread is a Swift concurrency
    // violation. We keep a lock-protected duplicate for the BLE queues to
    // read/write safely, then propagate to @Published on main.
    // ──────────────────────────────────────────────────────────────────
    private let scanStateLock = NSLock()
    private var _isScanningInternal: Bool = false

    /// Thread-safe read of scan state. Safe from any queue.
    private var isScanningInternal: Bool {
        scanStateLock.lock()
        defer { scanStateLock.unlock() }
        return _isScanningInternal
    }

    /// Public thread-safe accessor for off-main callers (e.g. background
    /// mesh maintenance). Prefer this over `isScanning` whenever the
    /// caller is not guaranteed to be on the MainActor.
    var isCurrentlyScanning: Bool { isScanningInternal }

    /// Thread-safe write of scan state. Updates the internal flag
    /// synchronously, then mirrors to the @Published property on the
    /// MainActor for UI binding. Safe to call from any queue.
    private func setScanning(_ value: Bool) {
        scanStateLock.lock()
        _isScanningInternal = value
        scanStateLock.unlock()
        if Thread.isMainThread {
            self.isScanning = value
        } else {
            DispatchQueue.main.async { [weak self] in self?.isScanning = value }
        }
    }
    
    // Bug 4 fix: Continuation-based wait for BLE buffer readiness
    // Key: peripheral UUID, Value: array of continuations (supports concurrent waits)
    private var peripheralReadyContinuations: [UUID: [UUID: CheckedContinuation<Void, Never>]] = [:]
    private let readyContinuationsLock = NSLock()
    
    // Bug 3 fix: Continuation-based wait for Central (peripheral manager) buffer readiness
    private var centralReadyContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    private let centralReadyLock = NSLock()
    
    // MARK: - Thread Safety (Bug #1 fix)
    
    private let peersLock = OSAllocatedUnfairLock()
    /// Thread-safe snapshot of connectedPeers — read from ANY thread.
    /// Updated atomically whenever connectedPeers changes.
    private var peersSnapshot: [MeshPeer] = []
    
    /// Thread-safe read of the peers snapshot
    private func getSnapshot() -> [MeshPeer] {
        peersLock.withLock { peersSnapshot }
    }
    
    /// Call on main thread whenever connectedPeers is mutated
    private func syncSnapshot() {
        peersLock.withLock { peersSnapshot = connectedPeers }
    }
    
    // MARK: - Thread Safety for centralSubscribers (NSIndirectTaggedPointerString crash fix)
    
    private let subscribersLock = OSAllocatedUnfairLock()
    
    /// Thread-safe read of subscribers count
    var subscriberCount: Int {
        subscribersLock.withLock { centralSubscribers.count }
    }
    
    /// Thread-safe check if subscribers exist
    var hasSubscribers: Bool {
        subscribersLock.withLock { !centralSubscribers.isEmpty }
    }
    
    /// Check if we have any active connections (Central or Peripheral)
    var hasActiveConnections: Bool {
        return !getSnapshot().isEmpty || hasSubscribers
    }
    
    // MARK: - Smart Idle Detection (Battery Optimization)

    /// بررسی اینکه آیا شبکه بلوتوث درگیر اتصال، هندشیک یا انتقال دیتا است
    var isNetworkBusy: Bool {
        // 🛑 FIX 5: Only keep awake if there are ACTIVE connections
        let hasActiveSessions = sessionsLock.withLock { 
            peripheralSessions.values.contains { $0.state == .connected || $0.state == .connecting }
        }
        let hasSubscribers = subscribersLock.withLock { !centralSubscribers.isEmpty }
        let hasPendingOutbound = queueLock.withLock { !messageQueue.isEmpty }
        let hasPendingChunks = Self.chunkLock.withLock { !Self.pendingChunks.isEmpty }
        
        return hasActiveSessions || hasSubscribers || hasPendingOutbound || hasPendingChunks
    }
    
    /// Thread-safe snapshot of subscribers
    func getSubscribers() -> [(central: CBCentral, subscribedAt: Date)] {
        subscribersLock.withLock { centralSubscribers }
    }
    
    /// Thread-safe add subscriber
    private func addSubscriber(_ central: CBCentral) {
        subscribersLock.withLock {
            if !centralSubscribers.contains(where: { $0.central.identifier == central.identifier }) {
                centralSubscribers.append((central: central, subscribedAt: Date()))
            }
        }
    }
    
    /// Thread-safe remove subscriber
    private func removeSubscriber(_ central: CBCentral) {
        subscribersLock.withLock {
            centralSubscribers.removeAll { $0.central.identifier == central.identifier }
        }
    }
    
    /// Thread-safe cleanup of stale subscribers
    private func removeStaleSubscribers(olderThan threshold: TimeInterval = 300) -> Int {
        subscribersLock.withLock {
            let before = centralSubscribers.count
            // FIX: Do NOT remove subscribers based on time — active connections would be killed after 5 min.
            // CoreBluetooth's didUnsubscribeFrom delegate handles cleanup when devices truly disconnect.
            // centralSubscribers.removeAll { now.timeIntervalSince($0.subscribedAt) > threshold }
            return before - centralSubscribers.count
        }
    }
    
    // MARK: - Service UUIDs (Cross-platform compatible)
    // Note: internal access for BLEMeshEngine+Chunking extension
    
    static let serviceUUID = CBUUID(string: "12345678-1234-1234-1234-123456789ABC")
    static let messageCharacteristicUUID = CBUUID(string: "12345678-1234-1234-1234-123456789ABD")
    private static let deviceInfoCharacteristicUUID = CBUUID(string: "12345678-1234-1234-1234-123456789ABE")
    
    // MARK: - Core Bluetooth
    // Note: internal access for BLEMeshEngine+Chunking extension
    
    private var centralManager: CBCentralManager?
    var peripheralManager: CBPeripheralManager?  // internal for chunking extension
    var messageCharacteristic: CBMutableCharacteristic?  // internal for chunking extension
    private var deviceInfoCharacteristic: CBMutableCharacteristic?

    /// v2 message TX/RX — published alongside the v1 service. v2 envelopes
    /// flow over THIS characteristic (binary RUMProtocolV2 wire format)
    /// while v1 keeps using `messageCharacteristic` (JSON). Two channels
    /// means receivers don't have to byte-peek to disambiguate.
    private var v2MessageCharacteristic: CBMutableCharacteristic?

    /// v2 capabilities — read-only, value is a 4-byte big-endian uint32
    /// `RUMProtocolV2.Capabilities` bitfield. Lets peers learn which
    /// transports we support before deciding which protocol to speak.
    private var v2CapabilitiesCharacteristic: CBMutableCharacteristic?

    /// Per-peer capability bitfields, populated when we read their
    /// `RUMProtocolV2.capabilitiesCharacteristicUUID` after connection.
    /// Empty entry → peer didn't expose the v2 service → v1-only.
    private var peerCapabilities: [UUID: RUMProtocolV2.Capabilities] = [:]
    
    // MARK: - State (protected by sessionsLock)
    
    private let sessionsLock = OSAllocatedUnfairLock()
    private var peripheralSessions: [UUID: CBPeripheral] = [:]       // Protected by sessionsLock
    private var discoveredPeripheralIDs: Set<UUID> = []              // Protected by sessionsLock
    private var connectedPeerIDs: Set<UUID> = []                     // Protected by sessionsLock
    private var connectionAttemptStarted: [UUID: Date] = [:]         // Protected by sessionsLock
    private var reconnectAttempts: [UUID: Int] = [:]                  // Protected by sessionsLock
    private var connectionCooldowns: [UUID: Date] = [:]               // Protected by sessionsLock
    
    private var centralSubscribers: [(central: CBCentral, subscribedAt: Date)] = []  // Protected by subscribersLock
    private var messageQueue: [MeshEnvelope] = []  // Protected by queueLock
    private let queueLock = OSAllocatedUnfairLock()
    private let maxQueueSize = 50
    private var runtimeProfile: RuntimeProfile = .foreground
    
    // MARK: - Relay Queue (Store-and-Forward)
    /// Messages received from other peers that need forwarding to future peers.
    /// This is the core DTN store-and-forward buffer.
    private var relayQueue: [MeshEnvelope] = []  // Protected by relayQueueLock
    private let relayQueueLock = OSAllocatedUnfairLock()
    private let maxRelayQueueSize = 30
    
    // MARK: - Periodic Cleanup Timer
    
    private var cleanupTimer: Timer?
    
    // MARK: - Reconnection Tracking (Bug #5 fix)
    
    // reconnectAttempts moved to sessionsLock-protected block above
    private let maxReconnectAttempts = 5
    
    // MARK: - Connection Timeout Tracking
    
    // connectionAttemptStarted moved to sessionsLock-protected block above
    /// Maximum time to wait for didConnect before cancelling and retrying
    private let connectionTimeout: TimeInterval = 900
    
    // MARK: - Stop Tracking (for Internet-First)
    
    /// Message IDs that have been stopped (delivered via server) - uses timestamp for cleanup
    private var stoppedMessageIds: [String: Date] = [:]
    
    /// Lock protecting stoppedMessageIds, lastForwardedToPeer, peerForwardCount, inventoryExchangeState
    private let stateLock = OSAllocatedUnfairLock()
    
    // MARK: - Deduplication (atomic)
    
    private let processedLock = OSAllocatedUnfairLock()
    private var processedMessages: [String: Date] = [:]
    
    // Bug 1 fix: Actor-based serial packet processor (replaces ineffective GCD queue)
    private let packetProcessor = MeshPacketProcessor()
    
    // MARK: - Per-Peer Backoff (Battery saving)
    
    /// Tracks when we last forwarded to each peer (peer deviceId → timestamp)
    private var lastForwardedToPeer: [String: Date] = [:]
    /// Forward count per peer for exponential backoff
    private var peerForwardCount: [String: Int] = [:]
    /// Base interval between forwards to same peer (seconds)
    private let baseForwardInterval: TimeInterval = 2
    /// Maximum backoff interval (15 seconds)
    private let maxForwardInterval: TimeInterval = 15
    
    // MARK: - Inventory Exchange (Anti-Entropy)
    
    /// Per-peer inventory exchange rate-limiter
    private var inventoryExchangeState: [String: InventoryExchangeState] = [:]
    
    // MARK: - Bridge Downlink
    
    /// Tracks last bridge downlink poll to rate-limit
    private var lastBridgeDownlinkPoll: Date = .distantPast
    /// Minimum interval between bridge downlink polls (seconds)
    private let bridgeDownlinkInterval: TimeInterval = 15
    /// Per-message dedup with a 60s TTL.
    ///
    /// ⚡ A→C BRIDGE FIX: previously this was a permanent `Set<String>` that
    /// recorded every message the bridge had EVER attempted to relay. If a
    /// BLE broadcast didn't actually reach the destination peer (chunked
    /// fragment dropped, peer briefly disconnected, encryption mismatch),
    /// the bridge refused to retry on the next 15s poll because the id was
    /// already in the set. The recipient's `delivered_at` stayed NULL on
    /// the server forever — visible as "C → A works but A → C doesn't".
    ///
    /// Now we keep an `id → relayedAt` map. On each poll we evict entries
    /// older than 60s, so a failed delivery automatically retries 4 polls
    /// later. Mesh-level dedup (`MeshDedupRepository`) still prevents the
    /// recipient from processing the message twice if the previous attempt
    /// actually did land — this set only debounces tight retry loops.
    private var bridgeDownlinkRelayedAt: [String: Date] = [:]
    private let bridgeDownlinkRelayTTL: TimeInterval = 60
    /// Lock protecting lastBridgeDownlinkPoll and bridgeDownlinkRelayedAt from concurrent access
    private let downlinkLock = OSAllocatedUnfairLock()
    
    // MARK: - Callback
    
    var onMessageReceived: ((MeshEnvelope) -> Void)?
    var onACKReceived: ((MeshACKEnvelope) -> Void)?
    var onMeshPostReceived: ((MeshPostEnvelope) -> Void)?
    var onPeerConnected: ((String) -> Void)?  // Called with peerId when peer fully connects
    
    // MARK: - Feature Handler Registry
    
    /// Registered handlers for feature-specific mesh message kinds.
    /// Features register at app launch via `register(handler:for:)`.
    /// Thread-safe: protected by handlersLock.
    private var messageHandlers: [MeshMessageKind: (Data, String) async -> Void] = [:]
    private let handlersLock = OSAllocatedUnfairLock()
    
    /// Register a handler for a specific mesh message kind.
    /// Call this at app launch from each feature service.
    ///
    /// Example:
    /// ```swift
    /// BLEMeshEngine.shared.register(for: .echoBroadcast) { data, deviceId in
    ///     await EchoService.shared.handleIncoming(data: data, from: deviceId)
    /// }
    /// ```
    func register(for kind: MeshMessageKind, handler: @escaping (Data, String) async -> Void) {
        handlersLock.withLock {
            messageHandlers[kind] = handler
        }
        #if DEBUG
        print("📡 [BLE] Registered handler for \(kind.rawValue)")
        #endif
    }
    
    // MARK: - Device Info
    
    private var deviceId: String {
        // Use cryptographic fingerprint instead of hardware ID
        DeviceIdentityService.shared.fingerprint ?? UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    }
    
    private var localFingerprint: String? {
        DeviceIdentityService.shared.fingerprint
    }
    
    private var localPublicKey: Data? {
        DeviceIdentityService.shared.publicKeyData
    }
    
    // MARK: - Init
    
    private override init() {
        super.init()
    }
    
    // MARK: - Public API
    
    func start() {
        #if DEBUG
        print("🔍 [BLE DEBUG] start() called!")
        #endif

        // Subscribe the relay service to v2 envelope arrivals so multi-
        // hop forwarding works the moment we have any peers. Idempotent.
        Task { @MainActor in RUMRelayService.shared.start() }

        // Activate the WatchConnectivity bridge so a paired Apple Watch
        // can compose DMs through us. No-op when the user hasn't paired
        // a Watch or the Watch app isn't installed yet.
        Task { @MainActor in
            WatchBridgeService.shared.start()
            // Project chat/feed/room state into the Watch snapshot
            // pipeline. Idempotent; safe to invoke on every mesh start.
            WatchSnapshotProjector.shared.start()
        }

        // Activate Wi-Fi Aware (iOS 26+). On older systems this is a
        // no-op; the scaffold is in place so the moment we ship an
        // iOS 26-only build slice with the publisher/subscriber
        // bodies filled in, every v2 envelope path picks it up
        // automatically. Receivers dedup cross-transport via msg_id.
        //
        // SAME RACE FIX as `startMPCTransport()`: must `await initialize()`
        // before reading `fingerprint`, otherwise the WAT publisher
        // advertises as `"unknown"` and every cross-device auth handshake
        // silently drops payloads. (See the long comment block at line
        // 1430 for the original investigation.)
        Task { @MainActor in
            try? await DeviceIdentityService.shared.initialize()
            let fp = DeviceIdentityService.shared.fingerprint ?? "unknown"
            WiFiAwareTransport.shared.start(deviceFingerprint: fp)
            WiFiAwareTransport.shared.onDataReceived = { [weak self] data, peer in
                guard let self else { return }
                let deviceId = peer.displayName
                Task { @MainActor in
                    if data.first == RUMProtocolV2.version {
                        self.handleV2EnvelopePayload(data, from: deviceId)
                    } else {
                        // Old v1 JSON arriving over Wi-Fi Aware also
                        // routes to the existing chat ingest pipeline
                        // (decrypt + signature verify + dedup all live
                        // there).
                        Task { await self.packetProcessor.processPacket(data, from: deviceId, engine: self) }
                    }
                }
            }
        }

        if centralManager == nil {
            // Create with restoration identifier for background support.
            // Mac Catalyst doesn't support BLE state restoration — drop the
            // restore-identifier option but keep the manager itself.
            #if targetEnvironment(macCatalyst)
            let centralOptions: [String: Any] = [
                CBCentralManagerOptionShowPowerAlertKey: false
            ]
            #else
            let centralOptions: [String: Any] = [
                CBCentralManagerOptionRestoreIdentifierKey: "com.raven.ble.central.restore",
                CBCentralManagerOptionShowPowerAlertKey: false
            ]
            #endif
            centralManager = CBCentralManager(
                delegate: self,
                queue: DispatchQueue(label: "com.raven.ble.central", qos: .userInitiated),
                options: centralOptions
            )
            #if DEBUG
            print("🔍 [BLE DEBUG] Created CBCentralManager with restoration support")
            #endif
        }

        if peripheralManager == nil {
            // Create with restoration identifier for background support.
            // Mac Catalyst: see comment on centralManager above.
            #if targetEnvironment(macCatalyst)
            let peripheralOptions: [String: Any] = [
                CBPeripheralManagerOptionShowPowerAlertKey: false
            ]
            #else
            let peripheralOptions: [String: Any] = [
                CBPeripheralManagerOptionRestoreIdentifierKey: "com.raven.ble.peripheral.restore",
                CBPeripheralManagerOptionShowPowerAlertKey: false
            ]
            #endif
            peripheralManager = CBPeripheralManager(
                delegate: self,
                queue: DispatchQueue(label: "com.raven.ble.peripheral", qos: .userInitiated),
                options: peripheralOptions
            )
            #if DEBUG
            print("🔍 [BLE DEBUG] Created CBPeripheralManager with restoration support")
            #endif
        }
        
        // Start periodic cleanup timer
        startPeriodicCleanup()
        
        // Start MPC bulk transport alongside BLE
        startMPCTransport()
        
        #if DEBUG
        print("📡 [BLE] Engine starting with background restoration...")
        print("🔍 [BLE DEBUG] Waiting for Bluetooth state callbacks...")
        #endif
    }
    
    func stop() {
        Task { @MainActor in RUMRelayService.shared.stop() }
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        stopScanning()
        stopAdvertising()
        disconnectAllPeers()
        stopMPCTransport()
        // PRoPHET: Persist P-table on shutdown
        Task { await DeliveryPredictabilityService.shared.save() }
        #if DEBUG
        print("🔴 [BLE] Engine stopped")
        #endif
    }
    
    /// Toggle BLE runtime for foreground/background bridge behavior.
    /// NOTE: iOS does not allow truly "always-on" execution; this configures best-effort background behavior.
    func setBackgroundBridgeMode(enabled: Bool) {
        runtimeProfile = enabled ? .backgroundBridge : .foreground
        
        if enabled {
            BackgroundMeshManager.shared.beginBackgroundTask(
                identifier: "ble_background_bridge",
                reason: .userInitiated
            )
            restartScanningForCurrentProfile()
            // Flush any pending relay work while we have runtime.
            drainPendingFromDB()
            drainPendingFromOutbox()
            endBackgroundTaskLater(identifier: "ble_background_bridge", after: 25)
            #if DEBUG
            print("📡 [BLE] Background bridge mode enabled (best-effort)")
            #endif
        } else {
            restartScanningForCurrentProfile()
            BackgroundMeshManager.shared.endBackgroundTask(identifier: "ble_background_bridge")
            #if DEBUG
            print("📡 [BLE] Foreground BLE mode enabled")
            #endif
        }
    }
    
    /// Start periodic cleanup for stale data
    private func startPeriodicCleanup() {
        cleanupTimer?.invalidate()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.clearOldStops()
                self?.cleanupStaleSubscribers()
                self?.cleanupStaleChunks()
                self?.sweepStaleSessions()
                await self?.bridgeDownlinkPoll()
                // PRoPHET: Prune forgotten entries (lazy aging — no batch updates)
                await DeliveryPredictabilityService.shared.pruneForgotten()
            }
        }
    }
    
    /// Sweep stale BLE sessions using iOS's ground-truth API
    private func sweepStaleSessions() {
        guard let cm = centralManager else { return }
        
        var cancelled = 0
        var promoted = 0
        
        // Step 1: Ask iOS for TRULY connected peripherals (ground truth)
        let realConnected = cm.retrieveConnectedPeripherals(withServices: [Self.serviceUUID])
        let realUUIDs = Set(realConnected.map { $0.identifier })
        
        // Step 2: Snapshot session state under lock, compute actions, then execute outside lock
        struct SweepAction {
            var phantomsToCancel: [(uuid: UUID, peripheral: CBPeripheral)] = []
            var toPromote: [(uuid: UUID, peripheral: CBPeripheral)] = []
            var newlyDiscovered: [(uuid: UUID, peripheral: CBPeripheral)] = []
        }
        
        let actions: SweepAction = sessionsLock.withLock {
            var result = SweepAction()
            let sessionCount = peripheralSessions.count
            #if DEBUG
            print("[SW] sweep: sessions=\(sessionCount) real=\(realConnected.count)")
            #endif
            
            for (uuid, peripheral) in peripheralSessions {
                if realUUIDs.contains(uuid) {
                    if !connectedPeerIDs.contains(uuid) {
                        if let freshPeripheral = realConnected.first(where: { $0.identifier == uuid }) {
                            peripheralSessions[uuid] = freshPeripheral
                            result.toPromote.append((uuid: uuid, peripheral: freshPeripheral))
                        }
                    }
                } else {
                    // Give connecting/connected peripherals a grace period before cancelling
                    if peripheral.state == .connecting {
                        if let started = connectionAttemptStarted[uuid],
                           Date().timeIntervalSince(started) > connectionTimeout {
                            result.phantomsToCancel.append((uuid: uuid, peripheral: peripheral))
                        }
                    } else if peripheral.state == .connected {
                        if let started = connectionAttemptStarted[uuid] {
                            if Date().timeIntervalSince(started) > (connectionTimeout + 15) {
                                result.phantomsToCancel.append((uuid: uuid, peripheral: peripheral))
                            }
                        } else {
                            result.phantomsToCancel.append((uuid: uuid, peripheral: peripheral))
                        }
                    } else {
                        result.phantomsToCancel.append((uuid: uuid, peripheral: peripheral))
                    }
                }
            }
            
            // Remove phantoms AFTER iteration to avoid mutation-during-iteration crash
            for phantom in result.phantomsToCancel {
                peripheralSessions.removeValue(forKey: phantom.uuid)
                connectionAttemptStarted.removeValue(forKey: phantom.uuid)
                discoveredPeripheralIDs.remove(phantom.uuid)
                connectedPeerIDs.remove(phantom.uuid)
                connectionCooldowns[phantom.uuid] = Date().addingTimeInterval(60) // Cooldown for 60s
            }
            
            for real in realConnected {
                let uuid = real.identifier
                if peripheralSessions[uuid] == nil && !connectedPeerIDs.contains(uuid) {
                    peripheralSessions[uuid] = real
                    result.newlyDiscovered.append((uuid: uuid, peripheral: real))
                }
            }
            return result
        }
        
        // Execute CB API calls outside the lock
        for phantom in actions.phantomsToCancel {
            let peerId = phantom.uuid.uuidString.prefix(8)
            #if DEBUG
            print("[SW] 👻 phantom \(peerId) removed")
            #endif
            cm.cancelPeripheralConnection(phantom.peripheral)
            DispatchQueue.main.async {
                self.connectedPeers.removeAll { $0.id == phantom.uuid }
                self.syncSnapshot()
            }
            cancelled += 1
        }
        
        for item in actions.toPromote {
            let peerId = item.uuid.uuidString.prefix(8)
            item.peripheral.delegate = self
            if let ravenService = item.peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }),
               let chars = ravenService.characteristics, !chars.isEmpty {
                #if DEBUG
                print("[SW] \(peerId) cached GATT → fast-promote")
                #endif
                self.peripheral(item.peripheral, didDiscoverCharacteristicsFor: ravenService, error: nil)
            } else if let ravenService = item.peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) {
                #if DEBUG
                print("[SW] \(peerId) cached service → discover chars")
                #endif
                item.peripheral.discoverCharacteristics(
                    [Self.messageCharacteristicUUID, Self.deviceInfoCharacteristicUUID],
                    for: ravenService
                )
            } else {
                #if DEBUG
                print("[SW] \(peerId) connected → discover services")
                #endif
                item.peripheral.discoverServices([Self.serviceUUID])
            }
            promoted += 1
        }
        
        for item in actions.newlyDiscovered {
            let peerId = item.uuid.uuidString.prefix(8)
            #if DEBUG
            print("[SW] 🆕 unknown connected \(peerId) → discover")
            #endif
            item.peripheral.delegate = self
            item.peripheral.discoverServices([Self.serviceUUID])
            promoted += 1
        }
        
        let finalCount = sessionsLock.withLock { peripheralSessions.count }
        #if DEBUG
        print("[SW] done: cancelled=\(cancelled) promoted=\(promoted) sessions=\(finalCount)")
        #endif
        if cancelled > 0 { restartScanningForCurrentProfile() }
        
        // Fix: If we promoted peers, flush queued messages to them immediately
        if promoted > 0 {
            flushQueueIfNeeded()
            drainPendingFromOutbox()
        }
    }
    
    /// Broadcast message to all connected peers
    /// SECURITY: Signs envelope with Ed25519 before transmission
    func enqueueForBroadcast(_ envelope: MeshEnvelope) async {
        let allowedTypes = [0, 4, 6] // text, location, system
        guard allowedTypes.contains(envelope.type) else {
            return
        }

        let peers = getSnapshot()
        #if DEBUG
        print("[S1] send mid=\(envelope.clientMessageId.prefix(8)) peers=\(peers.count) subs=\(subscriberCount)")
        #endif
        
        // Store in relay queue so future peers also receive this message
        if envelope.sprayCounter > 0 {
            queueLock.withLock {
                messageQueue.removeAll { $0.clientMessageId == envelope.clientMessageId }
            }
            addToRelayQueue(envelope)
        }
        
        // Record mesh-path attempt for dual-path race visibility.
        try? await MessageRepository.shared.markSentViaMesh(clientMessageId: envelope.clientMessageId)
        
        // ════════════════════════════════════════════════════════════════
        // 🛡️ SECURITY: Sign + Encrypt envelope before BLE transmission
        // ════════════════════════════════════════════════════════════════
        let data: Data
        do {
            let secureEnvelope = envelope.toSecureEnvelope()
            let signedPayload = try await MeshCryptoService.shared.signEnvelope(secureEnvelope)
            
            // Bug 6: Broadcast messages are SIGNED but not encrypted.
            // BLE broadcasts go to ALL subscribed centrals simultaneously, so we
            // can't use per-peer ECDH shared secrets here. Point-to-point sends
            // (via `send(_:to:)`) DO encrypt using per-peer X25519 agreement keys
            // when available. Signature provides authentication + integrity.
            data = try JSONEncoder().encode(signedPayload)
            #if DEBUG
            print("[S1] signed broadcast (\(data.count)B)")
            #endif
            
        } catch {
            #if DEBUG
            print("  [S1] sign failed: \(error)")
            #endif
            return
        }
        
        if !hasActiveConnections {
            // Queue for later — evict lowest-priority if full
            queueLock.withLock {
                if messageQueue.count < maxQueueSize {
                    messageQueue.append(envelope)
                    #if DEBUG
                    print("[S2] queued (no peers) queue=\(messageQueue.count)")
                    #endif
                } else {
                    // EVICTION: Drop the oldest, lowest-priority message
                    if let evictIdx = messageQueue.indices.min(by: { a, b in
                        let pa = Self.envelopePriority(messageQueue[a])
                        let pb = Self.envelopePriority(messageQueue[b])
                        if pa != pb { return pa < pb }  // Lower priority first
                        return messageQueue[a].timestamp < messageQueue[b].timestamp  // Older first
                    }), Self.envelopePriority(envelope) > Self.envelopePriority(messageQueue[evictIdx]) {
                        let evicted = messageQueue[evictIdx]
                        messageQueue[evictIdx] = envelope
                        #if DEBUG
                        print("[S2] queue full, evicted \(evicted.clientMessageId.prefix(8))")
                        #endif
                    } else {
                        #if DEBUG
                        print("[S2] queue full, dropped")
                        #endif
                    }
                }
            }
            return
        }
        
        await broadcastDataChunked(data)
        #if DEBUG
        print("[S3] ✅ broadcast complete to \(peers.count) peers")
        #endif
    }
    
    /// Send ACK envelope for delivery/read receipt.
    /// ⚡ SECURITY (audit #5b): every outgoing ACK is now Ed25519-signed before
    /// broadcast. Receivers will reject unsigned ACKs, so callers MUST be in a
    /// state where the device identity can sign (i.e., DeviceIdentityService is
    /// initialized). If signing fails we drop the ACK rather than send unsigned.
    func sendACK(_ ack: MeshACKEnvelope) async {
        var signedAck = ack
        if signedAck.signature == nil {
            signedAck.sign()
        }
        guard signedAck.signature != nil else {
            #if DEBUG
            print("❌ [BLE] Refusing to send unsigned ACK \(ack.originalMessageId.prefix(8)) — signing failed")
            #endif
            return
        }
        guard let data = signedAck.toData() else {
            #if DEBUG
            print("❌ [BLE] Failed to encode signed ACK")
            #endif
            return
        }

        #if DEBUG
        print("📨 [BLE] Sending signed ACK for message \(signedAck.originalMessageId.prefix(8)) - status: \(signedAck.status.rawValue)")
        #endif
        await broadcastData(data)
    }
    
    /// Broadcast raw post data (called by MeshPostService)
    func broadcastPostData(_ data: Data) async {
        await broadcastDataChunked(data)
    }
    
    func sendPostData(_ data: Data, to peerDeviceId: String) async {
        if let peer = getSnapshot().first(where: { $0.deviceId == peerDeviceId }) {
            await sendDataChunkedToPeer(data, peer: peer)
        }
    }
    
    // MARK: - Stop Support (Internet-First v2.0)
    
    /// Stop a message and broadcast stop to mesh (server delivered first)
    /// SECURITY: Signs stop command with Ed25519
    func broadcastStop(_ messageId: String) async {
        // 1. Local stop
        stateLock.withLock { stoppedMessageIds[messageId] = Date() }
        queueLock.withLock {
            messageQueue.removeAll { $0.clientMessageId == messageId }
        }
        
        // 2. Persist to cache
        try? await StopCacheRepository.shared.persist(messageId)
        
        // 3. Remove from Relay Queue
        await RelayQueueRepository.shared.remove(messageId: messageId)
        
        // 4. Broadcast signed stop command to mesh
        var stopCommand = StopCommand(messageId: messageId, timestamp: Date().timeIntervalSince1970)
        stopCommand.sign()
        if let data = try? JSONEncoder().encode(stopCommand) {
            await broadcastData(data)
            #if DEBUG
            print("🛑 [BLE] Broadcast signed STOP(\(messageId.prefix(8))) to mesh")
            #endif
        }
    }
    
    /// Handle incoming stop command from mesh
    func handleStop(_ messageId: String) async {
        guard stateLock.withLock({ stoppedMessageIds[messageId] == nil }) else { return }
        
        // 1. Local stop
        stateLock.withLock { stoppedMessageIds[messageId] = Date() }
        queueLock.withLock {
            messageQueue.removeAll { $0.clientMessageId == messageId }
        }
        
        // 2. Persist with TTL
        try? await StopCacheRepository.shared.persist(messageId)
        
        // 3. Stop any delivery jobs
        try? await DeliveryJobRepository.shared.markStopped(messageId: messageId)
        
        // 4. Remove from Relay Queue
        await RelayQueueRepository.shared.remove(messageId: messageId)
        
        // 5. Forward signed stop to mesh (propagation)
        var stopCommand = StopCommand(messageId: messageId, timestamp: Date().timeIntervalSince1970)
        stopCommand.sign()
        if let data = try? JSONEncoder().encode(stopCommand) {
            await broadcastData(data)
        }
        
        #if DEBUG
        print("🛑 [BLE] Received and propagated STOP(\(messageId.prefix(8)))")
        #endif
    }
    
    /// Legacy stop method (for backward compatibility)
    func stopMessage(_ messageId: String) async {
        stateLock.withLock { stoppedMessageIds[messageId] = Date() }
        queueLock.withLock {
            messageQueue.removeAll { $0.clientMessageId == messageId }
        }
        #if DEBUG
        print("🛑 [BLE] Message \(messageId.prefix(8)) stopped - server delivered")
        #endif
    }
    
    /// Check if a message has been stopped
    func isMessageStopped(_ messageId: String) async -> Bool {
        // Check memory first, then persistent cache
        if stateLock.withLock({ stoppedMessageIds[messageId] != nil }) { return true }
        if let stopped = try? await StopCacheRepository.shared.isStopped(messageId), stopped {
            stateLock.withLock { stoppedMessageIds[messageId] = Date() } // Cache in memory too
            return true
        }
        return false
    }
    
    /// Apply a list of stop message IDs (from server sync)
    func applyStopList(_ messageIds: [String]) async {
        let now = Date()
        stateLock.withLock {
            for mid in messageIds {
                stoppedMessageIds[mid] = now
            }
        }
        queueLock.withLock {
            for mid in messageIds {
                messageQueue.removeAll { $0.clientMessageId == mid }
            }
        }
        for mid in messageIds { // Persist outside lock
            try? await StopCacheRepository.shared.persist(mid)
        }
        #if DEBUG
        print("🛑 [BLE] Applied stop list: \(messageIds.count) messages")
        #endif
    }
    
    /// Clear old stopped message IDs (call periodically) - now uses timestamp-based cleanup
    func clearOldStops() async {
        let cutoff = Date().addingTimeInterval(-7200) // 2 hours ago (increased for better dedup)
        stateLock.withLock {
            stoppedMessageIds = stoppedMessageIds.filter { $0.value > cutoff }
            lastForwardedToPeer = lastForwardedToPeer.filter { $0.value > cutoff }
            peerForwardCount = peerForwardCount.filter { lastForwardedToPeer[$0.key] != nil }
        }
        
        // Also cleanup processed messages cache
        processedLock.withLock {
            processedMessages = processedMessages.filter { $0.value > cutoff }
        }
        
        // Cleanup expired relay queue entries
        relayQueueLock.withLock {
            let relayBefore = relayQueue.count
            relayQueue.removeAll { $0.isExpired }
            let relayAfter = relayQueue.count
            
            #if DEBUG
            print("🧹 [BLE] Cleaned old stops/processed, remaining: \(stoppedMessageIds.count)/\(processedMessages.count) relay=\(relayAfter)")
            #endif
            if relayBefore != relayAfter {
                #if DEBUG
                print("🧹 [BLE] Expired \(relayBefore - relayAfter) relay queue entries")
                #endif
            }
        }
        
        // ⚡ Purge non-connected discovered peripherals to prevent memory leak.
        // BLE MAC randomization creates thousands of unique CBPeripheral UUIDs
        // in crowded environments. Keep only truly connected devices in memory.
        let activeIDs = sessionsLock.withLock { connectedPeerIDs }
        let purgedDiscoveredCount = sessionsLock.withLock { () -> Int in
            let before = discoveredPeripheralIDs.count
            discoveredPeripheralIDs = activeIDs
            
            // Clean up expired connection cooldowns
            let now = Date()
            connectionCooldowns = connectionCooldowns.filter { $0.value > now }
            
            return before - discoveredPeripheralIDs.count
        }
        if purgedDiscoveredCount > 0 {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.discoveredPeers = self.connectedPeers
                #if DEBUG
                print("🧹 [BLE] Purged \(purgedDiscoveredCount) stale discovered peripherals from memory")
                #endif
            }
        }
    }
    
    // MARK: - Relay Queue (Store-and-Forward)
    
    /// Add an envelope to the relay queue for future peer delivery
    private func addToRelayQueue(_ envelope: MeshEnvelope) {
        let count = relayQueueLock.withLock { () -> Int? in
            // Dedup: don't add if already queued
            guard !relayQueue.contains(where: { $0.clientMessageId == envelope.clientMessageId }) else {
                return nil
            }
            // Evict oldest if full
            if relayQueue.count >= maxRelayQueueSize, !relayQueue.isEmpty {
                let evicted = relayQueue.removeFirst()
                #if DEBUG
                print("📦 [RELAY-Q] Evicted oldest: \(evicted.clientMessageId.prefix(8))")
                #endif
            }
            relayQueue.append(envelope)
            return relayQueue.count
        }
        if let count {
            #if DEBUG
            print("📦 [RELAY-Q] Stored for forward: \(envelope.clientMessageId.prefix(8)) (mem=\(count))")
            #endif
            // Also persist to DB so it survives BLE restarts
            Task {
                await RelayQueueRepository.shared.enqueue(envelope)
            }
        }
    }
    
    /// Drain unexpired relay queue entries to a newly connected peer
    /// Checks both in-memory and persistent (SQLite) queues.
    private func drainRelayQueue(to peerDeviceId: String) {
        // In-memory eligible
        let memEligible = relayQueueLock.withLock { () -> [MeshEnvelope] in
            relayQueue.removeAll { $0.isExpired }
            return relayQueue.filter { !$0.hasPassedThrough(deviceId: peerDeviceId) }
        }
        
        guard let peer = getSnapshot().first(where: { $0.deviceId == peerDeviceId }) else { return }
        let myDeviceId = DeviceIdentityService.shared.fingerprint ?? ""
        
        Task {
            // Also get persistent queue entries (covers BLE restart scenario)
            let dbEligible = await RelayQueueRepository.shared.getEligible(excludingPeer: peerDeviceId)
            
            // Merge: use persistent entries that aren't already in memory
            let memIds = Set(memEligible.map { $0.clientMessageId })
            let extraFromDB = dbEligible.filter { !memIds.contains($0.clientMessageId) }
            let allEligible = memEligible + extraFromDB
            
            guard !allEligible.isEmpty else { return }
            
            #if DEBUG
            print("📦 [RELAY-Q] Draining \(allEligible.count) relay messages to \(peerDeviceId.prefix(8)) (mem=\(memEligible.count), db=\(extraFromDB.count))")
            #endif
            
            // Bug 3 fix: Binary Spray — halve tokens instead of giving all to first peer.
            // Track which messages to remove vs update in the relay queue.
            var exhaustedIds: [String] = []
            var updatedEnvelopes: [MeshEnvelope] = []
            
            for envelope in allEligible {
                // Binary spray: give half our spray budget to this peer
                let givenTokens = max(1, envelope.sprayCounter / 2)
                let keptTokens = envelope.sprayCounter - givenTokens
                
                var forwardedEnvelope = envelope.forwarded(by: myDeviceId)
                forwardedEnvelope.sprayCounter = givenTokens
                
                await self.send(forwardedEnvelope, to: peer)
                
                #if DEBUG
                print("📦 [RELAY-Q] Forwarded \(envelope.clientMessageId.prefix(8)) → \(peerDeviceId.prefix(8)) | Given: \(givenTokens), Kept: \(keptTokens)")
                #endif
                
                if keptTokens > 0 {
                    var updated = envelope
                    updated.sprayCounter = keptTokens
                    updatedEnvelopes.append(updated)
                } else {
                    exhaustedIds.append(envelope.clientMessageId)
                }
            }
            
            // Update relay queue: replace entries with updated token counts,
            // remove exhausted. Snapshot the mutable accumulators into `let`s
            // so the @Sendable withLock closure captures only Sendable values.
            let finalExhausted = exhaustedIds
            let finalUpdated = updatedEnvelopes
            self.relayQueueLock.withLock {
                self.relayQueue.removeAll { env in
                    finalExhausted.contains(env.clientMessageId)
                }
                for updated in finalUpdated {
                    if let idx = self.relayQueue.firstIndex(where: { $0.clientMessageId == updated.clientMessageId }) {
                        self.relayQueue[idx].sprayCounter = updated.sprayCounter
                    }
                }
            }
            // Remove only exhausted from DB; update remaining
            if !exhaustedIds.isEmpty {
                await RelayQueueRepository.shared.removeAll(messageIds: exhaustedIds)
            }
            for updated in updatedEnvelopes {
                await RelayQueueRepository.shared.updateSprayCounter(
                    messageId: updated.clientMessageId,
                    newCounter: updated.sprayCounter
                )
            }
            
            #if DEBUG
            print("📦 [RELAY-Q] Drain complete — \(allEligible.count) messages processed (exhausted=\(exhaustedIds.count), kept=\(updatedEnvelopes.count))")
            #endif
        }
    }
    
    // MARK: - Per-Peer Backoff Logic
    
    /// Check if we should forward to this peer based on exponential backoff.
    /// Returns true if enough time has elapsed since last forward to this peer.
    private func shouldForwardToPeer(_ peerId: String) -> Bool {
        stateLock.withLock {
            guard let lastForward = lastForwardedToPeer[peerId] else {
                return true  // Never forwarded to this peer
            }
            
            let count = peerForwardCount[peerId] ?? 0
            // Exponential backoff: 5s, 10s, 20s, 40s, 60s cap
            let interval = min(baseForwardInterval * pow(2.0, Double(count)), maxForwardInterval)
            
            return Date().timeIntervalSince(lastForward) >= interval
        }
    }
    
    /// Record that we forwarded to a peer (updates backoff state)
    private func markForwardedToPeer(_ peerId: String) {
        stateLock.withLock {
            lastForwardedToPeer[peerId] = Date()
            peerForwardCount[peerId] = (peerForwardCount[peerId] ?? 0) + 1
        }
    }
    
    /// Send message to specific peer
    /// - Parameters:
    ///   - envelope: The mesh envelope to send
    ///   - peer: Target peer
    ///   - originalSignature: Bug 5 fix: Original sender's signature (preserved through relay chain)
    ///   - originalSignerPublicKey: Bug 5 fix: Original sender's public key
    func send(_ envelope: MeshEnvelope, to peer: MeshPeer,
              originalSignature: String? = nil, originalSignerPublicKey: String? = nil) async {
        // Keep point-to-point sends aligned with the same secure transport format
        // used by broadcast path (signed, and encrypted when possible).
        let data: Data
        do {
            let secureEnvelope = envelope.toSecureEnvelope()
            var signedPayload = try await MeshCryptoService.shared.signEnvelope(secureEnvelope)
            
            // Bug 5 fix: Preserve original sender's signature through relay chain.
            // - For origin messages (hopCount == 0): our own signature IS the original
            // - For relayed messages (hopCount > 0): pass through the original sender's signature
            if envelope.hopCount > 0, let origSig = originalSignature, let origKey = originalSignerPublicKey {
                // Relay: preserve original sender's signature
                signedPayload.originalSignature = origSig
                signedPayload.originalSignerPublicKey = origKey
            } else if envelope.hopCount == 0 {
                // Origin: our own signature is the original
                signedPayload.originalSignature = signedPayload.signature
                signedPayload.originalSignerPublicKey = signedPayload.signerPublicKey
            }
            
            // Bug 6 fix: Opportunistic encryption — encrypt when peer's X25519
            // agreement key is available (exchanged during QR pairing), otherwise
            // fall back to signed-only. Ed25519 signing keys are NOT suitable for
            // X25519 key agreement — different curve encodings.
            //
            // v2 protocol upgrade: when the peer's capabilities advertise
            // V2_PROTOCOL, wrap the AES-GCM ciphertext in a v2 binary
            // envelope and write it to the v2 message characteristic.
            // The receiver decodes v2 and routes the inner payload back
            // through the existing v1 ingest, so chat semantics are
            // unchanged. Saves ~85% on BLE bandwidth for "hello"-sized
            // texts (60 B v2 header vs ~400 B v1 JSON envelope).
            if let peerUserId = peer.userId {
                let trustedDevices = await FriendDeviceRepository.shared.getTrustedDevices(forUser: peerUserId)
                if let agreementKey = trustedDevices.compactMap({ $0.agreementPublicKey }).first,
                   let sharedKey = DeviceIdentityService.shared.deriveSharedSecret(with: agreementKey) {
                    // Encrypt with ECDH-derived shared key
                    let encryptedPayload = try await MeshCryptoService.shared.encryptEnvelope(secureEnvelope, sharedKey: sharedKey)
                    let v1Data = try JSONEncoder().encode(encryptedPayload)

                    let caps = peerCapabilities[peer.id] ?? []
                    if caps.contains(.v2Protocol) {
                        // Per-peer protocol selection (C.1.d):
                        //
                        //   1. Established Noise session → v2 envelope
                        //      with `flags.noiseTransport`, payload =
                        //      Noise(transport)(v1 ciphertext). Forward
                        //      secrecy on top of v1's AES-GCM.
                        //   2. No Noise session → v2 envelope with
                        //      `type=noiseHandshake1`, payload = M1
                        //      bundling the v1 ciphertext for 1-RTT
                        //      delivery.
                        //   3. Either Noise path fails → fall back to
                        //      the legacy v2 frame (`flags.encrypted`).
                        let peerPID = RUMProtocolV2.peerID(fromPublicKey: agreementKey)
                        // For C.1.f native path: precompute the bare
                        // signed-payload JSON. The transport encoder
                        // below uses it iff `preferNoiseNativeTransport`
                        // is on. Falls back to nil on encode failure
                        // (the encoder then quietly takes the hybrid
                        // path as if the flag were off).
                        let nativeSignedJSON: Data? = try? JSONEncoder().encode(signedPayload)
                        let v2Bytes: Data? = await MainActor.run { () -> Data? in
                            if NoiseSessionStore.shared.hasSession(for: peerPID) {
                                return self.encodeV2NoiseTransportFrameForPeer(
                                    encryptedV1Payload: v1Data,
                                    nativeSignedPayload: nativeSignedJSON,
                                    clientMessageID: envelope.clientMessageId,
                                    peerPID: peerPID,
                                    hopCount: envelope.hopCount
                                )
                            } else {
                                return self.encodeV2NoiseHandshake1FrameForPeer(
                                    encryptedV1Payload: v1Data,
                                    clientMessageID: envelope.clientMessageId,
                                    peerAgreementKey: agreementKey,
                                    hopCount: envelope.hopCount
                                )
                            }
                        } ?? encodeV2FrameForPeer(
                            encryptedV1Payload: v1Data,
                            clientMessageID: envelope.clientMessageId,
                            peerAgreementKey: agreementKey,
                            hopCount: envelope.hopCount
                        )

                        if let v2Bytes {
                            // Prefer MPC if the peer has an authenticated
                            // MPC session (~250 Mbps vs. BLE's ~50 kbps).
                            // On any MPC failure we fall through to BLE —
                            // the receiver dedups cross-transport via
                            // msg_id.
                            if let mpcPeer = MPCTransportService.shared.mpcPeer(for: peer.deviceId) {
                                do {
                                    try MPCTransportService.shared.sendBulkData(v2Bytes, to: mpcPeer)
                                    #if DEBUG
                                    print("[S1] 🚀 v2 via MPC (\(v2Bytes.count)B, inner \(v1Data.count)B) → \(peer.deviceId.prefix(8))")
                                    #endif
                                    return
                                } catch {
                                    #if DEBUG
                                    print("[S1] mpc send failed (\(error)) — falling back to BLE")
                                    #endif
                                }
                            }

                            #if DEBUG
                            print("[S1] 🔐 v2 frame (\(v2Bytes.count)B, inner \(v1Data.count)B) → \(peer.deviceId.prefix(8))")
                            #endif
                            await sendDataChunkedToPeer(
                                v2Bytes,
                                peer: peer,
                                serviceUUID: RUMProtocolV2.serviceUUID,
                                characteristicUUID: RUMProtocolV2.messageCharacteristicUUID
                            )
                            return  // v2 path complete — skip the v1 sendData below
                        }
                    }

                    data = v1Data
                    #if DEBUG
                    print("[S1] 🔒 encrypted+signed v1 (\(data.count)B) → \(peer.deviceId.prefix(8))")
                    #endif
                } else {
                    data = try JSONEncoder().encode(signedPayload)
                    #if DEBUG
                    print("[S1] signed-only (\(data.count)B) → \(peer.deviceId.prefix(8)) (no agreement key)")
                    #endif
                }
            } else {
                data = try JSONEncoder().encode(signedPayload)
                #if DEBUG
                print("[S1] signed-only (\(data.count)B) → unknown peer")
                #endif
            }

        } catch {
            #if DEBUG
            print("❌ [BLE] Failed to encode secure envelope for peer \(peer.deviceId.prefix(8)): \(error)")
            #endif
            return
        }

        await sendData(data, to: peer)
    }
    
    /// Get currently connected peers
    func getConnectedPeers() async -> [MeshPeer] {
        let snap = getSnapshot()
        #if DEBUG
        sessionsLock.withLock {
            print("[SW] peers: connected=\(snap.count) sessions=\(peripheralSessions.count)")
            for (uuid, p) in peripheralSessions {
                print("[SW]   \(uuid.uuidString.prefix(8)) state=\(p.state.rawValue)")
            }
        }
        #endif
        return snap
    }
    
    // MARK: - ServerReceipt Gossip
    
    /// Gossip a ServerReceipt to nearby peers, proving a message is already on the server.
    /// This prevents redundant server uploads from other bridge nodes.
    func gossipReceipt(_ receipt: ServerReceipt) async {
        guard receipt.toData() != nil else {
            #if DEBUG
            print("❌ [BLE] Failed to encode ServerReceipt")
            #endif
            return
        }
        
        // Wrap in a tagged container so peers can identify the payload type
        let tagged = ServerReceiptWrapper(kind: "server_receipt_v1", receipt: receipt)
        guard let taggedData = try? JSONEncoder().encode(tagged) else { return }
        
        await broadcastData(taggedData)
        #if DEBUG
        print("📡 [BLE] Gossipped ServerReceipt for \(receipt.messageId.prefix(8))")
        #endif
    }
    
    // MARK: - MPC Integration (Bulk Transport)
    
    /// Send bulk data to a specific peer via the best available transport.
    /// - MPC (Wi-Fi Direct) for data > 4 KB
    /// - BLE for data ≤ 4 KB
    func sendBulkData(_ data: Data, to peerDeviceId: String) async throws {
        // Try MPC first for large payloads
        if data.count > MPCTransportService.bulkThreshold,
           let mpcPeer = MPCTransportService.shared.mpcPeer(for: peerDeviceId) {
            try MPCTransportService.shared.sendBulkData(data, to: mpcPeer)
            #if DEBUG
            print("📡 [MPC] Bulk send \(data.count)B → \(peerDeviceId.prefix(8)) via Wi-Fi")
            #endif
        } else {
            // Fallback to BLE chunked send
            guard let peer = getSnapshot().first(where: { $0.deviceId == peerDeviceId }) else {
                throw MPCTransportService.MPCError.peerNotConnected
            }
            await sendDataChunkedToPeer(data, peer: peer)
            #if DEBUG
            print("📡 [BLE] Send \(data.count)B → \(peerDeviceId.prefix(8)) via BLE")
            #endif
        }
    }
    
    /// Send a MeshEnvelope to a peer using the optimal transport.
    /// Small text messages → BLE, media-carrying messages → MPC (Wi-Fi Direct)
    func sendViaBestTransport(_ envelope: MeshEnvelope, to peerDeviceId: String) async {
        guard let peer = getSnapshot().first(where: { $0.deviceId == peerDeviceId }) else {
            return
        }
        
        let category = envelope.payloadCategory
        
        switch category {
        case .small:
            // Text messages → BLE (always-on, low-latency)
            await send(envelope, to: peer)
            
        case .medium, .large:
            // Media messages → try MPC first, fallback to BLE
            if let mpcPeer = MPCTransportService.shared.mpcPeer(for: peerDeviceId) {
                do {
                    let secureEnvelope = envelope.toSecureEnvelope()
                    let signedPayload = try await MeshCryptoService.shared.signEnvelope(secureEnvelope)
                    let data = try JSONEncoder().encode(signedPayload)
                    try MPCTransportService.shared.sendBulkData(data, to: mpcPeer)
                    #if DEBUG
                    print("📡 [MPC→BLE] Sent \(category) envelope \(envelope.clientMessageId.prefix(8)) via Wi-Fi (\(data.count)B)")
                    #endif
                    return
                } catch {
                    #if DEBUG
                    print("⚠️ [MPC] Bulk send failed, falling back to BLE: \(error.localizedDescription)")
                    #endif
                }
            }
            // Fallback: BLE chunked send
            await send(envelope, to: peer)
        }
    }
    
    /// Initialize MPC transport layer. Called when BLE engine starts.
    /// MPC runs alongside BLE — BLE discovers, MPC transfers bulk data.
    ///
    /// CRITICAL: must AWAIT `DeviceIdentityService.initialize()` before
    /// reading `fingerprint`. Even though `RAVENApp.swift` kicks off
    /// `initialize()` at launch, that runs in a separate `Task {}` —
    /// `BLEMeshEngine.shared.start()` (called from auth bootstrap) can
    /// fire BEFORE that Task finishes, the fingerprint is still nil,
    /// and we fall through to the `"unknown"` placeholder. The MCPeerID
    /// becomes `RAVEN-unknown` and every cross-device auth challenge
    /// fails the prefix check, silently dropping all bridge traffic.
    /// (Verified live in `log show` from a fresh Catalyst install on
    /// 2026-05-10: `Start advertising peer [RAVEN-unknown,…]`.)
    /// The fix: serialize identity init → MPC start in one Task.
    func startMPCTransport() {
        Task { @MainActor in
            try? await DeviceIdentityService.shared.initialize()
            // Prefer the real fingerprint after init completed. If it
            // is still unavailable (e.g. ad-hoc-signed Catalyst build on
            // macOS Tahoe stripping `keychain-access-groups`, blocking
            // SecItemAdd silently → fingerprint stays nil), fall through
            // to the literal "unknown" placeholder. This loses MPC peer
            // authentication (auth challenge prefix-check fails when
            // both peers use "unknown") but it keeps the discovery layer
            // alive for the surface where the keychain DOES work — Mac
            // App Store + iOS device + Developer-ID-signed Catalyst.
            // The previous `RAVEN-unknown` regression on Catalyst came
            // from `initialize()` racing the read; the await above is
            // the actual race fix. Keep the placeholder behaviour so
            // unsigned local dev builds still get something on the
            // wire — not silently nothing.
            let fingerprint = DeviceIdentityService.shared.fingerprint ?? "unknown"
            #if DEBUG
            if fingerprint == "unknown" {
                print("⚠️ [BLE] MPC starting with placeholder fingerprint — keychain access likely stripped by ad-hoc signing. Auth handshake will fail with peers; discovery only.")
            }
            #endif
            await self.bringUpMPC(with: fingerprint)
        }
    }

    /// Inner half of `startMPCTransport()` — runs once we have a real
    /// fingerprint in hand. Split out so the await chain stays readable.
    @MainActor
    private func bringUpMPC(with fingerprint: String) async {
        MPCTransportService.shared.start(deviceFingerprint: fingerprint)

        // Wire up MPC data callbacks → discriminate v1 (JSON, byte 0
        // is `{` = 0x7B) from v2 (binary, byte 0 = 0x02) and route
        // each to its own ingest path. Two parallel pipelines, same
        // dedup downstream (MeshDedupRepository on inner clientMessageId).
        MPCTransportService.shared.onDataReceived = { [weak self] data, mpcPeer in
            guard let self else { return }
            let deviceId = mpcPeer.displayName  // RAVEN-XXXXXXXX format
            if data.first == RUMProtocolV2.version {
                // v2 binary envelope arriving over MPC. No chunk framer —
                // MPC delivers complete messages — so we hand the bytes
                // straight to `handleV2EnvelopePayload`, which decodes,
                // posts the diagnostic notification (RUMRelayService
                // listens), folds the inner ciphertext into the v1
                // ingest if `flags.encrypted`, and emits STOP gossip
                // when the envelope is addressed to us.
                Task { @MainActor in
                    self.handleV2EnvelopePayload(data, from: deviceId)
                }
            } else {
                Task {
                    await self.packetProcessor.processPacket(data, from: deviceId, engine: self)
                }
            }
        }

        #if DEBUG
        print("📡 [MPC] Bulk transport layer started alongside BLE")
        #endif
    }
    
    /// Stop MPC transport layer.
    func stopMPCTransport() {
        MPCTransportService.shared.stop()
    }
    
    // MARK: - Private: Advertising (Peripheral Role)
    
    private func startAdvertising() {
        guard peripheralManager?.state == .poweredOn else {
            #if DEBUG
            print("[C0] ❌ advertise failed (state=\(peripheralManager?.state.rawValue ?? -1))")
            #endif
            return
        }
        
        if !isServiceAdded {
            peripheralManager?.removeAllServices() // Prevent stale GATT cache

            // ── v1 service (JSON envelopes, existing wire format) ────
            let service = CBMutableService(type: Self.serviceUUID, primary: true)

            let msgChar = CBMutableCharacteristic(
                type: Self.messageCharacteristicUUID,
                properties: [.notify, .write, .writeWithoutResponse],
                value: nil,
                permissions: [.readable, .writeable]
            )

            let deviceChar = CBMutableCharacteristic(
                type: Self.deviceInfoCharacteristicUUID,
                properties: [.read],
                value: deviceId.data(using: .utf8),
                permissions: [.readable]
            )

            self.messageCharacteristic = msgChar
            self.deviceInfoCharacteristic = deviceChar
            service.characteristics = [msgChar, deviceChar]

            peripheralManager?.add(service)

            // ── v2 service (binary RUMProtocolV2 envelopes) ──────────
            // Coexists with v1; v2-aware peers prefer it. v1-only peers
            // ignore this service. Capabilities bitfield is baked in at
            // characteristic creation — we don't track auth-state
            // changes here in Phase B; that's a Phase C refinement.
            let v2Caps: RUMProtocolV2.Capabilities = [.v2Protocol, .bleTransport, .canBeBridge]
            var v2CapsRawBE = v2Caps.rawValue.bigEndian
            let v2CapsValue = withUnsafeBytes(of: &v2CapsRawBE) { Data($0) }

            let v2MsgChar = CBMutableCharacteristic(
                type: RUMProtocolV2.messageCharacteristicUUID,
                properties: [.notify, .write, .writeWithoutResponse],
                value: nil,
                permissions: [.readable, .writeable]
            )
            let v2CapsChar = CBMutableCharacteristic(
                type: RUMProtocolV2.capabilitiesCharacteristicUUID,
                properties: [.read],
                value: v2CapsValue,
                permissions: [.readable]
            )

            self.v2MessageCharacteristic = v2MsgChar
            self.v2CapabilitiesCharacteristic = v2CapsChar
            let v2Service = CBMutableService(type: RUMProtocolV2.serviceUUID, primary: true)
            v2Service.characteristics = [v2MsgChar, v2CapsChar]

            peripheralManager?.add(v2Service)
            isServiceAdded = true
        }

        guard !isAdvertising else { return }

        // Advertise BOTH service UUIDs so v1 and v2 peers both find us.
        // A peer that supports v2 reads the capabilities characteristic
        // and switches; v1-only peers see the v1 UUID and use that.
        peripheralManager?.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID, RUMProtocolV2.serviceUUID],
            CBAdvertisementDataLocalNameKey: "RAVEN-\(deviceId.prefix(8))"
        ])
        
        DispatchQueue.main.async { self.isAdvertising = true }
        #if DEBUG
        print("[C0] advertising as RAVEN-\(deviceId.prefix(8))")
        #endif
    }
    
    private func stopAdvertising() {
        peripheralManager?.stopAdvertising()
        DispatchQueue.main.async { self.isAdvertising = false }
        #if DEBUG
        print("🔴 [BLE] Stopped advertising")
        #endif
    }
    
    // MARK: - Private: Scanning (Central Role)
    
    private func startScanning() {
        guard let cm = centralManager, cm.state == .poweredOn else {
            #if DEBUG
            print("[C1] ❌ scan failed (state=\(centralManager?.state.rawValue ?? -1))")
            #endif
            return
        }
        guard !isScanningInternal else { return }

        cm.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: currentScanOptions()
        )

        setScanning(true)
        #if DEBUG
        print("[C1] scanning started")
        #endif
    }
    
    private func stopScanning() {
        centralManager?.stopScan()
        setScanning(false)
        // scanning stopped
    }
    
    // maxConcurrentConnections removed — iPhones rotate MAC addresses,
    // causing stale sessions to fill the cap and block new connections.
    
    private func connectToPeer(_ peripheral: CBPeripheral) {
        let peerId = peripheral.identifier.uuidString.prefix(8)
        
        // Determine action under lock, then execute CB calls outside lock
        enum ConnectAction {
            case alreadyConnected(CBPeripheral)  // needs service discovery
            case timeout(CBPeripheral)           // needs cancel
            case stillConnecting                 // no-op
            case proceed                         // new connection
        }
        
        let action: ConnectAction = sessionsLock.withLock {
            if let existing = peripheralSessions[peripheral.identifier] {
                switch existing.state {
                case .connected:
                    if !connectedPeerIDs.contains(peripheral.identifier) {
                        return .alreadyConnected(existing)
                    }
                    return .stillConnecting // already fully connected
                case .connecting:
                    if let started = connectionAttemptStarted[peripheral.identifier],
                       Date().timeIntervalSince(started) > connectionTimeout {
                        peripheralSessions.removeValue(forKey: peripheral.identifier)
                        connectionAttemptStarted.removeValue(forKey: peripheral.identifier)
                        return .timeout(existing)
                    }
                    return .stillConnecting
                case .disconnected, .disconnecting:
                    peripheralSessions.removeValue(forKey: peripheral.identifier)
                    connectionAttemptStarted.removeValue(forKey: peripheral.identifier)
                @unknown default:
                    peripheralSessions.removeValue(forKey: peripheral.identifier)
                    connectionAttemptStarted.removeValue(forKey: peripheral.identifier)
                }
            }

            
            peripheralSessions[peripheral.identifier] = peripheral
            connectionAttemptStarted[peripheral.identifier] = Date()
            return .proceed
        }
        
        // Execute CB API calls outside lock
        switch action {
        case .alreadyConnected(let existing):
            if let ravenService = existing.services?.first(where: { $0.uuid == Self.serviceUUID }),
               let chars = ravenService.characteristics, !chars.isEmpty {
                #if DEBUG
                print("[C2] \(peerId) cached GATT → fast-promote")
                #endif
                self.peripheral(existing, didDiscoverCharacteristicsFor: ravenService, error: nil)
            } else {
                #if DEBUG
                print("[C2] \(peerId) connected → re-discover services")
                #endif
                existing.delegate = self
                existing.discoverServices([Self.serviceUUID])
            }
        case .timeout(let existing):
            #if DEBUG
            print("[C2] \(peerId) connect timeout → cancel")
            #endif
            centralManager?.cancelPeripheralConnection(existing)
            return // Let scanner re-discover this peripheral naturally
        case .stillConnecting:
            return
        case .proceed:
            peripheral.delegate = self
            centralManager?.connect(
                peripheral,
                options: [
                    CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                    CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
                    CBConnectPeripheralOptionNotifyOnNotificationKey: true
                ]
            )
            #if DEBUG
            print("[C2] connecting \(peerId)...")
            #endif
        }
    }
    
    private func currentScanOptions() -> [String: Any] {
        // ✅ Perf fix: false prevents BLE antenna from reporting duplicate peripherals every cycle.
        // Apple docs warn that `true` drastically increases battery consumption.
        return [CBCentralManagerScanOptionAllowDuplicatesKey: false]
    }
    
    private func restartScanningForCurrentProfile() {
        guard let cm = centralManager, cm.state == .poweredOn else { return }
        
        cm.stopScan()
        setScanning(false)

        // 🛑 FIX 3: iOS XPC Coalescing Bug
        // با دادن تاخیر ۱۰۰ میلیثانیهای، سیستمعامل متوجه توقف شده و کش را پاک میکند
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, let cm = self.centralManager, cm.state == .poweredOn else { return }

            cm.scanForPeripherals(
                withServices: [Self.serviceUUID],
                options: self.currentScanOptions()
            )
            self.setScanning(true)
        }
        
        #if DEBUG
        print("[C1] scanning restarted to clear duplicate filter")
        #endif
    }
    
    /// Schedule a background task that ends itself proactively after `seconds`.
    /// IMPORTANT: We MUST end the task ourselves before iOS's ~30s expiration handler fires.
    /// Relying on the expiration handler as the normal end-path is a Watchdog red flag
    /// that causes 0x8badf00d kills after repeated BLE wake-ups.
    private func endBackgroundTaskLater(identifier: String, after seconds: UInt64) {
        BackgroundMeshManager.shared.endBackgroundTask(identifier: identifier)

        #if targetEnvironment(macCatalyst)
        // Mac Catalyst: there's no iOS-style background task identifier to keep
        // alive — the process keeps running with the LaunchAgent companion.
        // Just emit the same end-of-task log on schedule for symmetry.
        Task {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            #if DEBUG
            print("⏱️ [Background] Task '\(identifier)' ended proactively after \(seconds)s")
            #endif
        }
        #else
        // Thread-safe box to prevent Simultaneous Memory Access trap
        final class TaskBox: @unchecked Sendable {
            var id: UIBackgroundTaskIdentifier = .invalid
            let lock = NSLock()
            func end() {
                lock.lock()
                defer { lock.unlock() }
                if id != .invalid {
                    UIApplication.shared.endBackgroundTask(id)
                    id = .invalid
                }
            }
        }

        let box = TaskBox()
        // beginBackgroundTask is thread-safe — do NOT wrap in DispatchQueue.main.sync
        // as that causes a deadlock when called from BLE restoration (background thread).
        box.lock.lock()
        box.id = UIApplication.shared.beginBackgroundTask(withName: "\(identifier)_timer") {
            box.end()
        }
        box.lock.unlock()

        Task {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            box.end()
            #if DEBUG
            print("⏱️ [Background] Task '\(identifier)' ended proactively after \(seconds)s")
            #endif
        }
        #endif
    }

    
    private func disconnectAllPeers() {
        guard centralManager != nil else { return }
        let peripherals = sessionsLock.withLock { Array(peripheralSessions.values) }
        for peripheral in peripherals {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        sessionsLock.withLock {
            peripheralSessions.removeAll()
            connectedPeerIDs.removeAll()
        }
        DispatchQueue.main.async {
            self.connectedPeers.removeAll()
            self.syncSnapshot()
        }
    }
    
    // MARK: - Private: Data Transmission
    
    private func broadcastData(_ data: Data) async {
        // CRITICAL: Route through chunked path to ensure consistent packet framing.
        // processIncomingPacket expects first byte = isChunked flag (0 or 1).
        // Without this, raw data gets its first byte stripped → silent corruption.
        await broadcastDataChunked(data)
    }
    
    // Fix: Delegate to chunked send so the isChunked prefix byte (0 or 1) is added.
    // processIncomingPacket always strips the first byte — without the prefix,
    // the '{' of the JSON payload gets dropped and decoding silently fails.
    private func sendData(_ data: Data, to peer: MeshPeer) async {
        await sendDataChunkedToPeer(data, peer: peer)
    }
    
    // MARK: - Private: Incoming Data
    // NOTE: handleIncomingData removed — processing is now serialized via MeshPacketProcessor actor
    
    /// Secure inbound data processing with signature verification
    /// Internal access so MeshPacketProcessor actor can call it.
    // MARK: - FAST-PATH JSON PEEKING & PRE-VERIFICATION DEDUP
    func processIncomingDataSecure(_ data: Data, from deviceId: String) async {
        // 💡 INNOVATION: O(1) Parsing to prevent CPU meltdown.
        // Using JSONSerialization is ~10x faster than blindly trying 8 different JSONDecoders.
        guard let jsonDict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return
        }
        
        let decoder = JSONDecoder()
        
        // 0. Feature Handler Dispatch (Flock, Echo, Proximity)
        // If the frame has an "mk" (message kind) field, route to registered handler.
        if let mkRaw = jsonDict["mk"] as? String, let kind = MeshMessageKind(rawValue: mkRaw) {
            // Dedup by messageId
            let messageId = jsonDict["mid"] as? String ?? mkRaw
            let dedupId = "frame:\(messageId)"
            let isNew = await MeshDedupRepository.shared.isNewMessage(id: dedupId)
            guard isNew else { return }
            await MeshDedupRepository.shared.markProcessed(id: dedupId)
            
            let handler = handlersLock.withLock { messageHandlers[kind] }
            if let handler = handler {
                await handler(data, deviceId)
                
                // Relay: forward frame to other peers if valid
                if let hc = jsonDict["hc"] as? Int,
                   let hl = jsonDict["hl"] as? Int,
                   let sc = jsonDict["sc"] as? Int,
                   hc < hl, sc > 0 {
                    // Re-broadcast with decremented spray counter
                    // (simplified — feature services can also handle their own relay)
                    let myDeviceId = DeviceIdentityService.shared.fingerprint ?? ""
                    if let rp = jsonDict["rp"] as? [String], !rp.contains(myDeviceId) {
                        await broadcastData(data)
                    }
                }
            } else {
                #if DEBUG
                print("⚠️ [BLE] No handler registered for kind: \(mkRaw)")
                #endif
            }
            return
        }
        
        // 1. ServerReceipt
        if let kind = jsonDict["kind"] as? String, kind == "server_receipt_v1" {
            if let wrapper = try? decoder.decode(ServerReceiptWrapper.self, from: data) {
                let receipt = wrapper.receipt
                guard !receipt.messageId.isEmpty, !receipt.uploaderDeviceId.isEmpty else { return }
                try? await OutboxRepository.shared.updateServerState(clientMessageId: receipt.messageId, state: .sent)
                try? await MessageRepository.shared.updateServerId(clientMessageId: receipt.messageId, serverId: receipt.messageId)
                try? await MessageRepository.shared.updateStatus(clientMessageId: receipt.messageId, status: .sent)
                await MainActor.run { NotificationCenter.default.post(name: Notification.Name("MeshACKReceived"), object: nil, userInfo: ["messageId": receipt.messageId, "status": MessageStatus.sent.rawValue]) }
                await handleStop(receipt.messageId)
            }
            return
        }
        
        // 2. Mesh Inventory / Post
        if let k = jsonDict["k"] as? String {
            if k == MeshInventoryKind.invBloom.rawValue {
                if let invFrame = try? decoder.decode(InvBloomFrame.self, from: data) { await handleInvBloom(invFrame, from: deviceId) }
                return
            } else if k == MeshInventoryKind.want.rawValue {
                if let wantFrame = try? decoder.decode(WantFrame.self, from: data) { await handleWant(wantFrame, from: deviceId) }
                return
            } else if k == "mesh_post_v1" {
                let postId = jsonDict["pid"] as? String ?? ""
                
                // 💡 PRE-VERIFICATION DEDUP: Check duplicates BEFORE Ed25519 validation
                let alreadySeen = processedLock.withLock { () -> Bool in
                    let exists = processedMessages[postId] != nil
                    if !exists { processedMessages[postId] = Date() }
                    return exists
                }
                if alreadySeen { return }
                
                if let postEnvelope = try? decoder.decode(MeshPostEnvelope.self, from: data) {
                    guard !postEnvelope.postId.isEmpty, !postEnvelope.authorId.isEmpty else {
                        _ = processedLock.withLock { processedMessages.removeValue(forKey: postId) }
                        return
                    }
                    
                    if postEnvelope.signature != nil {
                        guard postEnvelope.isSignatureValid() else {
                            _ = processedLock.withLock { processedMessages.removeValue(forKey: postId) }
                            return
                        }
                        if let signerKey = postEnvelope.signerPublicKey {
                            let authorId = postEnvelope.authorId
                            let myUserId = await KeychainService.shared.getUserId() ?? ""
                            if authorId == myUserId {
                                if signerKey != DeviceIdentityService.shared.publicKeyBase64 {
                                    _ = processedLock.withLock { processedMessages.removeValue(forKey: postId) }
                                    return
                                }
                            } else {
                                let trustedDevices = await FriendDeviceRepository.shared.getTrustedDevices(forUser: authorId)
                                let isTrustedKey = trustedDevices.contains { $0.publicKeyBase64 == signerKey }
                                if !isTrustedKey {
                                    _ = processedLock.withLock { processedMessages.removeValue(forKey: postId) }
                                    return
                                }
                            }
                        }
                    }
                    await MainActor.run { self.onMeshPostReceived?(postEnvelope) }
                }
                return
            } else if k == "raven.gateway.beacon.v1" {
                // Beacon from a neighbour advertising itself as a gateway.
                // The MVP doesn't pick gateways yet (single-hop two-phone
                // prototype) — we just log so the test pass shows beacons
                // are being received over the wire. Selection lands when
                // we have ≥2 candidate gateways in the field.
                if let beacon = try? decoder.decode(GatewayBeacon.self, from: data) {
                    #if DEBUG
                    NSLog("🌐 [Gateway] beacon recv from=\(beacon.gatewayDeviceId.prefix(8)) score=\(String(format: "%.2f", beacon.score))")
                    #endif
                }
                return
            } else if k == "raven.gateway.relay.v1" {
                // An offline neighbour is asking us to push their outbound
                // envelope through our internet connection.
                if let req = try? decoder.decode(GatewayRelayRequest.self, from: data) {
                    Task { @MainActor in
                        await MeshGatewayService.shared.handleOutboundFromNeighbour(req)
                    }
                }
                return
            } else if k == "raven.gateway.inbound.v1" {
                // Server-bound envelope being re-broadcast by another
                // gateway — relevant only if we're the recipient. Today
                // we just log; the recipient-side pickup is wired in v1.7.
                if let env = try? decoder.decode(GatewayInboundEnvelope.self, from: data) {
                    #if DEBUG
                    NSLog("🌐 [Gateway] inbound recv hint=\(env.recipientHint.prefix(8)) bytes=\(env.payload.count)")
                    #endif
                }
                return
            }
        }

        // 3. Stop Command
        if let type = jsonDict["type"] as? String, type == "STOP" {
            let messageId = jsonDict["messageId"] as? String ?? ""
            let dedupId = "stop:\(messageId)"
            
            let isNew = await MeshDedupRepository.shared.isNewMessage(id: dedupId)
            guard isNew else { return }
            
            if let stopCommand = try? decoder.decode(StopCommand.self, from: data) {
                // ⚡ SECURITY (audit #5b): unsigned Stop commands are now REJECTED.
                // Previously an attacker could broadcast an unsigned STOP and
                // halt mesh delivery of a target message. All legitimate senders
                // already call `.sign()` (see broadcastStop / forward sites).
                guard stopCommand.signature != nil, stopCommand.isSignatureValid() else {
                    #if DEBUG
                    print("[STOP] ❌ Rejected unsigned/invalid stop \(stopCommand.messageId.prefix(8))")
                    #endif
                    await MeshDedupRepository.shared.unclaimMessage(id: dedupId)
                    return
                }
                if let signerKey = stopCommand.signerPublicKey {
                    let allTrusted = await FriendDeviceRepository.shared.getAllTrustedDevices()
                    let isOwnKey = (signerKey == DeviceIdentityService.shared.publicKeyBase64)
                    let isTrustedKey = allTrusted.contains { $0.publicKeyBase64 == signerKey }
                    if !isOwnKey && !isTrustedKey {
                        await MeshDedupRepository.shared.unclaimMessage(id: dedupId)
                        return
                    }
                }
                await MeshDedupRepository.shared.markProcessed(id: dedupId)
                await handleStop(stopCommand.messageId)
            }
            return
        }
        
        // 4. ACK
        if jsonDict["isACK"] != nil || jsonDict["status"] != nil {
            let originalMessageId = jsonDict["originalMessageId"] as? String ?? ""
            let senderId = jsonDict["senderId"] as? String ?? ""
            let recipientId = jsonDict["recipientId"] as? String ?? ""
            let statusRaw = jsonDict["status"] as? String ?? ""
            let relayKey = "\(originalMessageId)|\(senderId)|\(recipientId)|\(statusRaw)"
            
            let dedupId = "ack:\(relayKey)"
            let isNew = await MeshDedupRepository.shared.isNewMessage(id: dedupId)
            guard isNew else { return }
            
            if let ack = MeshACKEnvelope.fromData(data), ack.isACK {
                // ⚡ SECURITY (audit #5b): unsigned ACKs are now REJECTED.
                // Previously an attacker could fabricate read/delivered ACKs,
                // poisoning sender-side delivery state and prematurely halting
                // mesh broadcast for a victim's message. All outgoing ACKs are
                // now signed in `sendACK(_:)`.
                guard ack.signature != nil, ack.isSignatureValid() else {
                    #if DEBUG
                    print("[ACK] ❌ Rejected unsigned/invalid ACK for \(ack.originalMessageId.prefix(8))")
                    #endif
                    await MeshDedupRepository.shared.unclaimMessage(id: dedupId)
                    return
                }
                do {
                    if let signerKey = ack.signerPublicKey {
                        let trustedDevices = await FriendDeviceRepository.shared.getTrustedDevices(forUser: ack.senderId)
                        let isOwnKey = (signerKey == DeviceIdentityService.shared.publicKeyBase64)
                        let keyMatches = trustedDevices.contains { $0.publicKeyBase64 == signerKey }
                        if !isOwnKey && !keyMatches {
                            if !trustedDevices.isEmpty {
                                await MeshDedupRepository.shared.unclaimMessage(id: dedupId)
                                return
                            }
                            if let pubKeyData = Data(base64Encoded: signerKey) {
                                let fingerprint = String(signerKey.prefix(16))
                                let device = FriendDevice(friendUserId: ack.senderId, fingerprint: fingerprint, publicKey: pubKeyData, trustState: .trusted, verifiedAt: Date(), addedAt: Date(), deviceName: "mesh-tofu-ack-\(ack.senderId.prefix(8))")
                                try? await FriendDeviceRepository.shared.upsert(device)
                            }
                        }
                    }
                }
                await MeshDedupRepository.shared.markProcessed(id: dedupId)
                await MainActor.run { self.processIncomingACK(ack, isAlreadyDeduped: true) }
            }
            return
        }
        
        // 5. EncryptedMeshPayload
        if jsonDict["c"] != nil && jsonDict["spk"] != nil {
            if let nonce = jsonDict["n"] as? String {
                let dedupId = "enc:\(nonce)"
                let isNew = await MeshDedupRepository.shared.isNewMessage(id: dedupId)
                guard isNew else { return }
                
                if let encryptedPayload = try? decoder.decode(EncryptedMeshPayload.self, from: data) {
                    do {
                        let senderPubKeyData = Data(base64Encoded: encryptedPayload.senderPublicKey) ?? Data()
                        if let sharedKey = DeviceIdentityService.shared.deriveSharedSecret(with: senderPubKeyData) {
                            let decrypted = try await MeshCryptoService.shared.decryptEnvelope(encryptedPayload, sharedKey: sharedKey)
                            let messageId = decrypted.clientMessageId
                            
                            let isNewMsg = await MeshDedupRepository.shared.isNewMessage(id: messageId)
                            if !isNewMsg {
                                let myUserId = await KeychainService.shared.getUserId() ?? ""
                                if decrypted.recipientId == myUserId {
                                    let ack = MeshACKEnvelope(originalMessageId: messageId, senderId: myUserId, recipientId: decrypted.senderId, status: .delivered, pathUsed: "mesh", originDeviceId: DeviceIdentityService.shared.fingerprint ?? "")
                                    await self.sendACK(ack)
                                }
                                return
                            }

                            if let signature = encryptedPayload.signature, let signerPublicKey = encryptedPayload.signerPublicKey {
                                let signedPayload = SignedMeshPayload(envelope: decrypted, signature: signature, signerPublicKey: signerPublicKey)
                                let isValid = await MeshCryptoService.shared.verifySignature(signedPayload)
                                guard isValid else {
                                    await MeshDedupRepository.shared.unclaimMessage(id: messageId)
                                    return
                                }
                                var envelope = decrypted.toMeshEnvelope()
                                envelope.originalSignature = signedPayload.originalSignature ?? signature
                                envelope.originalSignerPublicKey = signedPayload.originalSignerPublicKey ?? signerPublicKey
                                await MeshDedupRepository.shared.markProcessed(id: messageId)
                                await processVerifiedEnvelope(envelope, from: deviceId, isAlreadyDeduped: true)
                                return
                            } else {
                                await MeshDedupRepository.shared.unclaimMessage(id: messageId)
                            }
                        }
                    } catch {
                        // 🔍 Don't silently swallow — a stale shared secret or
                        // tampered ciphertext used to vanish without a trace,
                        // making "missing message" reports impossible to debug.
                        // Log in DEBUG and increment a metric for production.
                        #if DEBUG
                        print("🛑 [Mesh] Decrypt/verify failed for EncryptedMeshPayload from \(deviceId): \(error)")
                        #endif
                        await MeshDedupRepository.shared.unclaimMessage(id: "enc:\(jsonDict["n"] as? String ?? "?")")
                    }
                }
            }
            return
        }
        
        // 6. SignedMeshPayload
        if jsonDict["e"] != nil && jsonDict["s"] != nil && jsonDict["spk"] != nil {
            if let signedPayload = try? decoder.decode(SignedMeshPayload.self, from: data) {
                let messageId = signedPayload.envelope.clientMessageId
                let isNew = await MeshDedupRepository.shared.isNewMessage(id: messageId)
                if !isNew {
                    let myUserId = await KeychainService.shared.getUserId() ?? ""
                    if signedPayload.envelope.recipientId == myUserId {
                        let ack = MeshACKEnvelope(originalMessageId: messageId, senderId: myUserId, recipientId: signedPayload.envelope.senderId, status: .delivered, pathUsed: "mesh", originDeviceId: DeviceIdentityService.shared.fingerprint ?? "")
                        await self.sendACK(ack)
                    }
                    return
                }
                let isValid = await MeshCryptoService.shared.verifySignature(signedPayload)
                guard isValid else {
                    await MeshDedupRepository.shared.unclaimMessage(id: messageId)
                    return
                }
                var envelope = signedPayload.envelope.toMeshEnvelope()
                envelope.originalSignature = signedPayload.originalSignature ?? signedPayload.signature
                envelope.originalSignerPublicKey = signedPayload.originalSignerPublicKey ?? signedPayload.signerPublicKey
                await MeshDedupRepository.shared.markProcessed(id: messageId)
                await processVerifiedEnvelope(envelope, from: deviceId, isAlreadyDeduped: true)
            }
            return
        }
    }
    
    /// Process an envelope that has passed signature verification
    private func processVerifiedEnvelope(_ envelope: MeshEnvelope, from deviceId: String, isAlreadyDeduped: Bool = false) async {
        let boundsValid = await MeshCryptoService.shared.validateDTNBounds(
            hopCount: envelope.hopCount,
            hopLimit: envelope.hopLimit,
            sprayCounter: envelope.sprayCounter
        )
        if !boundsValid { return }
        
        if !isAlreadyDeduped {
            let isNew = await MeshDedupRepository.shared.isNewMessage(id: envelope.clientMessageId)
            if !isNew {
                let myUserId = await KeychainService.shared.getUserId() ?? ""
                if envelope.recipientId == myUserId {
                    let ack = MeshACKEnvelope(
                        originalMessageId: envelope.clientMessageId,
                        senderId: myUserId,
                        recipientId: envelope.senderId,
                        status: .delivered,
                        pathUsed: "mesh",
                        originDeviceId: DeviceIdentityService.shared.fingerprint ?? ""
                    )
                    await self.sendACK(ack)
                }
                return
            }
            await MeshDedupRepository.shared.markProcessed(id: envelope.clientMessageId)
        }
        
        await MainActor.run {
            self.processValidatedEnvelope(envelope, from: deviceId)
        }
    }
    
    /// ACK relay + optional uplink flow:
    /// 1) Dedup persistently, 2) deliver locally if recipient, 3) uplink if online bridge,
    /// 4) forward in mesh while under hop limit.
    private func processIncomingACK(_ ack: MeshACKEnvelope, isAlreadyDeduped: Bool = false) {
        Task {
            let dedupId = "ack:\(ack.relayKey)"
            if !isAlreadyDeduped {
                let isNew = await MeshDedupRepository.shared.isNewMessage(id: dedupId)
                guard isNew else { return }
                await MeshDedupRepository.shared.markProcessed(id: dedupId)
            }
            
            let myUserId = await KeychainService.shared.getUserId() ?? ""
            let isForMe = !myUserId.isEmpty && ack.recipientId == myUserId
            
            if isForMe {
                await MainActor.run { self.onACKReceived?(ack) }
            } else {
                await uplinkACKIfOnline(ack)
            }
            
            guard !isForMe else { return }
            let myDeviceId = DeviceIdentityService.shared.fingerprint ?? ""
            guard ack.canForward else { return }
            guard !ack.hasPassedThrough(deviceId: myDeviceId) else { return }
            
            let forwarded = ack.forwarded(by: myDeviceId)
            guard let forwardedData = forwarded.toData() else { return }
            await broadcastData(forwardedData)
        }
    }
    
    /// If this relay node has internet, uplink ACK to server for canonical delivery.
    private func uplinkACKIfOnline(_ ack: MeshACKEnvelope) async {
        guard ack.status == .delivered else { return }
        guard NetworkMonitor.shared.isOnline else { return }
        
        let deliveredVia = ack.pathUsed ?? "mesh"
        do {
            let response: AckDeliveredResponse = try await NetworkService.shared.post(
                path: "/api/messages/ack-delivered",
                body: AckDeliveredRequest(
                    messageId: ack.originalMessageId,
                    deliveredVia: deliveredVia,
                    pathUsed: "mesh-bridge"
                ),
                idempotencyKey: "ack-\(ack.relayKey)"
            )
            
            if response.stopMesh {
                await handleStop(ack.originalMessageId)
            }
            
            // Clear any queued legacy ACK for this message if present.
            try? await PendingACKRepository.shared.remove(clientMessageId: ack.originalMessageId)
            #if DEBUG
            print("✅ [BLE ACK] Uplinked ACK via bridge: \(ack.originalMessageId.prefix(8))")
            #endif
        } catch {
            // Keep a retry signal for next online sync cycle.
            try? await PendingACKRepository.shared.add(
                clientMessageId: ack.originalMessageId,
                deliveredVia: deliveredVia,
                pathUsed: "mesh-bridge",
                idempotencyKey: "ack-\(ack.relayKey)"
            )
            #if DEBUG
            print("⚠️ [BLE ACK] Bridge uplink failed, queued: \(ack.originalMessageId.prefix(8)) - \(error)")
            #endif
        }
    }
    
    /// Process envelope after all security checks passed
    private func processValidatedEnvelope(_ envelope: MeshEnvelope, from deviceId: String) {
        // ════════════════════════════════════════════════════════════════
        // ATOMIC DEDUPLICATION CHECK (Bug #9 fix - in-memory backup)
        // ════════════════════════════════════════════════════════════════
        let alreadyProcessed = processedLock.withLock { () -> Bool in
            let exists = processedMessages[envelope.clientMessageId] != nil
            if !exists {
                processedMessages[envelope.clientMessageId] = Date()
            }
            return exists
        }
        
        guard !alreadyProcessed else {
            #if DEBUG
            print("[R5] duplicate → drop")
            #endif
            return
        }
        
        if stateLock.withLock({ stoppedMessageIds[envelope.clientMessageId] != nil }) {
            #if DEBUG
            print("[R5] 🛑 stopped → drop")
            #endif
            return
        }
        
        if envelope.isExpired {
            #if DEBUG
            print("[R5] ⏰ expired → drop")
            #endif
            return
        }
        
        let myDeviceId = DeviceIdentityService.shared.fingerprint ?? ""
        
        if envelope.hasPassedThrough(deviceId: myDeviceId) {
            #if DEBUG
            print("[R5] loop → drop")
            #endif
            return
        }
        
        #if DEBUG
        print("[R6] ✅✅ DELIVERED mid=\(envelope.clientMessageId.prefix(8)) handler=\(onMessageReceived != nil)")
        #endif
        
        // ════════════════════════════════════════════════════════════════
        // BRIDGE FIX: Learn peer's userId from incoming envelopes.
        // BLE discovery only provides deviceId. When a peer sends a message,
        // we learn their userId from envelope.senderId and update the peer.
        // This enables bridge downlink to poll the server for messages
        // destined to specific nearby users (instead of __ALL_PEERS__).
        // ════════════════════════════════════════════════════════════════
        if !envelope.senderId.isEmpty {
            Task { @MainActor in
                if let idx = self.connectedPeers.firstIndex(where: { $0.deviceId == deviceId }),
                   self.connectedPeers[idx].userId == nil {
                    self.connectedPeers[idx] = MeshPeer(
                        id: self.connectedPeers[idx].id,
                        deviceId: self.connectedPeers[idx].deviceId,
                        userId: envelope.senderId,
                        displayName: self.connectedPeers[idx].displayName,
                        peripheral: self.connectedPeers[idx].peripheral,
                        rssi: self.connectedPeers[idx].rssi,
                        fingerprint: self.connectedPeers[idx].fingerprint,
                        publicKey: self.connectedPeers[idx].publicKey,
                        isTrusted: self.connectedPeers[idx].isTrusted
                    )
                    self.syncSnapshot()
                    #if DEBUG
                    print("🌉 [BRIDGE] Learned userId=\(envelope.senderId.prefix(8)) for peer \(deviceId.prefix(8))")
                    #endif
                }
            }
        }
        
        onMessageReceived?(envelope)
        
        // ════════════════════════════════════════════════════════════════
        // 🌉 BRIDGE/RELAY LOGIC (Binary Spray & Wait)
        // ════════════════════════════════════════════════════════════════
        
        if envelope.needsForwarding && envelope.isValid {
            let targetPeers = getSnapshot().filter { $0.deviceId != deviceId }

            // ⚡ SCALE FIX (#7 probabilistic gossip):
            // In dense BLE clusters every device re-broadcasting every envelope
            // creates quadratic chatter. Each relay now drops the relay with
            // probability tied to local peer density. We keep direct-recipient
            // and trusted-peer relays at 100% so delivery latency stays low,
            // and only thin out forwarding to the rest of the cluster. The
            // probability is deterministic per (envelope, device) so it never
            // biases delivery for a particular sender across attempts.
            //
            //   p(forward) = min(1.0, max(0.25, 3.0 / (peerCount + 1)))
            //
            // peerCount=2 → 100%, peerCount=5 → 50%, peerCount=10 → 27%
            let peerCount = targetPeers.count
            let forwardProbability: Double = peerCount <= 2
                ? 1.0
                : min(1.0, max(0.25, 3.0 / Double(peerCount + 1)))
            let probHash = abs({
                var h = Hasher()
                h.combine(envelope.clientMessageId)
                h.combine(DeviceIdentityService.shared.fingerprint ?? "")
                return h.finalize()
            }())
            let probSlot = Double(probHash % 1_000) / 1_000.0
            let isRecipientHere = targetPeers.contains { $0.userId == envelope.recipientId }
            let elected = isRecipientHere || (probSlot < forwardProbability)
            if !elected {
                #if DEBUG
                print("  [BRIDGE] 🎲 Probabilistic gossip dropped relay for \(envelope.clientMessageId.prefix(8)) (p=\(String(format: "%.2f", forwardProbability)), peers=\(peerCount))")
                #endif
                // Still keep it in the relay queue — if peers change later we
                // may forward to a future peer that wasn't in this snapshot.
                self.addToRelayQueue(envelope)
                return
            }

            if !targetPeers.isEmpty {
                #if DEBUG
                print("  [BRIDGE] Starting Smart Relay for \(envelope.clientMessageId.prefix(8)) (p=\(String(format: "%.2f", forwardProbability)))")
                #endif
                
                Task {
                    // Keep a mutable copy to manage our own spray budget
                    var myRemainingEnvelope = envelope
                    
                    for peer in targetPeers {
                        // Bug #6 fix: Removed shouldForwardToPeer backoff — spray counter
                        // already prevents flooding; the backoff was trapping messages in relayQueue.
                        
                        // 🧠 WAIT PHASE: If only 1 spray token left, don't risk it
                        // on a stranger — only give to the actual recipient or a
                        // trusted friend device.
                        if myRemainingEnvelope.sprayCounter <= 1 {
                            // Bug 1 fix: For group messages, recipientId = groupId, not a userId.
                            // Must check group membership to avoid blackholing group messages.
                            let isRecipient: Bool
                            if let peerUserId = peer.userId {
                                let isDirectRecipient = peerUserId == myRemainingEnvelope.recipientId
                                let isGroupMember = await GroupRepository().isMember(
                                    userId: peerUserId, groupId: myRemainingEnvelope.recipientId
                                )
                                isRecipient = isDirectRecipient || isGroupMember
                            } else {
                                isRecipient = false
                            }
                            let isTrusted: Bool
                            if let fingerprint = peer.fingerprint, !fingerprint.isEmpty {
                                isTrusted = await FriendDeviceRepository.shared.isTrusted(fingerprint)
                            } else {
                                isTrusted = false
                            }
                            
                            if !isRecipient && !isTrusted {
                                #if DEBUG
                                print("  [SMART-RELAY] Spray=1 (Wait Phase). Skipping stranger: \(peer.deviceId.prefix(8))")
                                #endif
                                continue
                            }
                        }
                        
                        // 📊 PRoPHET: Check if this peer is a better carrier for the destination
                        let peerId = peer.userId ?? peer.deviceId
                        let destination = myRemainingEnvelope.recipientId
                        let prophetApproved = await DeliveryPredictabilityService.shared
                            .shouldForward(to: peerId, destination: destination, sprayCounter: myRemainingEnvelope.sprayCounter)
                        
                        if !prophetApproved {
                            // Only skip if the peer is NOT the direct recipient or trusted
                            let isRecipientDirect = peer.userId == destination
                            let isPeerTrusted: Bool
                            if let fp = peer.fingerprint, !fp.isEmpty {
                                isPeerTrusted = await FriendDeviceRepository.shared.isTrusted(fp)
                            } else {
                                isPeerTrusted = false
                            }
                            if !isRecipientDirect && !isPeerTrusted {
                                #if DEBUG
                                print("  [SMART-RELAY] PRoPHET: skipping \(peer.deviceId.prefix(8)) for dest \(destination.prefix(8)) — we are better carrier")
                                #endif
                                continue
                            }
                        }
                        
                        // 🌊 BINARY SPRAY: Give half our spray budget to the peer
                        // e.g. from 50 → give 25, keep 25 (exponential distribution)
                        let givenSprayTokens = max(1, myRemainingEnvelope.sprayCounter / 2)
                        myRemainingEnvelope.sprayCounter -= givenSprayTokens
                        
                        var forwardedEnvelope = myRemainingEnvelope.forwarded(by: myDeviceId)
                        forwardedEnvelope.sprayCounter = givenSprayTokens
                        
                        await self.send(forwardedEnvelope, to: peer,
                                        originalSignature: forwardedEnvelope.originalSignature,
                                        originalSignerPublicKey: forwardedEnvelope.originalSignerPublicKey)
                        // Bug #6 fix: markForwardedToPeer removed (backoff logic no longer used)
                        
                        #if DEBUG
                        print("  [SMART-RELAY] Sent to \(peer.deviceId.prefix(8)) | Given Sprays: \(givenSprayTokens), Kept: \(myRemainingEnvelope.sprayCounter)")
                        #endif
                        
                        // If our budget is exhausted, stop giving to more peers
                        if myRemainingEnvelope.sprayCounter == 0 { break }
                    }
                    
                    // STORE-AND-FORWARD: Keep remaining budget for future peers
                    if myRemainingEnvelope.sprayCounter > 0 {
                        self.addToRelayQueue(myRemainingEnvelope)
                    }
                }
            } else {
                #if DEBUG
                print("  [BRIDGE] No connected peers for relay - stored in relay queue for later")
                #endif
                self.addToRelayQueue(envelope)
            }
        } else {
            #if DEBUG
            print("📩 [BLE] Message for direct delivery - no forwarding")
            #endif
        }
    }
    
    // MARK: - Private: Queue Flush
    
    private func flushQueueIfNeeded() {
        let sorted = queueLock.withLock { () -> [MeshEnvelope]? in
            guard hasActiveConnections, !messageQueue.isEmpty else {
                return nil
            }
            // PRIORITY SORT: control > direct > text > posts
            let sorted = messageQueue.sorted { a, b in
                Self.envelopePriority(a) > Self.envelopePriority(b)
            }
            messageQueue.removeAll()
            return sorted
        }
        
        guard let sorted else { return }
        
        Task {
            for envelope in sorted {
                await enqueueForBroadcast(envelope)
            }
            #if DEBUG
            print("📤 [BLE] Flushed \(sorted.count) queued messages (priority-sorted)")
            #endif
        }
    }
    
    /// Priority score for queue ordering: higher = send first.
    /// Control frames (CANCEL, RECEIPT) > DMs (direct recipient) > text posts > other
    private static func envelopePriority(_ e: MeshEnvelope) -> Int {
        // Type 0 = text DM, type 1 = media DM, type 10 = post, etc.
        var score = 40
        if !e.recipientId.isEmpty && e.recipientId != "broadcast" {
            score = 80  // Direct messages (DMs)
        } else if e.type == 0 {
            score = 60  // Text-only (even broadcast)
        }
        
        // VIP priority boost for RAVEN+ users' own outgoing messages
        if e.originDeviceId == DeviceIdentityService.shared.fingerprint {
            score += PremiumLimits.meshPriorityBoost  // Own message: use local premium status
        } else if e.hopLimit > 10 {
            score += 50  // Relayed premium message: fixed boost regardless of relay user's tier
        }
        
        return score
    }
    
    // MARK: - Public: Drain Pending
    
    func drainPendingFromDB() {
        // 💡 INNOVATIVE FIX: Prevent infinite crypto broadcast storms by delegating
        // the draining process to DeliveryJobRunner which has proper state management & backoff.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("MeshPeerConnected"), object: nil)
        }
    }
    
    func drainPendingFromOutbox() {
        // 💡 INNOVATIVE FIX: Delegated to DeliveryJobRunner
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("MeshPeerConnected"), object: nil)
        }
    }
    
    /// Parse a DB row into ChatMessage
    private func parseMessageRow(_ row: [String: Any]) -> ChatMessage? {
        guard let id = row["client_message_id"] as? String,
              let roomId = row["room_id"] as? String,
              let senderId = row["sender_id"] as? String,
              let recipientId = row["recipient_id"] as? String,
              let timestampStr = row["timestamp"] as? String,
              let timestamp = PerformanceConstants.iso8601.date(from: timestampStr),
              let typeStr = row["type"] as? String else {
            return nil
        }
        let type = MessageType.from(name: typeStr)
        
        return ChatMessage(
            id: id,
            serverId: row["server_id"] as? String,
            roomId: roomId,
            senderId: senderId,
            senderName: row["sender_name"] as? String ?? "",
            recipientId: recipientId,
            text: row["text"] as? String,
            timestamp: timestamp,
            type: type,
            status: .pending,
            deliveryAuthority: .mesh,
            createdAt: nil,
            deliveredAt: nil,
            readAt: nil,
            hopCount: 0,
            routePath: [],
            sprayCounter: PremiumLimits.meshSprayBudget,
            hopLimit: PremiumLimits.meshHopLimit,
            originDeviceId: deviceId,
            needsForwarding: true,
            attachmentUrl: row["remote_url"] as? String,
            thumbnailUrl: row["thumbnail_url"] as? String,
            fileName: row["file_name"] as? String,
            mimeType: row["mime_type"] as? String,
            fileSize: row["file_size"] as? Int,
            audioDurationSeconds: row["audio_duration_seconds"] as? Int,
            syncState: .localOnly,
            localPath: row["local_path"] as? String,
            uploadProgress: nil,
            lastError: nil,
            replyToMessageId: row["reply_to_message_id"] as? String,
            replyToTextPreview: row["reply_to_text_preview"] as? String,
            replyToSenderName: row["reply_to_sender_name"] as? String,
            replyToType: nil,
            sendMode: nil,
            scheduledAtUtc: nil
        )
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEMeshEngine: CBCentralManagerDelegate {
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let stateNames = ["unknown","resetting","unsupported","unauthorized","poweredOff","poweredOn"]
        let stateName = central.state.rawValue < stateNames.count ? stateNames[central.state.rawValue] : "??"
        #if DEBUG
        print("[C0] bluetooth → \(stateName)")
        #endif
        DispatchQueue.main.async {
            self.bluetoothState = central.state
        }
        
        if central.state == .poweredOn {
            // Immediately sweep stale sessions on BT power-on
            sweepStaleSessions()
            startScanning()
            
            // Drain queued messages after BT recovery — tiered delay to cover
            // both fast reconnects (~3s) and slow ones (~8s)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.flushQueueIfNeeded()
                self?.drainPendingFromDB()
                self?.drainPendingFromOutbox()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.flushQueueIfNeeded()
                self?.drainPendingFromDB()
                self?.drainPendingFromOutbox()
            }
        } else if central.state == .poweredOff {
            // ═══════════════════════════════════════════════════════════
            // CRITICAL: Reset ALL peer tracking state on Bluetooth OFF.
            // iOS invalidates every CBPeripheral reference when the radio
            // powers down.  If we keep stale UUIDs in discoveredPeripheralIDs
            // the didDiscover callback will skip those peripherals after
            // power-on, effectively killing the mesh.
            // ═══════════════════════════════════════════════════════════
            sessionsLock.withLock {
                peripheralSessions.removeAll()
                discoveredPeripheralIDs.removeAll()
                connectedPeerIDs.removeAll()
                connectionAttemptStarted.removeAll()
                reconnectAttempts.removeAll()
                connectionCooldowns.removeAll()
            }
            setScanning(false)
            DispatchQueue.main.async {
                self.connectedPeers.removeAll()
                self.discoveredPeers.removeAll()
                self.syncSnapshot()
            }
            #if DEBUG
            print("⚠️ [BLE] Bluetooth OFF → cleared all peer state for clean recovery")
            #endif
        }
    }
    
    // MARK: - Background State Restoration
    
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        #if DEBUG
        print("🔄 [BLE] ═══════════════════════════════════════")
        print("🔄 [BLE] CENTRAL STATE RESTORATION")
        print("🔄 [BLE] ═══════════════════════════════════════")
        #endif
        
        // Begin background task to have time to process
        BackgroundMeshManager.shared.beginBackgroundTask(
            identifier: "ble_central_restore",
            reason: .bleCentralRestore
        )
        
        // Restore connected peripherals
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            #if DEBUG
            print("🔄 [BLE] Restoring \(peripherals.count) peripherals")
            #endif
            
            // First, update session tracking under lock
            sessionsLock.withLock {
                for peripheral in peripherals {
                    peripheralSessions[peripheral.identifier] = peripheral
                }
            }
            
            // Then execute CB API calls outside lock
            for peripheral in peripherals {
                peripheral.delegate = self
                
                // Re-discover services if still connected
                if peripheral.state == .connected {
                    #if DEBUG
                    print("🔄 [BLE] Peripheral \(peripheral.identifier.uuidString.prefix(8)) still connected - rediscovering services")
                    #endif
                    peripheral.discoverServices([Self.serviceUUID])
                } else {
                    #if DEBUG
                    print("🔄 [BLE] Peripheral \(peripheral.identifier.uuidString.prefix(8)) disconnected - will reconnect")
                    #endif
                }
            }
        }
        
        // Log scan state
        if let scanServices = dict[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID] {
            #if DEBUG
            print("🔄 [BLE] Was scanning for services: \(scanServices)")
            #endif
            setScanning(true)
        }
        
        if let scanOptions = dict[CBCentralManagerRestoredStateScanOptionsKey] as? [String: Any] {
            #if DEBUG
            print("🔄 [BLE] Scan options: \(scanOptions)")
            #endif
        }
        
        restartScanningForCurrentProfile()
        drainPendingFromOutbox()
        endBackgroundTaskLater(identifier: "ble_central_restore", after: 25)
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Unknown"

        // Extract device ID. The iOS/Mac builds publish it as the BLE
        // LocalName "RAVEN-XXXXXXXX". Windows can't override the system
        // Bluetooth name in LocalName, so it puts the 8-char fingerprint
        // (UTF-8) in the ServiceData slot keyed by `serviceUUID`. Read
        // both — first hit wins. (See HANDOFF.md M3 in RAVEN-Windows for
        // the cross-platform discovery contract.)
        let peerDeviceId: String
        if name.hasPrefix("RAVEN-") {
            peerDeviceId = String(name.dropFirst(6))
        } else if let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
                  let raw = serviceData[Self.serviceUUID],
                  let s = String(data: raw, encoding: .utf8),
                  !s.isEmpty {
            peerDeviceId = s
        } else {
            peerDeviceId = peripheral.identifier.uuidString
        }
        
        // Skip self
        guard peerDeviceId != deviceId.prefix(8).description else {
            return
        }
        
        let uuid = peripheral.identifier
        
        // Fast O(1) dedup — prevents infinite "NEW peer" spam
        let isNew: Bool = sessionsLock.withLock {
            if discoveredPeripheralIDs.contains(uuid) {
                // Already known — only retry connect if not connected yet
                if !connectedPeerIDs.contains(uuid) && peripheralSessions[uuid]?.state != .connecting {
                    return false // not new, but needs reconnect (handled below)
                }
                return false
            }
            discoveredPeripheralIDs.insert(uuid)
            return true
        }
        
        if isNew {
            let peer = MeshPeer(
                id: uuid,
                deviceId: peerDeviceId,
                userId: nil,
                displayName: name,
                peripheral: peripheral,
                rssi: RSSI.intValue
            )
            
            DispatchQueue.main.async {
                if !self.discoveredPeers.contains(where: { $0.id == uuid }) {
                    self.discoveredPeers.append(peer)
                }
            }
            
            #if DEBUG
            print("[C1] discovered \(name) state=\(peripheral.state.rawValue)")
            #endif
        }
        
        // connectToPeer internally uses sessionsLock for its own checks
        let needsConnect: Bool = sessionsLock.withLock {
            if let cooldown = connectionCooldowns[uuid], cooldown > Date() {
                return false
            }
            
            // FIX: Skip connect if already connecting or connected (prevents spam before service discovery)
            let state = peripheralSessions[uuid]?.state
            if state == .connecting || state == .connected {
                return false
            }
            
            return isNew || !connectedPeerIDs.contains(uuid)
        }
        if needsConnect {
            connectToPeer(peripheral)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        sessionsLock.withLock {
            connectionAttemptStarted.removeValue(forKey: peripheral.identifier)
            reconnectAttempts.removeValue(forKey: peripheral.identifier)
        }
        #if DEBUG
        print("[C3] ✅ didConnect \(peripheral.name ?? peripheral.identifier.uuidString.prefix(8).description)")
        #endif
        
        if runtimeProfile == .backgroundBridge {
            BackgroundMeshManager.shared.beginBackgroundTask(
                identifier: "ble_peer_connected",
                reason: .bleDeviceConnected
            )
            endBackgroundTaskLater(identifier: "ble_peer_connected", after: 15)
        }
        
        // discover services called
        peripheral.discoverServices([Self.serviceUUID])
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let isIntentional = (error == nil)

        sessionsLock.withLock {
            peripheralSessions.removeValue(forKey: peripheral.identifier)
            connectionAttemptStarted.removeValue(forKey: peripheral.identifier)
            connectedPeerIDs.remove(peripheral.identifier)
            reconnectAttempts.removeValue(forKey: peripheral.identifier)

            // 🔴 Bug fix (2026-05-09): the previous implementation
            // unconditionally wiped the cooldown for this peripheral
            // here, which caused a tight reconnect loop:
            //   discover → no services → set 5-min cooldown →
            //   cancelPeripheralConnection → didDisconnect fires →
            //   we wipe the cooldown we just set → next scan re-finds
            //   the same peer → reconnect → repeat forever.
            //
            // The radio thrashing burned battery AND saturated the
            // event loop just enough to make video downloads stutter
            // (the user-reported "video unstable" symptom).
            //
            // Keep the cooldown if it's still in the future; only
            // drop expired ones to bound the dictionary size.
            if let cd = connectionCooldowns[peripheral.identifier], cd <= Date() {
                connectionCooldowns.removeValue(forKey: peripheral.identifier)
            }

            // فراموشی کامل دیوایس برای کشف مجدد —
            // also gated on the cooldown so a peer we just decided to
            // ignore doesn't get re-discovered → re-connected.
            if connectionCooldowns[peripheral.identifier] == nil {
                discoveredPeripheralIDs.remove(peripheral.identifier)
            }
        }
        
        DispatchQueue.main.async {
            self.connectedPeers.removeAll { $0.id == peripheral.identifier }
            self.syncSnapshot()
        }
        
        restartScanningForCurrentProfile()
        
        if !isIntentional {
            // 🛑 FIX 4: Hardware Pending Reconnect
            // سختافزار بلوتوث اپل این درخواست را نگه میدارد و به محض دیدن دیوایس 
            // بدون مصرف باتری اپلیکیشن را بیدار میکند.
            #if DEBUG
            print("🔄 [BLE] Hardware Pending Reconnect for \(peripheral.name ?? "Peer")")
            #endif
            self.connectToPeer(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        sessionsLock.withLock {
            peripheralSessions.removeValue(forKey: peripheral.identifier)
            connectionAttemptStarted.removeValue(forKey: peripheral.identifier)
            connectedPeerIDs.remove(peripheral.identifier)
            discoveredPeripheralIDs.remove(peripheral.identifier)
            reconnectAttempts.removeValue(forKey: peripheral.identifier)
            connectionCooldowns.removeValue(forKey: peripheral.identifier)
        }
        
        DispatchQueue.main.async {
            self.connectedPeers.removeAll { $0.id == peripheral.identifier }
            self.syncSnapshot()
        }
        
        restartScanningForCurrentProfile()
        self.connectToPeer(peripheral) // Hardware Pending Reconnect
    }
}

// MARK: - CBPeripheralDelegate

extension BLEMeshEngine: CBPeripheralDelegate {
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let peerId = peripheral.identifier.uuidString.prefix(8)
        if let error = error {
            #if DEBUG
            print("[C4] ❌ didDiscoverServices FAILED for \(peerId): \(error.localizedDescription)")
            #endif
            sessionsLock.withLock { connectionCooldowns[peripheral.identifier] = Date().addingTimeInterval(300) }
            centralManager?.cancelPeripheralConnection(peripheral)
            return
        }
        guard let services = peripheral.services, !services.isEmpty else {
            #if DEBUG
            print("[C4] ❌ no services on \(peerId)")
            #endif
            sessionsLock.withLock { connectionCooldowns[peripheral.identifier] = Date().addingTimeInterval(300) }
            centralManager?.cancelPeripheralConnection(peripheral)
            return
        }
        
        #if DEBUG
        print("[C4] ✅ \(services.count) services on \(peerId)")
        #endif
        
        var foundRavenService = false
        for service in services {
            if service.uuid == Self.serviceUUID {
                foundRavenService = true
                peripheral.discoverCharacteristics(
                    [Self.messageCharacteristicUUID, Self.deviceInfoCharacteristicUUID],
                    for: service
                )
            } else if service.uuid == RUMProtocolV2.serviceUUID {
                // v2-capable peer; discover characteristics so we can
                // subscribe to v2 notifies + read their caps bitfield.
                foundRavenService = true
                peripheral.discoverCharacteristics(
                    [RUMProtocolV2.messageCharacteristicUUID,
                     RUMProtocolV2.capabilitiesCharacteristicUUID],
                    for: service
                )
            }
        }
        if !foundRavenService {
            #if DEBUG
            print("[C4] ⚠️ RAVEN service NOT found")
            #endif
            sessionsLock.withLock { connectionCooldowns[peripheral.identifier] = Date().addingTimeInterval(300) }
            centralManager?.cancelPeripheralConnection(peripheral)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let peerId = peripheral.identifier.uuidString.prefix(8)
        if let error = error {
            #if DEBUG
            print("[C5] ❌ didDiscoverCharacteristics FAILED for \(peerId): \(error.localizedDescription)")
            #endif
            sessionsLock.withLock { connectionCooldowns[peripheral.identifier] = Date().addingTimeInterval(300) }
            centralManager?.cancelPeripheralConnection(peripheral)
            return
        }
        guard let characteristics = service.characteristics, !characteristics.isEmpty else {
            #if DEBUG
            print("[C5] ❌ no characteristics on \(peerId)")
            #endif
            sessionsLock.withLock { connectionCooldowns[peripheral.identifier] = Date().addingTimeInterval(300) }
            centralManager?.cancelPeripheralConnection(peripheral)
            return
        }
        
        #if DEBUG
        print("[C5] ✅ \(characteristics.count) chars on \(peerId)")
        #endif
        
        for char in characteristics {
            if char.uuid == Self.messageCharacteristicUUID {
                peripheral.setNotifyValue(true, for: char)
                // subscribed to message notifications
            } else if char.uuid == Self.deviceInfoCharacteristicUUID {
                peripheral.readValue(for: char)
                // reading deviceInfo
            } else if char.uuid == RUMProtocolV2.messageCharacteristicUUID {
                // Subscribe to v2 message notifies. The Phase C sender
                // will gate v2 encoding on cached peer capabilities.
                peripheral.setNotifyValue(true, for: char)
            } else if char.uuid == RUMProtocolV2.capabilitiesCharacteristicUUID {
                peripheral.readValue(for: char)
            }
        }
        
        // Mark as fully connected — promote to connectedPeers
        let peer: MeshPeer
        if let existing = discoveredPeers.first(where: { $0.id == peripheral.identifier }) {
            peer = existing
        } else {
            // Peer connected (e.g. via state restoration or race condition) but wasn't in discoveredPeers.
            // Create a MeshPeer on-the-fly so we can still use it.
            let name = peripheral.name ?? "RAVEN-\(peerId)"
            let peerDeviceId = name.hasPrefix("RAVEN-") ? String(name.dropFirst(6)) : String(peerId)
            peer = MeshPeer(
                id: peripheral.identifier,
                deviceId: peerDeviceId,
                userId: nil,
                displayName: name,
                peripheral: peripheral,
                rssi: -50
            )
            #if DEBUG
            print("[C6] created MeshPeer on-the-fly for \(peerId)")
            #endif
        }
        
        DispatchQueue.main.async {
            // Ensure in discoveredPeers
            if !self.discoveredPeers.contains(where: { $0.id == peripheral.identifier }) {
                self.discoveredPeers.append(peer)
            }
            // Promote to connectedPeers
            if !self.connectedPeers.contains(where: { $0.id == peripheral.identifier }) {
                _ = self.sessionsLock.withLock {
                    self.connectedPeerIDs.insert(peripheral.identifier)
                }
                self.connectedPeers.append(peer)
                self.syncSnapshot()
                #if DEBUG
                print("[C6] ✅✅ FULLY CONNECTED \(peer.deviceId.prefix(8)) → flushing queues")
                #endif
                
                self.flushQueueIfNeeded()
                self.drainPendingFromDB()
                self.drainPendingFromOutbox()
                self.drainRelayQueue(to: peer.deviceId)
                Task {
                    await MeshPostService.shared.drainMeshPosts(to: peer.deviceId)
                    await self.initiateInventoryExchange(with: peer.deviceId)
                    // PRoPHET: Record encounter for delivery predictability
                    let encounterId = peer.userId ?? peer.deviceId
                    await DeliveryPredictabilityService.shared.recordEncounter(with: encounterId)
                }
                self.onPeerConnected?(peer.deviceId)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }

        if characteristic.uuid == Self.messageCharacteristicUUID {
            let deviceId = getSnapshot().first { $0.id == peripheral.identifier }?.deviceId ?? "unknown"

            // Bug #10: Process with chunk handling
            guard let completeData = processIncomingPacket(data, from: deviceId) else {
                return  // Waiting for more chunks
            }

            // Bug 1 fix: Use actor for serialized processing (replaces broken GCD+Task pattern)
            Task { [weak self] in
                guard let self else { return }
                await self.packetProcessor.processPacket(completeData, from: deviceId, engine: self)
            }
        } else if characteristic.uuid == RUMProtocolV2.messageCharacteristicUUID {
            // v2 binary envelope arriving via notify. Reuse the v1 chunk
            // framer (same 6-byte chunked frame layer); the assembled
            // bytes are routed to the v2 decode path instead of the
            // JSON parser.
            let deviceId = getSnapshot().first { $0.id == peripheral.identifier }?.deviceId ?? "unknown"
            guard let completeData = processIncomingPacket(data, from: deviceId) else {
                return  // waiting for more chunks
            }
            handleV2EnvelopePayload(completeData, from: deviceId)
        } else if characteristic.uuid == RUMProtocolV2.capabilitiesCharacteristicUUID {
            // Cache the peer's capability bitfield. The Phase C sender
            // gates v2 encoding on `caps.contains(.v2Protocol)`.
            peerCapabilities[peripheral.identifier] = parseV2Capabilities(data)
            #if DEBUG
            let raw = data.map { String(format: "%02x", $0) }.joined()
            print("[mesh-v2] caps from \(peripheral.identifier.uuidString.prefix(8)): 0x\(raw)")
            #endif
        }
    }

    /// Parse a 4-byte big-endian uint32 from the v2 capabilities
    /// characteristic. Returns an empty set if `data` is shorter.
    private func parseV2Capabilities(_ data: Data) -> RUMProtocolV2.Capabilities {
        guard data.count >= 4 else { return [] }
        let base = data.startIndex
        let raw =
            (UInt32(data[base    ]) << 24) |
            (UInt32(data[base + 1]) << 16) |
            (UInt32(data[base + 2]) <<  8) |
             UInt32(data[base + 3])
        return RUMProtocolV2.Capabilities(rawValue: raw)
    }

    /// Decode an assembled v2 envelope and route its inner payload back
    /// through the existing v1 ingest pipeline.
    ///
    /// Today the v2 frame is a thin transport wrapper: when
    /// `flags.encrypted` is set, `payload` is the same AES-GCM blob v1
    /// has always emitted. Routing it to `packetProcessor.processPacket`
    /// (the v1 chat ingest path) means a v2 receiver lights up chat
    /// without a new ingest hook. Phase C.1 swaps the inner crypto for
    /// Noise IK and changes this path to decrypt via Noise instead.
    private func handleV2EnvelopePayload(_ data: Data, from deviceId: String) {
        let envelope: RUMProtocolV2.Envelope
        do {
            envelope = try RUMProtocolV2.decode(data)
        } catch {
            #if DEBUG
            print("[mesh-v2] decode failed from \(deviceId): \(error)")
            #endif
            return
        }
        #if DEBUG
        print("[mesh-v2] received \(envelope.type) from \(deviceId) — \(envelope.payload.count) B payload, ttl=\(envelope.ttl)")
        #endif
        // Diagnostic notification — useful for protocol-level debugging.
        NotificationCenter.default.post(
            name: .ravenMeshV2EnvelopeReceived,
            object: nil,
            userInfo: ["envelope": envelope, "peerDeviceId": deviceId]
        )

        // ── Noise IK routing (C.1.c) ────────────────────────────────
        //
        // Three new shapes ride v2 envelopes alongside the legacy
        // AES-GCM `flags.encrypted` path:
        //
        //   • `type == noiseHandshake1` → initiator's M1; process, emit
        //     our M2, and ingest the embedded payload (1-RTT IK lets us
        //     deliver chat text inside the handshake itself).
        //   • `type == noiseHandshake2` → responder's M2; finalize the
        //     cached initiator-side session.
        //   • `flags.noiseTransport`    → transport-mode AEAD; decrypt
        //     via the cached session and fold plaintext back into the
        //     existing v1 chat ingest pipeline.
        //
        // We only act on envelopes addressed to *us* — relays continue
        // to forward Noise frames opaquely (the relay can't decrypt; it
        // just transports bytes).
        let myPID: Data? = DeviceIdentityService.shared.agreementPublicKeyData
            .map { RUMProtocolV2.peerID(fromPublicKey: $0) }

        if envelope.destPID == myPID {
            switch envelope.type {
            case .noiseHandshake1:
                Task { @MainActor in self.handleInboundNoiseHandshake1(envelope, from: deviceId) }
            case .noiseHandshake2:
                Task { @MainActor in self.handleInboundNoiseHandshake2(envelope, from: deviceId) }
            default:
                if envelope.flags.contains(.noiseTransport) {
                    Task { @MainActor in self.handleInboundNoiseTransport(envelope, from: deviceId) }
                }
            }
        }

        // Hand the inner ciphertext to the existing v1 ingest pipeline.
        // Dedup happens in the packet processor on the inner clientMessageId,
        // so we don't double-fire vs. a parallel v1 receipt of the same
        // message. Skip when Noise already handled it.
        if envelope.flags.contains(.encrypted), !envelope.flags.contains(.noiseTransport) {
            let inner = envelope.payload
            Task { [weak self] in
                guard let self else { return }
                await self.packetProcessor.processPacket(inner, from: deviceId, engine: self)
            }
        }

        // STOP gossip — when this envelope is addressed to us, broadcast
        // a STOP back into the mesh so carriers can drop their remaining
        // spray copies. Skipped for incoming STOPs (those flow through
        // `RUMRelayService`, which marks them stopped + relays) and for
        // Noise handshake messages (single-recipient by definition).
        if envelope.type != .stop,
           envelope.type != .noiseHandshake1,
           envelope.type != .noiseHandshake2,
           let myPID,
           envelope.destPID == myPID {
            Task { @MainActor in self.broadcastV2Stop(forMsgID: envelope.msgID) }
        }
    }

    // MARK: - Noise IK ingest (C.1.c)

    @MainActor
    private func handleInboundNoiseHandshake1(_ envelope: RUMProtocolV2.Envelope, from deviceId: String) {
        let result: (payload: Data, message2: Data, peerID: Data)
        do {
            result = try NoiseSessionStore.shared.processInboundHandshake1(message1: envelope.payload)
        } catch {
            #if DEBUG
            print("[mesh-v2-noise] M1 process failed from \(deviceId): \(error)")
            #endif
            return
        }

        guard let myAgreement = DeviceIdentityService.shared.agreementPublicKeyData else { return }
        let myPID = RUMProtocolV2.peerID(fromPublicKey: myAgreement)

        var msgID = Data(count: 16)
        msgID.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, 16, base)
        }

        let m2Envelope = RUMProtocolV2.Envelope(
            type: .noiseHandshake2,
            ttl: RUMProtocolV2.defaultTTL,
            flags: [],
            timestamp: UInt32(Date().timeIntervalSince1970),
            msgID: msgID,
            senderPID: myPID,
            destPID: envelope.senderPID,
            hopCount: 0,
            sprayRemaining: RUMProtocolV2.defaultSprayCopies,
            payload: result.message2,
            signature: nil
        )

        if let encoded = try? RUMProtocolV2.encode(m2Envelope) {
            let padded = RUMProtocolV2.pad(encoded)
            Task { await self.relayV2EnvelopeBytesToAllPeers(padded, except: "") }
        }

        // Embedded payload (typically the actual chat text) → existing
        // v1 ingest path. Noise-native routing replaces this in C.1.d.
        if !result.payload.isEmpty {
            let inner = result.payload
            Task { [weak self] in
                guard let self else { return }
                await self.packetProcessor.processPacket(inner, from: deviceId, engine: self)
            }
        }

        #if DEBUG
        print("[mesh-v2-noise] processed M1 from \(deviceId); session established")
        #endif
    }

    @MainActor
    private func handleInboundNoiseHandshake2(_ envelope: RUMProtocolV2.Envelope, from deviceId: String) {
        let peerID = envelope.senderPID
        do {
            _ = try NoiseSessionStore.shared.finishHandshakeAsInitiator(
                message2: envelope.payload,
                peerID: peerID
            )
            #if DEBUG
            print("[mesh-v2-noise] processed M2 from \(deviceId); transport keys ready")
            #endif
        } catch {
            #if DEBUG
            print("[mesh-v2-noise] M2 process failed from \(deviceId): \(error)")
            #endif
        }
    }

    @MainActor
    private func handleInboundNoiseTransport(_ envelope: RUMProtocolV2.Envelope, from deviceId: String) {
        let peerID = envelope.senderPID
        guard let plaintext = NoiseSessionStore.shared.decrypt(
            envelope.payload,
            ad: envelope.msgID,
            fromPeer: peerID
        ) else {
            #if DEBUG
            print("[mesh-v2-noise] transport decrypt failed from \(deviceId) — no session or AEAD failure")
            #endif
            return
        }
        // Two shapes ride a Noise transport-mode payload:
        //
        //   • `flags.encrypted` set → C.1.d migration shape. Plaintext is
        //     a v1 `EncryptedMeshPayload` JSON; we still need the AES-GCM
        //     unwrap, so we hand the bytes to `packetProcessor.processPacket`
        //     which understands the legacy wire format.
        //
        //   • `flags.encrypted` clear → C.1.e Noise-native shape. The
        //     inner AES-GCM layer is gone; plaintext is a JSON
        //     `SignedMeshPayload` (Ed25519-signed bare SecureMeshEnvelope).
        //     Verify the signature, convert to `MeshEnvelope`, and
        //     route to the same `processVerifiedEnvelope` consumer the
        //     v1 paths funnel into.
        if envelope.flags.contains(.encrypted) {
            let inner = plaintext
            Task { [weak self] in
                guard let self else { return }
                await self.packetProcessor.processPacket(inner, from: deviceId, engine: self)
            }
        } else {
            handleNoiseNativeSignedPayload(plaintext, from: deviceId)
        }
    }

    /// C.1.e ingest for iOS: decode a `SignedMeshPayload` JSON that
    /// just came out of the Noise transport-mode decrypt, verify
    /// the relay-chain Ed25519 signature, dedup, and route to
    /// `processVerifiedEnvelope` — the same downstream consumer the
    /// v1 receive paths funnel into.
    @MainActor
    private func handleNoiseNativeSignedPayload(_ data: Data, from deviceId: String) {
        let signedPayload: SignedMeshPayload
        do {
            signedPayload = try JSONDecoder().decode(SignedMeshPayload.self, from: data)
        } catch {
            #if DEBUG
            print("[mesh-v2-noise-native] SignedMeshPayload decode failed from \(deviceId): \(error)")
            #endif
            return
        }
        let messageId = signedPayload.envelope.clientMessageId
        Task { [weak self] in
            guard let self else { return }

            let isNew = await MeshDedupRepository.shared.isNewMessage(id: messageId)
            if !isNew {
                #if DEBUG
                print("[mesh-v2-noise-native] duplicate \(messageId.prefix(8)) — skipping")
                #endif
                return
            }

            let isValid = await MeshCryptoService.shared.verifySignature(signedPayload)
            guard isValid else {
                await MeshDedupRepository.shared.unclaimMessage(id: messageId)
                #if DEBUG
                print("[mesh-v2-noise-native] signature verify failed from \(deviceId)")
                #endif
                return
            }

            var envelope = signedPayload.envelope.toMeshEnvelope()
            envelope.originalSignature = signedPayload.originalSignature ?? signedPayload.signature
            envelope.originalSignerPublicKey = signedPayload.originalSignerPublicKey ?? signedPayload.signerPublicKey
            await MeshDedupRepository.shared.markProcessed(id: messageId)
            await self.processVerifiedEnvelope(envelope, from: deviceId, isAlreadyDeduped: true)
        }
    }

    /// Build + broadcast a STOP gossip envelope pointing at
    /// `originalMsgID`. Called when we're the recipient and have just
    /// ingested the original; STOP propagates so carriers stop
    /// spraying remaining copies.
    @MainActor
    private func broadcastV2Stop(forMsgID originalMsgID: Data) {
        guard let myAgreement = DeviceIdentityService.shared.agreementPublicKeyData else { return }
        let myPID = RUMProtocolV2.peerID(fromPublicKey: myAgreement)

        // STOP carries its own fresh msg_id so its bloom-dedup is
        // independent of the original's. Payload = 16 bytes of the
        // original `msg_id` — that's what carriers look up to suppress
        // future spray.
        var stopMsgID = Data(count: 16)
        stopMsgID.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, 16, base)
        }

        let stop = RUMProtocolV2.Envelope(
            type: .stop,
            ttl: RUMProtocolV2.defaultTTL,
            flags: [],
            timestamp: UInt32(Date().timeIntervalSince1970),
            msgID: stopMsgID,
            senderPID: myPID,
            destPID: RUMProtocolV2.broadcastPeerID,
            hopCount: 0,
            // STOP wants higher reach than user text (defaults to 4) —
            // it's small, header-only, and the goal is to suppress
            // spray everywhere. Bloom-dedup + TTL bound prevent loops.
            sprayRemaining: 32,
            payload: originalMsgID,
            signature: nil
        )

        guard let encoded = try? RUMProtocolV2.encode(stop) else { return }
        let padded = RUMProtocolV2.pad(encoded)

        // Mark stopped locally before broadcast so a concurrent arrival
        // of the original via a different path doesn't get re-sprayed.
        RUMRelayService.shared.markStopped(msgID: originalMsgID)

        #if DEBUG
        let originalHex = originalMsgID.map { String(format: "%02x", $0) }.joined()
        print("[mesh-v2] emitting STOP for \(originalHex.prefix(8))")
        #endif

        Task { await self.relayV2EnvelopeBytesToAllPeers(padded, except: "") }
    }
    
    // MARK: - Bug 4 fix: BLE Buffer Readiness Delegate
    
    /// Called by CoreBluetooth when the peripheral's write buffer has space available.
    /// This replaces the unreliable poll-and-sleep pattern in sendDataChunkedToPeer.
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        readyContinuationsLock.lock()
        // Bug 1 fix: Drain all waiting continuations for this peripheral
        let continuations = peripheralReadyContinuations.removeValue(forKey: peripheral.identifier) ?? [:]
        readyContinuationsLock.unlock()
        
        for (_, c) in continuations { c.resume() }
    }
    
    /// Async wait for a peripheral's write buffer to become available.
    /// Uses CheckedContinuation backed by peripheralIsReady delegate callback.
    /// Includes a 2-second safety timeout to prevent indefinite hangs.
    func waitForPeripheralReady(_ peripheral: CBPeripheral) async {
        // Quick check — buffer already available
        if peripheral.canSendWriteWithoutResponse { return }
        
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let id = UUID()
            readyContinuationsLock.lock()
            // Bug 1 fix: Store with unique UUID key — prevents cross-chunk theft
            peripheralReadyContinuations[peripheral.identifier, default: [:]][id] = continuation
            readyContinuationsLock.unlock()
            
            // Safety timeout: resume after 2s if delegate never fires (e.g., disconnected peripheral)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                self.readyContinuationsLock.lock()
                // Bug 1 fix: Only remove OUR continuation by exact UUID match
                let pendingContinuation = self.peripheralReadyContinuations[peripheral.identifier]?.removeValue(forKey: id)
                if self.peripheralReadyContinuations[peripheral.identifier]?.isEmpty == true {
                    self.peripheralReadyContinuations.removeValue(forKey: peripheral.identifier)
                }
                self.readyContinuationsLock.unlock()
                pendingContinuation?.resume()
            }
        }
    }
    
    /// Async wait for the peripheral manager's notification buffer to become available.
    /// Used by sendDataChunkedToCentral to avoid dropping chunks when updateValue returns false.
    /// Bug 3 fix: Added 2s safety timeout to prevent indefinite hangs.
    private func waitForCentralReady() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let id = UUID()
            centralReadyLock.lock()
            // Bug 1 fix: Store with unique UUID key — prevents cross-chunk theft
            centralReadyContinuations[id] = continuation
            centralReadyLock.unlock()
            
            // Safety timeout — prevents eternal hang if peripheralManagerIsReady never fires
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                self.centralReadyLock.lock()
                // Bug 1 fix: Only remove OUR continuation by exact UUID match
                let c = self.centralReadyContinuations.removeValue(forKey: id)
                self.centralReadyLock.unlock()
                c?.resume()
            }
        }
    }
}
// MARK: - CBPeripheralManagerDelegate

extension BLEMeshEngine: CBPeripheralManagerDelegate {
    
    /// Called by CoreBluetooth when the peripheral manager's notification buffer has space.
    /// Resumes all waitForCentralReady() continuations so chunks can proceed.
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        centralReadyLock.lock()
        let continuations = centralReadyContinuations
        centralReadyContinuations.removeAll()
        centralReadyLock.unlock()
        for (_, c) in continuations { c.resume() }
    }
    
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let stateNames = ["unknown","resetting","unsupported","unauthorized","poweredOff","poweredOn"]
        let stateName = peripheral.state.rawValue < stateNames.count ? stateNames[peripheral.state.rawValue] : "??"
        #if DEBUG
        print("[C0] peripheral → \(stateName)")
        #endif
        if peripheral.state == .poweredOn {
            startAdvertising()
            // NOTE: Do NOT drain outbox here — peripheral manager powers on for
            // advertising (receiving). Sending requires central manager to have
            // reconnected peers first. Drains are triggered by centralManagerDidUpdateState
            // and sweepStaleSessions after peers are available.
        } else if peripheral.state == .poweredOff {
            // ═══════════════════════════════════════════════════════════
            // CRITICAL: iOS removes all GATT services on power-off.
            // Reset advertising + characteristic refs so startAdvertising()
            // re-adds the service from scratch on next power-on.
            // ═══════════════════════════════════════════════════════════
            isAdvertising = false
            isServiceAdded = false
            messageCharacteristic = nil
            deviceInfoCharacteristic = nil
            subscribersLock.withLock { centralSubscribers.removeAll() }
            #if DEBUG
            print("⚠️ [BLE] Peripheral OFF → cleared advertising + GATT state")
            #endif
        }
    }
    
    // MARK: - Background State Restoration
    
    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        #if DEBUG
        print("🔄 [BLE] ═══════════════════════════════════════")
        print("🔄 [BLE] PERIPHERAL STATE RESTORATION")
        print("🔄 [BLE] ═══════════════════════════════════════")
        #endif
        
        // Begin background task
        BackgroundMeshManager.shared.beginBackgroundTask(
            identifier: "ble_peripheral_restore",
            reason: .blePeripheralRestore
        )
        
        // Restore services and characteristics
        if let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] {
            #if DEBUG
            print("🔄 [BLE] Restoring \(services.count) services")
            #endif
            
            for service in services {
                if let chars = service.characteristics as? [CBMutableCharacteristic] {
                    for char in chars {
                        if char.uuid == Self.messageCharacteristicUUID {
                            messageCharacteristic = char
                            #if DEBUG
                            print("🔄 [BLE] Restored message characteristic")
                            #endif
                        } else if char.uuid == Self.deviceInfoCharacteristicUUID {
                            deviceInfoCharacteristic = char
                            #if DEBUG
                            print("🔄 [BLE] Restored device info characteristic")
                            #endif
                        }
                    }
                }
            }
        }
        
        // Check if was advertising
        if let advertisementData = dict[CBPeripheralManagerRestoredStateAdvertisementDataKey] as? [String: Any] {
            #if DEBUG
            print("🔄 [BLE] Was advertising: \(advertisementData)")
            #endif
            DispatchQueue.main.async { self.isAdvertising = true }
        }
        
        drainPendingFromOutbox()
        endBackgroundTaskLater(identifier: "ble_peripheral_restore", after: 25)
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        addSubscriber(central)
        #if DEBUG
        print("[C6] remote central subscribed (subs=\(subscriberCount))")
        #endif
        
        // CRITICAL: Drain pending messages when central subscribes too!
        flushQueueIfNeeded()
        drainPendingFromDB()
        drainPendingFromOutbox()
        
        // Drain mesh posts to newly subscribed peer
        let subscriberDeviceId = getSnapshot().first { $0.peripheral.identifier == central.identifier }?.deviceId
            ?? central.identifier.uuidString
        Task {
            await MeshPostService.shared.drainMeshPosts(to: subscriberDeviceId)
        }
        
        if runtimeProfile == .backgroundBridge {
            BackgroundMeshManager.shared.beginBackgroundTask(
                identifier: "ble_central_subscribed",
                reason: .bleDeviceConnected
            )
            endBackgroundTaskLater(identifier: "ble_central_subscribed", after: 15)
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        removeSubscriber(central)
        #if DEBUG
        print("📴 [BLE] Central unsubscribed (\(subscriberCount) remaining)")
        #endif
    }
    
    /// Bug #2: Cleanup stale subscribers (call periodically)
    func cleanupStaleSubscribers() {
        let removed = removeStaleSubscribers()
        if removed > 0 {
            #if DEBUG
            print("🧹 [BLE] Cleaned \(removed) stale subscribers")
            #endif
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        // ── v1 path (existing) ──────────────────────────────────────
        let messageRequests = requests.filter { $0.characteristic.uuid == Self.messageCharacteristicUUID }

        if !messageRequests.isEmpty, let firstRequest = messageRequests.first {
            let deviceId = getSnapshot().first { $0.peripheral.identifier == firstRequest.central.identifier }?.deviceId
                ?? firstRequest.central.identifier.uuidString

            // Fix: Assemble Long Write fragments into a single Data
            var assembledWriteData = Data()
            for request in messageRequests.sorted(by: { $0.offset < $1.offset }) {
                if let data = request.value {
                    assembledWriteData.append(data)
                }
            }

            if !assembledWriteData.isEmpty {
                if let completeData = processIncomingPacket(assembledWriteData, from: deviceId) {
                    // Bug 1 fix: Use actor for serialized processing
                    Task { [weak self] in
                        guard let self else { return }
                        await self.packetProcessor.processPacket(completeData, from: deviceId, engine: self)
                    }
                }
            }
        }

        // ── v2 path (parallel to v1) ────────────────────────────────
        // v2 envelopes arrive on a SEPARATE characteristic, so we just
        // filter on UUID and route the assembled bytes to the v2 decode
        // helper. No interaction with the v1 packet processor.
        let v2Requests = requests.filter { $0.characteristic.uuid == RUMProtocolV2.messageCharacteristicUUID }
        if !v2Requests.isEmpty, let firstV2 = v2Requests.first {
            let deviceId = getSnapshot().first { $0.peripheral.identifier == firstV2.central.identifier }?.deviceId
                ?? firstV2.central.identifier.uuidString

            var assembled = Data()
            for r in v2Requests.sorted(by: { $0.offset < $1.offset }) {
                if let d = r.value { assembled.append(d) }
            }
            if !assembled.isEmpty,
               let complete = processIncomingPacket(assembled, from: deviceId) {
                handleV2EnvelopePayload(complete, from: deviceId)
            }
        }

        // Respond to first request (prevents CoreBluetooth crash)
        if let firstRequest = requests.first {
            peripheral.respond(to: firstRequest, withResult: .success)
        }
    }
}

// MARK: - BLE Chunking Extension (Bug #10 Fix)

extension BLEMeshEngine {
    
    // MARK: - Constants
    static let headerSize = 6 // [messageHash(4), totalChunks(1), chunkIndex(1)]
    
    /// Dynamic MTU calculation per peripheral
    func effectivePayload(for peripheral: CBPeripheral?) -> Int {
        guard let peripheral = peripheral else { return 180 }
        let maxWrite = peripheral.maximumWriteValueLength(for: .withResponse)
        return max(maxWrite - Self.headerSize - 1, 20)
    }
    
    // MARK: - Pending Reassembly Storage
    private static var pendingChunks: [String: [Int: Data]] = [:]
    private static var pendingChunksMeta: [String: (total: Int, receivedAt: Date)] = [:]
    private static let chunkLock = OSAllocatedUnfairLock()
    private static let maxPendingHashKeys = 64
    private static let maxTotalChunks = 255
    
    // MARK: - Chunked Broadcast
    func broadcastDataChunked(_ data: Data) async {
        await withTaskGroup(of: Void.self) { group in
            // Send to Central subscribers concurrently
            for sub in getSubscribers() {
                group.addTask { await self.sendDataChunkedToCentral(data, central: sub.central) }
            }
            // Send to connected Peripheral peers concurrently
            for peer in getSnapshot() {
                group.addTask { await self.sendDataChunkedToPeer(data, peer: peer) }
            }
        }
    }
    
    private func sendDataChunkedToCentral(_ data: Data, central: CBCentral) async {
        let maxUpdateLength = central.maximumUpdateValueLength
        let centralMTU = max(maxUpdateLength - 1, 20)
        
        if data.count <= centralMTU {
            var packet = Data([0]) // 0 = not chunked
            packet.append(data)
            if let char = messageCharacteristic {
                var success = peripheralManager?.updateValue(packet, for: char, onSubscribedCentrals: [central]) ?? false
                var retries = 0
                while !success && retries < 15 {
                    // 🟡 BUG FIX (2026-05-10): observe Task cancellation
                    // so a peer-disconnect / mesh-stop / app-background
                    // can short-circuit this 15-iteration loop instead
                    // of running it to completion (battery drain +
                    // tying up `messageCharacteristic` while the next
                    // pending message waits).
                    if Task.isCancelled { return }
                    await waitForCentralReady()
                    success = peripheralManager?.updateValue(packet, for: char, onSubscribedCentrals: [central]) ?? false
                    retries += 1
                }
                guard success else {
                    #if DEBUG
                    print("❌ [BLE] Failed to send non-chunked message after 15 retries. Aborting.")
                    #endif
                    return
                }
            }
            return
        }
        
        let chunkPayloadSize = centralMTU - Self.headerSize
        let chunks = splitIntoChunks(data, payloadSize: chunkPayloadSize)
        guard chunks.count <= 255 else { return }
        
        let messageHash = UInt32(truncatingIfNeeded: data.hashValue).littleEndian
        
        for (index, chunk) in chunks.enumerated() {
            var packet = Data([1]) // 1 = chunked
            let hashBytes = withUnsafeBytes(of: messageHash) { Array($0) }
            packet.append(contentsOf: hashBytes)
            packet.append(UInt8(chunks.count))
            packet.append(UInt8(index))
            packet.append(chunk)
            
            if let char = messageCharacteristic {
                var success = peripheralManager?.updateValue(packet, for: char, onSubscribedCentrals: [central]) ?? false
                var retries = 0
                while !success && retries < 15 {
                    // 🟡 BUG FIX (2026-05-10): see non-chunked path
                    // above. Same cancellation observation needed
                    // here so a peer-disconnect / mesh-stop can
                    // short-circuit the per-chunk retry loop.
                    if Task.isCancelled { return }
                    await waitForCentralReady()
                    success = peripheralManager?.updateValue(packet, for: char, onSubscribedCentrals: [central]) ?? false
                    retries += 1
                }
                guard success else {
                    #if DEBUG
                    print("❌ [BLE] Failed to send chunk \(index)/\(chunks.count) after 15 retries. Aborting message.")
                    #endif
                    return
                }
                
                // 🛑 FIX 2: Prevent CoreBluetooth XPC Flood on Central side
                try? await Task.sleep(nanoseconds: 15_000_000)
            }
        }
    }
    
    private func sendDataDirect(
        _ data: Data,
        to peer: MeshPeer,
        type: CBCharacteristicWriteType = .withoutResponse,
        serviceUUID: CBUUID = BLEMeshEngine.serviceUUID,
        characteristicUUID: CBUUID = BLEMeshEngine.messageCharacteristicUUID
    ) async {
        guard let services = peer.peripheral.services,
              let service = services.first(where: { $0.uuid == serviceUUID }),
              let characteristics = service.characteristics,
              let char = characteristics.first(where: { $0.uuid == characteristicUUID }) else {
            return
        }

        peer.peripheral.writeValue(data, for: char, type: type)
    }

    private func sendDataChunkedToPeer(
        _ data: Data,
        peer: MeshPeer,
        serviceUUID: CBUUID = BLEMeshEngine.serviceUUID,
        characteristicUUID: CBUUID = BLEMeshEngine.messageCharacteristicUUID
    ) async {
        // Bug 2 fix: Use .withoutResponse + waitForPeripheralReady for flow control.
        // .withResponse fires hundreds of XPC requests without waiting for didWriteValueFor,
        // overflowing iOS's internal queue and causing "Peripheral is busy" disconnects.
        let maxWrite = peer.peripheral.maximumWriteValueLength(for: .withoutResponse)
        let maxDataPerPacket = max(maxWrite - Self.headerSize - 1, 20)

        if data.count <= maxDataPerPacket {
            var packet = Data([0])
            packet.append(data)
            await waitForPeripheralReady(peer.peripheral)
            await sendDataDirect(packet, to: peer, type: .withoutResponse,
                                 serviceUUID: serviceUUID,
                                 characteristicUUID: characteristicUUID)
            return
        }

        let chunkPayloadSize = maxDataPerPacket
        let chunks = splitIntoChunks(data, payloadSize: chunkPayloadSize)
        guard chunks.count <= 255 else { return }

        let messageHash = UInt32(truncatingIfNeeded: data.hashValue).littleEndian

        for (index, chunk) in chunks.enumerated() {
            // 🛡️ Ghost-loop guard: abort immediately if peer disconnected mid-transfer.
            // Without this, each remaining chunk waits 2s for timeout (250 chunks × 2s = 8 min hang).
            guard peer.peripheral.state == .connected else {
                #if DEBUG
                print("⚠️ [BLE] Peer disconnected mid-transfer at chunk \(index)/\(chunks.count). Aborting.")
                #endif
                break
            }

            var packet = Data([1])
            let hashBytes = withUnsafeBytes(of: messageHash) { Array($0) }
            packet.append(contentsOf: hashBytes)
            packet.append(UInt8(chunks.count))
            packet.append(UInt8(index))
            packet.append(chunk)

            await waitForPeripheralReady(peer.peripheral)
            await sendDataDirect(packet, to: peer, type: .withoutResponse,
                                 serviceUUID: serviceUUID,
                                 characteristicUUID: characteristicUUID)

            // 🛑 FIX 1: Prevent CoreBluetooth XPC Flood (Result accumulator timeout)
            // دادن فرصت ۱۵ میلیثانیهای به iOS برای هضم پکت در صف سختافزاری
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    // MARK: - V2 framing helper
    //
    // Wrap an already-AES-GCM-encrypted v1 ciphertext blob in a v2
    // binary envelope. Symmetric to RAVEN-MacApp/.../BLEMeshEngine.swift's
    // `encodeV2Frame` — same wire format on both ends.
    //
    // The v2 frame is a thin transport upgrade for now: payload still
    // carries the v1 AES-GCM ciphertext, so existing chat ingest works
    // unchanged. Phase C.1 swaps the inner crypto for Noise IK.
    func encodeV2FrameForPeer(
        encryptedV1Payload: Data,
        clientMessageID: String,
        peerAgreementKey: Data,
        hopCount: Int = 0
    ) -> Data? {
        guard let myAgreement = DeviceIdentityService.shared.agreementPublicKeyData else {
            return nil
        }
        let mySenderPID = RUMProtocolV2.peerID(fromPublicKey: myAgreement)
        let destPID     = RUMProtocolV2.peerID(fromPublicKey: peerAgreementKey)
        guard let msgID = uuidStringToBytes(clientMessageID) else { return nil }

        let v2 = RUMProtocolV2.Envelope(
            type: .text,
            ttl: RUMProtocolV2.defaultTTL,
            flags: [.encrypted, .needsForwarding],
            timestamp: UInt32(clamping: Int(Date().timeIntervalSince1970)),
            msgID: msgID,
            senderPID: mySenderPID,
            destPID: destPID,
            hopCount: UInt8(min(255, max(0, hopCount))),
            sprayRemaining: RUMProtocolV2.defaultSprayCopies,
            payload: encryptedV1Payload,
            signature: nil
        )
        do {
            let encoded = try RUMProtocolV2.encode(v2)
            return RUMProtocolV2.pad(encoded)
        } catch {
            #if DEBUG
            print("[mesh-v2] encode failed: \(error)")
            #endif
            return nil
        }
    }

    /// Wrap a v1 ciphertext in a v2 envelope encrypted with the cached
    /// Noise transport-mode key for `peerPID`. AD = the envelope's
    /// `msg_id` so a replay against a different envelope fails the
    /// AEAD verify cleanly. Returns nil when no Noise session exists
    /// for `peerPID` — the caller should then fall back to the
    /// handshake encoder below.
    @MainActor
    func encodeV2NoiseTransportFrameForPeer(
        encryptedV1Payload: Data,
        nativeSignedPayload: Data? = nil,
        clientMessageID: String,
        peerPID: Data,
        hopCount: Int = 0
    ) -> Data? {
        guard let myAgreement = DeviceIdentityService.shared.agreementPublicKeyData else { return nil }
        guard let msgID = uuidStringToBytes(clientMessageID) else { return nil }

        // C.1.f: when both peers are on a build that handles
        // Noise-native receive (handled in C.1.e for Mac+iOS), drop
        // the inner AES-GCM layer. We only switch when the caller
        // gave us a `nativeSignedPayload` AND the protocol-level
        // flag is on; either condition false → fall back to hybrid
        // (Noise-wraps-AES-GCM).
        let plaintextForNoise: Data
        let frameFlags: RUMProtocolV2.Flags
        if RUMProtocolV2.preferNoiseNativeTransport, let native = nativeSignedPayload {
            plaintextForNoise = native
            frameFlags = [.noiseTransport, .needsForwarding]
        } else {
            plaintextForNoise = encryptedV1Payload
            frameFlags = [.encrypted, .noiseTransport, .needsForwarding]
        }

        guard let noiseCT = NoiseSessionStore.shared.encrypt(
            plaintextForNoise,
            ad: msgID,
            forPeer: peerPID
        ) else { return nil }

        let mySenderPID = RUMProtocolV2.peerID(fromPublicKey: myAgreement)
        let v2 = RUMProtocolV2.Envelope(
            type: .text,
            ttl: RUMProtocolV2.defaultTTL,
            flags: frameFlags,
            timestamp: UInt32(clamping: Int(Date().timeIntervalSince1970)),
            msgID: msgID,
            senderPID: mySenderPID,
            destPID: peerPID,
            hopCount: UInt8(min(255, max(0, hopCount))),
            sprayRemaining: RUMProtocolV2.defaultSprayCopies,
            payload: noiseCT,
            signature: nil
        )
        return (try? RUMProtocolV2.encode(v2)).map(RUMProtocolV2.pad)
    }

    /// Build a v2 envelope of `type=noiseHandshake1` that bundles the
    /// v1 ciphertext as the embedded M1 payload. The receiver
    /// processes M1, establishes transport keys, decrypts the
    /// embedded payload, and emits M2 back. Future sends to this peer
    /// then use `encodeV2NoiseTransportFrameForPeer` — no extra
    /// round-trip beyond this initial 1-RTT IK handshake.
    @MainActor
    func encodeV2NoiseHandshake1FrameForPeer(
        encryptedV1Payload: Data,
        clientMessageID: String,
        peerAgreementKey: Data,
        hopCount: Int = 0
    ) -> Data? {
        guard let myAgreement = DeviceIdentityService.shared.agreementPublicKeyData else { return nil }
        guard let msgID = uuidStringToBytes(clientMessageID) else { return nil }
        let peerPubKey: Curve25519.KeyAgreement.PublicKey
        do {
            peerPubKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerAgreementKey)
        } catch {
            return nil
        }

        let m1Bytes: Data
        let peerPID: Data
        do {
            let result = try NoiseSessionStore.shared.startHandshake(
                toPeer: peerPubKey,
                payload: encryptedV1Payload
            )
            m1Bytes = result.message1
            peerPID = result.peerID
        } catch {
            return nil
        }

        let mySenderPID = RUMProtocolV2.peerID(fromPublicKey: myAgreement)
        let v2 = RUMProtocolV2.Envelope(
            type: .noiseHandshake1,
            ttl: RUMProtocolV2.defaultTTL,
            flags: [.needsForwarding],
            timestamp: UInt32(clamping: Int(Date().timeIntervalSince1970)),
            msgID: msgID,
            senderPID: mySenderPID,
            destPID: peerPID,
            hopCount: UInt8(min(255, max(0, hopCount))),
            sprayRemaining: RUMProtocolV2.defaultSprayCopies,
            payload: m1Bytes,
            signature: nil
        )
        return (try? RUMProtocolV2.encode(v2)).map(RUMProtocolV2.pad)
    }

    /// "12345678-1234-…" → 16 raw bytes for the v2 envelope's `msg_id`.
    private func uuidStringToBytes(_ s: String) -> Data? {
        guard let u = UUID(uuidString: s) else { return nil }
        let t = u.uuid
        return Data([
            t.0,  t.1,  t.2,  t.3,  t.4,  t.5,  t.6,  t.7,
            t.8,  t.9,  t.10, t.11, t.12, t.13, t.14, t.15
        ])
    }

    /// Forward an already-encoded v2 envelope to every v2-capable peer
    /// currently connected, except the one named in `except` (so we
    /// don't echo it straight back to the source). Called by
    /// `RUMRelayService` for multi-hop spray. The payload is the inner
    /// AES-GCM ciphertext addressed to the original recipient — a
    /// relay device cannot read what it forwards.
    ///
    /// Fans out over BOTH transports:
    ///   1. **BLE** — every v2-capable connected peripheral.
    ///   2. **MPC** — every authenticated MultipeerConnectivity peer
    ///      (Apple-only, Wi-Fi-Direct-or-LAN, ~250 Mbps vs BLE's
    ///      ~50 kbps). Receivers dedup via the bloom filter on
    ///      `msg_id`, so cross-transport duplicates collapse cleanly.
    func relayV2EnvelopeBytesToAllPeers(_ bytes: Data, except sourceDeviceId: String) async {
        let snapshot = getSnapshot()
        for peer in snapshot {
            if peer.deviceId == sourceDeviceId { continue }
            let caps = peerCapabilities[peer.id] ?? []
            guard caps.contains(.v2Protocol) else { continue }
            await sendDataChunkedToPeer(
                bytes,
                peer: peer,
                serviceUUID: RUMProtocolV2.serviceUUID,
                characteristicUUID: RUMProtocolV2.messageCharacteristicUUID
            )
        }

        // MPC fan-out — only authenticated peers (the service rejects
        // sends to unauthenticated). `connectedPeerIds` is read once
        // here, so a peer disconnecting mid-loop is harmless (the send
        // throws and we log + continue).
        for mpcPeer in MPCTransportService.shared.connectedPeerIds {
            if mpcPeer.displayName == sourceDeviceId { continue }
            do {
                try MPCTransportService.shared.sendBulkData(bytes, to: mpcPeer)
            } catch {
                #if DEBUG
                print("[mesh-v2-relay] mpc send to \(mpcPeer.displayName) failed: \(error)")
                #endif
            }
        }

        // Wi-Fi Aware fan-out (iOS 26+; no-op when the scaffold isn't
        // yet wired). Same exclusion + cross-transport dedup contract
        // as MPC and BLE. The transport is @MainActor-isolated, so
        // we hop briefly to MainActor for the send loop.
        await MainActor.run {
            for waPeer in WiFiAwareTransport.shared.connectedPeerIds {
                if waPeer.displayName == sourceDeviceId { continue }
                do {
                    try WiFiAwareTransport.shared.sendBulkData(bytes, to: waPeer)
                } catch {
                    #if DEBUG
                    print("[mesh-v2-relay] wifi-aware send to \(waPeer.displayName) failed: \(error)")
                    #endif
                }
            }
        }
    }
    
    // MARK: - Chunk Splitting
    private func splitIntoChunks(_ data: Data, payloadSize: Int) -> [Data] {
        let effectiveSize = max(payloadSize, 10)
        var chunks: [Data] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + effectiveSize, data.count)
            chunks.append(data[offset..<end])
            offset = end
        }
        return chunks
    }
    
    // MARK: - Chunk Reassembly
    func processIncomingPacket(_ packet: Data, from deviceId: String) -> Data? {
        guard packet.count > 1 else { return nil }
        let isChunked = packet[0] == 1
        let payload = packet.dropFirst()
        
        if !isChunked { return Data(payload) }
        return reassembleChunk(Data(payload), from: deviceId)
    }
    
    private func reassembleChunk(_ packet: Data, from deviceId: String) -> Data? {
        guard packet.count >= Self.headerSize else { return nil }
        
        // Bug #1 fix: Copy to Array first to avoid Data Slice alignment issues on ARM64
        let hashBytes = Array(packet[0..<4])
        let messageHash = hashBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let totalChunks = Int(packet[4])
        let chunkIndex = Int(packet[5])
        let chunkData = packet.dropFirst(Self.headerSize)
        
        guard totalChunks > 0, totalChunks <= Self.maxTotalChunks else { return nil }
        let key = "\(deviceId)-\(messageHash)"
        
        Self.chunkLock.lock()
        defer { Self.chunkLock.unlock() }
        
        if Self.pendingChunks[key] == nil {
            if Self.pendingChunks.count >= Self.maxPendingHashKeys {
                if let oldest = Self.pendingChunksMeta.min(by: { $0.value.receivedAt < $1.value.receivedAt }) {
                    Self.pendingChunks.removeValue(forKey: oldest.key)
                    Self.pendingChunksMeta.removeValue(forKey: oldest.key)
                }
            }
            Self.pendingChunks[key] = [:]
            Self.pendingChunksMeta[key] = (total: totalChunks, receivedAt: Date())
        }
        
        Self.pendingChunks[key]?[chunkIndex] = Data(chunkData)
        guard Self.pendingChunks[key]?.count == totalChunks else { return nil }
        
        var assembled = Data()
        for i in 0..<totalChunks {
            guard let chunk = Self.pendingChunks[key]?[i] else {
                Self.pendingChunks.removeValue(forKey: key)
                Self.pendingChunksMeta.removeValue(forKey: key)
                return nil
            }
            assembled.append(chunk)
        }
        
        Self.pendingChunks.removeValue(forKey: key)
        Self.pendingChunksMeta.removeValue(forKey: key)
        return assembled
    }
    
    func cleanupStaleChunks() {
        Self.chunkLock.lock()
        defer { Self.chunkLock.unlock() }
        
        let staleThreshold: TimeInterval = 30
        let now = Date()
        let staleKeys = Self.pendingChunksMeta.filter {
            now.timeIntervalSince($0.value.receivedAt) > staleThreshold
        }.map { $0.key }
        
        for key in staleKeys {
            Self.pendingChunks.removeValue(forKey: key)
            Self.pendingChunksMeta.removeValue(forKey: key)
        }
    }
    
    // MARK: - Inventory Exchange (Anti-Entropy)
    
    /// Initiate an inventory exchange with a newly connected peer.
    /// Builds a Bloom filter of message IDs we've seen and sends it.
    private func initiateInventoryExchange(with peerDeviceId: String) async {
        // Rate-limit: at most once per minute per peer
        let canExchange = stateLock.withLock { () -> Bool in
            let state = inventoryExchangeState[peerDeviceId] ?? InventoryExchangeState()
            guard state.canExchange else { return false }
            // Update rate-limiter FIRST to prevent re-entry from concurrent Tasks
            inventoryExchangeState[peerDeviceId] = InventoryExchangeState(lastExchangeAt: Date())
            return true
        }
        guard canExchange else {
            #if DEBUG
            print("📦 [INV] Skipping exchange with \(peerDeviceId.prefix(8)) — too recent")
            #endif
            return
        }
        
        let myDeviceId = DeviceIdentityService.shared.fingerprint ?? ""
        let myUserId = await KeychainService.shared.getUserId()
        
        // Build Bloom filter from recent dedup cache
        let recentIds = await MeshDedupRepository.shared.getRecentMessageIds(limit: 500)
        // Cap Bloom size to keep BLE payload small
        let cappedIds = Array(recentIds.prefix(100))
        var bloom = BloomFilter(expectedItems: max(cappedIds.count, 50))
        for id in cappedIds {
            bloom.insert(id)
        }
        
        let frame = InvBloomFrame(
            kind: MeshInventoryKind.invBloom.rawValue,
            windowId: UUID().uuidString,
            bloom: bloom,
            peerDeviceId: myDeviceId,
            userId: myUserId
        )
        
        guard let data = try? JSONEncoder().encode(frame) else {
            #if DEBUG
            print("❌ [INV] Failed to encode InvBloom frame")
            #endif
            return
        }
        
        // Find the target peer and send ONLY to them (not broadcast).
        guard let peer = getSnapshot().first(where: { $0.deviceId == peerDeviceId }) else {
            #if DEBUG
            print("⚠️ [INV] Peer \(peerDeviceId.prefix(8)) not in snapshot — skipping")
            #endif
            return
        }
        
        #if DEBUG
        print("📦 [INV] Sending Bloom (\(cappedIds.count) items, \(data.count)B) to \(peerDeviceId.prefix(8))")
        #endif
        
        // Use chunked send to avoid exceeding BLE MTU (~185 bytes).
        // The old code sent a single unchunked packet that would silently fail
        // or drop the BLE connection for any payload larger than MTU.
        await sendDataChunkedToPeer(data, peer: peer)
    }
    
    /// Handle an incoming INV_BLOOM frame from a peer.
    /// Compare their Bloom against our local IDs and send a WANT for messages they seem to be missing.
    private func handleInvBloom(_ frame: InvBloomFrame, from peerDeviceId: String) async {
        // Learn userId from handshake frame — enables bridge to fetch messages for this peer
        if let userId = frame.userId, !userId.isEmpty {
            let actualPeerId = String(frame.peerDeviceId.prefix(8))
            
            // Use MainActor.run to ensure userId is set synchronously before bridgeDownlinkPoll reads it
            await MainActor.run {
                if let idx = self.connectedPeers.firstIndex(where: { $0.deviceId == actualPeerId || $0.deviceId == peerDeviceId }) {
                    self.connectedPeers[idx].userId = userId
                    self.syncSnapshot()
                    #if DEBUG
                    print("🔑 [INV] Learned userId \(userId.prefix(8)) for peer \(actualPeerId)")
                    #endif
                }
            }
            // Immediately poll server for messages destined to this now-identified peer
            if NetworkMonitor.shared.isOnline {
                Task { await self.bridgeDownlinkPoll() }
            }
        }
        
        // Get our recent messages
        let ourIds = await MeshDedupRepository.shared.getRecentMessageIds(limit: 1000)
        
        // Find IDs WE have that the PEER's Bloom says they DON'T have
        var missingForPeer: [String] = []
        for id in ourIds {
            if !frame.bloom.mightContain(id) {
                missingForPeer.append(id)
            }
        }
        
        // If peer has everything we have, also send our own Bloom for reciprocal exchange
        // (they may have things we don't)
        if missingForPeer.isEmpty {
            #if DEBUG
            print("📦 [INV] Peer \(peerDeviceId.prefix(8)) has all our messages — sending our Bloom for reciprocal check")
            #endif
        } else {
            #if DEBUG
            print("📦 [INV] Peer \(peerDeviceId.prefix(8)) missing \(missingForPeer.count) messages — telling them")
            #endif
        }
        
        // Send WANT frame telling peer what THEY should request from US
        // (Reversed: we tell them what we have that they don't, so they can pull)
        // Actually per protocol: we now re-broadcast those missing messages ourselves
        // But to stay efficient, cap at 20 messages per exchange
        let capped = Array(missingForPeer.prefix(5))
        
        if !capped.isEmpty {
            // Re-broadcast the messages they're missing
            for messageId in capped {
                // Check if we can find the message in our store
                if let rows = try? await MessageRepository.shared.getMessageByClientId(messageId),
                   let row = rows.first,
                   let msg = parseMessageFromRow(row) {
                    let envelope = msg.toMeshEnvelope()
                    if let peer = getSnapshot().first(where: { $0.deviceId == peerDeviceId }) {
                        await send(envelope, to: peer)
                        #if DEBUG
                        print("📦 [INV] Sent missing message \(messageId.prefix(8)) to \(peerDeviceId.prefix(8))")
                        #endif
                    }
                }
            }
        }
        
        // Now also initiate our own Bloom so we can receive THEIR unique messages
        await initiateInventoryExchange(with: peerDeviceId)
    }
    
    /// Handle an incoming WANT frame from a peer.
    /// They're requesting specific message IDs — send them.
    private func handleWant(_ frame: WantFrame, from peerDeviceId: String) async {
        guard !frame.wantedIds.isEmpty else { return }
        
        let capped = Array(frame.wantedIds.prefix(20))  // Safety cap
        #if DEBUG
        print("📦 [INV] Peer \(peerDeviceId.prefix(8)) wants \(capped.count) messages")
        #endif
        
        for messageId in capped {
            if let rows = try? await MessageRepository.shared.getMessageByClientId(messageId),
               let row = rows.first,
               let msg = parseMessageFromRow(row) {
                let envelope = msg.toMeshEnvelope()
                if let peer = getSnapshot().first(where: { $0.deviceId == peerDeviceId }) {
                    await send(envelope, to: peer)
                }
            }
        }
    }
    
    /// Parse a ChatMessage from a DB row dict (for inventory resend)
    private func parseMessageFromRow(_ row: [String: Any]) -> ChatMessage? {
        guard let id = row["client_message_id"] as? String,
              let senderId = row["sender_id"] as? String,
              let recipientId = row["recipient_id"] as? String,
              let timestampStr = row["timestamp"] as? String,
              let timestamp = PerformanceConstants.iso8601.date(from: timestampStr) else {
            return nil
        }
        
        let typeStr = row["type"] as? String ?? "text"
        let type = MessageType.from(name: typeStr)
        
        return ChatMessage(
            id: id,
            serverId: row["server_id"] as? String,
            roomId: row["room_id"] as? String,
            senderId: senderId,
            senderName: row["sender_name"] as? String ?? "",
            recipientId: recipientId,
            text: row["text"] as? String,
            timestamp: timestamp,
            type: type,
            status: .sent,
            deliveryAuthority: .mesh,
            createdAt: nil,
            deliveredAt: nil,
            readAt: nil,
            hopCount: 0,
            routePath: [],
            sprayCounter: PremiumLimits.meshSprayBudget,
            hopLimit: PremiumLimits.meshHopLimit,
            originDeviceId: DeviceIdentityService.shared.fingerprint ?? "",
            needsForwarding: true,
            attachmentUrl: row["remote_url"] as? String,
            thumbnailUrl: nil,
            fileName: row["file_name"] as? String,
            mimeType: row["mime_type"] as? String,
            fileSize: (row["file_size"] as? Int64).map { Int($0) },
            audioDurationSeconds: (row["audio_duration_seconds"] as? Int64).map { Int($0) },
            syncState: .synced,
            localPath: nil,
            uploadProgress: nil,
            lastError: nil,
            replyToMessageId: row["reply_to_message_id"] as? String,
            replyToTextPreview: nil,
            replyToSenderName: nil,
            replyToType: nil,
            sendMode: nil,
            scheduledAtUtc: nil
        )
    }
}

// MARK: - Bridge Downlink (Server → BLE) — Smart Routing

extension BLEMeshEngine {
    
    /// Smart Bridge Downlink request with routing context
    struct SmartBridgeDownlinkRequest: Encodable {
        let immediatePeers: [String]
        let currentGeohash: String?
        let bridgeUserId: String?
    }
    
    /// Poll server for undelivered messages destined for our BLE peers
    /// using Smart Context (geo-fencing + social mules) instead of global flooding.
    func bridgeDownlinkPoll() async {
        // Gate 0: Poll in foreground OR when background bridge mode is active
        let canPoll = await MainActor.run(body: {
            UIApplication.shared.applicationState == .active
        }) || runtimeProfile == .backgroundBridge
        guard canPoll, NetworkMonitor.shared.isOnline else { return }
        
        // Gate 1: Rate limit
        let shouldPoll = downlinkLock.withLock { () -> Bool in
            guard Date().timeIntervalSince(lastBridgeDownlinkPoll) >= bridgeDownlinkInterval else { return false }
            lastBridgeDownlinkPoll = Date()
            return true
        }
        guard shouldPoll else { return }
        
        // Collect peer userIds (filter out nil/empty)
        let peers = getSnapshot()
        let peerUserIds = peers.compactMap { $0.userId }.filter { !$0.isEmpty }
        let myUserId = await KeychainService.shared.getUserId()
        
        // Generate current GeoHash for geo-fenced message delivery
        var myGeohash: String? = nil
        let loc = await MainActor.run { LocationManager.shared.lastLocation }
        if let location = loc {
            myGeohash = GeoHashUtil.encode(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )
        }
        
        // 🛑 FIX: If we have no routing context at all (no peers nearby AND no
        // location), skip polling to prevent downloading messages we can't deliver.
        if peerUserIds.isEmpty && myGeohash == nil {
            #if DEBUG
            print("  [Bridge Downlink] No routing context available. Skipped to prevent global flood.")
            #endif
            return
        }
        
        #if DEBUG
        print("  [Bridge Downlink] Polling with SMART Context (Peers: \(peerUserIds.count), Geo: \(myGeohash ?? "nil"))")
        #endif
        
        do {
            let request = SmartBridgeDownlinkRequest(
                immediatePeers: peerUserIds,
                currentGeohash: myGeohash,
                bridgeUserId: myUserId
            )
            
            var response: BridgeDownlinkResponse? = nil
            do {
                // NetworkService encoder uses .convertToSnakeCase → immediatePeers → immediate_peers ✅
                response = try await NetworkService.shared.post(
                    path: "/api/messages/smart-bridge-downlink",
                    body: request
                )
            } catch {
                #if DEBUG
                print("  [Bridge Downlink] Smart poll failed (\(error.localizedDescription)), trying legacy fallback...")
                #endif
                do {
                    let legacyRequest = BridgeDownlinkRequest(peerUserIds: peerUserIds)
                    response = try await NetworkService.shared.post(
                        path: "/api/messages/bridge-downlink",
                        body: legacyRequest
                    )
                } catch {
                    #if DEBUG
                    print("  [Bridge Downlink] Legacy poll also failed: \(error.localizedDescription)")
                    #endif
                }
            }
            
            guard let validResponse = response, validResponse.count > 0 else { return }
            
            #if DEBUG
            print("  [Bridge Downlink] Got \(validResponse.count) messages to relay via BLE")
            #endif
            
            // UIDevice.current is MainActor-isolated; read the vendor ID from
            // there in one explicit hop instead of in a nonisolated autoclosure.
            let vendorId = await MainActor.run { UIDevice.current.identifierForVendor?.uuidString }
            let myDeviceId = DeviceIdentityService.shared.fingerprint ?? vendorId ?? UUID().uuidString
            
            var relayedCount = 0
            for msg in validResponse.messages {
                // Dedup with TTL — only skip if we've already relayed this
                // SAME message id within the last `bridgeDownlinkRelayTTL`
                // seconds. Older entries are evicted so a failed BLE
                // broadcast gets retried on the next poll instead of being
                // permanently dropped (the original A→C bug).
                let isNew = downlinkLock.withLock { () -> Bool in
                    let now = Date()
                    bridgeDownlinkRelayedAt = bridgeDownlinkRelayedAt.filter {
                        now.timeIntervalSince($0.value) < bridgeDownlinkRelayTTL
                    }
                    if bridgeDownlinkRelayedAt[msg.id] != nil { return false }
                    bridgeDownlinkRelayedAt[msg.id] = now
                    return true
                }
                guard isNew else { continue }
                
                let msgType = MessageType.from(name: msg.messageType ?? "text")
                guard msgType == .text || msgType == .location || msgType == .system else {
                    continue
                }
                
                // Build MeshEnvelope from server message
                // Server may override sprayCounter and hopLimit per routing rule:
                //   Direct Hit  → hop_limit=1, spray=1
                //   Social Mule → spray=0 (carry-only, no BLE spreading)
                //   Geo Match   → spray=meshSprayBudget (full city coverage)
                let envelope = MeshEnvelope(
                    clientMessageId: msg.id,
                    roomId: msg.roomId ?? msg.senderId ?? "",
                    senderId: msg.senderId ?? "",
                    senderName: msg.senderName ?? msg.senderUsername ?? "User",
                    recipientId: msg.recipientId ?? "",
                    type: MessageType.from(name: msg.messageType ?? "text").index,
                    text: msg.content,
                    timestamp: msg.timestamp?.timeIntervalSince1970 ?? Date().timeIntervalSince1970,
                    sprayCounter: msg.sprayCounter ?? 50,
                    hopCount: 1,
                    hopLimit: msg.hopLimit ?? 50,
                    routePath: [myDeviceId],
                    originDeviceId: myDeviceId,
                    needsForwarding: true,
                    ttlSeconds: msg.ttlSeconds ?? 259200,
                    mediaUrl: msg.audioUrl ?? msg.mediaUrl,
                    thumbnailUrl: msg.thumbnailUrl,
                    fileName: msg.fileName,
                    mimeType: msg.mimeType,
                    fileSize: msg.fileSize,
                    audioDuration: msg.resolvedAudioDuration,
                    replyToMessageId: msg.replyToMessageId,
                    replyToTextPreview: msg.replyToTextPreview,
                    replyToSenderName: msg.replyToSenderName,
                    isBridged: true
                )
                
                // Broadcast via BLE to peers (goes through sign+encrypt pipeline)
                await enqueueForBroadcast(envelope)
                
                // Store in relay queue so downlinked messages survive BLE disconnections
                addToRelayQueue(envelope)
                
                relayedCount += 1
                #if DEBUG
                print("  [Bridge Downlink] ✅ Relayed \(msg.id.prefix(8)) from \(msg.senderId?.prefix(8) ?? "?") → \(msg.recipientId?.prefix(8) ?? "?")")
                #endif
            }
            
            if relayedCount > 0 {
                #if DEBUG
                print("  [Bridge Downlink] ════ Relayed \(relayedCount)/\(validResponse.count) messages via BLE ════")
                #endif
            }
            
            // Cleanup is now handled inline by the TTL filter above — no
            // separate eviction needed. The map self-trims on every poll.
        }
        // The outer `do` is just a scope here; the only failing API calls
        // (NetworkService.post) are wrapped in their own do/catch above, so
        // there is no error path to catch out here.
    }
}

// MARK: - Server Uplink (Store & Forward)

extension BLEMeshEngine {
    struct MeshUplinkRequest: Encodable {
        let recipientId: String
        let content: String
        let messageType: String
        let messageId: String
        let bridgedFrom: String
        let originalSenderId: String
        let originalSenderName: String
        let isBridged: Bool
        let createdAt: String
        let ttlSeconds: Int
        let hopCount: Int
        let hopLimit: Int
        let sprayCounter: Int
        let bridgeSignature: String
        let bridgePublicKey: String
        
        let roomId: String?
        let mediaUrl: String?
        let thumbnailUrl: String?
        let fileName: String?
        let mimeType: String?
        let fileSize: Int?
        let audioDurationSeconds: Int?
        
        let replyToMessageId: String?
        let replyToTextPreview: String?
        let replyToSenderName: String?
    }

    /// Forward a mesh message to the server API
    @discardableResult
    func forwardMeshMessageToServer(_ message: ChatMessage) async -> Bool {
        #if DEBUG
        print("  [Bridge] Forwarding mesh message to server: \(message.id.prefix(8))")
        #endif
        
        let relayData = "relay:\(message.id):\(message.senderId):\(message.recipientId)".data(using: .utf8) ?? Data()
        let bridgeSig = DeviceIdentityService.shared.sign(relayData)?.base64EncodedString() ?? ""
        let bridgePubKey = DeviceIdentityService.shared.publicKeyBase64 ?? ""
        
        // CRITICAL FIX: Only add room_id if it is an ACTUAL group chat.
        let isGroupRoom = message.roomId != nil && !message.roomId!.isEmpty && message.roomId != message.recipientId && message.roomId != message.senderId
        
        let request = MeshUplinkRequest(
            recipientId: message.recipientId,
            content: message.text ?? "",
            messageType: message.type.rawValue,
            messageId: message.id,
            bridgedFrom: DeviceIdentityService.shared.fingerprint ?? "unknown",
            originalSenderId: message.senderId,
            originalSenderName: message.senderName,
            isBridged: true,
            createdAt: PerformanceConstants.iso8601.string(from: message.timestamp),
            ttlSeconds: PremiumLimits.meshTTLSeconds,
            hopCount: message.hopCount,
            hopLimit: message.hopLimit,
            sprayCounter: message.sprayCounter,
            bridgeSignature: bridgeSig,
            bridgePublicKey: bridgePubKey,
            roomId: isGroupRoom ? message.roomId : nil,
            mediaUrl: message.attachmentUrl,
            thumbnailUrl: message.thumbnailUrl,
            fileName: message.fileName,
            mimeType: message.mimeType,
            fileSize: message.fileSize,
            audioDurationSeconds: message.audioDurationSeconds,
            replyToMessageId: message.replyToMessageId,
            replyToTextPreview: message.replyToTextPreview,
            replyToSenderName: message.replyToSenderName
        )
        
        do {
            struct EmptyResp: Decodable {}
            let _: EmptyResp = try await NetworkService.shared.post(
                path: "/api/messages/uplink",
                body: request,
                idempotencyKey: message.id
            )
            return true
        } catch {
            do {
                struct EmptyResp: Decodable {}
                let _: EmptyResp = try await NetworkService.shared.post(
                    path: "/api/messages/bridge",
                    body: request,
                    idempotencyKey: message.id
                )
                return true
            } catch {
                #if DEBUG
                print("  [Bridge] Failed to forward mesh payload to server: \(error)")
                #endif
                return false
            }
        }
    }
    
    /// Bridge a mesh message to the server on behalf of the original sender.
    ///
    /// ⚡ Scale fix — probabilistic bridge election:
    /// In a dense BLE cluster, multiple online relays would otherwise all
    /// POST the same envelope to the server. Server-side idempotency on
    /// `messageId` deduplicates writes, but the redundant POSTs still cost
    /// bandwidth + battery + server CPU. Each relay now elects itself with
    /// probability `1 / max(1, connectedPeerCount)` so on average exactly
    /// one device in the cluster bridges. The election is deterministic per
    /// (envelope, device): we hash `clientMessageId + myDeviceId` and bridge
    /// only when the hash falls in the elected slice — predictable and
    /// jitter-free across attempts.
    @discardableResult
    func bridgeMeshMessageToServer(_ envelope: MeshEnvelope) async -> Bool {
        // ── Bridge election ──────────────────────────────────────────────
        let peerCount = await MainActor.run { self.connectedPeers.count }
        let myDevice = DeviceIdentityService.shared.fingerprint ?? ""
        let hashSeed = "\(envelope.clientMessageId)|\(myDevice)"
        var hasher = Hasher()
        hasher.combine(hashSeed)
        let hashSlot = abs(hasher.finalize())
        // Slot count = peerCount + 1 (this device + each connected peer).
        // We bridge if our slot == 0 (deterministic per envelope).
        let slots = max(1, peerCount + 1)
        let elected = (hashSlot % slots) == 0
        if !elected {
            #if DEBUG
            print("  [BRIDGE] 🗳️ Not elected for \(envelope.clientMessageId.prefix(8)) (peers=\(peerCount)) — skipping")
            #endif
            return false
        }
        #if DEBUG
        print("  [BRIDGE] Bridging mesh -> server for recipient: \(envelope.recipientId.prefix(8)) (peers=\(peerCount))")
        #endif


        let relayData = "relay:\(envelope.clientMessageId):\(envelope.senderId):\(envelope.recipientId)".data(using: .utf8) ?? Data()
        let bridgeSig = DeviceIdentityService.shared.sign(relayData)?.base64EncodedString() ?? ""
        let bridgePubKey = DeviceIdentityService.shared.publicKeyBase64 ?? ""

        // Bug 2 fix: Use envelope.isGroup flag for reliable group detection
        // instead of string comparison which misidentifies 1:1 chats as groups
        let isGroupRoom = envelope.isGroup == true

        // 🔐 GROUP-MESH BRIDGE PLAINTEXT FIX
        //
        // For GROUP messages, `envelope.text` is the AES-GCM ciphertext blob
        // (per-group symmetric key, version `envelope.groupKeyVersion`). If we
        // forward that blob as-is to /api/messages/uplink, the server stores
        // ciphertext and EVERY downstream member who fetches via the regular
        // /api/groups/{id}/messages route sees garbage base64 — they never
        // decrypt because the online-fetch code path doesn't run group-key
        // unwrap (only the BLE receive path does).
        //
        // Fix: as a bridge we ARE a group member (we have the key), so decrypt
        // here and send PLAINTEXT to the server. The server's at-rest
        // `encrypt_text` then handles confidentiality on the DB; downstream
        // members get plaintext on fetch like any normal group send.
        var contentForServer = envelope.text ?? ""
        if isGroupRoom, let version = envelope.groupKeyVersion, !contentForServer.isEmpty {
            if let plain = await GroupKeyService.shared.decrypt(
                contentForServer, groupId: envelope.recipientId, version: version
            ) {
                contentForServer = plain
                #if DEBUG
                print("  [BRIDGE] 🔓 Decrypted group cipher (v\(version)) → sending plaintext to server")
                #endif
            } else {
                #if DEBUG
                print("  [BRIDGE] ⚠️ Could not decrypt group cipher (v\(version)) — bridging blob as fallback (recipients may see garbage)")
                #endif
            }
        }

        let request = MeshUplinkRequest(
            recipientId: envelope.recipientId,
            content: contentForServer,
            messageType: MessageType.from(index: envelope.type).rawValue,
            messageId: envelope.clientMessageId,
            bridgedFrom: DeviceIdentityService.shared.fingerprint ?? "unknown",
            originalSenderId: envelope.senderId,
            originalSenderName: envelope.senderName,
            isBridged: true,
            createdAt: PerformanceConstants.iso8601.string(from: Date(timeIntervalSince1970: envelope.timestamp)),
            ttlSeconds: envelope.ttlSeconds,
            hopCount: envelope.hopCount,
            hopLimit: envelope.hopLimit,
            sprayCounter: envelope.sprayCounter,
            bridgeSignature: bridgeSig,
            bridgePublicKey: bridgePubKey,
            roomId: isGroupRoom ? envelope.roomId : nil,
            mediaUrl: envelope.mediaUrl,
            thumbnailUrl: envelope.thumbnailUrl,
            fileName: envelope.fileName,
            mimeType: envelope.mimeType,
            fileSize: envelope.fileSize,
            audioDurationSeconds: envelope.audioDuration,
            replyToMessageId: envelope.replyToMessageId,
            replyToTextPreview: envelope.replyToTextPreview,
            replyToSenderName: envelope.replyToSenderName
        )
        
        var success = false
        do {
            struct EmptyResp: Decodable {}
            let _: EmptyResp = try await NetworkService.shared.post(
                path: "/api/messages/uplink",
                body: request,
                idempotencyKey: envelope.clientMessageId
            )
            success = true
        } catch {
            do {
                struct EmptyResp: Decodable {}
                let _: EmptyResp = try await NetworkService.shared.post(
                    path: "/api/messages/bridge",
                    body: request,
                    idempotencyKey: envelope.clientMessageId
                )
                success = true
            } catch {
                #if DEBUG
                print("  [BRIDGE] Failed to bridge payload to server: \(error)")
                #endif
            }
        }
        
        if success {
            #if DEBUG
            print("  [BRIDGE] Successfully bridged mesh -> server!")
            #endif
            
            let receipt = ServerReceipt(
                messageId: envelope.clientMessageId,
                serverReceivedAt: Date(),
                serverSequence: nil,
                uploaderDeviceId: DeviceIdentityService.shared.fingerprint ?? ""
            )
            await gossipReceipt(receipt)
            
            await RelayQueueRepository.shared.remove(messageId: envelope.clientMessageId)
            await handleStop(envelope.clientMessageId)

            // ⚡ SCALE FIX (#7 server-coordinated dedup):
            // Now that the server has the message, tell every mesh peer to
            // stop relaying it. The signed STOP propagates through the cluster
            // and is honored by the (also-tightened) Stop receive path. This
            // collapses the long tail of stale relays that would otherwise
            // keep bouncing the envelope around for the full TTL window.
            await broadcastStop(envelope.clientMessageId)

            return true
        }
        return false
    }
}

// MARK: - Bridge Downlink Models
// Field names in camelCase because NetworkService decoder uses .convertFromSnakeCase
// Encoder uses .convertToSnakeCase for request body

private struct BridgeDownlinkRequest: Encodable {
    let peerUserIds: [String]
}

private struct BridgeDownlinkResponse: Decodable {
    let messages: [BridgeDownlinkMessage]
    let count: Int
}

private struct BridgeDownlinkMessage: Decodable {
    let id: String
    let senderId: String?
    let recipientId: String?
    let content: String?
    let timestamp: Date?
    let senderUsername: String?
    let senderName: String?
    let messageType: String?
    let roomId: String?
    // Media fields
    let audioUrl: String?
    let mediaUrl: String?
    let thumbnailUrl: String?
    let fileName: String?
    let mimeType: String?
    let fileSize: Int?
    let audioDuration: Int?
    let audioDurationSeconds: Int?
    // Reply fields
    let replyToMessageId: String?
    let replyToTextPreview: String?
    let replyToSenderName: String?
    // Mesh routing overrides from server
    let hopLimit: Int?
    let sprayCounter: Int?
    let ttlSeconds: Int?
    
    /// Convenience: server uses audioDurationSeconds, normalize to single field
    var resolvedAudioDuration: Int? { audioDuration ?? audioDurationSeconds }
}

// MARK: - MessageType Name Helper

extension MessageType {
    static func from(name: String) -> MessageType {
        switch name.lowercased() {
        case "text": return .text
        case "image": return .image
        case "file": return .file
        case "voice": return .voice
        case "location": return .location
        case "poll": return .poll
        case "post_share", "postshare": return .postShare
        case "contact_card", "contactcard": return .contactCard
        case "video": return .video
        case "video_note", "videonote": return .videoNote
        case "ephemeral_photo", "ephemeralphoto": return .ephemeralPhoto
        case "system": return .system
        default: return .text
        }
    }
}


