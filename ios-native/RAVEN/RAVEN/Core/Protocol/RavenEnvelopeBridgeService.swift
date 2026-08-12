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

    /// message_id (16B) → LAN connection waiting for recipient ACK (phone as B).
    private var ackWaiters: [Data: NWConnection] = [:]

    /// When true, Message ingress is treated as local destination (phone as C).
    /// App / tests set this; default false = bridge/relay preference when egress ready.
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
        // Optional thin LAN listen (phone as B). Port 0 / unset → no listener.
        if let port = RavenServerlessLanConfig.stored?.listenPort, port > 0 {
            startLanListener(port: port)
        }
        #if DEBUG
        print("🕊️ [Bridge] RavenEnvelopeBridgeService listening (flag ON)")
        #endif
    }

    public func stop() {
        if let bleObserver {
            NotificationCenter.default.removeObserver(bleObserver)
            self.bleObserver = nil
        }
        if let lanObserver {
            NotificationCenter.default.removeObserver(lanObserver)
            self.lanObserver = nil
        }
        for (_, conn) in ackWaiters { conn.cancel() }
        ackWaiters.removeAll()
        stopLanListener()
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

        let role = RavenEnvelopeEndpointIngest.classifyRole(
            envType: env.envType,
            localIsDestination: localIsDestination,
            bridgeEnabled: RavenServerlessLanConfig.stored != nil
        )
        if role == .deliverToEndpoint {
            let sender = await resolveSenderUserId(env: env)
            RavenEnvelopeEndpointIngest.publishSealedBody(
                messageId: env.messageId,
                sealedBody: env.messageCiphertext,
                hybridPQ: (env.flags & 1) != 0,
                peerKey: peerKey,
                senderUserId: sender
            )
            return
        }

        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let hits = peerHits(peerKey: peerKey, nowMs: nowMs)
        let mid = env.messageId
        let decision = Self.decideForward(
            packed: packed,
            messageId: mid,
            expiresAtMs: env.expiresAtMs,
            hopLimit: env.hopLimit,
            replicationBudget: env.replicationBudget,
            alreadySeen: seen.contains(mid),
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
        recordSeen(mid)
        recordPeerHit(peerKey: peerKey, nowMs: nowMs)

        var fwd = env
        fwd.hopLimit &-= 1
        fwd.replicationBudget &-= 1

        guard let lan = RavenServerlessLanConfig.stored else { return }
        do {
            _ = try await RavenServerlessLanPath.sendEnvelope(
                fwd,
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

    /// Recipient ACK on BLE → wake LAN waiter (phone as B) and/or forward to LAN.
    /// If this device has a pending outbound for the acked id, also publish to
    /// ChatWire (Delivered) without decrypting — BridgeSubsystem stays key-free.
    @discardableResult
    public func relayAckFromBle(packed: Data, env: RavenEnvelopeV1? = nil) async -> BridgeForwardDecision {
        guard FeatureFlag.isRavenEnvelopeV1Enabled else { return .flagOff }
        let env = env ?? RavenEnvelopeV1.unpack(packed)
        guard let env, env.envType == RavenEnvelopeV1.EnvType.ack.rawValue,
              let acked = RavenEnvelopeEndpointIngest.opaqueAckedMessageId(from: env) else {
            return .dropMalformed
        }
        let ackedKey = Data(acked)

        // Originator on this device: Delivered ticks via ChatWire (not bridge keys).
        let localOriginator = RavenEnvelopeChatWire.shared.hasPendingOutbound(envelopeMessageId: ackedKey)
        if localOriginator {
            RavenEnvelopeEndpointIngest.publishAck(ackedMessageId: ackedKey, packed: packed)
        }

        if let conn = ackWaiters.removeValue(forKey: ackedKey) {
            writeFramed(packed, to: conn)
            #if DEBUG
            print("🕊️ [Bridge] ACK relay BLE→LAN waiter mid=\(acked.prefix(4).map { String(format: "%02x", $0) }.joined())")
            #endif
            return .ackRelayed
        }
        // No waiter: best-effort LAN uplink if configured (opaque, no ACK-wait).
        if let lan = RavenServerlessLanConfig.stored {
            do {
                try await RavenServerlessLanPath.sendPackedFireAndForget(
                    packed,
                    host: lan.host,
                    port: lan.port
                )
                return .ackRelayed
            } catch {
                #if DEBUG
                print("🕊️ [Bridge] ACK LAN uplink failed: \(error)")
                #endif
                return localOriginator ? .ackRelayed : .dropNoEgress
            }
        }
        return localOriginator ? .ackRelayed : .dropNoEgress
    }

    // MARK: - LAN → BLE (reverse)

    private func onLanRvn1(_ note: Notification) async {
        guard FeatureFlag.isRavenEnvelopeV1Enabled else { return }
        guard let packed = note.userInfo?["packed"] as? Data else { return }
        let peerKey = (note.userInfo?["peerKey"] as? String) ?? "lan-unknown"
        if let conn = note.userInfo?["connection"] as? NWConnection {
            await handleLanIngress(packed: packed, peerKey: peerKey, replyConn: conn)
        } else {
            _ = await forwardLanToBle(packed: packed, peerKey: peerKey)
        }
    }

    /// Public entry for tests / LAN listener: opaque LAN→BLE when peers reachable.
    /// Registers ACK waiter when `replyConn` is provided (Message only).
    @discardableResult
    public func forwardLanToBle(
        packed: Data,
        peerKey: String,
        replyConn: NWConnection? = nil
    ) async -> BridgeForwardDecision {
        guard FeatureFlag.isRavenEnvelopeV1Enabled else { return .flagOff }
        guard let env = RavenEnvelopeV1.unpack(packed) else { return .dropMalformed }

        if env.envType == RavenEnvelopeV1.EnvType.ack.rawValue {
            return await forwardAckLanToBle(packed: packed, env: env, peerKey: peerKey)
        }
        guard env.envType == RavenEnvelopeV1.EnvType.message.rawValue else {
            return .dropMalformed
        }

        let role = RavenEnvelopeEndpointIngest.classifyRole(
            envType: env.envType,
            localIsDestination: localIsDestination,
            bridgeEnabled: true
        )
        if role == .deliverToEndpoint {
            let sender = await resolveSenderUserId(env: env)
            RavenEnvelopeEndpointIngest.publishSealedBody(
                messageId: env.messageId,
                sealedBody: env.messageCiphertext,
                hybridPQ: (env.flags & 1) != 0,
                peerKey: peerKey,
                senderUserId: sender
            )
            return .deliverToEndpoint
        }

        let bleReady = BLEMeshEngine.shared.hasActiveConnections
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let hits = peerHits(peerKey: peerKey, nowMs: nowMs)
        let mid = env.messageId
        let decision = Self.decideForward(
            packed: packed,
            messageId: mid,
            expiresAtMs: env.expiresAtMs,
            hopLimit: env.hopLimit,
            replicationBudget: env.replicationBudget,
            alreadySeen: seen.contains(mid),
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
        recordSeen(mid)
        recordPeerHit(peerKey: peerKey, nowMs: nowMs)

        if let replyConn {
            ackWaiters[mid] = replyConn
        }

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

    private func handleLanIngress(
        packed: Data,
        peerKey: String,
        replyConn: NWConnection
    ) async {
        _ = await forwardLanToBle(packed: packed, peerKey: peerKey, replyConn: replyConn)
    }

    private func forwardAckLanToBle(
        packed: Data,
        env: RavenEnvelopeV1,
        peerKey: String
    ) async -> BridgeForwardDecision {
        let bleReady = BLEMeshEngine.shared.hasActiveConnections
        guard bleReady else { return .dropNoEgress }
        var fwd = env
        if fwd.hopLimit > 0 { fwd.hopLimit &-= 1 }
        if fwd.replicationBudget > 0 { fwd.replicationBudget &-= 1 }
        await BLEMeshEngine.shared.enqueueRawRavenEnvelopeV1(fwd.pack())
        #if DEBUG
        let acked = RavenEnvelopeEndpointIngest.opaqueAckedMessageId(from: env)
        print("🕊️ [Bridge] ACK LAN→BLE peer=\(peerKey) acked=\(acked?.prefix(4).map { String(format: "%02x", $0) }.joined() ?? "?")")
        #endif
        return .ackRelayed
    }

    /// Test hook: register a synthetic ACK waiter (messageId → connection).
    public func registerAckWaiterForTests(messageId: Data, connection: NWConnection) {
        ackWaiters[messageId] = connection
    }

    /// Test hook: clear waiters.
    public func clearAckWaitersForTests() {
        ackWaiters.removeAll()
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

    private func writeFramed(_ packed: Data, to conn: NWConnection) {
        let framed = RavenServerlessLanPath.frame(packed)
        conn.send(content: framed, completion: .contentProcessed { err in
            #if DEBUG
            if let err {
                print("🕊️ [Bridge] ACK write failed: \(err)")
            }
            #endif
            conn.cancel()
        })
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

    private func recordSeen(_ mid: Data) {
        if seen.count >= maxSeen { seen.removeAll(keepingCapacity: true) }
        seen.insert(mid)
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
