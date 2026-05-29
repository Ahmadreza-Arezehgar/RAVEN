// BLEMeshEngine — peripheral-and-central BLE mesh for the macOS App
// Store edition.
//
// Wire-format compatible with the iOS / Catalyst RAVEN builds:
//
//   Service UUID         12345678-1234-1234-1234-123456789ABC
//   Message char (R/W/N) 12345678-1234-1234-1234-123456789ABD
//   Identity char (R)    12345678-1234-1234-1234-123456789ABE
//
// Packet framing identical to the iOS engine:
//
//   [isChunked: u8]
//     0 → payload follows directly
//     1 → [messageHash: u32 LE][totalChunks: u8][chunkIndex: u8][payload: …]
//
// The payload bytes are the JSON encoding of `EncryptedMeshPayload`,
// itself the AES-256-GCM ciphertext of `MeshEnvelope`. So an iPhone
// running the production app and a Mac running this build can swap
// envelopes byte-for-byte.
//
// What this Mac engine does NOT do (compared to the iOS reference):
//
//   • Background scanning / advertising — App Sandbox forbids it. The
//     mesh pauses when the app is hidden / quit. The FastAPI bridge
//     handles offline delivery via /api/mesh/pending-bridges.
//   • State restoration (CBCentralManagerOptionRestoreIdentifierKey is
//     incompatible with the App Sandbox).
//   • Spray-and-wait routing / mule service / gateway / geo fence.
//     This build acts as a *leaf* — it sends and receives but doesn't
//     relay other peers' envelopes onward.
//   • Multi-peer connectivity layer (MPCTransportService) for large
//     payloads. Anything that doesn't fit in BLE chunked transfer
//     falls back to the FastAPI server.
//
// This is enough to interop with iPhones in the same room: the Mac
// can deliver and receive E2E-encrypted DMs over BLE when the WS is
// unreachable, which is exactly the user-visible "mesh works" promise.

import Foundation
// `@preconcurrency` because CoreBluetooth's CBPeripheral / CBCentral /
// CBATTRequest are reference types that Apple hasn't yet annotated
// Sendable, but are de-facto safe to send between the BLE delegate
// queue and the MainActor (Apple's own samples do exactly this). The
// import attribute silences Swift 6's data-race warnings without
// changing behavior.
@preconcurrency import CoreBluetooth
import CryptoKit

@MainActor
final class BLEMeshEngine: NSObject, ObservableObject {
    static let shared = BLEMeshEngine()

    // MARK: - Wire UUIDs (match iOS)

    // `nonisolated` so the `nonisolated` Core Bluetooth delegate methods
    // can read these static UUIDs without an actor hop. They're constants
    // so no race possible.
    nonisolated static let serviceUUID = CBUUID(string: "12345678-1234-1234-1234-123456789ABC")
    nonisolated static let messageCharacteristicUUID = CBUUID(string: "12345678-1234-1234-1234-123456789ABD")
    nonisolated static let deviceInfoCharacteristicUUID = CBUUID(string: "12345678-1234-1234-1234-123456789ABE")

    // MARK: - Published state

    @Published private(set) var isAdvertising: Bool = false
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var bluetoothState: CBManagerState = .unknown
    @Published private(set) var connectedPeers: [MeshPeer] = []

    // MARK: - Core Bluetooth

    private var centralManager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var messageCharacteristic: CBMutableCharacteristic?
    private var deviceInfoCharacteristic: CBMutableCharacteristic?

    /// v2 message TX/RX — published alongside the v1 service. v2 envelopes
    /// flow over THIS characteristic (binary, RUMProtocolV2 wire format)
    /// while v1 keeps using `messageCharacteristic` (JSON). Two separate
    /// channels means receivers don't have to byte-peek to disambiguate.
    private var v2MessageCharacteristic: CBMutableCharacteristic?

    /// v2 capabilities — read-only, value is a 4-byte big-endian uint32
    /// `RUMProtocolV2.Capabilities` bitfield. Lets peers learn which
    /// transports we support before deciding which protocol to speak.
    private var v2CapabilitiesCharacteristic: CBMutableCharacteristic?

    /// Connected peripherals keyed by their identifier UUID.
    private var connectedPeripherals: [UUID: CBPeripheral] = [:]
    private var peripheralFingerprints: [UUID: String] = [:]
    private var peripheralAgreementKeys: [UUID: Data] = [:]

    /// Per-peer capability bitfields, populated when we read their
    /// `RUMProtocolV2.capabilitiesCharacteristicUUID` after connection.
    /// Empty entry → peer didn't expose the v2 service → v1-only.
    private var peerCapabilities: [UUID: RUMProtocolV2.Capabilities] = [:]

    /// Centrals subscribed to our message characteristic, used by the
    /// peripheral-side outbound path.
    private var subscribedCentrals: [CBCentral] = []

    // MARK: - Reassembly

    /// Pending chunk reassembly buffers keyed by `<deviceId>-<hash>`.
    private var pendingChunks: [String: [Int: Data]] = [:]
    private var pendingChunksMeta: [String: (total: Int, receivedAt: Date)] = [:]
    private static let headerSize = 6
    private static let maxTotalChunks = 255
    private static let maxPendingHashKeys = 64

    // MARK: - Outbound

    /// Currently in-flight broadcast tasks. Bounded so we don't leak.
    private var inFlightBroadcasts = 0
    private let maxInFlightBroadcasts = 16

    // MARK: - Lifecycle

    private override init() {
        super.init()
    }

    /// Spin up Core Bluetooth. Idempotent — calling twice is a no-op.
    func start() {
        // Subscribe the relay service to v2 envelope arrivals so multi-
        // hop forwarding works the moment we have any peers. Idempotent.
        RUMRelayService.shared.start()

        // Start the MultipeerConnectivity transport — Apple-only fast
        // path, ~250 Mbps over Wi-Fi vs BLE's ~50 kbps. Bonjour
        // service discovery requires `NSBonjourServices` in Info.plist
        // and the local-network entitlement (already configured).
        //
        // CRITICAL: must AWAIT `DeviceIdentityService.initialize()` before
        // reading `fingerprint`. The previous fire-and-forget version
        // raced against the keychain load, fell through to the literal
        // `"unknown"` placeholder, and advertised as `RAVEN-unknown`.
        // The iPhone could discover us, but the Ed25519 auth challenge
        // it sent contained the iPhone's real fingerprint — which never
        // has prefix `"unknown"` — so `MPCTransportService` rejected
        // every payload as "unauthenticated peer" and Mesh never moved
        // a single byte between Mac App Store + iPhone.
        // The fix: serialize identity init → MPC start in one Task.
        Task { @MainActor in
            try? await DeviceIdentityService.shared.initialize()
            guard let fp = DeviceIdentityService.shared.fingerprint else {
                #if DEBUG
                print("⚠️ [Mesh] Skipping MPC start — fingerprint unavailable after initialize()")
                #endif
                return
            }
            MPCTransportService.shared.start(deviceFingerprint: fp)

            // Route incoming MPC payloads — v1 JSON (`{` = 0x7B) → the
            // existing v1 chat ingest; v2 binary (byte 0 == 0x02) →
            // `handleV2EnvelopePayload`, which posts the diagnostic
            // notification (RUMRelayService listens), folds the inner
            // ciphertext back into the v1 ingest path when encrypted,
            // and emits STOP gossip when the envelope is for us.
            MPCTransportService.shared.onDataReceived = { [weak self] data, peer in
                guard let self else { return }
                let deviceId = peer.displayName
                Task { @MainActor in
                    if data.first == RUMProtocolV2.version {
                        self.handleV2EnvelopePayload(data, from: deviceId)
                    } else {
                        self.handleAssembledPayload(data, from: deviceId)
                    }
                }
            }
        }

        if centralManager == nil {
            // App Sandbox can't restore BLE state across launches, so we
            // skip the restoration identifier. Background scanning is
            // not allowed either; we stop on app hide.
            centralManager = CBCentralManager(
                delegate: self,
                queue: DispatchQueue(label: "app.raven.macos.ble.central", qos: .userInitiated),
                options: [CBCentralManagerOptionShowPowerAlertKey: false]
            )
        }
        if peripheralManager == nil {
            peripheralManager = CBPeripheralManager(
                delegate: self,
                queue: DispatchQueue(label: "app.raven.macos.ble.peripheral", qos: .userInitiated),
                options: [CBPeripheralManagerOptionShowPowerAlertKey: false]
            )
        }
    }

