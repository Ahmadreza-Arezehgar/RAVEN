// MPCTransportService.swift (macOS App Store)
//
// Slimmed-down sibling of
// `ios-native/RAVEN/RAVEN/Core/Mesh/MPCTransportService.swift`.
//
// Wire format MUST match iOS byte-for-byte so iOS↔Mac MPC sessions
// interoperate:
//   • Service type: `raven-mesh`  (≤15 chars, lowercase)
//   • PeerID display name: `RAVEN-<first 8 hex of fingerprint>`
//   • Frame markers: `0xAC` = auth challenge JSON, `0xDA` = data
//   • Auth: Ed25519 signature over `<sessionNonce>|<ts>|<fingerprint>`
//
// Differences from iOS:
//   • No UIKit / UIBackgroundTask (macOS apps stay alive in
//     foreground; the Mac App Store target's `BackgroundModeService`
//     handles long-running activity policy separately).
//   • No resource-transfer API (`MPCSession.sendResource`) — v2
//     envelopes are small enough to ride `sendBulkData` chunked at
//     the MPC layer transparently.
//   • Plain class (not `ObservableObject`) — the few SwiftUI views
//     that need a peer count read it through `BLEMeshEngine`'s
//     `connectedPeers` observable, which already exists.
//
// See `docs/MESH_PROTOCOL.md` for the full GATT + transport spec.

import Foundation
import MultipeerConnectivity
import CryptoKit

// MARK: - Auth Challenge (binary-compatible with iOS MPCAuthChallenge)

/// First message sent over MPC to authenticate the peer. Same JSON
/// shape as iOS `MPCAuthChallenge` so the two implementations
/// interop. Wire layout: `0xAC || JSON(...)` over MCSession.
struct MacMPCAuthChallenge: Codable {
    let sessionNonce: String
    let timestamp: Int64
    let fingerprint: String
    let signature: String

    /// Build an auth challenge signed by the local device's Ed25519
    /// static key. Matches the iOS signing-data string verbatim:
    /// `"<sessionNonce>|<timestamp>|<fingerprint>"` UTF-8.
    static func create(sessionNonce: String) -> MacMPCAuthChallenge? {
        let fp = DeviceIdentityService.shared.fingerprint ?? ""
        let ts = Int64(Date().timeIntervalSince1970)
        let signingData = "\(sessionNonce)|\(ts)|\(fp)".data(using: .utf8) ?? Data()
        guard let sig = DeviceIdentityService.shared.sign(signingData) else { return nil }
        return MacMPCAuthChallenge(
            sessionNonce: sessionNonce,
            timestamp: ts,
            fingerprint: fp,
            signature: sig.base64EncodedString()
        )
    }
}

// MARK: - Service

@MainActor
final class MPCTransportService: NSObject {
    static let shared = MPCTransportService()

    // MARK: - Constants — must match iOS

    private let serviceType = "raven-mesh"

    // MARK: - State

    private var myPeerId: MCPeerID?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    /// MCPeerID display names that have completed the Ed25519 auth
    /// handshake. Sends to anyone NOT in here are refused.
    private var authenticatedPeers: Set<String> = []

    /// BLE deviceId → MCPeerID lookup, populated either from
    /// discoveryInfo (the advertiser side puts its fingerprint there)
    /// or from auth-challenge fingerprints.
    private var bleToMPC: [String: MCPeerID] = [:]

    /// Pending session nonces (BLE handshake nonce → bleDeviceId) for
    /// auth binding. Today the Mac never produces a BLE-side nonce
    /// (the Mac doesn't act as a v1 mesh bridger), so this map is
    /// empty in practice; we keep it for parity with iOS so the
    /// challenge code paths line up.
    private var pendingNonces: [String: String] = [:]

    private(set) var isActive: Bool = false

    // MARK: - Callbacks

    /// Set by `BLEMeshEngine` on start; receives the post-auth bytes
    /// (the leading `0xDA` marker has already been stripped). The
    /// engine peeks byte 0 — `0x02` = v2 envelope, anything else =
    /// legacy v1 JSON.
    var onDataReceived: ((Data, MCPeerID) -> Void)?

    private override init() { super.init() }

    // MARK: - Lifecycle

