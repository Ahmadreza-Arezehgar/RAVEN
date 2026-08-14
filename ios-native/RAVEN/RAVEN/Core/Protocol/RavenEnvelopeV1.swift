//
//  RavenEnvelopeV1.swift
//  RAVEN — serverless V1 binary envelope (parallel to MeshEnvelope).
//
//  Byte-compatible with `protocol/RAVEN_ENVELOPE_V1.md` and
//  `shared-vectors/rvn1/envelope/`. Shipping MeshEnvelope JSON path is
//  unchanged; enable `FeatureFlag.ravenEnvelopeV1` for the parallel path.
//

import Foundation
import CryptoKit

/// Binary RavenEnvelopeV1 — same object Rust `raven-core` and terminal nodes use.
public struct RavenEnvelopeV1: Equatable, Sendable {
    public static let magic = Data([0x52, 0x56, 0x4E, 0x31]) // RVN1
    public static let version: UInt8 = 1
    public static let prefixLength = 86
    /// Canonical RVN1 object ceiling. Text ciphertext is capped at 256 KiB;
    /// media requires a separately versioned chunk transport.
    public static let maximumWireLength = 1_048_576

    private static let allowedFlags: UInt16 = 0b0000_0011
    private static let authenticationLength = 64

    public var envType: UInt8
    public var flags: UInt16
    public var messageId: Data // 16
    public var routingTag: Data // 16
    public var destDeviceHint: UInt64
    public var createdAtMs: UInt64
    public var expiresAtMs: UInt64
    public var hopLimit: UInt8
    public var replicationBudget: UInt8
    public var antiReplayNonce: Data // 12
    public var ratchetHeaderCiphertext: Data
    public var messageCiphertext: Data
    public var senderAuthentication: Data // 64 when signed

    public enum EnvType: UInt8 {
        case message = 1
        case ack = 2
        case aliasGossip = 3
        case capabilities = 4
    }

    public init(
        envType: UInt8,
        flags: UInt16 = 0,
        messageId: Data,
        routingTag: Data,
        destDeviceHint: UInt64 = 0,
        createdAtMs: UInt64,
        expiresAtMs: UInt64,
        hopLimit: UInt8 = 8,
        replicationBudget: UInt8 = 3,
        antiReplayNonce: Data,
        ratchetHeaderCiphertext: Data = Data(),
        messageCiphertext: Data,
        senderAuthentication: Data = Data()
    ) {
        self.envType = envType
        self.flags = flags
        self.messageId = messageId
        self.routingTag = routingTag
        self.destDeviceHint = destDeviceHint
        self.createdAtMs = createdAtMs
        self.expiresAtMs = expiresAtMs
        self.hopLimit = hopLimit
        self.replicationBudget = replicationBudget
        self.antiReplayNonce = antiReplayNonce
        self.ratchetHeaderCiphertext = ratchetHeaderCiphertext
        self.messageCiphertext = messageCiphertext
        self.senderAuthentication = senderAuthentication
    }

    public func pack() -> Data {
        var out = Data(capacity: Self.prefixLength + ratchetHeaderCiphertext.count
                       + messageCiphertext.count + senderAuthentication.count)
        out.append(Self.magic)
        out.append(Self.version)
        out.append(envType)
        out.appendUInt16BE(flags)
        out.append(messageId)
        out.append(routingTag)
        out.appendUInt64BE(destDeviceHint)
        out.appendUInt64BE(createdAtMs)
        out.appendUInt64BE(expiresAtMs)
        out.append(hopLimit)
        out.append(replicationBudget)
        out.append(antiReplayNonce)
        out.appendUInt16BE(UInt16(ratchetHeaderCiphertext.count))
        out.appendUInt32BE(UInt32(messageCiphertext.count))
        out.appendUInt16BE(UInt16(senderAuthentication.count))
        out.append(ratchetHeaderCiphertext)
        out.append(messageCiphertext)
        out.append(senderAuthentication)
        return out
    }