    /// Stop scanning, advertising, and tear down all connections.
    func stop() {
        RUMRelayService.shared.stop()
        Task { @MainActor in MPCTransportService.shared.stop() }
        if isScanning {
            centralManager?.stopScan()
            isScanning = false
        }
        if isAdvertising {
            peripheralManager?.stopAdvertising()
            isAdvertising = false
        }
        for (_, peripheral) in connectedPeripherals {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        connectedPeripherals.removeAll()
        peripheralFingerprints.removeAll()
        peripheralAgreementKeys.removeAll()
        peerCapabilities.removeAll()
        subscribedCentrals.removeAll()
        pendingChunks.removeAll()
        pendingChunksMeta.removeAll()
        rebuildConnectedPeers()
    }

    /// Parse a 4-byte big-endian uint32 from the v2 capabilities
    /// characteristic. Returns an empty set if `data` is shorter.
    private func parseCapabilities(_ data: Data) -> RUMProtocolV2.Capabilities {
        guard data.count >= 4 else { return [] }
        let base = data.startIndex
        let raw =
            (UInt32(data[base    ]) << 24) |
            (UInt32(data[base + 1]) << 16) |
            (UInt32(data[base + 2]) <<  8) |
             UInt32(data[base + 3])
        return RUMProtocolV2.Capabilities(rawValue: raw)
    }

    // MARK: - Public API

    /// Send a 1:1 chat envelope to nearby peers. The recipient discovers
    /// the envelope via BLE, decrypts with the shared ECDH secret, and
    /// surfaces it as a regular Message via `ravenInboxMessagesReceived`.
    /// Best-effort — returns silently if no peer is reachable.
    @discardableResult
    func broadcastChat(_ envelope: MeshEnvelope) async -> Bool {
        guard !connectedPeripherals.isEmpty || !subscribedCentrals.isEmpty else {
            return false
        }
        // Per-peer protocol selection (C.1.d):
        //
        //   1. v1-only peer        → legacy JSON ciphertext (unchanged)
        //   2. v2-capable, no Noise session yet
        //                          → v2 envelope, type=noiseHandshake1,
        //                            v1 ciphertext rides inside M1 for
        //                            1-RTT delivery
        //   3. v2-capable, session established
        //                          → v2 envelope, flags.noiseTransport
        //                            wraps the v1 ciphertext in
        //                            Noise transport-mode AEAD, giving
        //                            forward secrecy that the
        //                            constant-salt AES-GCM path lacks
        //
        // The inner v1 ciphertext stays a v1 ciphertext for now; that
        // keeps receive-side ingest unchanged (Noise decrypt → existing
        // `handleAssembledPayload` → AES-GCM decrypt). Phase C.1.e
        // drops the inner AES-GCM once every shipping client speaks
        // Noise transport mode.
        var sent = false
        for (uuid, peripheral) in connectedPeripherals {
            guard let agreementKey = peripheralAgreementKeys[uuid] else { continue }
            guard let payloadCipher = encryptEnvelope(envelope, to: agreementKey) else { continue }

            let caps = peerCapabilities[uuid] ?? []
            if caps.contains(.v2Protocol) {
                let peerPID = RUMProtocolV2.peerID(fromPublicKey: agreementKey)
                if NoiseSessionStore.shared.hasSession(for: peerPID),
                   let v2Bytes = encodeV2NoiseTransportFrame(
                       envelope: envelope,
                       payloadCipher: payloadCipher,
                       peerPID: peerPID
                   ) {
                    await sendDataChunkedToPeer(
                        v2Bytes,
                        peripheral: peripheral,
                        serviceUUID: RUMProtocolV2.serviceUUID,
                        characteristicUUID: RUMProtocolV2.messageCharacteristicUUID
                    )
                    sent = true
                    continue
                }
                if let v2Bytes = encodeV2NoiseHandshake1Frame(
                    envelope: envelope,
                    payloadCipher: payloadCipher,
                    peerAgreementKey: agreementKey
                ) {
                    await sendDataChunkedToPeer(
                        v2Bytes,
                        peripheral: peripheral,
                        serviceUUID: RUMProtocolV2.serviceUUID,
                        characteristicUUID: RUMProtocolV2.messageCharacteristicUUID
                    )
                    sent = true
                    continue
                }
                // Noise paths failed (missing identity key, bad peer
                // pubkey, etc.) — fall through to the legacy v2 frame
                // that just carries the v1 ciphertext as `.encrypted`.
                if let v2Bytes = encodeV2Frame(
                    envelope: envelope,
                    payloadCipher: payloadCipher,
                    peerAgreementKey: agreementKey
                ) {
                    await sendDataChunkedToPeer(
                        v2Bytes,
                        peripheral: peripheral,
                        serviceUUID: RUMProtocolV2.serviceUUID,
                        characteristicUUID: RUMProtocolV2.messageCharacteristicUUID
                    )
                    sent = true
                    continue
                }
            }
            await sendDataChunkedToPeer(payloadCipher, peripheral: peripheral)
            sent = true
        }
        return sent
    }

    /// Wrap an outbound envelope in a v2 frame encrypted with the
    /// cached Noise transport-mode key for `peerPID`. AD = the
    /// envelope's `msg_id` so a replay against a different envelope
    /// fails the AEAD verify cleanly.
    ///
    /// Two shapes depending on `RUMProtocolV2.preferNoiseNativeTransport`:
    ///
    ///   • **Native (C.1.f)** — sign the bare `MeshEnvelope`, JSON
    ///     it, and hand straight to Noise. Sets only
    ///     `.noiseTransport` (NOT `.encrypted`). Drops the inner
    ///     AES-GCM layer entirely → ~20–30 B/envelope smaller +
    ///     fewer crypto round-trips.
    ///
    ///   • **Hybrid (C.1.d)** — wrap the existing v1 AES-GCM
    ///     ciphertext (`payloadCipher`) in Noise. Sets BOTH
    ///     `.encrypted` and `.noiseTransport` so receivers run the
    ///     v1 AES-GCM unwrap on the Noise-decrypted bytes.
    ///
    /// Receivers process both via `handleInboundNoiseTransport`,
    /// which branches on `flags.encrypted` to pick the right
    /// downstream ingest. A flip of `preferNoiseNativeTransport`
    /// back to false stays interoperable with peers that already
    /// got native frames.
    private func encodeV2NoiseTransportFrame(
        envelope: MeshEnvelope,
        payloadCipher: Data,
        peerPID: Data
    ) -> Data? {
        guard let myAgreement = DeviceIdentityService.shared.agreementPublicKeyData else { return nil }
        guard let msgID = uuidStringToBytes(envelope.clientMessageId) else { return nil }

        let plaintextForNoise: Data
        let frameFlags: RUMProtocolV2.Flags

        if RUMProtocolV2.preferNoiseNativeTransport {
            // Native path — sign the bare envelope, JSON-encode, hand
            // straight to Noise. The signature lives on the envelope
            // itself so the receive-side `handleNoiseNativeEnvelopeBytes`
            // can verify before posting to chat ingest.
            var signed = envelope
            if let sig = DeviceIdentityService.shared.sign(envelope.signingData()) {
                signed.originalSignature = sig.base64EncodedString()
                signed.originalSignerPublicKey = DeviceIdentityService.shared.publicKeyBase64
            }
            guard let json = try? JSONEncoder().encode(signed) else { return nil }
            plaintextForNoise = json
            frameFlags = [.noiseTransport, .needsForwarding]
        } else {
            // Hybrid path — Noise wraps the existing v1 ciphertext.
            plaintextForNoise = payloadCipher
            frameFlags = [.encrypted, .noiseTransport, .needsForwarding]
        }

        guard let noiseCT = NoiseSessionStore.shared.encrypt(
            plaintextForNoise,
            ad: msgID,
            forPeer: peerPID
        ) else { return nil }

        let mySenderPID = RUMProtocolV2.peerID(fromPublicKey: myAgreement)
        let v2 = RUMProtocolV2.Envelope(
            type: .text,
            ttl: RUMProtocolV2.defaultTTL,
            flags: frameFlags,
            timestamp: UInt32(clamping: Int(Date().timeIntervalSince1970)),
            msgID: msgID,
            senderPID: mySenderPID,
            destPID: peerPID,
            hopCount: UInt8(min(255, max(0, envelope.hopCount))),
            sprayRemaining: RUMProtocolV2.defaultSprayCopies,
            payload: noiseCT,
            signature: nil
        )
        do {
            let encoded = try RUMProtocolV2.encode(v2)
            return RUMProtocolV2.pad(encoded)
        } catch {
            return nil
        }
    }

    /// Build a v2 envelope of `type=noiseHandshake1` that bundles the
    /// v1 ciphertext as the embedded M1 payload. The receiver will
    /// process M1 (establishing transport keys), decrypt the embedded
    /// payload, and emit M2 back. From there, future sends go via
    /// `encodeV2NoiseTransportFrame` — no extra round-trip.
    private func encodeV2NoiseHandshake1Frame(
        envelope: MeshEnvelope,
        payloadCipher: Data,
        peerAgreementKey: Data
    ) -> Data? {
        guard let myAgreement = DeviceIdentityService.shared.agreementPublicKeyData else { return nil }
        guard let msgID = uuidStringToBytes(envelope.clientMessageId) else { return nil }
        let peerPubKey: Curve25519.KeyAgreement.PublicKey
        do {
            peerPubKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerAgreementKey)
        } catch {
            return nil
        }

        let m1Bytes: Data
        let peerPID: Data
        do {
            let result = try NoiseSessionStore.shared.startHandshake(
                toPeer: peerPubKey,
                payload: payloadCipher
            )
            m1Bytes = result.message1
            peerPID = result.peerID
        } catch {
            return nil
        }

        let mySenderPID = RUMProtocolV2.peerID(fromPublicKey: myAgreement)
        let v2 = RUMProtocolV2.Envelope(
            type: .noiseHandshake1,
            ttl: RUMProtocolV2.defaultTTL,
            flags: [.needsForwarding],
            timestamp: UInt32(clamping: Int(Date().timeIntervalSince1970)),
            msgID: msgID,
            senderPID: mySenderPID,
            destPID: peerPID,
            hopCount: UInt8(min(255, max(0, envelope.hopCount))),
            sprayRemaining: RUMProtocolV2.defaultSprayCopies,
            payload: m1Bytes,
            signature: nil
        )
        do {
            let encoded = try RUMProtocolV2.encode(v2)
            return RUMProtocolV2.pad(encoded)
        } catch {
            return nil
        }
    }

