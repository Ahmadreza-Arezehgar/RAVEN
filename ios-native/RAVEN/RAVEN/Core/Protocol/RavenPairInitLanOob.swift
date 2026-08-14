//
//  RavenPairInitLanOob.swift
//  RAVEN — LAN OOB carrier for PairInit/PairResponse (Test A, same Wi‑Fi).
//
//  Spec §7 allows PairInit on an already confidential/OOB channel. Raw RVPI1/
//  RVPR1 cannot ride strict RVN1 IPC alone; wrap as EnvType.message ciphertext.
//

import Foundation
import CryptoKit

enum RavenPairInitLanOob {
    /// Advisory outer flag (bit 8) — classifiers still sniff inner magic.
    static let flagPairInitOob: UInt16 = 1 << 8

    enum Kind: Equatable {
        case pairInit(Data)
        case pairResponse(Data)
        case notPairInitOob
    }

    private static let initMagic = Data([0x52, 0x56, 0x50, 0x49, 0x31, 0, 0, 0])
    private static let responseMagic = Data([0x52, 0x56, 0x50, 0x52, 0x31, 0, 0, 0])

    static func classifyMessageCiphertext(_ body: Data) -> Kind {
        if body.count == ATSAMPairInitV1.initWireLength, body.starts(with: initMagic) {
            return .pairInit(body)
        }
        if body.count == ATSAMPairInitV1.responseWireLength, body.starts(with: responseMagic) {
            return .pairResponse(body)
        }
        return .notPairInitOob
    }

    static func classifyPackedEnvelope(_ packed: Data) -> Kind {
        guard let env = RavenEnvelopeV1.unpack(packed),
              env.envType == RavenEnvelopeV1.EnvType.message.rawValue else {
            return .notPairInitOob
        }
        return classifyMessageCiphertext(env.messageCiphertext)
    }

    static func wrapOobWire(
        _ wire: Data,
        isPairInit: Bool,
        signingKey: Curve25519.Signing.PrivateKey,
        nowMs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)
    ) throws -> Data {
        if isPairInit {
            guard wire.count == ATSAMPairInitV1.initWireLength, wire.starts(with: initMagic) else {
                throw LanOobError.badInitWire
            }
        } else {
            guard wire.count == ATSAMPairInitV1.responseWireLength, wire.starts(with: responseMagic) else {
                throw LanOobError.badResponseWire
            }
        }
        var messageId = Data(count: 16)
        messageId.withUnsafeMutableBytes { buf in
            _ = SecRandomCopyBytes(kSecRandomDefault, 16, buf.baseAddress!)
        }
        var nonce = Data(count: 12)
        nonce.withUnsafeMutableBytes { buf in
            _ = SecRandomCopyBytes(kSecRandomDefault, 12, buf.baseAddress!)
        }
        var tag = Data(count: 16)
        tag.withUnsafeMutableBytes { buf in
            _ = SecRandomCopyBytes(kSecRandomDefault, 16, buf.baseAddress!)
        }
        var env = RavenEnvelopeV1(
            envType: RavenEnvelopeV1.EnvType.message.rawValue,
            flags: 0, // magic-sniff only; flag bit 8 not in ALLOWED_FLAGS yet
            messageId: messageId,
            routingTag: tag,
            destDeviceHint: 0,
            createdAtMs: nowMs,
            expiresAtMs: nowMs &+ 7 * 24 * 3600 * 1_000,
            hopLimit: 8,
            replicationBudget: 2,
            antiReplayNonce: nonce,
            ratchetHeaderCiphertext: Data(),
            messageCiphertext: wire
        )
        env.sign(with: signingKey)
        return env.pack()
    }

    enum LanOobError: Error {
        case badInitWire
        case badResponseWire
    }
}