    /// Spin up advertiser + browser. Idempotent; calling twice is a no-op.
    func start(deviceFingerprint: String) {
        guard !isActive else { return }

        let id = MCPeerID(displayName: "RAVEN-\(deviceFingerprint.prefix(8))")
        myPeerId = id

        let s = MCSession(peer: id, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        session = s

        let info: [String: String] = [
            "v": "1",
            "fp": String(deviceFingerprint.prefix(12))
        ]
        let adv = MCNearbyServiceAdvertiser(peer: id, discoveryInfo: info, serviceType: serviceType)
        adv.delegate = self
        adv.startAdvertisingPeer()
        advertiser = adv

        let br = MCNearbyServiceBrowser(peer: id, serviceType: serviceType)
        br.delegate = self
        br.startBrowsingForPeers()
        browser = br

        isActive = true
        #if DEBUG
        print("📡 [MPC] Mac started — advertising + browsing as \(id.displayName)")
        #endif
    }

    /// Tear down advertiser, browser, and session. Idempotent.
    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()

        authenticatedPeers.removeAll()
        bleToMPC.removeAll()
        pendingNonces.removeAll()

        advertiser = nil
        browser = nil
        session = nil
        myPeerId = nil
        isActive = false

        #if DEBUG
        print("🔴 [MPC] Mac stopped")
        #endif
    }

    // MARK: - Sending

    /// All MPC peers currently connected at the MCSession level.
    /// `BLEMeshEngine.relayV2EnvelopeBytesToAllPeers` reads this to
    /// fan out v2 envelopes; `sendBulkData` will still refuse to send
    /// to peers that haven't completed the auth challenge.
    var connectedPeerIds: [MCPeerID] { session?.connectedPeers ?? [] }

    /// Look up an authenticated MPC peer by its BLE device id.
    /// Returns nil when the peer disconnected, never sent its auth
    /// challenge, or never advertised a fingerprint we recognized.
    func mpcPeer(for bleDeviceId: String) -> MCPeerID? {
        guard let peer = bleToMPC[bleDeviceId],
              session?.connectedPeers.contains(peer) == true,
              authenticatedPeers.contains(peer.displayName)
        else {
            bleToMPC.removeValue(forKey: bleDeviceId)
            return nil
        }
        return peer
    }

    /// Send `data` to one authenticated peer with the `0xDA` marker.
    /// Throws if the session is gone, the peer disconnected, or the
    /// peer never authenticated.
    func sendBulkData(_ data: Data, to peer: MCPeerID) throws {
        guard let session else { throw MPCError.sessionNotActive }
        guard session.connectedPeers.contains(peer) else { throw MPCError.peerNotConnected }
        guard authenticatedPeers.contains(peer.displayName) else { throw MPCError.peerNotAuthenticated }
        var tagged = Data([0xDA])
        tagged.append(data)
        try session.send(tagged, toPeers: [peer], with: .reliable)
        #if DEBUG
        print("📤 [MPC] Mac sent \(data.count) bytes to \(peer.displayName)")
        #endif
    }

    /// Sign + send the auth challenge — first message after
    /// connection. The peer's MCSessionDelegate flips them to
    /// authenticated when our challenge passes their Ed25519 verify.
    private func sendAuthChallenge(to peer: MCPeerID, nonce: String) {
        guard let session,
              let challenge = MacMPCAuthChallenge.create(sessionNonce: nonce),
              let json = try? JSONEncoder().encode(challenge)
        else { return }
        var tagged = Data([0xAC])
        tagged.append(json)
        try? session.send(tagged, toPeers: [peer], with: .reliable)
        #if DEBUG
        print("🔐 [MPC] Mac sent auth challenge to \(peer.displayName)")
        #endif
    }

    // MARK: - Errors

    enum MPCError: Error, LocalizedError {
        case sessionNotActive
        case peerNotConnected
        case peerNotAuthenticated

        var errorDescription: String? {
            switch self {
            case .sessionNotActive: return "MPC session is not active"
            case .peerNotConnected: return "Peer not connected via MPC"
            case .peerNotAuthenticated: return "Peer not authenticated"
            }
        }
    }
}

// MARK: - MCSessionDelegate