    /// Currently-connected peers, exposed for chat UI / debug overlays.
    func getConnectedPeers() -> [MeshPeer] { connectedPeers }

    /// Forward an already-encoded v2 envelope to every v2-capable peer
    /// currently connected, except the one named in `except` (so we
    /// don't echo it straight back to whoever just gave it to us).
    /// Used by `RUMRelayService` for multi-hop spray — the payload is
    /// the inner AES-GCM ciphertext addressed to the original recipient,
    /// so a relay device cannot read what it forwards.
    ///
    /// Fans out over BOTH transports:
    ///   1. **BLE** — every v2-capable connected peripheral.
    ///   2. **MPC** — every authenticated MultipeerConnectivity peer
    ///      (~250 Mbps vs. BLE's ~50 kbps). Receivers dedup via the
    ///      relay-service bloom filter on `msg_id`, so cross-transport
    ///      duplicates collapse cleanly.
    func relayV2EnvelopeBytesToAllPeers(_ bytes: Data, except sourceDeviceId: String) async {
        for (uuid, peripheral) in connectedPeripherals {
            if uuid.uuidString == sourceDeviceId { continue }
            let caps = peerCapabilities[uuid] ?? []
            guard caps.contains(.v2Protocol) else { continue }
            await sendDataChunkedToPeer(
                bytes,
                peripheral: peripheral,
                serviceUUID: RUMProtocolV2.serviceUUID,
                characteristicUUID: RUMProtocolV2.messageCharacteristicUUID
            )
        }

        // MPC fan-out — only authenticated peers; the service throws
        // for unauthenticated, which we swallow. `connectedPeerIds` is
        // read once here, so a peer disconnecting mid-loop just makes
        // the corresponding send throw and we move on.
        for mpcPeer in MPCTransportService.shared.connectedPeerIds {
            if mpcPeer.displayName == sourceDeviceId { continue }
            do {
                try MPCTransportService.shared.sendBulkData(bytes, to: mpcPeer)
            } catch {
                #if DEBUG
                print("[mesh-v2-relay] mac mpc send to \(mpcPeer.displayName) failed: \(error)")
                #endif
            }
        }
    }

    // MARK: - V2 framing

    /// Wrap a v1 `MeshEnvelope` (already encrypted by `encryptEnvelope`)
    /// in a v2 binary envelope. The v1 ciphertext goes straight into
    /// `payload` with the `encrypted` flag set. The receiver decodes
    /// the v2 frame, then runs the v1 decrypt on the inner bytes — so
    /// existing chat ingest just works.
    private func encodeV2Frame(
        envelope: MeshEnvelope,
        payloadCipher: Data,
        peerAgreementKey: Data
    ) -> Data? {
        guard let myAgreement = DeviceIdentityService.shared.agreementPublicKeyData else {
            return nil
        }
        let mySenderPID = RUMProtocolV2.peerID(fromPublicKey: myAgreement)
        let destPID     = RUMProtocolV2.peerID(fromPublicKey: peerAgreementKey)
        guard let msgID = uuidStringToBytes(envelope.clientMessageId) else {
            return nil
        }
        let v2 = RUMProtocolV2.Envelope(
            type: .text,
            ttl: RUMProtocolV2.defaultTTL,
            flags: [.encrypted, .needsForwarding],
            timestamp: UInt32(clamping: Int(Date().timeIntervalSince1970)),
            msgID: msgID,
            senderPID: mySenderPID,
            destPID: destPID,
            hopCount: UInt8(min(255, max(0, envelope.hopCount))),
            sprayRemaining: RUMProtocolV2.defaultSprayCopies,
            payload: payloadCipher,
            signature: nil
        )
        do {
            let encoded = try RUMProtocolV2.encode(v2)
            return RUMProtocolV2.pad(encoded)
        } catch {
            #if DEBUG
            print("[mesh-v2] encode failed: \(error)")
            #endif
            return nil
        }
    }

    /// Convert a "12345678-1234-1234-1234-123456789ABC" UUID string into
    /// the 16 raw bytes the v2 envelope's `msg_id` field expects.
    private func uuidStringToBytes(_ s: String) -> Data? {
        guard let u = UUID(uuidString: s) else { return nil }
        let t = u.uuid
        return Data([
            t.0,  t.1,  t.2,  t.3,  t.4,  t.5,  t.6,  t.7,
            t.8,  t.9,  t.10, t.11, t.12, t.13, t.14, t.15
        ])
    }

