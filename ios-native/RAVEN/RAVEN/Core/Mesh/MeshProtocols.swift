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

// MARK: - libp2p PeerID derivation
//
// A RAVEN device's libp2p host boots from its Ed25519 device key, so its PeerID
// is derived deterministically from the *public* half — which means a contact's
// PeerID is computable locally from their device identity key (no directory).
// This mirrors go-libp2p's `peer.IDFromPublicKey`:
//   1. marshal the public key as the libp2p `PublicKey` protobuf
//      (field 1 KeyType=Ed25519(1), field 2 Data=raw 32-byte key) → 36 bytes.
//   2. since that is ≤ 42 bytes, the PeerID multihash uses the *identity* hash
//      (code 0x00): 0x00 || len(0x24) || marshaled  → 38 bytes.
//   3. base58btc-encode the multihash → "12D3Koo…".
enum Libp2pPeerID {
    /// Derive the canonical libp2p PeerID string ("12D3Koo…") from a raw
    /// 32-byte Ed25519 public key. Returns nil if the key isn't 32 bytes.
    static func fromEd25519(_ publicKey: Data) -> String? {
        guard publicKey.count == 32 else { return nil }
        // libp2p PublicKey protobuf: 0x08 0x01 (Type=Ed25519) | 0x12 0x20 (Data, len 32) | <key>
        var marshaled: [UInt8] = [0x08, 0x01, 0x12, 0x20]
        marshaled.append(contentsOf: publicKey)
        // Identity multihash: code 0x00, length 0x24 (36), then the marshaled key.
        var mh: [UInt8] = [0x00, UInt8(marshaled.count)]
        mh.append(contentsOf: marshaled)
        return base58btc(mh)
    }

    /// Whether a string already looks like a libp2p PeerID (so callers can pass
    /// a PeerID through untouched rather than resolving a userId).
    static func looksLikePeerID(_ s: String) -> Bool {
        s.hasPrefix("12D3Koo") || s.hasPrefix("Qm") || s.hasPrefix("bafz")
    }

    /// Bitcoin/IPFS base58 alphabet.
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    private static func base58btc(_ bytes: [UInt8]) -> String {
        var digits: [Int] = [0]
        for byte in bytes {
            var carry = Int(byte)
            for i in 0..<digits.count {
                carry += digits[i] << 8
                digits[i] = carry % 58
                carry /= 58
            }
            while carry > 0 {
                digits.append(carry % 58)
                carry /= 58
            }
        }
        var out = ""
        // Each leading 0x00 byte → a leading '1'.
        for byte in bytes { if byte == 0 { out.append("1") } else { break } }
        for d in digits.reversed() { out.append(alphabet[d]) }
        return out
    }
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

final class LibP2PBridgeTransport: NSObject, BridgeTransport, RavenbridgeDelegateProtocol {
    static let shared = LibP2PBridgeTransport()
    private override init() { super.init() }

    private var node: RavenbridgeNode?
    private(set) var isConnected: Bool = false
    private(set) var localPeerID: String = ""

    /// Call once at startup with the device Ed25519 seed (32-byte CryptoKit
    /// `rawRepresentation`) + comma-separated libp2p bootstrap multiaddrs
    /// (from remote-config). Boots the libp2p host (DHT + Circuit Relay v2).
    ///
    /// `RavenbridgeNewNode` is a gomobile free function, so its trailing
    /// `error` is an `NSError` out-param (not a Swift `throws`); the instance
    /// methods (`start`/`send`) *are* imported as throwing.
    func configure(identitySeed: Data, bootstrapCSV: String) {
        guard node == nil else { return }
        var err: NSError?
        guard let n = RavenbridgeNewNode(identitySeed, self, &err), err == nil else {
            #if DEBUG
            print("❌ [libp2p] NewNode failed: \(String(describing: err))")
            #endif
            return
        }
        do {
            try n.start(bootstrapCSV)
            node = n
            localPeerID = n.peerID()
        } catch {
            #if DEBUG
            print("❌ [libp2p] start failed: \(error)")
            #endif
        }
    }