    public static func unpack(_ raw: Data) -> RavenEnvelopeV1? {
        // Network-strict entry point used by the LAN, BLE, bridge, and endpoint
        // ingress paths. Bound the frame before reading declared lengths.
        guard raw.count >= prefixLength, raw.count <= maximumWireLength else { return nil }
        guard raw.prefix(4).elementsEqual(magic), raw[4] == version else { return nil }
        let envType = raw[5]
        guard EnvType(rawValue: envType) != nil else { return nil }
        let flags = raw.readUInt16BE(at: 6)
        guard flags & ~allowedFlags == 0 else { return nil }
        let messageId = raw.subdata(in: 8..<24)
        let routingTag = raw.subdata(in: 24..<40)
        let destHint = raw.readUInt64BE(at: 40)
        let created = raw.readUInt64BE(at: 48)
        let expires = raw.readUInt64BE(at: 56)
        guard expires > created else { return nil }
        let hop = raw[64]
        let repl = raw[65]
        let nonce = raw.subdata(in: 66..<78)
        let hdrLen = Int(raw.readUInt16BE(at: 78))
        let bodyLen = Int(raw.readUInt32BE(at: 80))
        let authLen = Int(raw.readUInt16BE(at: 84))
        guard authLen == authenticationLength else { return nil }

        let (headerEnd, headerOverflow) = prefixLength.addingReportingOverflow(hdrLen)
        let (bodyEnd, bodyOverflow) = headerEnd.addingReportingOverflow(bodyLen)
        let (authenticationEnd, authenticationOverflow) = bodyEnd.addingReportingOverflow(authLen)
        guard !headerOverflow, !bodyOverflow, !authenticationOverflow,
              raw.count == authenticationEnd else { return nil }
        let hdr = raw.subdata(in: prefixLength..<headerEnd)
        let body = raw.subdata(in: headerEnd..<bodyEnd)
        let auth = raw.subdata(in: bodyEnd..<authenticationEnd)
        return RavenEnvelopeV1(
            envType: envType,
            flags: flags,
            messageId: messageId,
            routingTag: routingTag,
            destDeviceHint: destHint,
            createdAtMs: created,
            expiresAtMs: expires,
            hopLimit: hop,
            replicationBudget: repl,
            antiReplayNonce: nonce,
            ratchetHeaderCiphertext: hdr,
            messageCiphertext: body,
            senderAuthentication: auth
        )
    }

    /// Signing bytes: mutable fields zeroed, auth_len=64, ciphertext by SHA-256.
    public func signingBytes() -> Data {
        var prefix = Data(capacity: Self.prefixLength)
        prefix.append(Self.magic)
        prefix.append(Self.version)
        prefix.append(envType)
        prefix.appendUInt16BE(flags)
        prefix.append(messageId)
        prefix.append(routingTag)
        prefix.appendUInt64BE(0) // dest_device_hint
        prefix.appendUInt64BE(createdAtMs)
        prefix.appendUInt64BE(expiresAtMs)
        prefix.append(0) // hop
        prefix.append(0) // repl
        prefix.append(antiReplayNonce)
        prefix.appendUInt16BE(UInt16(ratchetHeaderCiphertext.count))
        prefix.appendUInt32BE(UInt32(messageCiphertext.count))
        prefix.appendUInt16BE(64)
        assert(prefix.count == Self.prefixLength)
        var out = prefix
        out.append(Data(SHA256.hash(data: ratchetHeaderCiphertext)))
        out.append(Data(SHA256.hash(data: messageCiphertext)))
        return out
    }

    public mutating func sign(with privateKey: Curve25519.Signing.PrivateKey) {
        let sig = try! privateKey.signature(for: signingBytes())
        senderAuthentication = Data(sig)
    }

    public func verify(publicKey: Curve25519.Signing.PublicKey) -> Bool {
        guard senderAuthentication.count == 64 else { return false }
        return publicKey.isValidSignature(senderAuthentication, for: signingBytes())
    }

    /// Stable relay-cache key for the immutable envelope object.
    ///
    /// This is not proof that an unknown sender is authentic. It deliberately
    /// includes the purported signature and the canonical signing bytes so an
    /// attacker cannot poison relay dedup merely by copying a public message ID.
    /// Mutable hop fields are already normalized by `signingBytes()`.
    public func relayObjectDigest() -> Data {
        var digest = SHA256()
        digest.update(data: Data("rvn1/relay-object-digest/v1".utf8))
        digest.update(data: signingBytes())
        digest.update(data: senderAuthentication)
        return Data(digest.finalize())
    }
}

// MARK: - Routing tag

/// Frozen RavenRoutingTagV1 primitive:
/// `HMAC-SHA256(K_route, "rvn1/route" || epoch_be8 || counter_be8)[:16]`.
///
/// This type intentionally implements only the interoperable primitive. How a
/// session allocates and persists `(epoch, counter)` is a protocol decision and
/// must not be guessed from mutable transport state.
enum RavenRoutingTagV1 {
    private static let domain = Data("rvn1/route".utf8)

    static func derive(kRoute: Data, epoch: UInt64, counter: UInt64) -> Data? {
        guard kRoute.count == 32 else { return nil }
        var input = Data(capacity: domain.count + 16)
        input.append(domain)
        input.appendUInt64BE(epoch)
        input.appendUInt64BE(counter)
        let code = HMAC<SHA256>.authenticationCode(
            for: input,
            using: SymmetricKey(data: kRoute)
        )
        return Data(code.prefix(16))
    }

