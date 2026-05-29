// MeshBridgeReceiver — picks up bridge envelopes the FastAPI server
// stashed on behalf of mesh-bridging devices.
//
// Sibling of `RAVEN-MacApp/RAVEN/Services/MeshBridgeReceiver.swift` —
// the Mac App Store edition shipped this drain-and-decrypt path first
// and we're porting it back to iOS so v1.6 devices can finally see the
// envelopes the bridge upload chain (now also fixed to hit
// `/api/mesh/bridge-envelope` instead of the stub `/api/gateway/relay`)
// is producing.
//
// Two drain paths:
//   1. On WebSocket (re)connect and on cold start, hit
//      `GET /api/mesh/pending-bridges?since=<lastSync>`. The server
//      returns up to 500 envelopes deposited inside the 24-hour
//      retention window. We dedup by `idempotency_key` against a small
//      on-disk set so we don't re-process across restarts.
//   2. When the inbox WebSocket pushes a `bridge_envelope` event
//      inline, `RealtimeEngine` calls `ingest(...)` directly. Same
//      dedup path.
//
// Decryption goes through the existing iOS crypto stack
// (`MeshCryptoService` + `DeviceIdentityService`) — we don't duplicate
// that here. The decrypted envelope is then handed to
// `RAVENApp.handleMeshMessage(_:)` — the same entry point the
// `BLEMeshEngine.onMessageReceived` callback fires when a verified
// envelope arrives over Bluetooth. That keeps persistence, ACK uplink,
// group routing, and `MeshMessageReceived` notification dispatch in a
// single place; we don't need to duplicate any of it here.
//
// Mac note: the AppKit sibling fans out via a dedicated
// `ravenMeshEnvelopeReceived` notification because its chat-store
// observer was wired before the unified ingest helper existed. iOS
// already has the helper, so we use it directly.

import Foundation
import os

fileprivate let logger = Logger(subsystem: "app.raven.ios", category: "Mesh.BridgeReceiver")

@MainActor
final class MeshBridgeReceiver: NSObject, ObservableObject {
    static let shared = MeshBridgeReceiver()

    /// On-disk dedup set (idempotency keys). Capped at 4k entries; we
    /// trim the oldest half when we exceed that to keep the file small.
    /// Survives sign-out — duplicate envelopes from before sign-out
    /// would just be ignored, which is the desired outcome.
    private var seenKeys: Set<String> = []
    private var keyOrder: [String] = []
    private let maxKeys = 4_000

    /// Last bridge sync timestamp — passed as `?since=` so we don't
    /// re-fetch the entire 24-hour window every reconnect.
    private var lastSyncAt: Date?

    private override init() {
        super.init()
        let url = Self.computeStoreURL()
        if let data = try? Data(contentsOf: url),
           let p = try? JSONDecoder().decode(Persisted.self, from: data) {
            self.keyOrder = p.keys
            self.seenKeys = Set(p.keys)
            self.lastSyncAt = p.lastSyncAt
        }
    }

    // MARK: - Public entry points

    /// Called from `RealtimeEngine.start()` and on every successful WS
    /// connect. Idempotent + cheap when there's nothing pending.
    func drainPendingBridges() async {
        do {
            let envelopes = try await NetworkService.shared.pendingBridges(since: lastSyncAt)
            var counter = 0
            for env in envelopes {
                if await ingest(
                    envelopeB64: env.envelopeB64,
                    idempotencyKey: env.idempotencyKey,
                    bridgedAt: env.bridgedAt
                ) {
                    counter += 1
                }
            }
            // Advance the watermark even when the batch was empty, so
            // a follow-up call doesn't re-scan the same retention slice.
            lastSyncAt = Date()
            persistToDisk()

            #if DEBUG
            if !envelopes.isEmpty {
                print("[mesh-bridge] drained \(envelopes.count) envelopes (\(counter) new)")
            }
            #endif
        } catch {
            #if DEBUG
            print("[mesh-bridge] drain failed: \(error)")
            #endif
        }
    }

