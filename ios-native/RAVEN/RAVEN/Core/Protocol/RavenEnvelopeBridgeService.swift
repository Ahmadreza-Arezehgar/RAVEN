//
//  RavenEnvelopeBridgeService.swift
//  RAVEN — flagged Bridge V1 observer: opaque RVN1 cross-transport forward.
//
//  When FeatureFlag.ravenEnvelopeV1 is ON:
//    • BLE inbound packed RVN1 → optional LAN forward (phone as B)
//    • LAN inbound packed RVN1 → BLE forward when mesh peers reachable (reverse)
//    • Recipient ACK reverse: BLE↔LAN without decrypting content
//    • Local destination → RavenEnvelopeEndpointIngest (not bridge)
//    • Never decrypts sealed content (BridgeSubsystem separate from endpoint)
//  When flag OFF: no-op; MeshEnvelope path unchanged.
//

import Foundation
import CryptoKit
import Network

@MainActor
public final class RavenEnvelopeBridgeService {
    public static let shared = RavenEnvelopeBridgeService()

    private var bleObserver: NSObjectProtocol?
    private var lanObserver: NSObjectProtocol?
    private var seen = Set<Data>()
    private let maxSeen = 2048

    /// Per opaque peer key: enqueue timestamps (ms) inside the rate window.
    private var peerEnqueueMs: [String: [UInt64]] = [:]
    private let maxPerPeerPerWindow = 30
    private let rateWindowMs: UInt64 = 60_000

    private var listener: NWListener?
    private var listenPort: UInt16 = 0
    private var pullTask: Task<Void, Never>?

    /// Legacy role preference retained for source compatibility. It is not a
    /// per-envelope destination proof and is intentionally ignored until RVN1
    /// routing-tag/session matching is implemented.
    public var localIsDestination: Bool = false

    private init() {}

    public func start() {
        guard FeatureFlag.isRavenEnvelopeV1Enabled else {
            stop()
            return
        }
        if bleObserver == nil {
            bleObserver = NotificationCenter.default.addObserver(
                forName: .ravenEnvelopeV1BleReceived,
                object: nil,
                queue: .main
            ) { [weak self] note in
                Task { @MainActor in
                    await self?.onBleRvn1(note)
                }
            }
        }
        if lanObserver == nil {
            lanObserver = NotificationCenter.default.addObserver(
                forName: .ravenEnvelopeV1LanReceived,
                object: nil,
                queue: .main
            ) { [weak self] note in
                Task { @MainActor in
                    await self?.onLanRvn1(note)
                }
            }
        }
        // Phone listens so Mac can dial (fallback when Pull never connects).
        let listen = RavenServerlessLanConfig.stored?.listenPort ?? 0
        let port = listen > 0 ? listen : 7421
        startLanListener(port: port)
        startMacQueuePullLoop()
        #if DEBUG
        print("🕊️ [Bridge] RavenEnvelopeBridgeService listening :\(port) (flag ON; unmatched envelopes relay/drop)")
        #endif
    }

    public func stop() {
        pullTask?.cancel()
        pullTask = nil
        if let bleObserver {
            NotificationCenter.default.removeObserver(bleObserver)
            self.bleObserver = nil
        }
        if let lanObserver {
            NotificationCenter.default.removeObserver(lanObserver)
            self.lanObserver = nil
        }
        stopLanListener()
    }

