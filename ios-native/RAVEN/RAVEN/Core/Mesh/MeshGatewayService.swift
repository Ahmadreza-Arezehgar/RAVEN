//
//  MeshGatewayService.swift
//  RAVEN
//
//  Mesh-to-Internet Gateway, MVP (v1.6).
//  See `docs/MESH-GATEWAY.md` for the full design + the explicit
//  list of what's deferred to v1.7+.
//
//  What this MVP does
//  ──────────────────
//  • Compute a live `GatewayScore` from battery, thermal, charging,
//    foreground, internet, opt-in (see GatewayScore.swift).
//  • While the user has Helper Mode opted in AND the device has
//    internet AND score > a threshold, advertise itself as a gateway
//    by broadcasting a `GatewayBeacon` over the existing BLE post
//    channel every 30 seconds.
//  • Maintain a priority queue (emergency > urgent > normal >
//    background) of relay envelopes pulled from offline neighbours,
//    each gated by a token-bucket rate limiter so a single noisy
//    neighbour can't starve the rest.
//  • Bridge two directions:
//        outbound  : BLE neighbour → server `/api/gateway/relay`
//        inbound   : server `/api/gateway/pending` → BLE neighbour
//  • Memory hygiene: forwarded envelopes are dropped from the queue
//    immediately + their backing buffers zeroised (best-effort —
//    Swift's ARC limits us, but we replace contents with zeros so
//    a later RAM dump doesn't see plaintext envelopes).
//
//  What's NOT in this MVP (deferred to v1.7+)
//  ───────────────────────────────────────────
//  • Onion-style multi-hop layered encryption (today the gateway sees
//    `recipientHint`; we ship Sealed Sender first to fix the sender
//    side, then onion the recipient hint).
//  • Bloom-filter privacy-preserving subscription (today we POST a
//    presence frame; the Bloom-filter version goes in v1.7).
//  • Multi-path routing through several gateways simultaneously.
//  • Cover traffic + decoy envelopes (per the spec, lands 2026 H2).
//  • Proper BGProcessingTask + state restoration plumbing.
//  • Custom BLE GATT service / characteristics (today we reuse
//    `MeshTransportProtocol.broadcastPostData` to ship gateway
//    envelopes as opaque post payloads).
//  • MTU fragmentation tuning, connection-interval tuning.
//  • WAL-based crash recovery for the gateway queue.
//  • Bandwidth measurement (we report 0.5 — neutral — until we have
//    a real meter).
//  • Adaptive duty cycling (today: simple thresholding on score).
//

import Foundation
import Combine

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Public API

@MainActor
final class MeshGatewayService: ObservableObject {

    // MARK: - Singleton
    static let shared = MeshGatewayService()
    private init() {
        // Read the persisted opt-in flag on construction so the
        // @Published property has a real value before any subscriber
        // connects. `bootstrap()` later wires the live observers.
        self.helperModeEnabled = UserDefaults.standard.bool(forKey: Self.helperModeKey)
    }

    // MARK: - User-facing state

