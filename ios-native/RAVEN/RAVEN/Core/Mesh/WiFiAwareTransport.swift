// WiFiAwareTransport.swift
//
// Wi-Fi Aware (NAN — Neighbor Awareness Networking) transport for iOS.
//
// Apple shipped Wi-Fi Aware on iOS 26 in 2025 (under EU Digital
// Markets Act pressure). It's the first time iOS can do real
// peer-to-peer Wi-Fi with Android — bandwidth tops out around
// **250 Mbps** vs BLE GATT's ~50 kbps practical, a roughly 5,000×
// speedup. Unlike Multipeer Connectivity, Wi-Fi Aware is a
// cross-vendor IEEE / Wi-Fi Alliance standard, so the same RAVEN
// session can carry envelopes between iPhone and Pixel without going
// through a hotspot or shared network.
//
// This file is a SCAFFOLD: the integration points (start/stop,
// per-peer send, broadcast send, dataReceived hook) are wired into
// `BLEMeshEngine`, but the body of each method is a TODO until the
// project ships an iOS-26-only build slice. The wiring is what
// matters — the moment we fill these methods in, every v2 envelope
// path (point-to-point send, multi-hop relay, STOP gossip) starts
// using Wi-Fi Aware whenever a peer is reachable that way.
//
// Why scaffold-now: it's much cheaper to add the integration points
// once and fill behavior later than it is to rewrite the BLE engine
// when we revisit the transport stack. Receivers dedup cross-
// transport via the relay-service Bloom filter on `msg_id`, so it's
// safe to fan envelopes out across BLE + MPC + Wi-Fi Aware in
// parallel — duplicates collapse cleanly downstream.

import Foundation

#if canImport(WiFiAware)
import WiFiAware
#endif

/// Stable identity for a Wi-Fi Aware peer that mirrors the MPC
/// `MCPeerID.displayName` shape — `"RAVEN-<8 hex of fingerprint>"` —
/// so the relay layer's `except sourceDeviceId:` exclusion works
/// consistently regardless of which transport the source used.
public struct WiFiAwarePeerID: Hashable {
    public let displayName: String
    public init(displayName: String) { self.displayName = displayName }
}

/// Single point of entry for the Wi-Fi Aware transport. Lifecycle
/// matches `MPCTransportService` so `BLEMeshEngine` can treat them
/// interchangeably.
@MainActor
final class WiFiAwareTransport {
    static let shared = WiFiAwareTransport()

    /// True once `start()` has finished announcing the publisher
    /// service AND we've subscribed for nearby peers. Reset by `stop()`.
    private(set) var isActive: Bool = false

    /// Authenticated peers keyed by their advertised display name.
    /// Populated from the discovery callback once we've verified the
    /// peer's Ed25519 challenge (same trust model as the MPC path).
    private(set) var connectedPeers: Set<WiFiAwarePeerID> = []

    /// Set by `BLEMeshEngine.start` — receives post-auth bytes. The
    /// engine peeks byte 0: `0x02` = v2 binary, anything else = v1
    /// JSON. Same hand-off as the MPC transport.
    var onDataReceived: ((Data, WiFiAwarePeerID) -> Void)?

    private init() {}

    // MARK: - Lifecycle

