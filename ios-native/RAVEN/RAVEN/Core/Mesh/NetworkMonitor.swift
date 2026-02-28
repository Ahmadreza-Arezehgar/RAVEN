//
//  NetworkMonitor.swift
//  RAVEN
//
//  DTN Mesh Implementation - Network Connectivity Monitor
//

import Network
import Combine
import Foundation

// MARK: - Notification for Network State Changes
extension Notification.Name {
    static let networkStatusChanged = Notification.Name("networkStatusChanged")
}

// MARK: - API Models for Sync

/// Response from stop-list endpoint
struct StopListResponse: Codable {
    let stopList: [String]
    
    enum CodingKeys: String, CodingKey {
        case stopList = "stop_list"
    }
}

/// Response from cancelled endpoint (new control-plane shape).
struct CancelledMessagesResponse: Codable {
    let cancelled: [String]?
    let messageIds: [String]?
    let stopList: [String]?
    
    enum CodingKeys: String, CodingKey {
        case cancelled
        case messageIds = "message_ids"
        case stopList = "stop_list"
    }
    
    var allMessageIds: [String] {
        if let cancelled, !cancelled.isEmpty { return cancelled }
        if let messageIds, !messageIds.isEmpty { return messageIds }
        return stopList ?? []
    }
}

/// Request to report mesh delivery
struct AckDeliveredRequest: Codable {
    let messageId: String
    let deliveredVia: String
    let pathUsed: String?
    
    init(messageId: String, deliveredVia: String, pathUsed: String? = nil) {
        self.messageId = messageId
        self.deliveredVia = deliveredVia
        self.pathUsed = pathUsed
    }
    
    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case deliveredVia = "delivered_via"
        case pathUsed = "path_used"
    }
}

/// Response from ack-delivered endpoint
/// Note: No CodingKeys needed — NetworkService's decoder uses .convertFromSnakeCase
struct AckDeliveredResponse: Codable {
    let success: Bool
    let messageId: String
    let alreadyDelivered: Bool
    let stopMesh: Bool
}

/// Monitors network connectivity status for Server-first, Mesh-fallback routing
final class NetworkMonitor: ObservableObject, NetworkStatusProviding {
    static let shared = NetworkMonitor()
    private static let cancelledSyncSinceKey = "mesh.cancelled.sync.since"
    
    // MARK: - Published State
    
    @Published private(set) var isOnline: Bool = false
    @Published private(set) var connectionType: ConnectionType = .none
    @Published private(set) var isExpensive: Bool = false
    @Published private(set) var isConstrained: Bool = false
    
    /// Application-layer reachability: true only when we can actually reach our backend.
    /// Unlike `isOnline` (NWPath), this detects captive portals and broken Wi-Fi.
    @Published private(set) var serverReachable: Bool = false
    
    /// True when the network has been flipping between reachable/unreachable recently.
    /// Used by MessageRouter to decide whether to dual-path send.
    @Published private(set) var isNetworkFlaky: Bool = false
    
    /// Unified connectivity state (Spec V1 §2.1)
    /// Collapses isOnline + serverReachable + isNetworkFlaky into one decision input.
    var netState: NetState {
        guard isOnline else { return .offline }
        if serverReachable && !isNetworkFlaky { return .online }
        return .degraded
    }
    
    // MARK: - Connection Type
    
    enum ConnectionType: String {
        case wifi = "WiFi"
        case cellular = "Cellular"
        case wiredEthernet = "Ethernet"
        case loopback = "Loopback"
        case other = "Other"
        case none = "None"
    }
    
    // MARK: - Private
    