    // MARK: - Encryption helpers

    /// AES-GCM-encrypt `envelope` to JSON bytes ready for chunked send.
    private func encryptEnvelope(_ envelope: MeshEnvelope, to peerAgreementKey: Data) -> Data? {
        guard let symmetric = DeviceIdentityService.shared.deriveSharedSecret(with: peerAgreementKey) else {
            return nil
        }
        do {
            let payload = try await_encrypt(envelope: envelope, key: symmetric)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return try encoder.encode(payload)
        } catch {
            #if DEBUG
            print("[mesh] encrypt failed: \(error)")
            #endif
            return nil
        }
    }

    /// Synchronous wrapper around the actor — we don't need the actor
    /// hop semantics here, just AES.GCM.seal which is safe to call from
    /// any thread. We use an inline synchronous helper to avoid yielding
    /// the BLE queue.
    private func await_encrypt(envelope: MeshEnvelope, key: SymmetricKey) throws -> EncryptedMeshPayload {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let plaintext = try encoder.encode(envelope)

        var nonceBytes = [UInt8](repeating: 0, count: 12)
        guard SecRandomCopyBytes(kSecRandomDefault, 12, &nonceBytes) == errSecSuccess else {
            throw MeshError.encryptionFailed
        }
        let nonce = try AES.GCM.Nonce(data: Data(nonceBytes))
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        guard let ciphertext = sealed.combined else { throw MeshError.encryptionFailed }

        let signingData = envelope.signingData()
        let signature = DeviceIdentityService.shared.sign(signingData)

        return EncryptedMeshPayload(
            ciphertext: ciphertext.base64EncodedString(),
            nonce: Data(nonceBytes).base64EncodedString(),
            senderPublicKey: DeviceIdentityService.shared.agreementPublicKeyBase64 ?? "",
            version: 1,
            signature: signature?.base64EncodedString(),
            signerPublicKey: DeviceIdentityService.shared.publicKeyBase64
        )
    }

    /// Decrypt an incoming JSON-encoded `EncryptedMeshPayload` blob.
    private func decryptIncoming(_ data: Data) -> MeshEnvelope? {
        guard let payload = try? JSONDecoder().decode(EncryptedMeshPayload.self, from: data),
              let peerAgreement = Data(base64Encoded: payload.senderPublicKey),
              let sharedKey = DeviceIdentityService.shared.deriveSharedSecret(with: peerAgreement),
              let ciphertext = Data(base64Encoded: payload.ciphertext)
        else {
            return nil
        }
        do {
            let sealed = try AES.GCM.SealedBox(combined: ciphertext)
            let plaintext = try AES.GCM.open(sealed, using: sharedKey)
            let envelope = try JSONDecoder().decode(MeshEnvelope.self, from: plaintext)
            // Verify signature if present — drop forgeries.
            if let sigStr = payload.signature,
               let signerStr = payload.signerPublicKey,
               let sig = Data(base64Encoded: sigStr),
               let pk = Data(base64Encoded: signerStr) {
                let valid = DeviceIdentityService.shared.verify(
                    signature: sig,
                    data: envelope.signingData(),
                    publicKey: pk
                )
                guard valid else {
                    #if DEBUG
                    print("[mesh] signature verification failed")
                    #endif
                    return nil
                }
            }
            return envelope
        } catch {
            #if DEBUG
            print("[mesh] decrypt failed: \(error)")
            #endif
            return nil
        }
    }

    // MARK: - Chunked send

    /// Chunked write to one peer. The service + characteristic UUIDs are
    /// parameterized so the same chunk framer handles v1 and v2 traffic
    /// — v1 callers use the defaults; the v2 path passes the v2 service
    /// + message characteristic UUIDs.
    private func sendDataChunkedToPeer(
        _ data: Data,
        peripheral: CBPeripheral,
        serviceUUID: CBUUID = BLEMeshEngine.serviceUUID,
        characteristicUUID: CBUUID = BLEMeshEngine.messageCharacteristicUUID
    ) async {
        guard let services = peripheral.services,
              let service = services.first(where: { $0.uuid == serviceUUID }),
              let chars = service.characteristics,
              let char = chars.first(where: { $0.uuid == characteristicUUID })
        else { return }

        let maxWrite = peripheral.maximumWriteValueLength(for: .withoutResponse)
        let maxDataPerPacket = max(maxWrite - Self.headerSize - 1, 20)

        if data.count <= maxDataPerPacket {
            var packet = Data([0])
            packet.append(data)
            peripheral.writeValue(packet, for: char, type: .withoutResponse)
            return
        }

        let chunks = splitIntoChunks(data, payloadSize: maxDataPerPacket)
        guard chunks.count <= Self.maxTotalChunks else { return }
        let messageHash = UInt32(truncatingIfNeeded: data.hashValue).littleEndian

        for (idx, chunk) in chunks.enumerated() {
            guard peripheral.state == .connected else { break }
            var packet = Data([1])
            withUnsafeBytes(of: messageHash) { packet.append(contentsOf: $0) }
            packet.append(UInt8(chunks.count))
            packet.append(UInt8(idx))
            packet.append(chunk)
            peripheral.writeValue(packet, for: char, type: .withoutResponse)
            // Pace the send loop so CoreBluetooth's XPC queue doesn't
            // overflow — same 15 ms gap the iOS engine uses.
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    private func splitIntoChunks(_ data: Data, payloadSize: Int) -> [Data] {
        let effective = max(payloadSize, 10)
        var out: [Data] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + effective, data.count)
            out.append(data.subdata(in: offset..<end))
            offset = end
        }
        return out
    }

    // MARK: - Chunk reassembly

    private func processIncomingPacket(_ packet: Data, from deviceId: String) -> Data? {
        guard packet.count > 1 else { return nil }
        let isChunked = packet[packet.startIndex] == 1
        let payload = packet.dropFirst()
        if !isChunked { return Data(payload) }
        return reassembleChunk(Data(payload), from: deviceId)
    }

    private func reassembleChunk(_ packet: Data, from deviceId: String) -> Data? {
        guard packet.count >= Self.headerSize else { return nil }
        let hashBytes = Array(packet[packet.startIndex..<packet.startIndex.advanced(by: 4)])
        let messageHash = hashBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let totalChunks = Int(packet[packet.startIndex.advanced(by: 4)])
        let chunkIndex = Int(packet[packet.startIndex.advanced(by: 5)])
        let chunkData = packet.dropFirst(Self.headerSize)

        guard totalChunks > 0, totalChunks <= Self.maxTotalChunks else { return nil }
        let key = "\(deviceId)-\(messageHash)"

        if pendingChunks[key] == nil {
            if pendingChunks.count >= Self.maxPendingHashKeys,
               let oldest = pendingChunksMeta.min(by: { $0.value.receivedAt < $1.value.receivedAt }) {
                pendingChunks.removeValue(forKey: oldest.key)
                pendingChunksMeta.removeValue(forKey: oldest.key)
            }
            pendingChunks[key] = [:]
            pendingChunksMeta[key] = (total: totalChunks, receivedAt: Date())
        }
        pendingChunks[key]?[chunkIndex] = Data(chunkData)
        guard pendingChunks[key]?.count == totalChunks else { return nil }

        var assembled = Data()
        for i in 0..<totalChunks {
            guard let c = pendingChunks[key]?[i] else {
                pendingChunks.removeValue(forKey: key)
                pendingChunksMeta.removeValue(forKey: key)
                return nil
            }
            assembled.append(c)
        }
        pendingChunks.removeValue(forKey: key)
        pendingChunksMeta.removeValue(forKey: key)
        return assembled
    }

