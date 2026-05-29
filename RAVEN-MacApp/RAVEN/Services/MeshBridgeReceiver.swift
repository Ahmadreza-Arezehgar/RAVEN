// MeshBridgeReceiver — picks up bridge envelopes the FastAPI server
// stashed on behalf of mesh-bridging devices (iPhones, Catalyst DMG,
// Windows native).
//
// The Mac App Store sandbox forbids BLE peripheral mode, so this build
// can never be a *bridge* — it cannot uplink envelopes itself. But it
// can absolutely be the *online recipient* the bridges target. Two
// drain paths:
//
//   1. On WebSocket (re)connect and on cold start, hit
//      `GET /api/mesh/pending-bridges?since=<lastSync>`. The server
//      returns up to 500 envelopes deposited inside the 24-hour
//      retention window. We dedup by `idempotency_key` against a small
//      on-disk set so we don't re-process across restarts.
//
//   2. When the inbox WebSocket pushes a `bridge_envelope` event
//      inline, `RealtimeEngine` calls `ingest(...)` directly. Same
//      dedup path.
//
// Decryption is intentionally NOT performed here. The opaque envelopes
// are end-to-end encrypted between iOS / Catalyst peers and the Mac
// App Store build doesn't ship the device-identity / mesh crypto stack
// (those live under `ios-native/RAVEN/RAVEN/Core/Mesh/`). What this
// receiver guarantees is:
//
//   • The server's bridge queue gets drained on every reconnect, so
//     envelopes don't expire unread inside the 24-hour retention window.
//   • Once we record an idempotency key as seen, we never re-process it.
//   • The chat list refreshes via `Notification.Name.ravenMeshBridgesDrained`
//     so any DM the server has since promoted out of the bridge queue
//     into a real `messages` row appears in the inbox.
//
// When the Mac client gains a crypto stack later, plug a real
// envelope-handler into `onEnvelope` and it'll be invoked once per
// freshly-seen envelope.

import Foundation
import os.log

private let bridgeLog = Logger(subsystem: "app.raven.macos", category: "mesh-bridge")

extension Notification.Name {
    /// Posted when `/api/mesh/pending-bridges` fails with anything
    /// other than an auth-expired error. UI can show a banner so the
    /// user knows envelopes may be stuck.
    static let ravenMeshBridgeDrainFailed = Notification.Name("raven.mesh.bridgeDrainFailed")
}