    /// Dedicated session for health-check probes — NOT URLSession.shared.
    /// URLSession.shared fails silently on Wi-Fi→Cellular transitions.
    private let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.waitsForConnectivity = true   // FIX: Allow cellular radio to wake up
        return URLSession(configuration: config)
    }()
    
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.raven.networkmonitor", qos: .userInitiated)
    private var isStarted = false
    private var lastControlPlaneSyncAt: Date?
    private let controlPlaneSyncInterval: TimeInterval = 30
    
    // MARK: - Server Probe State
    
    private var probeTimer: Timer?
    private let probeInterval: TimeInterval = 30       // Probe every 30s while NWPath is satisfied
    private let probeTimeout: TimeInterval = 8         // Give up after 8s
    private var recentProbeResults: [Bool] = []        // Rolling window for flaky detection
    private let flakyWindowSize = 6                    // Last 6 probes (~3 minutes)
    private let flakyThreshold = 2                     // ≥2 failures in window → flaky
    private let probeLock = NSLock()                   // Thread-safety for probe results
    
    // MARK: - Init
    
    private init() {}
    
    // MARK: - Public API
    
    func start() {
        guard !isStarted else { return }
        isStarted = true
        
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.updateStatus(from: path)
            }
        }
        monitor.start(queue: queue)
        #if DEBUG
        print("🌐 [NetworkMonitor] Started monitoring")
        #endif
    }
    
    // MARK: - Server Probe
    
    /// Start periodic server probe (called when NWPath becomes satisfied)
    private func startProbeTimer() {
        stopProbeTimer()
        
        // Probe immediately on transition
        Task { await runServerProbe() }
        
        // Then periodically
        probeTimer = Timer.scheduledTimer(withTimeInterval: probeInterval, repeats: true) { [weak self] _ in
            Task { await self?.runServerProbe() }
        }
    }
    
    /// Stop probe timer (called when NWPath goes unsatisfied)
    private func stopProbeTimer() {
        probeTimer?.invalidate()
        probeTimer = nil
    }
    
    /// Lightweight probe to check if our backend is actually reachable.
    /// Detects captive portals, broken Wi-Fi, DNS issues, etc.
    private func runServerProbe() async {
        guard isOnline else {
            updateProbeResult(success: false)
            return
        }
        
        let success = await probeBackend()
        updateProbeResult(success: success)
        
        await MainActor.run {
            let wasReachable = serverReachable
            serverReachable = success
            
            if wasReachable != success {
                if success {
                    #if DEBUG
                    print("✅ [NetworkMonitor] Server probe PASSED — backend reachable")
                    #endif
                } else {
                    #if DEBUG
                    print("⚠️ [NetworkMonitor] Server probe FAILED — NWPath satisfied but backend unreachable")
                    #endif
                }
                NotificationCenter.default.post(name: .networkStatusChanged, object: nil)
            }
        }
    }
    
    /// The actual HTTP probe — lightweight HEAD/GET to our backend.
    private func probeBackend() async -> Bool {
        guard let url = AppConfig.apiURL(path: "/health") else { return false }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = probeTimeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // Don't send auth tokens for health check — keep it lightweight
        
        do {
            // 👇 Use dedicated probeSession (NOT URLSession.shared — it fails on cellular transitions)
            let (_, response) = try await probeSession.data(for: request)
            if let http = response as? HTTPURLResponse {
                // Any 2xx or even 401 means the server is reachable
                let success = http.statusCode < 500
                #if DEBUG
                print("🌐 [NetworkMonitor] Server probe HTTP Status: \(http.statusCode) -> \(success)")
                #endif
                return success
            }
            return false
        } catch {
            let nsError = error as NSError
            #if DEBUG
            print("🔴 [NetworkMonitor] Server probe FAILED: \(error.localizedDescription) (Code: \(nsError.code))")
            #endif
            return false
        }
    }
    
    /// Track probe results for flaky detection
    private func updateProbeResult(success: Bool) {
        probeLock.lock()
        recentProbeResults.append(success)
        if recentProbeResults.count > flakyWindowSize {
            recentProbeResults.removeFirst()
        }
        let failures = recentProbeResults.filter { !$0 }.count
        let successes = recentProbeResults.filter { $0 }.count
        let newFlaky = failures >= flakyThreshold && successes >= 1
        probeLock.unlock()
        
        DispatchQueue.main.async { [weak self] in
            self?.isNetworkFlaky = newFlaky
        }
    }
    
    func stop() {
        guard isStarted else { return }
        monitor.cancel()
        isStarted = false
        #if DEBUG
        print("🌐 [NetworkMonitor] Stopped monitoring")
        #endif
    }
    
    /// Keep control-plane state (CANCEL + pending ACK sync) fresh while online.
    /// This prevents mesh relays from running too long when server delivery wins later.
    func syncControlPlaneIfNeeded(force: Bool = false) async {
        guard isOnline else { return }
        
        let now = Date()
        if !force,
           let last = lastControlPlaneSyncAt,
           now.timeIntervalSince(last) < controlPlaneSyncInterval {
            return
        }
        
        lastControlPlaneSyncAt = now
        await syncStopList()
        await MessageRouter.shared.syncPendingACKs()
        
        // Flush offline read queue
        await PendingReadService.shared.sync()
        
        // Sync mesh view receipts to server
        await MeshViewReceiptService.shared.syncIfOnline()
    }
    
    // MARK: - Private Helpers
    
    private func updateStatus(from path: NWPath) {
        let wasOnline = isOnline
        isOnline = (path.status == .satisfied)
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
        connectionType = determineConnectionType(from: path)
        
        // 🌐 Log full path state (critical for diagnosing IPv6/NAT64 cellular issues)
        #if DEBUG
        print("🌐 [NetworkMonitor] Path Update: status=\(path.status), type=\(connectionType.rawValue), isOnline=\(isOnline), IPv4=\(path.supportsIPv4), IPv6=\(path.supportsIPv6), Expensive=\(isExpensive)")
        #endif
        
        // Log state changes
        if wasOnline != isOnline {
            if isOnline {
                #if DEBUG
                print("✅ [NetworkMonitor] Network is ONLINE via \(connectionType.rawValue)")
                #endif
                
                // Start probing the backend to confirm true reachability
                startProbeTimer()
                
                // Sync control-plane state (CANCEL + pending ACKs) and report mesh deliveries
                // NOTE: Message draining is handled by PendingSyncManager to preserve media & reply data
                Task {
                    await self.syncControlPlaneIfNeeded(force: true)
                    await self.reportMeshDeliveries()
                }
            } else {
                #if DEBUG
                print("❌ [NetworkMonitor] Network is OFFLINE - switching to Mesh mode")
                #endif
                
                // Stop probing and mark server unreachable
                stopProbeTimer()
                serverReachable = false
            }
            // Notify listeners (OutboxManager uses this to sync pending messages)
            NotificationCenter.default.post(name: .networkStatusChanged, object: nil)
        }
    }
    
    
    /// Get stop list from server and apply to mesh
    private func syncStopList() async {
        let since = UserDefaults.standard.string(forKey: Self.cancelledSyncSinceKey)
        let queryItems = since.map { [URLQueryItem(name: "since", value: $0)] }
        
        // Preferred endpoint for CANCEL propagation.
        do {
            let cancelledIds: [String]
            if let structured: CancelledMessagesResponse = try? await NetworkService.shared.get(
                path: "/api/messages/cancelled",
                queryItems: queryItems
            ) {
                cancelledIds = structured.allMessageIds
            } else {
                // Some backends may return a raw string array.
                let raw: [String] = try await NetworkService.shared.get(
                    path: "/api/messages/cancelled",
                    queryItems: queryItems
                )
                cancelledIds = raw
            }
            
            if !cancelledIds.isEmpty {
                await BLEMeshEngine.shared.applyStopList(cancelledIds)
                #if DEBUG
                print("🛑 [Sync] Applied \(cancelledIds.count) cancellations from server")
                #endif
            }
            
            UserDefaults.standard.set(
                PerformanceConstants.iso8601.string(from: Date()),
                forKey: Self.cancelledSyncSinceKey
            )
            return
        } catch {
            // Silent fallback — /cancelled might not exist on older servers
        }
        
        // Backward-compatible fallback.
        do {
            let response: StopListResponse = try await NetworkService.shared.get(path: "/api/messages/stop-list")
            if !response.stopList.isEmpty {
                await BLEMeshEngine.shared.applyStopList(response.stopList)
                #if DEBUG
                print("🛑 [Sync] Applied \(response.stopList.count) stops from fallback endpoint")
                #endif
            }
        } catch {
            // Only log if both endpoints fail — not on normal fallback
            #if DEBUG
            print("⚠️ [Sync] Stop list sync unavailable: \(error.localizedDescription)")
            #endif
        }
    }
    
    /// Report mesh-delivered messages to server
    private func reportMeshDeliveries() async {
        // Get messages delivered via mesh that server doesn't know about
        // These are messages with status=delivered and authority=mesh
        do {
            let deliveredRows = try await MessageRepository.shared.getMeshDelivered()
            
            for row in deliveredRows {
                guard let clientId = row["client_message_id"] as? String else { continue }
                
                // Report to server
                let response: AckDeliveredResponse = try await NetworkService.shared.post(
                    path: "/api/messages/ack-delivered",
                    body: AckDeliveredRequest(
                        messageId: clientId,
                        deliveredVia: "mesh",
                        pathUsed: "mesh"
                    ),
                    idempotencyKey: "ack-\(clientId)"
                )
                
                if response.stopMesh {
                    await BLEMeshEngine.shared.handleStop(clientId)
                }
                
                #if DEBUG
                print("✅ [Sync] Reported mesh delivery: \(clientId.prefix(8))")
                #endif
            }
        } catch {
            #if DEBUG
            print("⚠️ [Sync] Failed to report mesh deliveries: \(error)")
            #endif
        }
    }
    
    
    private func determineConnectionType(from path: NWPath) -> ConnectionType {
        let interfaces = path.availableInterfaces
        
        if interfaces.contains(where: { $0.type == .wifi }) {
            return .wifi
        } else if interfaces.contains(where: { $0.type == .cellular }) {
            return .cellular
        } else if interfaces.contains(where: { $0.type == .wiredEthernet }) {
            return .wiredEthernet
        } else if interfaces.contains(where: { $0.type == .loopback }) {
            return .loopback
        } else if interfaces.contains(where: { $0.type == .other }) {
            return .other
        }
        
        return .none
    }
}