    /// Record one envelope and run it through the local decrypt path.
    /// Returns `true` if it was new, `false` if we had already
    /// processed this idempotency key.
    @discardableResult
    func ingest(envelopeB64: String, idempotencyKey: String, bridgedAt: Date) async -> Bool {
        guard !seenKeys.contains(idempotencyKey) else { return false }
        seenKeys.insert(idempotencyKey)
        keyOrder.append(idempotencyKey)
        trimIfNeeded()
        lastSyncAt = max(lastSyncAt ?? .distantPast, bridgedAt)

        // Decrypt + verify, then fan out via the same notification the
        // BLE engine uses so existing observers (RealtimeEngine,
        // ConversationStore) don't need to know whether the envelope
        // arrived over BLE or via the bridge endpoint.
        await Self.decryptAndPublish(envelopeB64: envelopeB64, idempotencyKey: idempotencyKey)
        return true
    }

    func reset() {
        seenKeys.removeAll(keepingCapacity: false)
        keyOrder.removeAll(keepingCapacity: false)
        lastSyncAt = nil
        persistToDisk()
    }

    // MARK: - Crypto

    nonisolated private static func decryptAndPublish(envelopeB64: String, idempotencyKey: String) async {
        guard let envelopeData = Data(base64Encoded: envelopeB64) else {
            #if DEBUG
            print("[mesh-bridge] decrypt skip: not base64 (\(idempotencyKey))")
            #endif
            return
        }
        let payload: EncryptedMeshPayload
        do {
            payload = try JSONDecoder().decode(EncryptedMeshPayload.self, from: envelopeData)
        } catch {
            #if DEBUG
            print("[mesh-bridge] decrypt skip: payload decode failed — \(error)")
            #endif
            return
        }
        guard let peerKeyData = Data(base64Encoded: payload.senderPublicKey),
              let sharedKey = DeviceIdentityService.shared.deriveSharedSecret(with: peerKeyData)
        else {
            #if DEBUG
            print("[mesh-bridge] decrypt skip: shared-secret derivation failed (\(idempotencyKey))")
            #endif
            return
        }
        do {
            let secureEnv = try await MeshCryptoService.shared.decryptEnvelope(payload, sharedKey: sharedKey)
            let envelope = secureEnv.toMeshEnvelope()
            // Manual signature verify — iOS `MeshCryptoService.verifySignature`
            // is keyed on `SignedMeshPayload` (the legacy signed wrapper),
            // not on `EncryptedMeshPayload`. The Mac sibling calls
            // `DeviceIdentityService.verify` directly for this exact
            // reason; mirror that here. Match the BLE ingest path —
            // refuse to deliver an envelope that doesn't carry a valid
            // signature, otherwise a server compromise could inject
            // bogus payloads onto our chat surface.
            guard let sigStr = payload.signature,
                  let signerStr = payload.signerPublicKey,
                  let signature = Data(base64Encoded: sigStr),
                  let signerKey = Data(base64Encoded: signerStr),
                  DeviceIdentityService.shared.verify(
                      signature: signature,
                      data: secureEnv.signingData(),
                      publicKey: signerKey
                  )
            else {
                logger.debug("reject: signature missing or invalid (\(idempotencyKey, privacy: .private))")
                return
            }
            let preview = (envelope.text ?? "[non-text]").prefix(60)
            logger.debug("decrypted from \(envelope.senderName, privacy: .private): \(preview, privacy: .private)")
            // Cross-channel dedup: the same envelope can arrive once
            // over BLE (which records the `clientMessageId` in the
            // shared `MeshDedupRepository`) AND once via the bridge.
            // The `seenKeys` set we already check is keyed on the
            // BRIDGE idempotency key — useful for replay across server
            // restarts but doesn't catch the cross-channel duplicate.
            // Claim against the same repo BLE uses; on a hit, skip the
            // ingest so the user doesn't see two bubbles for one msg.
            let isNew = await MeshDedupRepository.shared.isNewMessage(id: envelope.clientMessageId)
            guard isNew else {
                logger.debug("cross-channel duplicate of \(envelope.clientMessageId, privacy: .private) — skipping")
                return
            }
            await MeshDedupRepository.shared.markProcessed(id: envelope.clientMessageId)

            // 🔴 ROUND 19 — hacker-audit Bridge F3 HIGH.
            // The shared ingest persists the (decrypted) body into
            // local SQLite. When the bridge device is NOT the
            // intended recipient — i.e. we're purely forwarding —
            // that means every transit message lands in our DB and
            // a future backup-extraction / jailbreak / lost-device
            // event exposes it. Branch on (recipient == me OR I'm
            // a member of the target group) and discard otherwise.
            let myId = await KeychainService.shared.getUserId() ?? ""
            let isForMe: Bool = {
                guard !myId.isEmpty else { return false }
                if envelope.recipientId == myId { return true }
                if envelope.senderId == myId { return true }   // own send arriving via bridge
                if envelope.isGroup == true {
                    // For groups we don't know membership cheaply
                    // here — fall through to the normal handler;
                    // the GroupKeyService.decrypt path already
                    // refuses to decrypt without the group key, so
                    // a non-member's row never ends up readable.
                    return true
                }
                return false
            }()
            guard isForMe else {
                logger.debug("dropping bridge-only message \(envelope.clientMessageId, privacy: .private) — recipient is not us; refusing local persistence to limit blast radius.")
                return
            }

            // Hand off to the same per-envelope ingest the BLE engine's
            // `onMessageReceived` callback uses — covers persistence,
            // group routing, group-key decryption, and ACK uplink. The
            // helper lives on `AppDelegate` (where the BLE callback is
            // wired in `start()`), not on the SwiftUI `App` struct.
            await AppDelegate.handleMeshMessage(envelope)
        } catch {
            #if DEBUG
            print("[mesh-bridge] decrypt failed (\(idempotencyKey)): \(error)")
            #endif
        }
    }

