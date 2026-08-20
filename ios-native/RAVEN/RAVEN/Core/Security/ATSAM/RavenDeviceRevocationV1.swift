//
//  RavenDeviceRevocationV1.swift
//  RAVEN
//
//  Byte-exact RavenDeviceRevocationV1 codec + store snapshot hash (vector freeze).
//  Production disabled — KAT / parity only until companion APPROVED.
//

import CryptoKit
import Foundation

enum RavenDeviceRevocationV1 {
    static let magic = Data([0x52, 0x56, 0x44, 0x52, 0x31, 0, 0, 0]) // RVDR1
    static let version: UInt8 = 0x01
    static let suite: UInt8 = 0x01
    private static let signingDomain = Data("rvn1/device-revocation".utf8)
    private static let storeDomain = Data("rvn1/device-revocation/store-v1".utf8)
    private static let addressLen = 44
    private static let sigLen = 64

    struct Record: Equatable {
        var identityAddress: String
        var deviceId: Data
        var deviceEdPub: Data
        var deviceXPub: Data
        var deviceCertHash: Data
        var issuerDeviceId: Data
        var issuerSeq: UInt64
        var revocationId: Data
        var reasonCode: UInt8
        var createdAtMs: UInt64
        var signature: Data
    }

    struct ExhaustedMarker: Equatable {
        var identityAddress: String
        var claimDigest: Data
        var exactRecordBytes: Data
    }

    struct CorruptMarker: Equatable {
        var scope: String
        var reasonCode: UInt8
    }

    enum CodecError: Error {
        case badMagic, badVersionSuite, badLength, trailingBytes, badAddress, verifyFailed, digestMismatch
    }

    static func lp(_ data: Data) throws -> Data {
        guard (1...64).contains(data.count) else { throw CodecError.badLength }
        var out = Data()
        out.append(UInt8((data.count >> 8) & 0xff))
        out.append(UInt8(data.count & 0xff))
        out.append(data)
        return out
    }

    static func u32be(_ n: UInt32) -> Data {
        var be = n.bigEndian
        return Data(bytes: &be, count: 4)
    }

    static func u64be(_ n: UInt64) -> Data {
        var be = n.bigEndian
        return Data(bytes: &be, count: 8)
    }

    static func signingBytes(_ r: Record) throws -> Data {
        guard r.identityAddress.utf8.count == addressLen else { throw CodecError.badAddress }
        guard r.deviceEdPub.count == 32, r.deviceXPub.count == 32, r.deviceCertHash.count == 32 else {
            throw CodecError.badLength
        }
        guard r.revocationId.count == 16, r.revocationId != Data(count: 16) else {
            throw CodecError.badLength
        }
        var out = signingDomain
        out.append(version)
        out.append(suite)
        out.append(Data(r.identityAddress.utf8))
        out.append(try lp(r.deviceId))
        out.append(r.deviceEdPub)
        out.append(r.deviceXPub)
        out.append(r.deviceCertHash)
        out.append(try lp(r.issuerDeviceId))
        out.append(u64be(r.issuerSeq))
        out.append(r.revocationId)
        out.append(r.reasonCode)
        out.append(u64be(r.createdAtMs))
        return out
    }

    static func encode(_ r: Record) throws -> Data {
        guard r.signature.count == sigLen else { throw CodecError.badLength }
        let sb = try signingBytes(r)
        var out = magic
        out.append(sb.dropFirst(signingDomain.count))
        out.append(r.signature)
        return out
    }