    /// Length-checked comparison that performs the same work for every byte.
    static func matches(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == 16, rhs.count == 16 else { return false }
        var difference: UInt8 = 0
        for index in 0..<16 {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}

// MARK: - Address (Bech32m) — thin wrapper for vector tests

public enum RavenAddressV1 {
    public static let hrp = "rvn"
    public static let version: UInt8 = 1

    public static func encode(ed25519PublicKey: Data) -> String? {
        guard ed25519PublicKey.count == 32 else { return nil }
        let hash = Data(SHA256.hash(data: ed25519PublicKey))
        var payload = Data([version])
        payload.append(hash.prefix(20))
        return Bech32m.encode(hrp: hrp, payload: payload)
    }
}

// MARK: - Bech32m (BIP-350)

enum Bech32m {
    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    private static let const: UInt32 = 0x2bc830a3

    static func encode(hrp: String, payload: Data) -> String? {
        guard let values = convertBits(Array(payload), fromBits: 8, toBits: 5, pad: true) else {
            return nil
        }
        let checksum = createChecksum(hrp: hrp, data: values)
        let combined = values + checksum
        let body = combined.map { charset[Int($0)] }
        return hrp + "1" + String(body)
    }

    static func decode(_ s: String) -> (String, Data)? {
        let lowered = s.lowercased()
        guard lowered == s || s.uppercased() == s else { return nil }
        guard let pos = lowered.lastIndex(of: "1") else { return nil }
        let hrp = String(lowered[..<pos])
        let dataPart = lowered[lowered.index(after: pos)...]
        var data: [UInt8] = []
        for ch in dataPart {
            guard let idx = charset.firstIndex(of: ch) else { return nil }
            data.append(UInt8(charset.distance(from: charset.startIndex, to: idx)))
        }
        guard data.count >= 6 else { return nil }
        guard verifyChecksum(hrp: hrp, data: data) else { return nil }
        let values = Array(data.dropLast(6))
        guard let payload = convertBits(values, fromBits: 5, toBits: 8, pad: false) else {
            return nil
        }
        return (hrp, Data(payload))
    }

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        let gen: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var chk: UInt32 = 1
        for v in values {
            let b = chk >> 25
            chk = ((chk & 0x1ffffff) << 5) ^ UInt32(v)
            for i in 0..<5 {
                if ((b >> i) & 1) != 0 { chk ^= gen[i] }
            }
        }
        return chk
    }

    private static func hrpExpand(_ hrp: String) -> [UInt8] {
        var out: [UInt8] = []
        for c in hrp.utf8 { out.append(c >> 5) }
        out.append(0)
        for c in hrp.utf8 { out.append(c & 31) }
        return out
    }

    private static func createChecksum(hrp: String, data: [UInt8]) -> [UInt8] {
        let values = hrpExpand(hrp) + data + [0, 0, 0, 0, 0, 0]
        let mod = polymod(values) ^ const
        return (0..<6).map { UInt8((mod >> (5 * (5 - $0))) & 31) }
    }

    private static func verifyChecksum(hrp: String, data: [UInt8]) -> Bool {
        polymod(hrpExpand(hrp) + data) == const
    }

    private static func convertBits(_ data: [UInt8], fromBits: Int, toBits: Int, pad: Bool) -> [UInt8]? {
        var acc = 0
        var bits = 0
        var ret: [UInt8] = []
        let maxv = (1 << toBits) - 1
        for value in data {
            if value < 0 || (Int(value) >> fromBits) != 0 { return nil }
            acc = (acc << fromBits) | Int(value)
            bits += fromBits
            while bits >= toBits {
                bits -= toBits
                ret.append(UInt8((acc >> bits) & maxv))
            }
        }
        if pad {
            if bits > 0 {
                ret.append(UInt8((acc << (toBits - bits)) & maxv))
            }
        } else if bits >= fromBits || ((acc << (toBits - bits)) & maxv) != 0 {
            return nil
        }
        return ret
    }
}

// MARK: - Data helpers

extension Data {
    mutating func appendUInt16BE(_ v: UInt16) {
        append(UInt8((v >> 8) & 0xff))
        append(UInt8(v & 0xff))
    }
    mutating func appendUInt32BE(_ v: UInt32) {
        append(UInt8((v >> 24) & 0xff))
        append(UInt8((v >> 16) & 0xff))
        append(UInt8((v >> 8) & 0xff))
        append(UInt8(v & 0xff))
    }
    mutating func appendUInt64BE(_ v: UInt64) {
        for i in (0..<8).reversed() {
            append(UInt8((v >> (UInt64(i) * 8)) & 0xff))
        }
    }
    func readUInt16BE(at o: Int) -> UInt16 {
        (UInt16(self[o]) << 8) | UInt16(self[o + 1])
    }
    func readUInt32BE(at o: Int) -> UInt32 {
        (UInt32(self[o]) << 24) | (UInt32(self[o + 1]) << 16)
            | (UInt32(self[o + 2]) << 8) | UInt32(self[o + 3])
    }
    func readUInt64BE(at o: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(self[o + i]) }
        return v
    }
}