    /// Activate the publisher (advertising) and subscriber (discovery)
    /// in parallel. Idempotent. iOS < 26 returns immediately and the
    /// transport stays inactive — every send routine no-ops, leaving
    /// BLE / MPC to carry traffic.
    func start(deviceFingerprint: String) {
        guard !isActive else { return }
        if #available(iOS 26.0, *) {
            startAvailable(deviceFingerprint: deviceFingerprint)
        } else {
            // Wi-Fi Aware needs iOS 26+. Older builds stay on BLE+MPC.
            #if DEBUG
            print("[wifi-aware] skipped — requires iOS 26+")
            #endif
        }
    }

    /// Tear down publisher + subscriber. Idempotent.
    func stop() {
        guard isActive else { return }
        if #available(iOS 26.0, *) {
            stopAvailable()
        }
        connectedPeers.removeAll()
        isActive = false
    }

    // MARK: - Sending (relay-layer interface)

    /// All peers currently reachable over Wi-Fi Aware. Read by
    /// `BLEMeshEngine.relayV2EnvelopeBytesToAllPeers` to fan out
    /// alongside BLE + MPC.
    var connectedPeerIds: [WiFiAwarePeerID] { Array(connectedPeers) }

    /// Look up a peer by its BLE/MPC display name. Returns nil when
    /// the peer never authenticated, never advertised, or vanished.
    func peer(for displayName: String) -> WiFiAwarePeerID? {
        let id = WiFiAwarePeerID(displayName: displayName)
        return connectedPeers.contains(id) ? id : nil
    }

    /// Send `data` to one peer. Throws on missing/disconnected peer.
    /// Today: returns silently when we're not yet on iOS 26 OR when
    /// the actual API hookup hasn't landed (the `if #available` block
    /// is a TODO). The relay layer catches these silently; v2 traffic
    /// continues over BLE + MPC.
    func sendBulkData(_ data: Data, to peer: WiFiAwarePeerID) throws {
        guard isActive else { throw WiFiAwareError.transportInactive }
        guard connectedPeers.contains(peer) else { throw WiFiAwareError.peerNotConnected }
        if #available(iOS 26.0, *) {
            try sendAvailable(data, to: peer)
        } else {
            throw WiFiAwareError.transportInactive
        }
    }

    // MARK: - iOS 26+ implementation

    @available(iOS 26.0, *)
    private func startAvailable(deviceFingerprint: String) {
        // TODO(wifi-aware-impl): instantiate the publisher service with
        // the canonical RAVEN service name `raven-mesh-v2`, set the
        // discoveryInfo to advertise our 16-byte peer id (SHA-256 of
        // the static Curve25519 key), bind the publisher's data
        // callback to `self.handleIncoming(_:from:)`, and start a
        // subscriber on the same service name. The Wi-Fi Aware
        // framework on iOS 26 exposes:
        //
        //   • `WAPublishableService(name:)` — advertises us
        //   • `WASubscribableService(name:)` — discovers peers
        //   • `WAConnection` — established peer link
        //
        // Authentication: send a challenge identical to the MPC
        // 0xAC envelope after connect, gate `connectedPeers`
        // insertion on Ed25519 verify. Wire format byte-identical
        // with MPC so cross-transport dedup is just a `msg_id` match.
        //
        // FIX (2026-05-10): keep `isActive = false` while the body is
        // a TODO. The previous version flipped it `true` "for the
        // scaffold" which made `BLEMeshEngine.relayV2EnvelopeBytesToAllPeers`
        // happily route v2 envelopes through `sendAvailable`, which then
        // throws `notImplemented` and silently drops the payload. Result:
        // a transport that looked alive in metrics but ate every message
        // it was handed. Stay false until publisher/subscriber actually
        // exist; flip to true at the end of the real implementation.
        // isActive remains false here intentionally.
        #if DEBUG
        print("[wifi-aware] iOS 26+ scaffold present but inactive (TODO body) for \(deviceFingerprint.prefix(8))")
        #endif
    }

    @available(iOS 26.0, *)
    private func stopAvailable() {
        // TODO(wifi-aware-impl): tear down publisher + subscriber +
        // any open `WAConnection`s.
    }

    @available(iOS 26.0, *)
    private func sendAvailable(_ data: Data, to peer: WiFiAwarePeerID) throws {
        // TODO(wifi-aware-impl): look up the live `WAConnection` for
        // `peer.displayName` and `connection.send(data)`. The
        // 0xDA-marker convention from MPC carries over so the
        // receiver can multiplex auth (0xAC) and data (0xDA) on
        // the same channel.
        throw WiFiAwareError.notImplemented
    }

    /// Centralized data-receive handler. Wired up from the
    /// publisher / subscriber callbacks once the iOS-26 bodies above
    /// are filled in. Keep this method body small — discrimination
    /// between v1 and v2 envelopes lives in `BLEMeshEngine`'s
    /// `onDataReceived` hook (peeks byte 0).
    private func handleIncoming(_ data: Data, from peer: WiFiAwarePeerID) {
        connectedPeers.insert(peer)
        onDataReceived?(data, peer)
    }

    // MARK: - Errors

    enum WiFiAwareError: Error, LocalizedError {
        case transportInactive
        case peerNotConnected
        case notImplemented

        var errorDescription: String? {
            switch self {
            case .transportInactive: return "Wi-Fi Aware transport not active"
            case .peerNotConnected: return "Wi-Fi Aware peer not connected"
            case .notImplemented: return "Wi-Fi Aware send body not yet wired"
            }
        }
    }
}
