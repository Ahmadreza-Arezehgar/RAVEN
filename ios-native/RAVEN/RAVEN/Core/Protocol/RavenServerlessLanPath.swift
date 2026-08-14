//
//  RavenServerlessLanPath.swift
//  RAVEN — flagged LAN path: sealed content → RavenEnvelopeV1 → raven-node TCP.
//
//  Gated by FeatureFlag.ravenEnvelopeV1 (default OFF). When off, callers MUST
//  keep using MeshEnvelope / BLEMeshEngine unchanged.
//
//  Frame: u32 BE length || packed RavenEnvelopeV1  (same as raven-node).
//

import Foundation
import Network
import CryptoKit
import Security

// MARK: - Debug endpoint config (no secrets)

/// Optional localhost / LAN peer for serverless smoke. Public key hex only.
public struct RavenServerlessLanConfig: Equatable, Sendable {
    public var host: String
    public var port: UInt16
    /// Peer Ed25519 public key (32 bytes hex) for envelope verify on the node.
    public var peerPubHex: String
    /// Optional local TCP listen for LAN→BLE reverse (phone as B). 0 = off.
    public var listenPort: UInt16

    private static let hostKey = "raven.serverless.lan.host"
    private static let portKey = "raven.serverless.lan.port"
    private static let pubKey = "raven.serverless.lan.peer_pub_hex"
    private static let listenPortKey = "raven.serverless.lan.listen_port"

    public init(host: String, port: UInt16, peerPubHex: String, listenPort: UInt16 = 0) {
        self.host = host
        self.port = port
        self.peerPubHex = peerPubHex
        self.listenPort = listenPort
    }

    public static var stored: RavenServerlessLanConfig? {
        let defaults = UserDefaults.standard
        guard let host = defaults.string(forKey: hostKey), !host.isEmpty,
              let pub = defaults.string(forKey: pubKey), pub.count == 64 else {
            return nil
        }
        let port = UInt16(defaults.integer(forKey: portKey))
        guard port > 0 else { return nil }
        let listen = UInt16(defaults.integer(forKey: listenPortKey))
        return RavenServerlessLanConfig(host: host, port: port, peerPubHex: pub, listenPort: listen)
    }

    public func save() {
        let defaults = UserDefaults.standard
        defaults.set(host, forKey: Self.hostKey)
        defaults.set(Int(port), forKey: Self.portKey)
        defaults.set(peerPubHex, forKey: Self.pubKey)
        defaults.set(Int(listenPort), forKey: Self.listenPortKey)
    }

    public static func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: hostKey)
        defaults.removeObject(forKey: portKey)
        defaults.removeObject(forKey: pubKey)
        defaults.removeObject(forKey: listenPortKey)
    }
}

// MARK: - Transport preference (mirrors raven-core::transport)

public enum RavenTransportPreference: Equatable, Sendable {
    case directLan
    case internetLibp2p
    case bleMesh
}

public enum RavenHybridTransport {
    /// Situational selection — content stays RavenEnvelopeV1; carrier only.
    public static func prefer(wifiUp: Bool, peerOnLan: Bool, blePeersNearby: Bool) -> RavenTransportPreference {
        if wifiUp && peerOnLan { return .directLan }
        if wifiUp { return .internetLibp2p }
        if blePeersNearby { return .bleMesh }
        return .directLan
    }
}

// MARK: - Envelope packer

public enum RavenServerlessLanPath {

    /// True when the parallel serverless path may run (flag on + optional config).
    public static var isActive: Bool {
        FeatureFlag.isRavenEnvelopeV1Enabled
    }

    /// Whether to attempt LAN for this send. Parallel with BLE — not exclusive.
    public static func shouldAttemptLan(
        wifiUp: Bool,
        peerOnLan: Bool,
        blePeersNearby: Bool
    ) -> Bool {
        guard isActive else { return false }
        _ = blePeersNearby // situational preference no longer blocks parallel LAN
        return wifiUp && peerOnLan
    }

