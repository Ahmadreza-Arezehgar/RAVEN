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

/// Serverless libp2p bridge transport — STUB.
///
/// Phase B target: wraps a go-libp2p host compiled via `gomobile bind`
/// (`RavenLibp2p.xcframework`). The host identity is RAVEN's existing
/// Ed25519 device key (DeviceIdentityService), so its libp2p PeerID derives
/// from the same public key as the device fingerprint — a QR-scanned
/// contact's PeerID is computable locally with no directory. Until the
/// native xcframework is built + bound, every call is a no-op/throw.
///
/// See docs/libp2p-bridge-plan.md for the build pipeline + milestones.
final class LibP2PBridgeTransport: BridgeTransport {
    static let shared = LibP2PBridgeTransport()
    private init() {}

    /// Flips to true once `Start(privKey:bootstrap:)` on the native host succeeds.
    private(set) var isConnected: Bool = false

    func uploadEnvelope(_ envelopeB64: String, idempotencyKey: String, recipientHint: String?) async throws {
        // TODO(Phase B): RavenLibp2p.send(peerID: recipientHint, envelopeB64:, idemKey:)
        throw BridgeTransportError.notImplemented
    }

    func drainPending(since: Date?) async throws -> [BridgeEnvelopeItem] {
        // TODO(Phase B): RavenLibp2p.drain() — inbound envelopes arrive via the
        // /raven/bridge/1.0.0 stream handler and are queued in the native host.
        throw BridgeTransportError.notImplemented
    }
}