    func uploadEnvelope(_ envelopeB64: String, idempotencyKey: String, recipientHint: String?) async throws {
        guard let node else { throw BridgeTransportError.notConnected }
        guard let hint = recipientHint, !hint.isEmpty else { throw BridgeTransportError.notConnected }
        // `node.send` needs a real libp2p PeerID (it does peer.Decode). Resolve
        // the caller's `recipientHint`:
        //   • already a PeerID ("12D3Koo…") → use as-is;
        //   • otherwise a RAVEN userId → derive the contact's PeerID from their
        //     pinned Ed25519 identity key (the same key their libp2p host boots
        //     from — see Libp2pPeerID), no directory needed.
        // If it's neither (e.g. an opaque relay hash we hold no identity key
        // for), we can't route it — fail rather than dial a bogus peer.
        let peerID: String
        if Libp2pPeerID.looksLikePeerID(hint) {
            peerID = hint
        } else if let idKey = await PeerKeyDirectory.shared.identityKey(for: hint),
                  let derived = Libp2pPeerID.fromEd25519(idKey) {
            peerID = derived
        } else {
            throw BridgeTransportError.notConnected
        }
        try node.send(peerID, envelopeB64: envelopeB64, idempotencyKey: idempotencyKey)
    }

    /// libp2p is push-based: inbound envelopes arrive on the RavenbridgeDelegate
    /// callback and go straight to MeshBridgeReceiver — nothing to poll.
    func drainPending(since: Date?) async throws -> [BridgeEnvelopeItem] { [] }

    // MARK: - Remote contact add (rendezvous)
    //
    // Thin passthrough to the Go rendezvous layer. Everything that matters for
    // trust — building the signed card and verifying the peer's — happens in
    // `RemoteInviteService`; these carry opaque strings.

    /// Set by `RemoteInviteService` to receive the redeemer's card on the
    /// INVITER's device. Fires on a background thread.
    var onInviteRedeemedHandler: ((String, String) -> Void)?

    /// Note the gomobile import shape: a Go `(string, error)` return becomes an
    /// `NSErrorPointer` out-param, NOT a Swift `throws` — same quirk as
    /// `RavenbridgeNewNode` above. Only `(error)`-only returns (cancelInvite)
    /// import as throwing.
    func createInvite(cardJSON: String, ttlSeconds: Int) throws -> String {
        guard let node else { throw BridgeTransportError.notConnected }
        var err: NSError?
        let token = node.createInvite(cardJSON, ttlSeconds: ttlSeconds, error: &err)
        if let err { throw err }
        guard !token.isEmpty else { throw BridgeTransportError.notConnected }
        return token
    }

    func redeemInvite(token: String, myCardJSON: String) throws -> String {
        guard let node else { throw BridgeTransportError.notConnected }
        var err: NSError?
        let card = node.redeemInvite(token, myCardJSON: myCardJSON, error: &err)
        if let err { throw err }
        guard !card.isEmpty else { throw BridgeTransportError.notConnected }
        return card
    }

    func cancelInvite(_ token: String) throws {
        guard let node else { return }
        try node.cancelInvite(token)
    }

    // MARK: RavenbridgeDelegateProtocol (callbacks arrive on a background thread;
    // the gomobile protocol is `@objc`, so the methods must be too).
    @objc func onEnvelope(_ envelopeB64: String?, idempotencyKey: String?) {
        guard let env = envelopeB64, let key = idempotencyKey else { return }
        Task { _ = await MeshBridgeReceiver.shared.ingest(envelopeB64: env, idempotencyKey: key, bridgedAt: Date()) }
    }
    @objc func onStatus(_ connected: Bool, peerID: String?) {
        isConnected = connected
        if let peerID { localPeerID = peerID }
    }
    /// Someone redeemed one of our live invites. The card is UNVERIFIED here —
    /// `RemoteInviteService` runs `FriendQRPayload.parseAndVerify` before any of
    /// it is trusted.
    @objc func onInviteRedeemed(_ token: String?, peerCardJSON: String?) {
        guard let token, let card = peerCardJSON else { return }
        onInviteRedeemedHandler?(token, card)
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
    // Remote contact add — same surface as the real transport so call sites
    // compile without the xcframework embedded.
    var onInviteRedeemedHandler: ((String, String) -> Void)? {
        get { nil }
        set { _ = newValue }
    }
    func createInvite(cardJSON: String, ttlSeconds: Int) throws -> String {
        throw BridgeTransportError.notImplemented
    }
    func redeemInvite(token: String, myCardJSON: String) throws -> String {
        throw BridgeTransportError.notImplemented
    }
    func cancelInvite(_ token: String) throws {
        throw BridgeTransportError.notImplemented
    }
}
#endif