    /// Pack already-sealed content (ATSAM RVNA1, Noise RVNS1, or interim 0x7F) into RavenEnvelopeV1.
    public static func packSealedMessage(
        sealedBody: Data,
        messageId: Data,
        routingTag: Data,
        signingKey: Curve25519.Signing.PrivateKey,
        hopLimit: UInt8 = 8,
        replicationBudget: UInt8 = 3,
        hybridPQHint: Bool = false,
        nowMs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)
    ) -> RavenEnvelopeV1 {
        precondition(messageId.count == 16)
        precondition(routingTag.count == 16)
        var nonce = Data(count: 12)
        nonce.withUnsafeMutableBytes { buf in
            _ = SecRandomCopyBytes(kSecRandomDefault, 12, buf.baseAddress!)
        }
        var flags: UInt16 = 0
        if hybridPQHint { flags |= 1 }
        var env = RavenEnvelopeV1(
            envType: RavenEnvelopeV1.EnvType.message.rawValue,
            flags: flags,
            messageId: messageId,
            routingTag: routingTag,
            destDeviceHint: 0,
            createdAtMs: nowMs,
            expiresAtMs: nowMs &+ 86_400_000,
            hopLimit: hopLimit,
            replicationBudget: replicationBudget,
            antiReplayNonce: nonce,
            ratchetHeaderCiphertext: Data(),
            messageCiphertext: sealedBody
        )
        env.sign(with: signingKey)
        return env
    }

    /// Length-prefix a packed envelope (raven-node frame).
    public static func frame(_ envelopeBytes: Data) -> Data {
        var out = Data(capacity: 4 + envelopeBytes.count)
        let len = UInt32(envelopeBytes.count).bigEndian
        withUnsafeBytes(of: len) { out.append(contentsOf: $0) }
        out.append(envelopeBytes)
        return out
    }

    /// Parse one length-prefixed frame from a buffer; returns (payload, remainder).
    public static func deframe(_ buffer: Data) -> (Data, Data)? {
        guard buffer.count >= 4 else { return nil }
        let len = Int(buffer.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        guard len > 0, len <= 1_048_576, buffer.count >= 4 + len else { return nil }
        let payload = buffer.subdata(in: 4..<(4 + len))
        let rest = buffer.subdata(in: (4 + len)..<buffer.count)
        return (payload, rest)
    }

    // MARK: - TCP client

    public enum LanError: Error, Equatable {
        case flagDisabled
        case invalidPeerPub
        case connectFailed(String)
        case timeout
        case noAck
        case badAck
        case unverifiedAck
        case invalidEnvelope
        case unsafeInterimDisabled
        case unsupportedSealedBody
    }

    /// Outbound carrier admission. A signed outer envelope is not encryption:
    /// accepting RVNP1 (or arbitrary bytes) here would expose the message to
    /// every relay. Only formats whose own parsers can authenticate ciphertext
    /// are eligible, with cheap structural bounds before any network attempt.
    static func isEligibleOutboundSealedBody(_ body: Data) -> Bool {
        let maxBodyBytes = 256 * 1024
        guard body.count <= maxBodyBytes else { return false }

        if body.prefix(ATSAMMessageSealer.magic.count) == ATSAMMessageSealer.magic {
            // Shipping ATSAM v2: magic(8), proto/suite(2), index(4), nonce(12),
            // at least one ciphertext byte, and Poly1305 tag(16). V1 is
            // receive-only and the public-key-derived 0x7f demo is forbidden.
            let minimumV2Bytes = 8 + 2 + 4 + 12 + 1 + 16
            return body.count >= minimumV2Bytes
                && body[8] == RavenInterimSeal.atsamProtoV2
                && body[9] == RavenInterimSeal.suite
        }

        if body.prefix(MessageContentSealer.sealedMagic.count)
            == MessageContentSealer.sealedMagic {
            // A transport ciphertext has at least one byte plus its 16-byte tag.
            return body.count >= MessageContentSealer.sealedMagic.count + 17
        }

        if body.prefix(MessageContentSealer.handshakeMagic.count)
            == MessageContentSealer.handshakeMagic {
            // Noise IK message 1: e(32) + encrypted static(48) + encrypted
            // payload tag(16). The application itself rejects blank text.
            return body.count >= MessageContentSealer.handshakeMagic.count + 96
        }

        return false
    }

    /// Legacy request/response transport helper.
    ///
    /// A structural `env_type=ACK` is not recipient delivery evidence. This API
    /// therefore sends the frame but rejects every response until a caller can
    /// supply a session-aware endpoint ACK validator. Production submission
    /// paths use `sendPackedFireAndForget` and retain their pending state.
    public static func sendEnvelope(
        _ env: RavenEnvelopeV1,
        host: String,
        port: UInt16,
        timeoutSeconds: TimeInterval = 15
    ) async throws -> RavenEnvelopeV1 {
        guard isActive else { throw LanError.flagDisabled }
        let packed = env.pack()
        let framed = frame(packed)
        return try await withCheckedThrowingContinuation { cont in
            let queue = DispatchQueue(label: "raven.serverless.lan")
            let conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )
            final class Box: @unchecked Sendable {
                var resumed = false
                var rx = Data()
            }
            let box = Box()
            let finish: @Sendable (Result<RavenEnvelopeV1, Error>) -> Void = { result in
                queue.async {
                    guard !box.resumed else { return }
                    box.resumed = true
                    conn.cancel()
                    cont.resume(with: result)
                }
            }
            @Sendable func receiveMore() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let error {
                        finish(.failure(LanError.connectFailed(error.localizedDescription)))
                        return
                    }
                    if let data, !data.isEmpty {
                        box.rx.append(data)
                        if let (payload, _) = deframe(box.rx) {
                            finish(.failure(unverifiedResponseError(payload)))
                            return
                        }
                    }
                    if isComplete {
                        finish(.failure(LanError.noAck))
                        return
                    }
                    receiveMore()
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: framed, completion: .contentProcessed { err in
                        if let err {
                            finish(.failure(LanError.connectFailed(err.localizedDescription)))
                        }
                    })
                    receiveMore()
                case .failed(let err):
                    finish(.failure(LanError.connectFailed(err.localizedDescription)))
                case .cancelled:
                    break
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                finish(.failure(LanError.timeout))
            }
        }
    }

    /// Pure response classifier used by the transport and adversarial tests.
    /// It deliberately never returns an ACK object to application code.
    static func unverifiedResponseError(_ payload: Data) -> LanError {
        guard let envelope = RavenEnvelopeV1.unpack(payload),
              envelope.envType == RavenEnvelopeV1.EnvType.ack.rawValue else {
            return .badAck
        }
        return .unverifiedAck
    }

    /// Connect to Mac raven-node and read pending framed envelopes (Mac-listens path).
    /// Sends pull hello `RVNP` so Mac does not treat probes as recipients.
    public static func pullEnvelopes(
        host: String,
        port: UInt16,
        durationSeconds: TimeInterval = 6
    ) async -> [Data] {
        guard isActive else { return [] }
        // Direct IP TCP often does not show the Local Network prompt; Bonjour does.
        await triggerLocalNetworkPermissionPrompt()
        return await withCheckedContinuation { cont in
            let queue = DispatchQueue(label: "raven.serverless.lan.pull")
            let conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )
            final class Box: @unchecked Sendable {
                var resumed = false
                var rx = Data()
                var out: [Data] = []
            }
            let box = Box()
            let finish: @Sendable () -> Void = {
                queue.async {
                    guard !box.resumed else { return }
                    box.resumed = true
                    conn.cancel()
                    cont.resume(returning: box.out)
                }
            }
            @Sendable func receiveMore() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if error != nil || isComplete {
                        finish()
                        return
                    }
                    if let data, !data.isEmpty {
                        box.rx.append(data)
                        while let (payload, rest) = deframe(box.rx) {
                            box.rx = rest
                            if let env = RavenEnvelopeV1.unpack(payload),
                               env.envType == RavenEnvelopeV1.EnvType.message.rawValue {
                                box.out.append(payload)
                            }
                        }
                    }
                    receiveMore()
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // Pull hello — Mac waits for RVNP (or ~400ms silent legacy).
                    conn.send(content: Data("RVNP".utf8), completion: .contentProcessed { _ in
                        receiveMore()
                    })
                case .waiting(let err):
                    var tag = "waiting"
                    if #available(iOS 14.0, *) {
                        if case .localNetworkDenied? = conn.currentPath?.unsatisfiedReason {
                            tag = "localNetworkDenied"
                        }
                    }
                    #if DEBUG
                    print("🕊️ [LAN pull] \(tag):\(err.localizedDescription)")
                    #endif
                case .failed(let err):
                    #if DEBUG
                    print("🕊️ [LAN pull] failed: \(err.localizedDescription)")
                    #endif
                    finish()
                case .cancelled:
                    finish()
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + durationSeconds) {
                finish()
            }
        }
    }

    /// Browse a declared Bonjour type briefly so iOS shows Local Network permission.
    private static func triggerLocalNetworkPermissionPrompt() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "raven.serverless.lan.bonjour")
            let params = NWParameters()
            params.includePeerToPeer = true
            guard let browser = try? NWBrowser(
                for: .bonjour(type: "_raven-ash._tcp", domain: nil),
                using: params
            ) else {
                cont.resume()
                return
            }
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            let finish: @Sendable () -> Void = {
                queue.async {
                    guard !once.done else { return }
                    once.done = true
                    browser.cancel()
                    cont.resume()
                }
            }
            browser.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .cancelled:
                    finish()
                default:
                    break
                }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 1.2) { finish() }
        }
    }

    /// Write one framed envelope and close — no ACK wait (used for ACK reverse uplink).
    public static func sendPackedFireAndForget(
        _ packed: Data,
        host: String,
        port: UInt16,
        timeoutSeconds: TimeInterval = 8
    ) async throws {
        guard isActive else { throw LanError.flagDisabled }
        // This is a relay-capable API, so it deliberately does not inspect the
        // opaque body. It must still enforce the canonical RVN1 wire boundary
        // before opening a socket; a magic-prefix check is not admission.
        guard RavenEnvelopeV1.unpack(packed) != nil else {
            throw LanError.invalidEnvelope
        }
        let framed = frame(packed)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "raven.serverless.lan.ff")
            let conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )
            final class Box: @unchecked Sendable {
                var resumed = false
            }
            let box = Box()
            let finish: @Sendable (Result<Void, Error>) -> Void = { result in
                queue.async {
                    guard !box.resumed else { return }
                    box.resumed = true
                    conn.cancel()
                    cont.resume(with: result)
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: framed, completion: .contentProcessed { err in
                        if let err {
                            finish(.failure(LanError.connectFailed(err.localizedDescription)))
                        } else {
                            finish(.success(()))
                        }
                    })
                case .failed(let err):
                    finish(.failure(LanError.connectFailed(err.localizedDescription)))
                case .cancelled:
                    break
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                finish(.failure(LanError.timeout))
            }
        }
    }

    /// Convenience: interim-seal plaintext, pack, send to configured LAN peer.
    public static func sendInterimPlaintext(
        _ plaintext: Data,
        localPub: Data,
        localAddr: String,
        peerAddr: String,
        peerPub: Data,
        signingKey: Curve25519.Signing.PrivateKey,
        host: String,
        port: UInt16,
        messageId: Data = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    ) async throws -> RavenEnvelopeV1 {
        guard isActive else { throw LanError.flagDisabled }
        // This helper derived its AEAD key entirely from public Ed25519 keys.
        // Keeping the source-compatible entry point but failing unconditionally
        // prevents accidental use even in a feature-flagged production path.
        throw LanError.unsafeInterimDisabled
    }

    /// Pack real ATSAM/Noise sealed bytes and submit them opaquely. The returned
    /// value is the outbound envelope, never a delivery ACK.
    public static func sendOpaqueSealed(
        sealedBody: Data,
        signingKey: Curve25519.Signing.PrivateKey,
        host: String,
        port: UInt16,
        messageId: Data = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    ) async throws -> RavenEnvelopeV1 {
        guard isActive else { throw LanError.flagDisabled }
        guard isEligibleOutboundSealedBody(sealedBody) else {
            throw LanError.unsupportedSealedBody
        }
        let hybrid = RavenInterimSeal.classify(sealedBody) == .opaqueAtsam(proto: RavenInterimSeal.atsamProtoV2)
            || RavenInterimSeal.classify(sealedBody) == .opaqueAtsam(proto: RavenInterimSeal.atsamProtoV1)
        var tagMaterial = sealedBody.prefix(32)
        tagMaterial.append(messageId)
        let routingTag = Data(SHA256.hash(data: tagMaterial)).prefix(16)
        let env = packSealedMessage(
            sealedBody: sealedBody,
            messageId: messageId,
            routingTag: Data(routingTag),
            signingKey: signingKey,
            hybridPQHint: hybrid
        )
        try await sendPackedFireAndForget(env.pack(), host: host, port: port)
        return env
    }
}