    static func decode(_ wire: Data) throws -> Record {
        guard wire.count >= 8 + 2 + addressLen + 2 + 1 + 32 * 3 + 2 + 1 + 8 + 16 + 1 + 8 + 64 else {
            throw CodecError.badLength
        }
        guard wire.prefix(8) == magic else { throw CodecError.badMagic }
        guard wire[8] == version, wire[9] == suite else { throw CodecError.badVersionSuite }
        var off = 10
        let addrData = wire.subdata(in: off..<(off + addressLen))
        off += addressLen
        guard let identityAddress = String(data: addrData, encoding: .ascii) else {
            throw CodecError.badAddress
        }
        let (deviceId, o1) = try readLp(wire, off)
        off = o1
        let deviceEd = wire.subdata(in: off..<(off + 32)); off += 32
        let deviceX = wire.subdata(in: off..<(off + 32)); off += 32
        let certHash = wire.subdata(in: off..<(off + 32)); off += 32
        let (issuerId, o2) = try readLp(wire, off)
        off = o2
        let issuerSeq = readU64(wire, off); off += 8
        let revId = wire.subdata(in: off..<(off + 16)); off += 16
        guard revId != Data(count: 16) else { throw CodecError.badLength }
        let reason = wire[off]; off += 1
        let created = readU64(wire, off); off += 8
        let sig = wire.subdata(in: off..<(off + 64)); off += 64
        guard off == wire.count else { throw CodecError.trailingBytes }
        return Record(
            identityAddress: identityAddress,
            deviceId: deviceId,
            deviceEdPub: deviceEd,
            deviceXPub: deviceX,
            deviceCertHash: certHash,
            issuerDeviceId: issuerId,
            issuerSeq: issuerSeq,
            revocationId: revId,
            reasonCode: reason,
            createdAtMs: created,
            signature: sig
        )
    }

    static func verify(_ r: Record, identityEdPub: Data) throws {
        guard RavenAddressV1.encode(ed25519PublicKey: identityEdPub) == r.identityAddress else {
            throw CodecError.verifyFailed
        }
        let pub = try Curve25519.Signing.PublicKey(rawRepresentation: identityEdPub)
        let sb = try signingBytes(r)
        guard pub.isValidSignature(r.signature, for: sb) else { throw CodecError.verifyFailed }
    }

    static func claimDigest(_ wire: Data) -> Data {
        Data(SHA256.hash(data: wire))
    }

    static func storeHash(
        generation: UInt64,
        claimWires: [Data],
        exhausted: [ExhaustedMarker] = [],
        corrupt: [CorruptMarker] = []
    ) throws -> Data {
        let claims = claimWires.sorted { claimDigest($0).lexicographicallyPrecedes(claimDigest($1)) }
        let exh = exhausted.sorted {
            if $0.identityAddress != $1.identityAddress {
                return $0.identityAddress < $1.identityAddress
            }
            return $0.claimDigest.lexicographicallyPrecedes($1.claimDigest)
        }
        let cor = corrupt.sorted { $0.scope < $1.scope }

        var snap = storeDomain
        snap.append(UInt8(0))
        snap.append(u64be(generation))
        snap.append(u32be(UInt32(claims.count)))
        for w in claims {
            let d = claimDigest(w)
            snap.append(d)
            snap.append(u32be(UInt32(w.count)))
            snap.append(w)
        }
        snap.append(u32be(UInt32(exh.count)))
        for e in exh {
            guard claimDigest(e.exactRecordBytes) == e.claimDigest else { throw CodecError.digestMismatch }
            snap.append(try lp(Data(e.identityAddress.utf8)))
            snap.append(e.claimDigest)
            snap.append(u32be(UInt32(e.exactRecordBytes.count)))
            snap.append(e.exactRecordBytes)
        }
        snap.append(u32be(UInt32(cor.count)))
        for c in cor {
            snap.append(try lp(Data(c.scope.utf8)))
            snap.append(c.reasonCode)
        }
        return Data(SHA256.hash(data: snap))
    }

    private static func readLp(_ wire: Data, _ off: Int) throws -> (Data, Int) {
        guard off + 2 <= wire.count else { throw CodecError.badLength }
        let n = Int(wire[off]) << 8 | Int(wire[off + 1])
        guard (1...64).contains(n), off + 2 + n <= wire.count else { throw CodecError.badLength }
        return (wire.subdata(in: (off + 2)..<(off + 2 + n)), off + 2 + n)
    }

    private static func readU64(_ wire: Data, _ off: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(wire[off + i]) }
        return v
    }
}

private extension Data {
    func lexicographicallyPrecedes(_ other: Data) -> Bool {
        for (a, b) in zip(self, other) {
            if a < b { return true }
            if a > b { return false }
        }
        return count < other.count
    }
}