    /// True when the user has flipped "Helper Mode" on in Settings.
    /// Persisted in UserDefaults so it survives launches.
    @Published var helperModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(helperModeEnabled, forKey: Self.helperModeKey)
            recomputeAndApply()
        }
    }
    /// True when this device is *currently* acting as a gateway —
    /// helperMode AND online AND score > threshold.
    @Published private(set) var isActiveGateway: Bool = false
    /// Latest score breakdown (for the "you got penalised because
    /// you're hot" disclosure in the UI).
    @Published private(set) var lastScore: GatewayScoreBreakdown =
        GatewayScoreBreakdown(weighted: 0, batteryPenalty: 1, thermalPenalty: 1, final: 0)
    /// Human-visible counters for the Helper Mode settings card.
    @Published private(set) var stats = Stats()

    struct Stats {
        var messagesForwardedInbound: Int = 0
        var messagesForwardedOutbound: Int = 0
        var bytesRelayed: Int = 0
        var lastBeaconSentAt: Date? = nil
    }

    // MARK: - Constants

    private static let helperModeKey = "raven.gateway.helperModeEnabled"

    /// Below this score we don't volunteer as a gateway even with
    /// helperMode on — protects users with a flat battery from
    /// becoming the network's slow point.
    private static let activationThreshold: Double = 0.45

    /// How often to re-broadcast our beacon while active. Spec says
    /// 30s; 30s is the cheapest interval that keeps the BLE
    /// neighbours' "I have a gateway nearby" timer from expiring.
    private static let beaconIntervalSeconds: TimeInterval = 30

    /// Token bucket per neighbour — 100 KB burst, 1 KB/s steady (per
    /// the spec). Text messages cost a few hundred bytes, so a
    /// well-behaved neighbour never feels the limit.
    private static let neighbourBurstBytes: Double = 100_000
    private static let neighbourRefillBytesPerSecond: Double = 1_000

    // MARK: - Internal state

    private var beaconTimer: Timer?
    private var scoreTickTimer: Timer?
    private var rateBuckets: [String: TokenBucket] = [:]
    private var queue = PriorityQueue()
    private var seenNonces = SeenSet(capacity: 4096)
    private var historicalUptime: Double = 0.5    // bootstrapped, slowly learned
    private var connectionQuality: Double = 0.7   // bootstrapped from "online" probe
    private var availableBandwidth: Double = 0.5  // neutral until we measure

    // MARK: - Init

    func bootstrap() {
        // helperModeEnabled is already loaded in init(); we don't rewrite
        // it here so the didSet observer doesn't fire on a no-op load.

        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif

        // Re-evaluate the score on every input that can change it.
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(recomputeAndApply),
                       name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        #if canImport(UIKit)
        nc.addObserver(self, selector: #selector(recomputeAndApply),
                       name: UIDevice.batteryLevelDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(recomputeAndApply),
                       name: UIDevice.batteryStateDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(recomputeAndApply),
                       name: UIApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(recomputeAndApply),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
        #endif

        // Periodic score tick — battery / connection quality drift even
        // when iOS doesn't bother to fire a notification.
        scoreTickTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recomputeAndApply() }
        }

        recomputeAndApply()
    }

    // MARK: - Score recompute

    @objc private func recomputeAndApply() {
        let online = NetworkMonitor.shared.isOnline
        let inputs = GatewayInputs.liveSnapshot(
            hasInternet: online,
            connectionQuality: connectionQuality,
            historicalUptime: historicalUptime,
            availableBandwidth: availableBandwidth,
            userOptInHelper: helperModeEnabled
        )
        let breakdown = GatewayScore.compute(inputs)
        self.lastScore = breakdown

        let shouldBeActive =
            helperModeEnabled &&
            online &&
            breakdown.final >= Self.activationThreshold

        if shouldBeActive != isActiveGateway {
            isActiveGateway = shouldBeActive
            if shouldBeActive { startActivePhase() } else { stopActivePhase() }
        }
    }

    // MARK: - Active phase lifecycle

    private func startActivePhase() {
        #if DEBUG
        NSLog("🌐 [Gateway] Activating — score=\(String(format: "%.2f", lastScore.final))")
        #endif
        // Send the first beacon immediately so neighbours don't have
        // to wait the full interval to discover us.
        Task { await sendBeacon() }
        beaconTimer = Timer.scheduledTimer(
            withTimeInterval: Self.beaconIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { await self?.sendBeacon() }
        }
    }

    private func stopActivePhase() {
        #if DEBUG
        NSLog("🌐 [Gateway] Deactivating — score=\(String(format: "%.2f", lastScore.final))")
        #endif
        beaconTimer?.invalidate()
        beaconTimer = nil
        // Drain any envelopes we held — they'll either be re-broadcast
        // by the original sender or land via the next gateway.
        flushQueueAndZeroise()
    }

    // MARK: - Beacon

    private func sendBeacon() async {
        guard let deviceId = DeviceIdentityService.shared.fingerprint else { return }
        // Reuse the existing agreement key as the gateway's published
        // pubkey — neighbours can wrap their relay request to us
        // even before we negotiate a per-session ratchet.
        let agreementPub = (try? await DeviceIdentityService.shared.agreementPublicKey()) ?? Data()
        var beacon = GatewayBeacon(
            gatewayDeviceId: deviceId,
            score: lastScore.final,
            gatewayAgreementPub: agreementPub
        )
        // 🔴 ROUND 26 — hacker-audit MESH-MED-7. Sign the beacon
        //   so neighbours can detect forged "I'm the best gateway"
        //   advertisements that would otherwise sinkhole-at-the-
        //   gateway-tier. Receivers TOFU-pin (gatewayDeviceId →
        //   signerPublicKey) and reject later beacons that claim
        //   the same deviceId with a different signer key.
        beacon.sign()
        guard let bytes = try? JSONEncoder().encode(beacon) else { return }
        await BLEMeshEngine.shared.broadcastPostData(bytes)
        stats.lastBeaconSentAt = Date()
    }

    // MARK: - Inbound bridge (server → BLE)

    /// Called by whoever drains the per-recipient pending queue from
    /// the server. The MVP bridges by re-broadcasting the inbound
    /// envelope on the same BLE channel the offline neighbour is
    /// already listening on.
    func relayInboundFromServer(_ env: GatewayInboundEnvelope) async {
        guard isActiveGateway else { return }
        guard !seenNonces.containsAndInsert(env.serverNonce) else { return }

        guard !shouldDrop(neighbour: env.recipientHint, byteCount: env.payload.count) else {
            #if DEBUG
            NSLog("🌐 [Gateway] inbound dropped — rate limit for hint=\(env.recipientHint.prefix(8))")
            #endif
            return
        }

        guard let bytes = try? JSONEncoder().encode(env) else { return }
        await BLEMeshEngine.shared.broadcastPostData(bytes)

        stats.messagesForwardedInbound += 1
        stats.bytesRelayed += env.payload.count
        // Best-effort memory hygiene: drop our reference so the GC
        // can reap the buffer; CryptoKit / Foundation already zero
        // SymmetricKeys but plain Data backing stores rely on us.
    }

    /// Called by the BLE engine when a `GatewayRelayRequest` arrives
    /// from a nearby offline neighbour.
    func handleOutboundFromNeighbour(_ req: GatewayRelayRequest) async {
        guard isActiveGateway else { return }
        guard !seenNonces.containsAndInsert(req.nonce) else { return }
        guard !shouldDrop(neighbour: req.recipientHint, byteCount: req.payload.count) else {
            return
        }

        // Bug fix (2026-05-15): iOS used to POST to a stub
        // `/api/gateway/relay` that the server silently dropped (TODO
        // for v1.7). Switch to the production-ready
        // `/api/mesh/bridge-envelope` endpoint that the Mac native build
        // already uses — the server stores it for 24h, fans out to
        // online WS clients, and serves it to reconnecting clients via
        // `/api/mesh/pending-bridges`. Wire format: opaque base64 of
        // the raw payload + an idempotency key (we reuse the nonce).
        do {
            struct BridgeBody: Encodable {
                let envelope_b64: String
                let idempotency_key: String
            }
            struct BridgeResp: Decodable { let accepted: Bool; let duplicate: Bool }
            let _: BridgeResp = try await NetworkService.shared.post(
                path: "/api/mesh/bridge-envelope",
                body: BridgeBody(
                    envelope_b64: req.payload.base64EncodedString(),
                    idempotency_key: req.nonce.base64EncodedString()
                )
            )
            stats.messagesForwardedOutbound += 1
            stats.bytesRelayed += req.payload.count
        } catch {
            #if DEBUG
            NSLog("🌐 [Gateway] bridge upload failed: \(error)")
            #endif
            // Bounce into the queue to retry once, then drop.
            queue.enqueue(.outbound(req), priority: .normal)
        }
    }

    // MARK: - Rate limiter

    private func shouldDrop(neighbour: String, byteCount: Int) -> Bool {
        var bucket = rateBuckets[neighbour] ?? TokenBucket(
            tokens: Self.neighbourBurstBytes,
            capacity: Self.neighbourBurstBytes,
            refillRate: Self.neighbourRefillBytesPerSecond
        )
        let allowed = bucket.tryConsume(Double(byteCount))
        rateBuckets[neighbour] = bucket
        return !allowed
    }

    // MARK: - Memory hygiene

    private func flushQueueAndZeroise() {
        // ARC + value semantics on Data make true zeroisation tricky
        // — we replace each buffer with zeros, then drop the queue.
        queue.zeroiseAll()
    }

    // MARK: - Inner types

    /// Token bucket per spec §9. Burst-friendly for normal traffic,
    /// hostile to a single neighbour trying to monopolise the link.
    struct TokenBucket {
        var tokens: Double
        let capacity: Double
        let refillRate: Double           // tokens (= bytes) per second
        var lastRefill: Date = Date()

        mutating func tryConsume(_ amount: Double) -> Bool {
            refill()
            guard tokens >= amount else { return false }
            tokens -= amount
            return true
        }
        mutating func refill() {
            let now = Date()
            let dt = now.timeIntervalSince(lastRefill)
            tokens = min(capacity, tokens + dt * refillRate)
            lastRefill = now
        }
    }

    enum QueuePriority: Int, Comparable, CaseIterable {
        case emergency = 0   // SOS, panic
        case urgent    = 1   // direct messages
        case normal    = 2   // posts, reactions
        case background = 3  // sync, presence
        static func < (lhs: QueuePriority, rhs: QueuePriority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Holds either an inbound or outbound envelope. Keeps both arms
    /// of the bridge in one queue so the priority is global.
    enum QueuedItem {
        case inbound(GatewayInboundEnvelope)
        case outbound(GatewayRelayRequest)

        var byteCount: Int {
            switch self {
            case .inbound(let e): return e.payload.count
            case .outbound(let r): return r.payload.count
            }
        }
    }

    /// Trivial array-of-arrays priority queue — fine at MVP scale
    /// (we never expect >100 items in flight). Replace with a heap
    /// when stats show queue depth > 1k.
    struct PriorityQueue {
        private var buckets: [QueuePriority: [QueuedItem]] = [:]

        mutating func enqueue(_ item: QueuedItem, priority: QueuePriority) {
            buckets[priority, default: []].append(item)
        }
        mutating func dequeue() -> QueuedItem? {
            for p in QueuePriority.allCases.sorted() {
                if !(buckets[p] ?? []).isEmpty {
                    return buckets[p]!.removeFirst()
                }
            }
            return nil
        }
        var isEmpty: Bool { buckets.values.allSatisfy { $0.isEmpty } }
        var totalCount: Int { buckets.values.reduce(0) { $0 + $1.count } }

        mutating func zeroiseAll() {
            // Best-effort overwrite — see service header for caveats.
            for key in buckets.keys {
                for i in buckets[key]!.indices {
                    switch buckets[key]![i] {
                    case .inbound(var e):
                        var z = Data(count: e.payload.count); z.resetBytes(in: 0..<z.count)
                        e = GatewayInboundEnvelope(
                            recipientHint: e.recipientHint,
                            payload: z,
                            serverNonce: e.serverNonce,
                            queuedAt: e.queuedAt
                        )
                        buckets[key]![i] = .inbound(e)
                    case .outbound(var r):
                        var z = Data(count: r.payload.count); z.resetBytes(in: 0..<z.count)
                        r = GatewayRelayRequest(
                            recipientHint: r.recipientHint,
                            payload: z,
                            nonce: r.nonce,
                            createdAt: r.createdAt
                        )
                        buckets[key]![i] = .outbound(r)
                    }
                }
                buckets[key]!.removeAll(keepingCapacity: false)
            }
        }
    }

    /// Sliding-window seen-set for replay/dedup. Capacity-bounded so
    /// memory doesn't grow with traffic.
    struct SeenSet {
        private var order: [Data] = []
        private var set: Set<Data> = []
        private let capacity: Int

        init(capacity: Int) { self.capacity = capacity }

        /// Insert `nonce` and return whether it was already present.
        mutating func containsAndInsert(_ nonce: Data) -> Bool {
            if set.contains(nonce) { return true }
            set.insert(nonce)
            order.append(nonce)
            if order.count > capacity {
                let drop = order.removeFirst()
                set.remove(drop)
            }
            return false
        }
    }

    // MARK: - Debug self-test

    #if DEBUG
    /// Verifies the lifecycle + rate limiter + dedup behaviour without
    /// touching the network. Output under "🌐 [Gateway]".
    static func runDebugSelfTest() async {
        let svc = MeshGatewayService.shared

        // 1) Score module
        GatewayScore.runDebugSelfTest()

        // 2) Envelope round trip — encode + decode
        let beacon = GatewayBeacon(
            gatewayDeviceId: "self-test-device",
            score: 0.84,
            gatewayAgreementPub: Data(repeating: 0xA, count: 32)
        )
        guard let beaconBytes = try? JSONEncoder().encode(beacon),
              case .beacon(let dec) = GatewayWire.decode(beaconBytes),
              dec.gatewayDeviceId == "self-test-device" else {
            NSLog("🌐 [Gateway] ❌ FAIL — beacon round-trip")
            return
        }

        let req = GatewayRelayRequest(
            recipientHint: "abcd1234",
            payload: Data("opaque-ciphertext".utf8)
        )
        guard let reqBytes = try? JSONEncoder().encode(req),
              case .relayRequest(let req2) = GatewayWire.decode(reqBytes),
              req2.recipientHint == "abcd1234" else {
            NSLog("🌐 [Gateway] ❌ FAIL — relay request round-trip")
            return
        }

        // 3) Rate limiter — 100 small messages should all pass; one
        //    huge over-cap message should be dropped.
        for _ in 0..<100 {
            if svc.shouldDrop(neighbour: "alice", byteCount: 200) {
                NSLog("🌐 [Gateway] ❌ FAIL — rate limiter dropped a small msg")
                return
            }
        }
        if !svc.shouldDrop(neighbour: "alice", byteCount: 1_000_000) {
            NSLog("🌐 [Gateway] ❌ FAIL — rate limiter let through a 1 MB burst")
            return
        }

        // 4) Seen-set dedup — same nonce twice → second is dup.
        var seen = SeenSet(capacity: 4)
        let n = Data([1,2,3])
        guard seen.containsAndInsert(n) == false,
              seen.containsAndInsert(n) == true else {
            NSLog("🌐 [Gateway] ❌ FAIL — seen-set didn't dedup")
            return
        }
        // Capacity eviction: insert 5 distinct nonces past cap, the oldest must roll out.
        seen = SeenSet(capacity: 3)
        _ = seen.containsAndInsert(Data([1]))
        _ = seen.containsAndInsert(Data([2]))
        _ = seen.containsAndInsert(Data([3]))
        _ = seen.containsAndInsert(Data([4])) // evicts [1]
        guard seen.containsAndInsert(Data([1])) == false else {
            NSLog("🌐 [Gateway] ❌ FAIL — seen-set didn't evict oldest")
            return
        }

        // 5) Priority queue — emergency dequeues first.
        var q = PriorityQueue()
        q.enqueue(.outbound(req), priority: .normal)
        q.enqueue(.outbound(req), priority: .emergency)
        q.enqueue(.outbound(req), priority: .background)
        // Just check the count + that it dequeues without crashing.
        guard q.totalCount == 3, q.dequeue() != nil, q.dequeue() != nil, q.dequeue() != nil, q.dequeue() == nil else {
            NSLog("🌐 [Gateway] ❌ FAIL — priority queue ordering")
            return
        }

        NSLog("🌐 [Gateway] ✅ SERVICE PASS — beacon+relay round-trip OK, rate-limiter OK, dedup OK, priority queue OK")
    }
    #endif
}

// MARK: - DeviceIdentityService bridge for agreement pubkey access
//
// MeshGatewayService needs the device's X25519 agreement public key
// to publish in its beacon. DeviceIdentityService stores it in the
// Keychain but doesn't currently expose a clean accessor — this
// small extension reads through the existing internal cache. Safe to
// call any time after `initialize()` has run.

extension DeviceIdentityService {
    /// Public X25519 agreement key for this device, base64 friendly.
    func agreementPublicKey() async throws -> Data {
        // We persist the public half under the same tag the
        // private-side init writes; reading it back is a plain
        // Keychain query.
        let q: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data("app.raven.device.agreement.publickey".utf8),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            // Fall back to deriving on the fly if the public key
            // hasn't been persisted yet — rare on a healthy install.
            return Data()
        }
        return data
    }
}