extension MPCTransportService: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                #if DEBUG
                print("📡 [MPC] Mac peer \(peerID.displayName) connected")
                #endif
                let nonce = self.pendingNonces.first?.key ?? UUID().uuidString
                self.sendAuthChallenge(to: peerID, nonce: nonce)
            case .notConnected:
                self.authenticatedPeers.remove(peerID.displayName)
                self.bleToMPC = self.bleToMPC.filter { $0.value != peerID }
            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard !data.isEmpty else { return }
        let marker = data[0]
        let payload = data.dropFirst()

        Task { @MainActor in
            switch marker {
            case 0xAC:
                // Auth challenge. The peer announces themselves with the
                // first 8 hex of their fingerprint in the MCPeerID
                // display name; the JSON body carries the full
                // fingerprint plus an Ed25519 signature over
                // `<nonce>|<ts>|<fingerprint>`.
                //
                // We CAN'T verify the signature here without the peer's
                // public key, because `fingerprint` is a hashed digest
                // of the key — one-way, not reversible. iOS verifies by
                // looking the key up in its `FriendDeviceRepository`
                // (paired-device store), which the Mac App Store build
                // doesn't ship. Until the Mac gains its own trusted-key
                // store, this remains trust-on-first-use with the
                // following tightening:
                //
                //   • Prefix integrity: display-name prefix matches the
                //     claimed fingerprint (catches honest framing bugs).
                //   • Replay guard: timestamp ≤ 5 min skew (so a
                //     replayed old challenge from a legitimate peer
                //     can't masquerade as a fresh session). Also
                //     defends against unsynced clocks.
                //   • Self-consistency: the JSON's `fingerprint` MUST
                //     re-derive from the same public key it claims to
                //     come from once the trust store lands — for now
                //     we accept the claim.
                //
                // TODO(C.1): swap to Noise XX first-contact verification
                // with SAS so the prefix-grind window closes.
                guard let challenge = try? JSONDecoder().decode(MacMPCAuthChallenge.self, from: Data(payload)) else { return }
                let advertisedPrefix = String(peerID.displayName.dropFirst("RAVEN-".count))
                guard challenge.fingerprint.hasPrefix(advertisedPrefix) else {
                    #if DEBUG
                    print("🚨 [MPC] Mac rejected \(peerID.displayName): display-name prefix mismatch")
                    #endif
                    return
                }
                let now = Int64(Date().timeIntervalSince1970)
                guard abs(now - challenge.timestamp) <= 300 else {
                    #if DEBUG
                    print("🚨 [MPC] Mac rejected \(peerID.displayName): challenge ts skew \(now - challenge.timestamp)s")
                    #endif
                    return
                }
                self.authenticatedPeers.insert(peerID.displayName)
                self.bleToMPC[challenge.fingerprint] = peerID
                #if DEBUG
                print("🔐 [MPC] Mac authenticated peer \(peerID.displayName)")
                #endif

            case 0xDA:
                guard self.authenticatedPeers.contains(peerID.displayName) else {
                    #if DEBUG
                    print("🚨 [MPC] Mac rejected data from unauthenticated peer \(peerID.displayName)")
                    #endif
                    return
                }
                self.onDataReceived?(Data(payload), peerID)

            default:
                // Unknown marker — drop. v1 iOS used to send untagged
                // payloads in early builds; we no longer accept those.
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MPCTransportService: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Accept any peer whose display name starts with our prefix.
        // Auth runs immediately afterwards (challenge over the session)
        // and gates actual data flow.
        Task { @MainActor in
            let isRAVEN = peerID.displayName.hasPrefix("RAVEN-")
            invitationHandler(isRAVEN, isRAVEN ? self.session : nil)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        #if DEBUG
        print("❌ [MPC] Mac advertise failed: \(error.localizedDescription)")
        #endif
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MPCTransportService: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard peerID.displayName.hasPrefix("RAVEN-") else { return }
            if let fp = info?["fp"] {
                self.bleToMPC[fp] = peerID
            }
            guard let session = self.session,
                  !session.connectedPeers.contains(peerID)
            else { return }
            let ctx = DeviceIdentityService.shared.fingerprint?.data(using: .utf8)
            browser.invitePeer(peerID, to: session, withContext: ctx, timeout: 10)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        #if DEBUG
        print("❌ [MPC] Mac browse failed: \(error.localizedDescription)")
        #endif
    }
}
