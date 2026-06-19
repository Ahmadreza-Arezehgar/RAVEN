//
//  MeshProtocols.swift
//  RAVEN
//
//  Protocol abstractions for mesh networking layer.
//  Enables dependency injection and unit testing with mock implementations.
//

import Foundation

// MARK: - Mesh Transport Protocol

/// Abstracts the BLE mesh engine's public API for message transport.
/// Consumers depend on this protocol instead of `BLEMeshEngine` directly,
/// enabling mock injection for unit tests.
protocol MeshTransportProtocol: AnyObject {
    /// Broadcast a message envelope to all connected mesh peers
    func enqueueForBroadcast(_ envelope: MeshEnvelope) async
    
    /// Send a delivery/read receipt ACK via mesh
    func sendACK(_ ack: MeshACKEnvelope) async
    
    /// Broadcast raw post data to mesh peers
    func broadcastPostData(_ data: Data) async
    
    // BUG FIX [P2]: اضافه کردن متد ارسال مستقیم به یک Peer
    /// Send raw post data to a specific peer
    func sendPostData(_ data: Data, to peerDeviceId: String) async
    
    /// Stop a message and broadcast stop command to mesh
    func broadcastStop(_ messageId: String) async
    
    /// Handle an incoming stop command
    func handleStop(_ messageId: String) async
    
    /// Check if a message has been stopped
    func isMessageStopped(_ messageId: String) async -> Bool
    
    /// Apply a batch of stop IDs (from server sync)
    func applyStopList(_ messageIds: [String]) async
    
    /// Get currently connected mesh peers
    func getConnectedPeers() async -> [MeshPeer]
    
    /// Check if we have any active connections (Central or Peripheral)
    var hasActiveConnections: Bool { get }
    
    /// Gossip a ServerReceipt to nearby peers (proves message is on server)
    func gossipReceipt(_ receipt: ServerReceipt) async
    
    /// Send bulk data via best available transport (MPC for large payloads, BLE for small)
    func sendBulkData(_ data: Data, to peerDeviceId: String) async throws
    
    /// Send an envelope to a specific peer using the optimal transport
    func sendViaBestTransport(_ envelope: MeshEnvelope, to peerDeviceId: String) async
}

// MARK: - Network Status Providing

/// Abstracts the network connectivity monitor.
/// Consumers check `isOnline` and trigger control-plane sync through this protocol.
protocol NetworkStatusProviding: AnyObject {
    /// Whether the device currently has internet connectivity (NWPath)
    var isOnline: Bool { get }
    
    /// Whether the backend server is actually reachable (application-layer probe).
    /// More reliable than `isOnline` — detects captive portals and broken Wi-Fi.
    var serverReachable: Bool { get }
    
    /// Whether the network connection is flaky (recent mix of probe successes/failures).
    /// Used by MessageRouter to decide whether to dual-path send.
    var isNetworkFlaky: Bool { get }
    
    /// Whether the current path is expensive (cellular/hotspot)
    var isExpensive: Bool { get }
    
    /// Whether the current path is constrained (Low Data Mode)
    var isConstrained: Bool { get }
    
    /// Unified connectivity state (Spec V1 §2.1)
    var netState: NetState { get }
    
    /// Sync control-plane state (cancel list + pending ACKs) if interval has elapsed
    func syncControlPlaneIfNeeded(force: Bool) async
}

// MARK: - Deduplication Providing

/// Abstracts the persistent deduplication repository.
/// Used by the mesh engine to check for replay attacks.
protocol DeduplicationProviding: Actor {
    /// Returns `true` if the message ID has NOT been seen before (is new)
    func isNewMessage(id: String) async -> Bool

    /// Mark a message ID as processed
    func markProcessed(id: String, nonce: String?) async
}

// MARK: - Bridge Transport (internet rendezvous — serverless via libp2p)
//
// The "bridge" carries an opaque, E2E-encrypted envelope between two devices
// that are both online but not in BLE range. Today this goes through the
// server (`/api/mesh/bridge-envelope` + `/pending-bridges`). The messenger
// pivot replaces that rendezvous with a serverless go-libp2p transport
// (DHT discovery + Circuit Relay v2). This protocol is the seam so the
// rendezvous is pluggable — see docs/libp2p-bridge-plan.md.

/// One opaque, E2E-encrypted envelope that crossed the internet bridge.
struct BridgeEnvelopeItem {
    let envelopeB64: String
    let idempotencyKey: String
    let bridgedAt: Date
}

enum BridgeTransportError: Error {
    /// The libp2p native transport is not yet wired in (Phase B in progress).
    case notImplemented
    /// No internet rendezvous path is currently available.
    case notConnected
}