actor MeshBridgeReceiver {
    static let shared = MeshBridgeReceiver()

    /// Optional hook for a future crypto stack. Receives the opaque
    /// base64 envelope plus its idempotency key. Nil by default; today
    /// we just track the idempotency keys to keep dedup honest.
    var onEnvelope: ((_ envelopeB64: String, _ idempotencyKey: String) async -> Void)?

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

    private init() {
        // Load from disk synchronously inside the init so subsequent
        // calls already see the dedup set. Inlined (vs. calling a
        // separate actor-isolated method) so the actor's nonisolated
        // init doesn't trip the Swift 6 cross-isolation warning.
        let url = MeshBridgeReceiver.computeStoreURL()
        if let data = try? Data(contentsOf: url),
           let p = try? JSONDecoder().decode(Persisted.self, from: data) {
            self.keyOrder = p.keys
            self.seenKeys = Set(p.keys)
            self.lastSyncAt = p.lastSyncAt
        }
    }

    // MARK: - Public entry points (called from RealtimeEngine)

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
            // Advance the watermark using the freshest envelope's
            // server-stamped `bridgedAt` instead of the local `Date()`.
            // Previously we wrote `Date()` here, which made `?since=`
            // depend on the client clock — if the client lagged the
            // server clock the next drain re-fetched envelopes; if it
            // led, envelopes timestamped between client-now and the
            // actual server insert moment were silently skipped.
            // `ingest(...)` already updates `lastSyncAt` from each
            // envelope's `bridgedAt`, so we just persist what's there.
            // On an empty batch nothing moves — that's correct: the
            // next call should still cover the same retention slice.
            persistToDisk()

            // Snapshot into a let before the @Sendable closure so Swift 6
            // doesn't flag the var capture.
            let newCount = counter
            if newCount > 0 {
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .ravenMeshBridgesDrained,
                        object: nil,
                        userInfo: ["count": newCount]
                    )
                }
            }
            #if DEBUG
            if !envelopes.isEmpty {
                print("[mesh-bridge] drained \(envelopes.count) envelopes (\(newCount) new)")
            }
            #endif
        } catch APIError.authExpired {
            // Auth tear-down handled by AuthService — nothing to do.
            return
        } catch {
            // Use the unified logging system so the failure shows up
            // in Console.app + telemetry, and post a notification so
            // the chat list can surface a "bridge sync failed" banner.
            // Previously this only `print`ed in DEBUG, which made
            // production failures invisible until envelopes expired.
            bridgeLog.error("drain failed: \(error.localizedDescription, privacy: .public)")
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .ravenMeshBridgeDrainFailed,
                    object: nil,
                    userInfo: ["error": String(describing: error)]
                )
            }
        }
    }

    /// Record one envelope. Returns `true` if it was new, `false` if we
    /// had already processed this idempotency key. Safe to call many
    /// times for the same key.
    @discardableResult
    func ingest(envelopeB64: String, idempotencyKey: String, bridgedAt: Date) async -> Bool {
        guard !seenKeys.contains(idempotencyKey) else { return false }
        seenKeys.insert(idempotencyKey)
        keyOrder.append(idempotencyKey)
        trimIfNeeded()
        // Track the freshest envelope timestamp so the next
        // /pending-bridges call can use it as `since`.
        lastSyncAt = max(lastSyncAt ?? .distantPast, bridgedAt)
        if let handler = onEnvelope {
            await handler(envelopeB64, idempotencyKey)
        }
        return true
    }

    /// Wipe local state — called from `AuthService.signOut` so the next
    /// account doesn't inherit dedup keys.
    func reset() {
        seenKeys.removeAll(keepingCapacity: false)
        keyOrder.removeAll(keepingCapacity: false)
        lastSyncAt = nil
        persistToDisk()
    }

    // MARK: - Crypto wire-up

    /// Wire the default `onEnvelope` handler that runs each freshly-seen
    /// bridge envelope through the local crypto stack:
    ///
    ///   1. JSON-decode the opaque blob → `EncryptedMeshPayload`
    ///   2. X25519 ECDH against the carrier's `senderPublicKey`
    ///      → `SymmetricKey` (cached per-peer in `DeviceIdentityService`)
    ///   3. `MeshCryptoService.decryptEnvelope` — AES-256-GCM open
    ///   4. `MeshCryptoService.verifySignature` — Ed25519 verify
    ///   5. `Notification.Name.ravenMeshBridgeDecrypted` so any UI layer
    ///      that wants to surface the plaintext can observe it. Today
    ///      there is no chat-store insertion path on the App Store build
    ///      (messages are server-source-of-truth here), so the chat list
    ///      still relies on the existing `ravenMeshBridgesDrained` →
    ///      server refetch. The decrypted notification is the bridge
    ///      ready for a richer UI surface in a follow-up.
    ///
    /// Idempotent. Failures (decode / decrypt / verify) are logged in
    /// debug builds and otherwise dropped silently — a corrupt bridge
    /// envelope must never crash the receiver.
    ///
    /// Call once at app launch (after `DeviceIdentityService.initialize`
    /// has run, so the agreement private key is in cache).
    func attachDefaultDecryptHandler() {
        // Sendable-clean closure: only references global `shared` actors,
        // doesn't capture `self` (avoids re-entrant actor-hop noise).
        onEnvelope = { @Sendable envelopeB64, idempotencyKey in
            await Self.handleEnvelope(envelopeB64: envelopeB64, idempotencyKey: idempotencyKey)
        }
        #if DEBUG
        print("[mesh-bridge] crypto handler attached")
        #endif
    }

    /// Static so the actor's `onEnvelope` closure doesn't re-enter the
    /// actor for every decrypt — keeps drain throughput high when a
    /// reconnect dumps hundreds of queued envelopes at once.
    nonisolated private static func handleEnvelope(envelopeB64: String, idempotencyKey: String) async {
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
            let envelope = try await MeshCryptoService.shared.decryptEnvelope(payload, sharedKey: sharedKey)
            let signatureValid = await MeshCryptoService.shared.verifySignature(envelope: envelope, payload: payload)
            #if DEBUG
            let preview = (envelope.text ?? "[non-text]").prefix(60)
            print("📨 [mesh-bridge] decrypted from \(envelope.senderName) sig=\(signatureValid ? "✓" : "✗"): \(preview)")
            #endif

            // Snapshot before crossing the MainActor boundary; userInfo
            // requires Sendable values and the envelope itself is Codable
            // (good enough for cross-isolation transfer).
            let envCopy = envelope
            let valid = signatureValid
            let key = idempotencyKey
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .ravenMeshBridgeDecrypted,
                    object: nil,
                    userInfo: [
                        "envelope": envCopy,
                        "signatureValid": valid,
                        "idempotencyKey": key
                    ]
                )
            }
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

    private var storeURL: URL { Self.computeStoreURL() }

    /// Static so it can be called from the nonisolated init without
    /// a cross-actor hop. Always returns the same path.
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
        try? data.write(to: storeURL, options: .atomic)
    }

    private func trimIfNeeded() {
        guard keyOrder.count > maxKeys else { return }
        let drop = keyOrder.count - (maxKeys / 2)
        let removed = keyOrder.prefix(drop)
        keyOrder.removeFirst(drop)
        for k in removed { seenKeys.remove(k) }
    }
}