    // MARK: - Inbound dispatch

    /// Process a fully-reassembled blob from `deviceId`, decrypt, and
    /// forward to chat listeners.
    private func handleAssembledPayload(_ data: Data, from deviceId: String) {
        // 🔵 Bluetooth-login fallback (2026-05-09): if the inbound
        // bytes are a plain-JSON login envelope (Phase 1 approval
        // OR Phase 2 token forward), peek the discriminator BEFORE
        // the encrypted-chat decrypt pipeline. The Phase-1 approval
        // envelopes are intentionally unencrypted at the BLE layer —
        // they're already signed by the phone's identity key and the
        // desktop only acts on them while its QR sheet is open + only
        // for the matching session id. The Phase-2 token envelopes
        // ARE end-to-end encrypted (ECDH + AES-GCM under the
        // desktop's X25519 pubkey carried in the QR), so the JWT is
        // never visible on the wire. See `docs/BLUETOOTH-LOGIN.md`
        // for the full threat model.
        if let kindOnly = try? JSONDecoder().decode(KindOnly.self, from: data) {
            switch kindOnly.k {
            case "raven.login.approval.v1":
                handleLoginApprovalPayload(data, from: deviceId)
                return
            case "raven.login.token.v1":
                handleLoginTokenPayload(data, from: deviceId)
                return
            default:
                break
            }
        }

        guard let envelope = decryptIncoming(data) else { return }
        Task {
            // Dedup
            guard await MeshDedupRepository.shared.isNewMessage(id: envelope.clientMessageId) else {
                return
            }
            await MeshDedupRepository.shared.markProcessed(id: envelope.clientMessageId)
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .ravenMeshEnvelopeReceived,
                    object: nil,
                    userInfo: ["envelope": envelope, "peerDeviceId": deviceId]
                )
            }
        }
    }

    /// Tiny shape for the discriminator peek. Kept private so the
    /// general `JSONDecoder` path can't accidentally key off it.
    private struct KindOnly: Decodable { let k: String }

    /// Decode + signature-verify a `MeshLoginApprovalEnvelope`. On
    /// success, post a notification that `AuthLandingView`'s QR sheet
    /// observes — the sheet then calls `AuthService.completeBluetoothLogin(_:)`.
    /// Bad signature or stale timestamp → silent drop (don't leak
    /// "we saw your envelope" to mesh peers).
    private func handleLoginApprovalPayload(_ data: Data, from deviceId: String) {
        guard let env = try? JSONDecoder().decode(MeshLoginApprovalEnvelope.self, from: data) else {
            return
        }

        // Bound replay — accept only envelopes ≤ 5 minutes old.
        let now = Int(Date().timeIntervalSince1970)
        guard abs(now - env.timestamp) <= 300 else {
            #if DEBUG
            print("🔵 [BLE-Login] dropping stale envelope (Δt=\(now - env.timestamp)s)")
            #endif
            return
        }

        // Verify the phone's signature against the pubkey it embedded.
        guard let pubBytes = Data(base64Encoded: env.phonePublicKey),
              let sigBytes = Data(base64Encoded: env.signature) else { return }
        let signed = MeshLoginApprovalEnvelope.signedPayload(
            sessionId: env.sessionId, userId: env.userId, timestamp: env.timestamp
        )
        do {
            let pub = try Curve25519.Signing.PublicKey(rawRepresentation: pubBytes)
            guard pub.isValidSignature(sigBytes, for: signed) else {
                #if DEBUG
                print("🔵 [BLE-Login] signature invalid for sid=\(env.sessionId.prefix(8))")
                #endif
                return
            }
        } catch {
            return
        }

        #if DEBUG
        print("🔵 [BLE-Login] valid envelope for sid=\(env.sessionId.prefix(8)) user=\(env.username)")
        #endif

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .ravenBluetoothLoginApproved,
                object: nil,
                userInfo: [
                    "envelope": env,
                    "peerDeviceId": deviceId
                ]
            )
        }
    }

    /// Phase-2 receiver: decrypt a `MeshLoginTokenEnvelope` with our
    /// X25519 private key, recover the JWT, fire a notification the
    /// QR sheet observes. On success, the desktop ends up with a
    /// **real server-grade session** (full feature set) — not the
    /// mesh-only session of Phase 1.
    private func handleLoginTokenPayload(_ data: Data, from deviceId: String) {
        guard let env = try? JSONDecoder().decode(MeshLoginTokenEnvelope.self, from: data) else {
            return
        }
        // Bound replay — same 5-min window as Phase 1.
        let now = Int(Date().timeIntervalSince1970)
        guard abs(now - env.timestamp) <= 300 else {
            #if DEBUG
            print("🔵 [BLE-Login] dropping stale token envelope (Δt=\(now - env.timestamp)s)")
            #endif
            return
        }
        // Materialise the byte buffers.
        guard let ephRaw = Data(base64Encoded: env.ephemeralPub),
              let nonceRaw = Data(base64Encoded: env.nonce),
              let ctRaw = Data(base64Encoded: env.ciphertext),
              ctRaw.count >= 16 else {
            return
        }
        // Pull our X25519 private key — same one DeviceIdentityService
        // exposes for chat ECDH. If we don't have one (fresh install,
        // pre-launch race), drop silently.
        guard let myPrivData = DeviceIdentityService.shared.agreementPrivateKeyData else {
            #if DEBUG
            print("🔵 [BLE-Login] no local agreement key to decrypt token envelope")
            #endif
            return
        }
        do {
            let myPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: myPrivData)
            let ephPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephRaw)
            let shared = try myPriv.sharedSecretFromKeyAgreement(with: ephPub)
            let key = shared.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: Data(),
                sharedInfo: Data("raven.login.token.v1".utf8),
                outputByteCount: 32
            )
            // SealedBox = ciphertext (last 16 bytes are the auth tag).
            let ciphertextBody = ctRaw.prefix(ctRaw.count - 16)
            let tag = ctRaw.suffix(16)
            let box = try AES.GCM.SealedBox(
                nonce: try AES.GCM.Nonce(data: nonceRaw),
                ciphertext: ciphertextBody,
                tag: tag
            )
            let plain = try AES.GCM.open(box, using: key)
            let payload = try JSONDecoder().decode(MeshLoginTokenPayload.self, from: plain)
            #if DEBUG
            print("🔵 [BLE-Login] decrypted token envelope for sid=\(env.sessionId.prefix(8)) user=\(payload.username)")
            #endif
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .ravenBluetoothLoginTokenReceived,
                    object: nil,
                    userInfo: [
                        "sessionId": env.sessionId,
                        "payload": payload,
                        "peerDeviceId": deviceId
                    ]
                )
            }
        } catch {
            #if DEBUG
            print("🔵 [BLE-Login] decrypt failed: \(error)")
            #endif
        }
    }

    /// Process a fully-reassembled v2 envelope (binary RUMProtocolV2
    /// wire format) from `deviceId`.
    ///
    /// The v2 frame is a thin transport wrapper — when `flags.encrypted`
    /// is set, `payload` is the same AES-GCM blob v1 has always emitted,
    /// so we can hand it straight to the existing v1 decrypt + chat
    /// ingest path. That's how a v2 receiver lights up chat without a
    /// new ingest hook in `ChatStore`. Phase C.1 swaps the inner crypto
    /// for Noise IK and changes this path to decrypt via Noise instead.
    private func handleV2EnvelopePayload(_ data: Data, from deviceId: String) {
        let envelope: RUMProtocolV2.Envelope
        do {
            envelope = try RUMProtocolV2.decode(data)
        } catch {
            #if DEBUG
            print("[mesh-v2] decode failed from \(deviceId.prefix(8)): \(error)")
            #endif
            return
        }
        #if DEBUG
        print("[mesh-v2] received \(envelope.type) from \(deviceId.prefix(8)) — \(envelope.payload.count) B payload, ttl=\(envelope.ttl)")
        #endif
        // Diagnostic notification (everything goes through this; useful
        // for protocol-level debugging — and `RUMRelayService` listens
        // here too, so STOP envelopes are mark-stopped + propagated).
        NotificationCenter.default.post(
            name: .ravenMeshV2EnvelopeReceived,
            object: nil,
            userInfo: ["envelope": envelope, "peerDeviceId": deviceId]
        )

        // ── Noise IK routing (C.1.c) ────────────────────────────────
        //
        // Three new shapes ride v2 envelopes alongside the legacy
        // AES-GCM `flags.encrypted` path:
        //
        //   • `type == noiseHandshake1` → initiator's M1; process, emit
        //     our M2, and ingest the embedded payload (1-RTT IK lets us
        //     deliver chat text inside the handshake itself).
        //   • `type == noiseHandshake2` → responder's M2; process and
        //     finalize the cached session keys.
        //   • `flags.noiseTransport`    → transport-mode AEAD; decrypt
        //     via the cached session and fold plaintext into the
        //     existing v1 chat ingest path.
        //
        // We only act on envelopes addressed to *us* — relays continue
        // to forward Noise frames opaquely (the relay can't decrypt; it
        // just transports bytes). When the env is *not* for us, fall
        // through to the relay/STOP/ingest logic below unchanged.
        let myPID: Data? = DeviceIdentityService.shared.agreementPublicKeyData
            .map { RUMProtocolV2.peerID(fromPublicKey: $0) }

        if envelope.destPID == myPID {
            switch envelope.type {
            case .noiseHandshake1:
                handleInboundNoiseHandshake1(envelope, from: deviceId)
            case .noiseHandshake2:
                handleInboundNoiseHandshake2(envelope, from: deviceId)
            default:
                if envelope.flags.contains(.noiseTransport) {
                    handleInboundNoiseTransport(envelope, from: deviceId)
                }
            }
        }

        // If the payload is an AES-GCM-encrypted v1 envelope, fold it
        // back into the existing chat ingest. Dedup happens inside
        // handleAssembledPayload (via MeshDedupRepository on the inner
        // clientMessageId), so we don't double-fire. Skip when Noise
        // already handled this envelope (above).
        if envelope.flags.contains(.encrypted), !envelope.flags.contains(.noiseTransport) {
            handleAssembledPayload(envelope.payload, from: deviceId)
        }

        // STOP gossip — when this envelope is addressed to us, broadcast
        // a STOP back into the mesh so carriers can drop their remaining
        // spray copies. Skipped for incoming STOPs (those already flow
        // through `RUMRelayService`, which marks them stopped + relays)
        // and for Noise handshake messages (the handshake itself is
        // single-recipient and already terminates after M2).
        if envelope.type != .stop,
           envelope.type != .noiseHandshake1,
           envelope.type != .noiseHandshake2,
           let myPID,
           envelope.destPID == myPID {
            broadcastV2Stop(forMsgID: envelope.msgID)
        }
    }

    // MARK: - Noise IK ingest (C.1.c)

    /// Process an inbound `noiseHandshake1`: hand the bytes to the
    /// session store, ship our M2 reply back to the initiator, and
    /// fold the embedded chat payload into the existing v1 ingest.
    private func handleInboundNoiseHandshake1(_ envelope: RUMProtocolV2.Envelope, from deviceId: String) {
        let result: (payload: Data, message2: Data, peerID: Data)
        do {
            result = try NoiseSessionStore.shared.processInboundHandshake1(message1: envelope.payload)
        } catch {
            #if DEBUG
            print("[mesh-v2-noise] M1 process failed from \(deviceId.prefix(8)): \(error)")
            #endif
            return
        }

        // Send M2 back to the initiator. It rides the mesh just like
        // any other v2 envelope; relays forward toward the
        // initiator's peerID without needing to decrypt.
        guard let myAgreement = DeviceIdentityService.shared.agreementPublicKeyData else { return }
        let myPID = RUMProtocolV2.peerID(fromPublicKey: myAgreement)

        var msgID = Data(count: 16)
        msgID.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, 16, base)
        }

        let m2Envelope = RUMProtocolV2.Envelope(
            type: .noiseHandshake2,
            ttl: RUMProtocolV2.defaultTTL,
            flags: [],
            timestamp: UInt32(Date().timeIntervalSince1970),
            msgID: msgID,
            senderPID: myPID,
            destPID: envelope.senderPID,
            hopCount: 0,
            sprayRemaining: RUMProtocolV2.defaultSprayCopies,
            payload: result.message2,
            signature: nil
        )

        if let encoded = try? RUMProtocolV2.encode(m2Envelope) {
            let padded = RUMProtocolV2.pad(encoded)
            Task { await self.relayV2EnvelopeBytesToAllPeers(padded, except: "") }
        }

        // Treat the embedded payload as a v1 cipher-text and run it
        // through the existing chat ingest. When we wire C.1.d later
        // and use Noise transport mode end-to-end, this path becomes
        // a plain handoff to a Noise-aware ingest hook; for now,
        // honoring the legacy ciphertext shape keeps interop trivial
        // with any peer that bundled v1-shaped bytes into M1.
        if !result.payload.isEmpty {
            handleAssembledPayload(result.payload, from: deviceId)
        }

        #if DEBUG
        print("[mesh-v2-noise] processed M1 from \(deviceId.prefix(8)); session established")
        #endif
    }

    /// Process an inbound `noiseHandshake2`: finalize the cached
    /// initiator-side session. The handshake's reply payload is
    /// available but typically empty for IK; we ignore it.
    private func handleInboundNoiseHandshake2(_ envelope: RUMProtocolV2.Envelope, from deviceId: String) {
        // Recovering the local peerID lookup from the responder's
        // senderPID — that's the same `peerID(fromPublicKey: rs)` we
        // stashed under when initiating.
        let peerID = envelope.senderPID
        do {
            _ = try NoiseSessionStore.shared.finishHandshakeAsInitiator(
                message2: envelope.payload,
                peerID: peerID
            )
            #if DEBUG
            print("[mesh-v2-noise] processed M2 from \(deviceId.prefix(8)); transport keys ready")
            #endif
        } catch {
            #if DEBUG
            print("[mesh-v2-noise] M2 process failed from \(deviceId.prefix(8)): \(error)")
            #endif
        }
    }

    /// Decrypt a transport-mode payload via the cached session keys.
    /// AD = `msg_id` so a replay against a different envelope fails
    /// the AEAD check; the bound makes nonce reuse across messages
    /// detectable.
    private func handleInboundNoiseTransport(_ envelope: RUMProtocolV2.Envelope, from deviceId: String) {
        let peerID = envelope.senderPID
        guard let plaintext = NoiseSessionStore.shared.decrypt(
            envelope.payload,
            ad: envelope.msgID,
            fromPeer: peerID
        ) else {
            #if DEBUG
            print("[mesh-v2-noise] transport decrypt failed from \(deviceId.prefix(8)) — no session or AEAD failure")
            #endif
            return
        }
        // Two shapes ride a Noise transport-mode payload:
        //
        //   • `encrypted` flag set → plaintext is the legacy v1
        //     `EncryptedMeshPayload` JSON (Noise wraps AES-GCM).
        //     Hand to the v1 ingest pipeline (C.1.d migration shape).
        //
        //   • `encrypted` flag clear → plaintext is the JSON of a
        //     bare `MeshEnvelope`. The inner AES-GCM layer is gone
        //     (C.1.e). We verify the relay-chain Ed25519 signature
        //     here — same check the v1 wrapper used to perform.
        if envelope.flags.contains(.encrypted) {
            handleAssembledPayload(plaintext, from: deviceId)
        } else {
            handleNoiseNativeEnvelopeBytes(plaintext, from: deviceId)
        }
    }

    /// C.1.e: ingest a bare `MeshEnvelope` JSON that came out of the
    /// Noise transport-mode decrypt. Verifies the relay-chain
    /// Ed25519 signature so a malicious relay can't fabricate
    /// envelopes after the Noise outer layer strips off.
    private func handleNoiseNativeEnvelopeBytes(_ data: Data, from deviceId: String) {
        let envelope: MeshEnvelope
        do {
            envelope = try JSONDecoder().decode(MeshEnvelope.self, from: data)
        } catch {
            #if DEBUG
            print("[mesh-v2-noise-native] envelope decode failed from \(deviceId.prefix(8)): \(error)")
            #endif
            return
        }

        if let sigStr = envelope.originalSignature,
           let signerStr = envelope.originalSignerPublicKey,
           let sig = Data(base64Encoded: sigStr),
           let pk = Data(base64Encoded: signerStr) {
            let valid = DeviceIdentityService.shared.verify(
                signature: sig,
                data: envelope.signingData(),
                publicKey: pk
            )
            guard valid else {
                #if DEBUG
                print("[mesh-v2-noise-native] signature verification failed from \(deviceId.prefix(8))")
                #endif
                return
            }
        }

        Task {
            guard await MeshDedupRepository.shared.isNewMessage(id: envelope.clientMessageId) else { return }
            await MeshDedupRepository.shared.markProcessed(id: envelope.clientMessageId)
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .ravenMeshEnvelopeReceived,
                    object: nil,
                    userInfo: ["envelope": envelope, "peerDeviceId": deviceId]
                )
            }
        }
    }

    /// Build + broadcast a STOP gossip envelope pointing at
    /// `originalMsgID`. Called when we're the recipient and have just
    /// ingested the original; STOP propagates so carriers stop
    /// spraying remaining copies.
    private func broadcastV2Stop(forMsgID originalMsgID: Data) {
        guard let myAgreement = DeviceIdentityService.shared.agreementPublicKeyData else { return }
        let myPID = RUMProtocolV2.peerID(fromPublicKey: myAgreement)

        // STOP carries its own fresh msg_id so its bloom-dedup is
        // independent of the original's. Payload = 16 bytes of the
        // original `msg_id` — that's what carriers look up to suppress
        // future spray.
        var stopMsgID = Data(count: 16)
        stopMsgID.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, 16, base)
        }

        let stop = RUMProtocolV2.Envelope(
            type: .stop,
            ttl: RUMProtocolV2.defaultTTL,
            flags: [],
            timestamp: UInt32(Date().timeIntervalSince1970),
            msgID: stopMsgID,
            senderPID: myPID,
            destPID: RUMProtocolV2.broadcastPeerID,
            hopCount: 0,
            // STOP wants higher reach than user text (defaults to 4) —
            // it's small, header-only, and the goal is to suppress
            // spray everywhere. Bloom-dedup + TTL bound prevent loops.
            sprayRemaining: 32,
            payload: originalMsgID,
            signature: nil
        )

        guard let encoded = try? RUMProtocolV2.encode(stop) else { return }
        let padded = RUMProtocolV2.pad(encoded)

        // Mark stopped locally before broadcast so a concurrent arrival
        // of the original via a different path doesn't get re-sprayed.
        RUMRelayService.shared.markStopped(msgID: originalMsgID)

        #if DEBUG
        let originalHex = originalMsgID.map { String(format: "%02x", $0) }.joined()
        print("[mesh-v2] emitting STOP for \(originalHex.prefix(8))")
        #endif

        Task { await self.relayV2EnvelopeBytesToAllPeers(padded, except: "") }
    }

    // MARK: - Peripheral state

    private func setupPeripheralServiceIfNeeded() {
        guard let pm = peripheralManager, pm.state == .poweredOn else { return }
        guard messageCharacteristic == nil else { return }

        // ── v1 service (JSON envelopes, existing wire format) ─────────
        let messageChar = CBMutableCharacteristic(
            type: Self.messageCharacteristicUUID,
            properties: [.read, .write, .writeWithoutResponse, .notify],
            value: nil,
            permissions: [.readable, .writeable]
        )
        let infoChar = CBMutableCharacteristic(
            type: Self.deviceInfoCharacteristicUUID,
            properties: [.read],
            value: nil,
            permissions: [.readable]
        )
        let v1Service = CBMutableService(type: Self.serviceUUID, primary: true)
        v1Service.characteristics = [messageChar, infoChar]
        pm.add(v1Service)
        self.messageCharacteristic = messageChar
        self.deviceInfoCharacteristic = infoChar

        // ── v2 service (binary RUMProtocolV2 envelopes) ───────────────
        // Coexists with v1; peers that know v2 prefer it (decode is
        // already wired below). v1-only peers ignore this service.
        let v2MessageChar = CBMutableCharacteristic(
            type: RUMProtocolV2.messageCharacteristicUUID,
            properties: [.read, .write, .writeWithoutResponse, .notify],
            value: nil,
            permissions: [.readable, .writeable]
        )
        let v2CapsChar = CBMutableCharacteristic(
            type: RUMProtocolV2.capabilitiesCharacteristicUUID,
            properties: [.read],
            value: nil,
            permissions: [.readable]
        )
        let v2Service = CBMutableService(type: RUMProtocolV2.serviceUUID, primary: true)
        v2Service.characteristics = [v2MessageChar, v2CapsChar]
        pm.add(v2Service)
        self.v2MessageCharacteristic = v2MessageChar
        self.v2CapabilitiesCharacteristic = v2CapsChar
    }

    private func startAdvertisingIfPossible() {
        guard let pm = peripheralManager, pm.state == .poweredOn else { return }
        guard !isAdvertising else { return }
        let name = (Host.current().localizedName ?? "RAVEN-Mac").prefix(8)
        // Advertise BOTH service UUIDs so v1 and v2 peers both find us.
        // A peer that supports v2 reads the capabilities characteristic
        // and switches; v1-only peers see the v1 UUID and use that.
        pm.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID, RUMProtocolV2.serviceUUID],
            CBAdvertisementDataLocalNameKey: String(name)
        ])
        isAdvertising = true
        rebuildConnectedPeers()
    }

    /// Bitfield we serve on `v2CapabilitiesCharacteristic`. Computed each
    /// time so server-bridge availability reflects the current login
    /// state (the user may have signed out / lost connectivity since the
    /// last read). 4-byte big-endian uint32 on the wire — same encoding
    /// across iOS/Mac/Windows/Android.
    private func currentCapabilitiesBytes() -> Data {
        // App Sandbox blocks Wi-Fi Direct and (today) Wi-Fi Aware, and
        // we never act as a bridger ourselves on the App Store target —
        // so we advertise only protocol + BLE + server-bridge consumer.
        var caps: RUMProtocolV2.Capabilities = [.v2Protocol, .bleTransport]
        if AuthService.shared.isAuthenticated {
            caps.insert(.serverBridge)
        }
        var be = caps.rawValue.bigEndian
        return withUnsafeBytes(of: &be) { Data($0) }
    }

    private func startScanningIfPossible() {
        guard let cm = centralManager, cm.state == .poweredOn else { return }
        guard !isScanning else { return }
        cm.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        isScanning = true
        rebuildConnectedPeers()
    }

    private func rebuildConnectedPeers() {
        connectedPeers = connectedPeripherals.map { uuid, peripheral in
            MeshPeer(
                fingerprint: peripheralFingerprints[uuid],
                deviceId: uuid.uuidString,
                name: peripheral.name,
                lastSeenAt: Date()
            )
        }
        NotificationCenter.default.post(
            name: .ravenMeshStateChanged,
            object: nil,
            userInfo: [
                "connectedPeerCount": connectedPeers.count,
                "advertising": isAdvertising,
                "scanning": isScanning,
            ]
        )
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEMeshEngine: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            self.bluetoothState = central.state
            switch central.state {
            case .poweredOn:
                self.startScanningIfPossible()
            case .poweredOff, .unauthorized, .unsupported:
                MeshError.bluetoothUnavailable.post()
            default:
                break
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            let id = peripheral.identifier
            guard self.connectedPeripherals[id] == nil else { return }
            self.connectedPeripherals[id] = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            // Discover BOTH the v1 and v2 services. The peripheral-side
            // delegate above iterates the discovered services and only
            // discovers characteristics for the ones it recognizes — so
            // an old v1-only peer simply lacks the v2 service and we
            // skip it without error.
            peripheral.discoverServices([Self.serviceUUID, RUMProtocolV2.serviceUUID])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            self.connectedPeripherals.removeValue(forKey: peripheral.identifier)
            self.peripheralFingerprints.removeValue(forKey: peripheral.identifier)
            self.peripheralAgreementKeys.removeValue(forKey: peripheral.identifier)
            self.rebuildConnectedPeers()
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            self.connectedPeripherals.removeValue(forKey: peripheral.identifier)
            self.peripheralFingerprints.removeValue(forKey: peripheral.identifier)
            self.peripheralAgreementKeys.removeValue(forKey: peripheral.identifier)
            self.rebuildConnectedPeers()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEMeshEngine: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard error == nil else { return }
            for service in peripheral.services ?? [] {
                if service.uuid == Self.serviceUUID {
                    peripheral.discoverCharacteristics(
                        [Self.messageCharacteristicUUID, Self.deviceInfoCharacteristicUUID],
                        for: service
                    )
                } else if service.uuid == RUMProtocolV2.serviceUUID {
                    peripheral.discoverCharacteristics(
                        [RUMProtocolV2.messageCharacteristicUUID,
                         RUMProtocolV2.capabilitiesCharacteristicUUID],
                        for: service
                    )
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            guard error == nil else { return }
            for char in service.characteristics ?? [] {
                if char.uuid == Self.messageCharacteristicUUID {
                    peripheral.setNotifyValue(true, for: char)
                } else if char.uuid == Self.deviceInfoCharacteristicUUID {
                    peripheral.readValue(for: char)
                } else if char.uuid == RUMProtocolV2.messageCharacteristicUUID {
                    // Subscribe to v2 message notifications. The peer
                    // hasn't sent any v2 envelopes yet (encoder lands in
                    // Phase C) but discovery + subscription is what
                    // tells the peer "yes, route v2 to me too".
                    peripheral.setNotifyValue(true, for: char)
                } else if char.uuid == RUMProtocolV2.capabilitiesCharacteristicUUID {
                    // Pull the peer's capability bitfield once. Used by
                    // the sender path (Phase C) to choose v2 vs v1.
                    peripheral.readValue(for: char)
                }
            }
            self.rebuildConnectedPeers()
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            guard let data = characteristic.value, error == nil else { return }
            if characteristic.uuid == Self.messageCharacteristicUUID {
                let deviceId = peripheral.identifier.uuidString
                if let assembled = self.processIncomingPacket(data, from: deviceId) {
                    self.handleAssembledPayload(assembled, from: deviceId)
                }
            } else if characteristic.uuid == Self.deviceInfoCharacteristicUUID {
                // Device info characteristic carries the peer's
                // agreement public key (bytes) so we can derive a
                // shared AES secret. Bytes-only — no JSON wrapping.
                self.peripheralAgreementKeys[peripheral.identifier] = data
                let fp = DeviceIdentityService.deriveFingerprint(from: data)
                self.peripheralFingerprints[peripheral.identifier] = fp
                self.rebuildConnectedPeers()
            } else if characteristic.uuid == RUMProtocolV2.messageCharacteristicUUID {
                let deviceId = peripheral.identifier.uuidString
                if let assembled = self.processIncomingPacket(data, from: deviceId) {
                    self.handleV2EnvelopePayload(assembled, from: deviceId)
                }
            } else if characteristic.uuid == RUMProtocolV2.capabilitiesCharacteristicUUID {
                // Cache the peer's capability bitfield. Phase C senders
                // will gate v2 encoding on `caps.contains(.v2Protocol)`.
                self.peerCapabilities[peripheral.identifier] = self.parseCapabilities(data)
                #if DEBUG
                let raw = data.map { String(format: "%02x", $0) }.joined()
                print("[mesh-v2] caps from \(peripheral.identifier.uuidString.prefix(8)): 0x\(raw)")
                #endif
            }
        }
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLEMeshEngine: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @MainActor in
            self.bluetoothState = peripheral.state
            switch peripheral.state {
            case .poweredOn:
                self.setupPeripheralServiceIfNeeded()
                self.startAdvertisingIfPossible()
            case .poweredOff, .unauthorized, .unsupported:
                MeshError.bluetoothUnavailable.post()
            default:
                break
            }
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveRead request: CBATTRequest
    ) {
        Task { @MainActor in
            if request.characteristic.uuid == Self.deviceInfoCharacteristicUUID,
               let agreementKey = DeviceIdentityService.shared.agreementPublicKeyData {
                request.value = agreementKey
                peripheral.respond(to: request, withResult: .success)
            } else if request.characteristic.uuid == RUMProtocolV2.capabilitiesCharacteristicUUID {
                // Peer is asking what protocols/transports we speak.
                request.value = self.currentCapabilitiesBytes()
                peripheral.respond(to: request, withResult: .success)
            } else {
                peripheral.respond(to: request, withResult: .readNotPermitted)
            }
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        // Extract the bytes + per-request metadata on the BLE queue so
        // we don't have to send the `[CBATTRequest]` array across the
        // actor boundary (Array<CBATTRequest> is non-Sendable even
        // with @preconcurrency).
        //
        // We tag each payload with which characteristic it came in on
        // so the actor side can route v1 envelopes to the JSON parser
        // and v2 envelopes to the binary `RUMProtocolV2` decode.
        let v1MessageCharUUID = Self.messageCharacteristicUUID
        let v2MessageCharUUID = RUMProtocolV2.messageCharacteristicUUID
        let payloads: [(deviceId: String, data: Data, isV2: Bool)] = requests.compactMap { req in
            guard let data = req.value else { return nil }
            if req.characteristic.uuid == v1MessageCharUUID {
                return (req.central.identifier.uuidString, data, false)
            }
            if req.characteristic.uuid == v2MessageCharUUID {
                return (req.central.identifier.uuidString, data, true)
            }
            return nil
        }
        // Acknowledge synchronously on the BLE queue — Core Bluetooth
        // requires exactly one reply per batch. .success is fine: we
        // already have the bytes copied above.
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }

        Task { @MainActor in
            for p in payloads {
                guard let assembled = self.processIncomingPacket(p.data, from: p.deviceId) else { continue }
                if p.isV2 {
                    self.handleV2EnvelopePayload(assembled, from: p.deviceId)
                } else {
                    self.handleAssembledPayload(assembled, from: p.deviceId)
                }
            }
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        Task { @MainActor in
            if !self.subscribedCentrals.contains(where: { $0.identifier == central.identifier }) {
                self.subscribedCentrals.append(central)
            }
            self.rebuildConnectedPeers()
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        Task { @MainActor in
            self.subscribedCentrals.removeAll { $0.identifier == central.identifier }
            self.rebuildConnectedPeers()
        }
    }
}