    /// Mac-listens path: periodically connect so raven-node can flush queued Mac→phone envelopes.
    private func startMacQueuePullLoop() {
        pullTask?.cancel()
        pullTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pullOnceFromMac()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    /// Manual / settings-triggered pull of Mac local-listen queue.
    @discardableResult
    public func pullMacQueueNow() async -> Int {
        await pullOnceFromMac()
    }

    @discardableResult
    private func pullOnceFromMac() async -> Int {
        guard FeatureFlag.isRavenEnvelopeV1Enabled,
              let lan = RavenServerlessLanConfig.stored else { return 0 }
        let packs = await RavenServerlessLanPath.pullEnvelopes(
            host: lan.host,
            port: lan.port,
            durationSeconds: 3
        )
        var n = 0
        for packed in packs {
            guard RavenEnvelopeV1.unpack(packed) != nil else { continue }
            // Mac local-listen queue is addressed to this phone — deliver to
            // endpoint (PairInit OOB / sealed message / ACK), never steal as bridge.
            await MainActor.run {
                RavenEnvelopeEndpointIngest.publishPacked(
                    packed: packed,
                    peerKey: "lan-mac-pull"
                )
            }
            n += 1
        }
        return n
    }

    // MARK: - Pure decision (unit-testable)

    public enum BridgeForwardDecision: Equatable, Sendable {
        case forward
        case dropExpired
        case dropHop
        case dropDuplicate
        case dropRateLimited
        case dropNoEgress
        case dropMalformed
        case flagOff
        case deliverToEndpoint
        case ackRelayed
    }

    /// Opaque hop/TTL/dedup/rate decision for cross-transport forward.
    nonisolated public static func decideForward(
        packed: Data,
        messageId: Data,
        expiresAtMs: UInt64,
        hopLimit: UInt8,
        replicationBudget: UInt8,
        alreadySeen: Bool,
        egressReady: Bool,
        peerKey: String,
        peerHitsInWindow: Int,
        maxPerPeer: Int,
        nowMs: UInt64,
        flagOn: Bool
    ) -> BridgeForwardDecision {
        guard flagOn else { return .flagOff }
        guard RavenBleRvn1Carrier.looksLikeRavenEnvelopeV1(packed) else { return .dropMalformed }
        guard messageId.count == 16 else { return .dropMalformed }
        if alreadySeen { return .dropDuplicate }
        if nowMs > expiresAtMs { return .dropExpired }
        if hopLimit == 0 || replicationBudget == 0 { return .dropHop }
        if peerHitsInWindow >= maxPerPeer { return .dropRateLimited }
        if !egressReady { return .dropNoEgress }
        return .forward
    }

    /// Destination is a per-envelope cryptographic fact, not a global device
    /// role. An unmatched envelope may be relayed when an egress exists; without
    /// an egress it must be dropped rather than handed to the endpoint.
    nonisolated static func classifyMessageRoute(
        localRouteMatched: Bool,
        bridgeEnabled: Bool
    ) -> RavenEnvelopeEndpointIngest.RoleDisposition {
        if localRouteMatched { return .deliverToEndpoint }
        if bridgeEnabled { return .bridgeForward }
        return .drop
    }

    // MARK: - BLE inbound (Message / ACK)

    private func onBleRvn1(_ note: Notification) async {
        guard FeatureFlag.isRavenEnvelopeV1Enabled else { return }
        guard let packed = note.userInfo?["packed"] as? Data,
              RavenBleRvn1Carrier.looksLikeRavenEnvelopeV1(packed),
              let env = RavenEnvelopeV1.unpack(packed) else {
            #if DEBUG
            print("🕊️ [Bridge] BLE RVN1 notice without packed bytes — skip")
            #endif
            return
        }
        let peerKey = (note.userInfo?["peerDeviceId"] as? String) ?? "ble-unknown"

        if env.envType == RavenEnvelopeV1.EnvType.ack.rawValue {
            await relayAckFromBle(packed: packed, env: env)
            return
        }
        guard env.envType == RavenEnvelopeV1.EnvType.message.rawValue else { return }

        // No production RVN1 routing-tag/session matcher exists yet. A global
        // `localIsDestination` preference, sender signature, or pair key alone
        // does not prove this envelope targets this device, so fail closed.
        let role = Self.classifyMessageRoute(
            localRouteMatched: false,
            bridgeEnabled: RavenServerlessLanConfig.stored != nil
        )
        if role == .deliverToEndpoint {
            RavenEnvelopeEndpointIngest.publishPacked(packed: packed, peerKey: peerKey)
            return
        }

        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let hits = peerHits(peerKey: peerKey, nowMs: nowMs)
        let mid = env.messageId
        let objectDigest = env.relayObjectDigest()
        let decision = Self.decideForward(
            packed: packed,
            messageId: mid,
            expiresAtMs: env.expiresAtMs,
            hopLimit: env.hopLimit,
            replicationBudget: env.replicationBudget,
            alreadySeen: seen.contains(objectDigest),
            egressReady: RavenServerlessLanConfig.stored != nil,
            peerKey: peerKey,
            peerHitsInWindow: hits,
            maxPerPeer: maxPerPeerPerWindow,
            nowMs: nowMs,
            flagOn: true
        )
        guard decision == .forward else {
            #if DEBUG
            print("🕊️ [Bridge] BLE→LAN skip \(decision)")
            #endif
            return
        }
        recordSeen(objectDigest)
        recordPeerHit(peerKey: peerKey, nowMs: nowMs)

        var fwd = env
        fwd.hopLimit &-= 1
        fwd.replicationBudget &-= 1

        guard let lan = RavenServerlessLanConfig.stored else { return }
        do {
            try await RavenServerlessLanPath.sendPackedFireAndForget(
                fwd.pack(),
                host: lan.host,
                port: lan.port
            )
            #if DEBUG
            print("🕊️ [Bridge] BLE→LAN forward mid=\(mid.prefix(4).map { String(format: "%02x", $0) }.joined()) opaque")
            #endif
        } catch {
            #if DEBUG
            print("🕊️ [Bridge] BLE→LAN forward failed: \(error)")
            #endif
        }
    }

    /// Recipient ACK on BLE → opaque LAN relay. The bridge never opens the ACK
    /// body, correlates it with an outbound message, or marks delivery.
    @discardableResult
    public func relayAckFromBle(packed: Data, env: RavenEnvelopeV1? = nil) async -> BridgeForwardDecision {
        guard FeatureFlag.isRavenEnvelopeV1Enabled else { return .flagOff }
        let env = env ?? RavenEnvelopeV1.unpack(packed)
        guard let env, env.envType == RavenEnvelopeV1.EnvType.ack.rawValue else {
            return .dropMalformed
        }
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let peerKey = "ble-ack"
        let objectDigest = env.relayObjectDigest()
        let decision = Self.decideForward(
            packed: packed,
            messageId: env.messageId,
            expiresAtMs: env.expiresAtMs,
            hopLimit: env.hopLimit,
            replicationBudget: env.replicationBudget,
            alreadySeen: seen.contains(objectDigest),
            egressReady: RavenServerlessLanConfig.stored != nil,
            peerKey: peerKey,
            peerHitsInWindow: peerHits(peerKey: peerKey, nowMs: nowMs),
            maxPerPeer: maxPerPeerPerWindow,
            nowMs: nowMs,
            flagOn: true
        )
        guard decision == .forward, let lan = RavenServerlessLanConfig.stored else {
            return decision
        }

        recordSeen(objectDigest)
        recordPeerHit(peerKey: peerKey, nowMs: nowMs)
        var forwarded = env
        forwarded.hopLimit &-= 1
        forwarded.replicationBudget &-= 1
        do {
            try await RavenServerlessLanPath.sendPackedFireAndForget(
                forwarded.pack(),
                host: lan.host,
                port: lan.port
            )
            return .ackRelayed
        } catch {
            #if DEBUG
            print("🕊️ [Bridge] opaque ACK LAN uplink failed: \(error)")
            #endif
            return .dropNoEgress
        }
    }

    // MARK: - LAN → BLE (reverse)

    private func onLanRvn1(_ note: Notification) async {
        guard FeatureFlag.isRavenEnvelopeV1Enabled else { return }
        guard let packed = note.userInfo?["packed"] as? Data else { return }
        let peerKey = (note.userInfo?["peerKey"] as? String) ?? "lan-unknown"
        let conn = note.userInfo?["connection"] as? NWConnection
        _ = await forwardLanToBle(packed: packed, peerKey: peerKey)
        conn?.cancel()
    }

    /// Public entry for tests / LAN listener: opaque LAN→BLE when peers reachable.
    @discardableResult
    public func forwardLanToBle(
        packed: Data,
        peerKey: String
    ) async -> BridgeForwardDecision {
        guard FeatureFlag.isRavenEnvelopeV1Enabled else { return .flagOff }
        guard let env = RavenEnvelopeV1.unpack(packed) else { return .dropMalformed }

        if env.envType == RavenEnvelopeV1.EnvType.ack.rawValue {
            return await forwardAckLanToBle(packed: packed, env: env, peerKey: peerKey)
        }
        guard env.envType == RavenEnvelopeV1.EnvType.message.rawValue else {
            return .dropMalformed
        }

        let role = Self.classifyMessageRoute(
            localRouteMatched: false,
            bridgeEnabled: true
        )
        if role == .deliverToEndpoint {
            RavenEnvelopeEndpointIngest.publishPacked(packed: packed, peerKey: peerKey)
            return .deliverToEndpoint
        }

        let bleReady = BLEMeshEngine.shared.hasActiveConnections
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let hits = peerHits(peerKey: peerKey, nowMs: nowMs)
        let mid = env.messageId
        let objectDigest = env.relayObjectDigest()
        let decision = Self.decideForward(
            packed: packed,
            messageId: mid,
            expiresAtMs: env.expiresAtMs,
            hopLimit: env.hopLimit,
            replicationBudget: env.replicationBudget,
            alreadySeen: seen.contains(objectDigest),
            egressReady: bleReady,
            peerKey: peerKey,
            peerHitsInWindow: hits,
            maxPerPeer: maxPerPeerPerWindow,
            nowMs: nowMs,
            flagOn: true
        )
        guard decision == .forward else {
            #if DEBUG
            print("🕊️ [Bridge] LAN→BLE skip \(decision)")
            #endif
            return decision
        }
        recordSeen(objectDigest)
        recordPeerHit(peerKey: peerKey, nowMs: nowMs)

        var fwd = env
        fwd.hopLimit &-= 1
        fwd.replicationBudget &-= 1
        let out = fwd.pack()
        await BLEMeshEngine.shared.enqueueRawRavenEnvelopeV1(out)
        #if DEBUG
        print("🕊️ [Bridge] LAN→BLE forward mid=\(mid.prefix(4).map { String(format: "%02x", $0) }.joined()) opaque")
        #endif
        return .forward
    }

    private func forwardAckLanToBle(
        packed: Data,
        env: RavenEnvelopeV1,
        peerKey: String
    ) async -> BridgeForwardDecision {
        let bleReady = BLEMeshEngine.shared.hasActiveConnections
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let objectDigest = env.relayObjectDigest()
        let decision = Self.decideForward(
            packed: packed,
            messageId: env.messageId,
            expiresAtMs: env.expiresAtMs,
            hopLimit: env.hopLimit,
            replicationBudget: env.replicationBudget,
            alreadySeen: seen.contains(objectDigest),
            egressReady: bleReady,
            peerKey: peerKey,
            peerHitsInWindow: peerHits(peerKey: peerKey, nowMs: nowMs),
            maxPerPeer: maxPerPeerPerWindow,
            nowMs: nowMs,
            flagOn: true
        )
        guard decision == .forward else { return decision }
        recordSeen(objectDigest)
        recordPeerHit(peerKey: peerKey, nowMs: nowMs)
        var fwd = env
        fwd.hopLimit &-= 1
        fwd.replicationBudget &-= 1
        await BLEMeshEngine.shared.enqueueRawRavenEnvelopeV1(fwd.pack())
        #if DEBUG
        print("🕊️ [Bridge] opaque ACK LAN→BLE peer=\(peerKey)")
        #endif
        return .ackRelayed
    }

    // MARK: - Thin LAN listener (optional)

    private func startLanListener(port: UInt16) {
        if listener != nil, listenPort == port { return }
        stopLanListener()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        do {
            let lw = try NWListener(using: .tcp, on: nwPort)
            listenPort = port
            lw.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in
                    self?.handleLanConnection(conn)
                }
            }
            lw.stateUpdateHandler = { state in
                #if DEBUG
                if case .failed(let err) = state {
                    print("🕊️ [Bridge] LAN listen failed: \(err)")
                }
                #endif
            }
            lw.start(queue: .global(qos: .utility))
            listener = lw
            #if DEBUG
            print("🕊️ [Bridge] LAN listen :\(port) (flagged reverse path)")
            #endif
        } catch {
            #if DEBUG
            print("🕊️ [Bridge] LAN listen bind failed: \(error)")
            #endif
        }
    }

    private func stopLanListener() {
        listener?.cancel()
        listener = nil
        listenPort = 0
    }

    private func handleLanConnection(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .utility))
        var rx = Data()
        func receiveMore() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error {
                    #if DEBUG
                    print("🕊️ [Bridge] LAN conn error: \(error)")
                    #endif
                    conn.cancel()
                    return
                }
                if let data, !data.isEmpty {
                    rx.append(data)
                    while let (payload, rest) = RavenServerlessLanPath.deframe(rx) {
                        rx = rest
                        let peer = "lan:\(conn.endpoint)"
                        NotificationCenter.default.post(
                            name: .ravenEnvelopeV1LanReceived,
                            object: nil,
                            userInfo: [
                                "packed": payload,
                                "peerKey": peer,
                                "connection": conn
                            ]
                        )
                    }
                }
                if isComplete {
                    // Keep open if we still wait for ACK on this conn.
                    return
                }
                receiveMore()
            }
        }
        receiveMore()
    }

    // MARK: - Sender attribution (endpoint only)

    /// Resolve senderUserId for ChatWire / MessageContentSealer (not used by opaque forward).
    private func resolveSenderUserId(env: RavenEnvelopeV1) async -> String? {
        var candidates: [(userId: String, pub: Data, via: String)] = []
        if let lan = RavenServerlessLanConfig.stored,
           let pub = RavenEnvelopeSenderResolver.pubFromHex(lan.peerPubHex) {
            let fp = DeviceIdentityService.deriveFingerprint(from: pub)
            candidates.append((fp, pub, "lan_peer_pub"))
        }
        for (uid, pub) in await PeerKeyDirectory.shared.identityCandidates() {
            candidates.append((uid, pub, "peer_directory"))
        }
        if let r = RavenEnvelopeSenderResolver.resolve(env: env, candidatePubs: candidates) {
            return r.senderUserId
        }
        return nil
    }

    // MARK: - Dedup / rate helpers

    private func recordSeen(_ objectDigest: Data) {
        if seen.count >= maxSeen { seen.removeAll(keepingCapacity: true) }
        seen.insert(objectDigest)
    }

    private func peerHits(peerKey: String, nowMs: UInt64) -> Int {
        let cutoff = nowMs.saturatingSubtraction(rateWindowMs)
        let kept = (peerEnqueueMs[peerKey] ?? []).filter { $0 >= cutoff }
        peerEnqueueMs[peerKey] = kept
        return kept.count
    }

    private func recordPeerHit(peerKey: String, nowMs: UInt64) {
        var arr = peerEnqueueMs[peerKey] ?? []
        arr.append(nowMs)
        peerEnqueueMs[peerKey] = arr
    }
}

private extension UInt64 {
    func saturatingSubtraction(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
}

extension Notification.Name {
    /// Posted when a flagged LAN path accepts a RavenEnvelopeV1 for bridge reverse.
    /// userInfo: packed (Data), peerKey (String), connection (NWConnection)?
    static let ravenEnvelopeV1LanReceived = Notification.Name("ravenEnvelopeV1LanReceived")
}
