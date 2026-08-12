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
    }

    /// Send a packed envelope to host:port; wait for one ACK envelope (env_type=2).
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
                            guard let ack = RavenEnvelopeV1.unpack(payload),
                                  ack.envType == RavenEnvelopeV1.EnvType.ack.rawValue else {
                                finish(.failure(LanError.badAck))
                                return
                            }
                            finish(.success(ack))
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

    /// Write one framed envelope and close — no ACK wait (used for ACK reverse uplink).
    public static func sendPackedFireAndForget(
        _ packed: Data,
        host: String,
        port: UInt16,
        timeoutSeconds: TimeInterval = 8
    ) async throws {
        guard isActive else { throw LanError.flagDisabled }
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
        let key = RavenInterimSeal.derivePairwiseKey(localPub: localPub, peerPub: peerPub)
        let sealed = try RavenInterimSeal.seal(
            key: key,
            plaintext: plaintext,
            senderAddr: localAddr,
            recipientAddr: peerAddr,
            messageId: messageId
        )
        // Demo routing tag: first 16 bytes of SHA-256(peerPub || messageId)
        var tagMaterial = peerPub
        tagMaterial.append(messageId)
        let routingTag = Data(SHA256.hash(data: tagMaterial)).prefix(16)
        let env = packSealedMessage(
            sealedBody: sealed,
            messageId: messageId,
            routingTag: Data(routingTag),
            signingKey: signingKey,
            hybridPQHint: false
        )
        return try await sendEnvelope(env, host: host, port: port)
    }

    /// Pack real ATSAM/Noise sealed bytes as opaque envelope body (node ACKs without decrypt).
    public static func sendOpaqueSealed(
        sealedBody: Data,
        signingKey: Curve25519.Signing.PrivateKey,
        host: String,
        port: UInt16,
        messageId: Data = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    ) async throws -> RavenEnvelopeV1 {
        guard isActive else { throw LanError.flagDisabled }
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
        return try await sendEnvelope(env, host: host, port: port)
    }
}
