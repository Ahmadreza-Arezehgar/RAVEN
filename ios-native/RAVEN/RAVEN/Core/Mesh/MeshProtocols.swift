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