/// Abstracts the internet-bridge rendezvous. Implementations:
///   • `ServerBridgeTransport`  — legacy `/api/mesh/*` (server is off post-pivot)
///   • `LibP2PBridgeTransport`  — serverless go-libp2p (gomobile xcframework)
/// `MeshGatewayService` (upload) and `MeshBridgeReceiver` (drain) route
/// through the active transport instead of `NetworkService` directly.
protocol BridgeTransport: AnyObject {
    /// Push an opaque encrypted envelope toward its recipient over the internet.
    func uploadEnvelope(_ envelopeB64: String, idempotencyKey: String, recipientHint: String?) async throws

    /// Drain envelopes addressed to us that arrived since `since`.
    func drainPending(since: Date?) async throws -> [BridgeEnvelopeItem]

    /// Whether this transport currently has an internet rendezvous path.
    var isConnected: Bool { get }
}

/// Central accessor for the active internet-bridge transport. Post-pivot the
/// server is off, so this resolves to the serverless libp2p transport.
/// `MeshGatewayService` (upload) and `MeshBridgeReceiver` (drain) route through
/// `MeshBridge.transport` rather than calling `NetworkService` directly. Held
/// as a `var` so tests can inject a mock.
enum MeshBridge {
    static var transport: BridgeTransport = LibP2PBridgeTransport.shared
}

/// Serverless libp2p bridge transport.
///
/// Wraps the go-libp2p host compiled via `gomobile bind`
/// (Libp2pBridge/RavenLibp2p.xcframework). The host identity is RAVEN's
/// existing Ed25519 device key, so its libp2p PeerID derives from the same
/// public key as the device fingerprint — a QR-scanned contact's PeerID is
/// computable locally, no directory. Guarded by `#if canImport(RavenLibp2p)`:
/// the real implementation activates once the xcframework is embedded
/// (Xcode → Embed & Sign); until then it is a no-op stub so the app builds.
/// See Libp2pBridge/README.md and LIBP2P_BRIDGE_PLAN.md.
///
/// NOTE: the `canImport` branch is not compiled until the framework is linked,
/// so verify it on first integration (gomobile-generated symbol names).
#if canImport(RavenLibp2p)
import RavenLibp2p

final class LibP2PBridgeTransport: NSObject, BridgeTransport, RavenbridgeDelegate {
    static let shared = LibP2PBridgeTransport()
    private override init() { super.init() }

    private var node: RavenbridgeNode?
    private(set) var isConnected: Bool = false
    private(set) var localPeerID: String = ""

    /// Call once at startup with the device Ed25519 seed (32-byte CryptoKit
    /// `rawRepresentation`) + comma-separated libp2p bootstrap multiaddrs
    /// (from remote-config). Boots the libp2p host (DHT + Circuit Relay v2).
    func configure(identitySeed: Data, bootstrapCSV: String) {
        guard node == nil else { return }
        do {
            let n = try RavenbridgeNewNode(identitySeed, self)
            node = n
            try n.start(bootstrapCSV)
            localPeerID = n.peerID()
        } catch {
            #if DEBUG
            print("❌ [libp2p] start failed: \(error)")
            #endif
        }
    }

    func uploadEnvelope(_ envelopeB64: String, idempotencyKey: String, recipientHint: String?) async throws {
        guard let node else { throw BridgeTransportError.notConnected }
        guard let peerID = recipientHint, !peerID.isEmpty else { throw BridgeTransportError.notConnected }
        try node.send(peerID, envelopeB64: envelopeB64, idempotencyKey: idempotencyKey)
    }

    /// libp2p is push-based: inbound envelopes arrive on the RavenbridgeDelegate
    /// callback and go straight to MeshBridgeReceiver — nothing to poll.
    func drainPending(since: Date?) async throws -> [BridgeEnvelopeItem] { [] }

    // MARK: RavenbridgeDelegate (callbacks arrive on a background thread)
    func onEnvelope(_ envelopeB64: String?, idempotencyKey: String?) {
        guard let env = envelopeB64, let key = idempotencyKey else { return }
        Task { _ = await MeshBridgeReceiver.shared.ingest(envelopeB64: env, idempotencyKey: key, bridgedAt: Date()) }
    }
    func onStatus(_ connected: Bool, peerID: String?) {
        isConnected = connected
        if let peerID { localPeerID = peerID }
    }
}
#else
/// No-op stub until RavenLibp2p.xcframework is embedded (Libp2pBridge/README.md).
final class LibP2PBridgeTransport: BridgeTransport {
    static let shared = LibP2PBridgeTransport()
    private init() {}
    private(set) var isConnected: Bool = false
    func configure(identitySeed: Data, bootstrapCSV: String) {}
    func uploadEnvelope(_ envelopeB64: String, idempotencyKey: String, recipientHint: String?) async throws {
        throw BridgeTransportError.notImplemented
    }
    func drainPending(since: Date?) async throws -> [BridgeEnvelopeItem] {
        throw BridgeTransportError.notImplemented
    }
}
#endif