    // MARK: - Persistence

    private struct Persisted: Codable {
        var keys: [String]
        var lastSyncAt: Date?
    }

    private static func computeStoreURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("RAVEN", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mesh_bridge_seen.json")
    }

    private func persistToDisk() {
        let p = Persisted(keys: keyOrder, lastSyncAt: lastSyncAt)
        guard let data = try? JSONEncoder().encode(p) else { return }
        try? data.write(to: Self.computeStoreURL(), options: .atomic)
    }

    private func trimIfNeeded() {
        guard keyOrder.count > maxKeys else { return }
        let drop = keyOrder.count - (maxKeys / 2)
        let removed = keyOrder.prefix(drop)
        keyOrder.removeFirst(drop)
        for k in removed { seenKeys.remove(k) }
    }
}

// MARK: - NetworkService extension

extension NetworkService {
    /// Wire-compatible with the Mac App native build.
    /// `GET /api/mesh/pending-bridges?since=<iso>`.
    func pendingBridges(since: Date? = nil) async throws -> [PendingBridgeEnvelope] {
        struct Wrapper: Decodable {
            let envelopes: [PendingBridgeEnvelope]
        }
        var queryItems: [URLQueryItem] = []
        if let since {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            queryItems.append(URLQueryItem(name: "since", value: iso.string(from: since)))
        }
        let response: Wrapper = try await get(
            path: "/api/mesh/pending-bridges",
            queryItems: queryItems
        )
        return response.envelopes
    }
}

struct PendingBridgeEnvelope: Decodable {
    let idempotencyKey: String
    let envelopeB64: String
    let bridgedAt: Date

    enum CodingKeys: String, CodingKey {
        case idempotencyKey = "idempotency_key"
        case envelopeB64 = "envelope_b64"
        case bridgedAt = "bridged_at"
    }
}
