//
//  ATSAMHybridRatchetV2TR.swift
//  RAVEN
//
//  EC Double Ratchet DH transitions + Raven Braid chunk KATs (production disabled).
//  No live callsites.
//

import CryptoKit
import Foundation

enum ATSAMHybridRatchetV2TR {
    static let productionEnabled = false

    static let braidChunkDomain = Data("ATSAM/v2/braid-chunk".utf8)
    static let braidMagic = Data([0x52, 0x56, 0x42, 0x43, 0x31, 0, 0, 0]) // RVBC1
    /// magic(8) | epoch_u64be(8) | type(1) | index_u32be(4) | plen_u16be(2)
    static let braidHeaderLen = 8 + 8 + 1 + 4 + 2 // 23
    static let braidDigestLen = 32
    /// Per-chunk semantic max aligned with default reassembly total budget.
    static let braidMaxTotalPayloadBytes = 8192
    static let braidMaxPayload = braidMaxTotalPayloadBytes
    static let braidMaxChunksPerEpoch = 64
    /// Binding digest is NOT authentication — outer signature + AEAD provide auth.
    static let maxMkskippedRetained = 2000
    static let braidMlkem768HeaderSize = 64
    /// Signal ek_vector size (not the full FIPS encapsulation key).
    static let braidMlkem768EkVectorSize = 1152
    /// Complete ML-KEM-768 encapsulation key = Header(64) || ek_vector(1152).
    static let braidMlkem768EkFipsSize = 1184
    static let braidMlkem768Ct1Size = 960
    static let braidMlkem768Ct2Size = 128
    static let chunkSize = 42
    static let chunkNone: UInt8 = 0
    static let chunkHdr: UInt8 = 1
    static let chunkEk: UInt8 = 2
    static let chunkEkCt1Ack: UInt8 = 3
    static let chunkCt1Ack: UInt8 = 4
    static let chunkCT1: UInt8 = 5
    static let chunkCT2: UInt8 = 6

    enum Error: Swift.Error, Equatable {
        case badLength
        case allZeroX25519
        case invalidX25519
        case nonContributoryDH
        case noSendingChain
        case noReceivingChain
        case pnBehindNr
        case maxSkipExceeded
        case maxMkskippedRetainedExceeded
        case dhRatchetRequiresNewLocalPriv
        case replayOfConsumedIndex
        case shortBraidChunk
        case badBraidMagic
        case unknownBraidChunkType
        case braidChunkLengthMismatch
        case braidPayloadExceedsMax
        case braidEmptyTypePayloadMustBeEmpty
        case braidEmptyTypeIndexMustBeZero
        case braidDataTypePayloadMustBeNonEmpty
        case badSessionIdLength
        case braidChunkTamper
        case alreadyPromoted
        case incompleteBraid
        case braidExpectedCountOutOfBounds
        case braidEpochOutOfRange
    }

    private static func braidTypeAllowed(_ t: UInt8) -> Bool { t <= 6 }

    private static func braidEmptyPayloadType(_ t: UInt8) -> Bool {
        t == chunkNone || t == chunkCt1Ack
    }

    private static func braidDataPayloadType(_ t: UInt8) -> Bool {
        braidTypeAllowed(t) && !braidEmptyPayloadType(t)
    }

    private static func requireSessionId(_ sessionId: Data) throws {
        guard sessionId.count == 32 else { throw Error.badSessionIdLength }
    }

    private static func validateBraidPayloadRules(type: UInt8, payload: Data, chunkIndex: UInt32) throws {
        guard braidTypeAllowed(type) else { throw Error.unknownBraidChunkType }
        if braidEmptyPayloadType(type) {
            if !payload.isEmpty { throw Error.braidEmptyTypePayloadMustBeEmpty }
            if chunkIndex != 0 { throw Error.braidEmptyTypeIndexMustBeZero }
        } else if braidDataPayloadType(type), payload.isEmpty {
            throw Error.braidDataTypePayloadMustBeNonEmpty
        }
    }

    private static func errorMessage(_ error: Error) -> String {
        switch error {
        case .shortBraidChunk: return "short braid chunk"
        case .badBraidMagic: return "bad braid magic"
        case .unknownBraidChunkType: return "unknown braid chunk type"
        case .braidChunkLengthMismatch: return "braid chunk length mismatch"
        case .braidPayloadExceedsMax: return "braid payload exceeds max"
        case .braidEmptyTypePayloadMustBeEmpty: return "braid empty-type payload must be empty"
        case .braidEmptyTypeIndexMustBeZero: return "braid empty-type chunk_index must be 0"
        case .braidDataTypePayloadMustBeNonEmpty: return "braid data-type payload must be non-empty"
        case .badSessionIdLength: return "session_id must be 32 bytes"
        case .braidChunkTamper: return "braid chunk tamper"
        case .maxMkskippedRetainedExceeded: return "MAX_MKSKIPPED_RETAINED exceeded"
        case .maxSkipExceeded: return "MAX_SKIP exceeded"
        case .braidEpochOutOfRange: return "braid epoch must be u64"
        default: return String(describing: error)
        }
    }

    // MARK: - X25519

    static func x25519Public(_ priv: Data) throws -> Data {
        guard priv.count == 32, priv != Data(count: 32) else {
            throw Error.allZeroX25519
        }
        do {
            let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: priv)
            return key.publicKey.rawRepresentation
        } catch {
            throw Error.invalidX25519
        }
    }

    static func x25519DH(_ priv: Data, _ pub: Data) throws -> Data {
        guard priv.count == 32, pub.count == 32 else { throw Error.badLength }
        guard priv != Data(count: 32), pub != Data(count: 32) else {
            throw Error.allZeroX25519
        }
        do {
            let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: priv)
            let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pub)
            let ss = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
            let out = ss.withUnsafeBytes { Data($0) }
            guard out != Data(count: 32) else { throw Error.nonContributoryDH }
            return out
        } catch let err as Error {
            throw err
        } catch {
            throw Error.invalidX25519
        }
    }

    private static func negativeX25519Message(_ error: Error) -> String {
        switch error {
        case .allZeroX25519: return "all-zero X25519 rejected"
        case .nonContributoryDH: return "non-contributory DH rejected"
        default: return "invalid X25519 input"
        }
    }

    // MARK: - EC Double Ratchet

    struct EcDrHeader: Equatable {
        var dhPub: Data
        var pn: UInt32
        var n: UInt32
    }

    struct EcDrState: Equatable {
        var rk: Data
        var dhsPriv: Data
        var dhsPub: Data
        var dhrPub: Data?
        var cks: Data?
        var ckr: Data?
        var ns: UInt32 = 0
        var nr: UInt32 = 0
        var pn: UInt32 = 0
        var mkskipped: [Data: Data] = [:]

        func fingerprint() -> Data {
            var items = Data()
            for key in mkskipped.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                items.append(key)
                items.append(mkskipped[key]!)
            }
            var nsBE = ns.bigEndian
            var nrBE = nr.bigEndian
            var pnBE = pn.bigEndian
            return Data(
                SHA256.hash(
                    data: rk
                        + dhsPub
                        + (dhrPub ?? Data(count: 32))
                        + (cks ?? Data(count: 32))
                        + (ckr ?? Data(count: 32))
                        + Data(bytes: &nsBE, count: 4)
                        + Data(bytes: &nrBE, count: 4)
                        + Data(bytes: &pnBE, count: 4)
                        + items
                )
            )
        }
    }

    private static func mkKey(dhPub: Data, n: UInt32) -> Data {
        var be = n.bigEndian
        return dhPub + Data(bytes: &be, count: 4)
    }

    static func ecDrInitAlice(rk0: Data, alicePriv: Data, bobPub: Data) throws -> EcDrState {
        let ss = try x25519DH(alicePriv, bobPub)
        let (rk1, cks) = try ATSAMHybridRatchetV2.kdfRK(rk: rk0, dhOut: ss)
        return EcDrState(
            rk: rk1,
            dhsPriv: alicePriv,
            dhsPub: try x25519Public(alicePriv),
            dhrPub: bobPub,
            cks: cks,
            ckr: nil
        )
    }

    static func ecDrInitBob(rk0: Data, bobPriv: Data) throws -> EcDrState {
        EcDrState(
            rk: rk0,
            dhsPriv: bobPriv,
            dhsPub: try x25519Public(bobPriv),
            dhrPub: nil,
            cks: nil,
            ckr: nil
        )
    }

    static func ecDrEncrypt(_ state: EcDrState, plaintextLabel: Data = Data()) throws -> (EcDrState, EcDrHeader, Data) {
        guard let cks = state.cks else { throw Error.noSendingChain }
        let (ck2, mk) = try ATSAMHybridRatchetV2.kdfCK(ck: cks)
        let header = EcDrHeader(dhPub: state.dhsPub, pn: state.pn, n: state.ns)
        let out = EcDrState(
            rk: state.rk,
            dhsPriv: state.dhsPriv,
            dhsPub: state.dhsPub,
            dhrPub: state.dhrPub,
            cks: ck2,
            ckr: state.ckr,
            ns: state.ns &+ 1,
            nr: state.nr,
            pn: state.pn,
            mkskipped: state.mkskipped
        )
        _ = plaintextLabel
        return (out, header, mk)
    }

    private static func dhRatchet(_ state: EcDrState, theirDH: Data, newLocalPriv: Data) throws -> EcDrState {
        let ss1 = try x25519DH(state.dhsPriv, theirDH)
        let (rk1, ckr) = try ATSAMHybridRatchetV2.kdfRK(rk: state.rk, dhOut: ss1)
        let localPub = try x25519Public(newLocalPriv)
        let ss2 = try x25519DH(newLocalPriv, theirDH)
        let (rk2, cks) = try ATSAMHybridRatchetV2.kdfRK(rk: rk1, dhOut: ss2)
        return EcDrState(
            rk: rk2,
            dhsPriv: newLocalPriv,
            dhsPub: localPub,
            dhrPub: theirDH,
            cks: cks,
            ckr: ckr,
            ns: 0,
            nr: 0,
            pn: state.ns,
            mkskipped: state.mkskipped
        )
    }

    static func ecDrDecrypt(
        _ state: EcDrState,
        header: EcDrHeader,
        maxSkip: Int = ATSAMHybridRatchetV2.maxSkip,
        newLocalPriv: Data? = nil,
        maxMkskipped: Int = maxMkskippedRetained
    ) throws -> (EcDrState, Data) {
        let dh = header.dhPub
        let n = header.n
        let pn = header.pn

        let key = mkKey(dhPub: dh, n: n)
        if let mk = state.mkskipped[key] {
            var skipped = state.mkskipped
            skipped.removeValue(forKey: key)
            let out = EcDrState(
                rk: state.rk,
                dhsPriv: state.dhsPriv,
                dhsPub: state.dhsPub,
                dhrPub: state.dhrPub,
                cks: state.cks,
                ckr: state.ckr,
                ns: state.ns,
                nr: state.nr,
                pn: state.pn,
                mkskipped: skipped
            )
            return (out, mk)
        }

        func insertSkipped(_ skipped: inout [Data: Data], key: Data, mkI: Data) throws {
            if skipped[key] != nil { return }
            if skipped.count >= maxMkskipped { throw Error.maxMkskippedRetainedExceeded }
            skipped[key] = mkI
        }

        var st = state
        if st.dhrPub == nil || dh != st.dhrPub {
            if st.dhrPub != nil, st.ckr != nil {
                let skipUntil = pn
                if skipUntil < st.nr { throw Error.pnBehindNr }
                if Int(skipUntil &- st.nr) > maxSkip { throw Error.maxSkipExceeded }
                var ck = st.ckr!
                var nr = st.nr
                var skipped = st.mkskipped
                while nr < skipUntil {
                    let (ckNext, mkI) = try ATSAMHybridRatchetV2.kdfCK(ck: ck)
                    try insertSkipped(&skipped, key: mkKey(dhPub: st.dhrPub!, n: nr), mkI: mkI)
                    ck = ckNext
                    nr &+= 1
                }
                st = EcDrState(
                    rk: st.rk,
                    dhsPriv: st.dhsPriv,
                    dhsPub: st.dhsPub,
                    dhrPub: st.dhrPub,
                    cks: st.cks,
                    ckr: ck,
                    ns: st.ns,
                    nr: nr,
                    pn: st.pn,
                    mkskipped: skipped
                )
            }
            guard let newLocalPriv else { throw Error.dhRatchetRequiresNewLocalPriv }
            st = try dhRatchet(st, theirDH: dh, newLocalPriv: newLocalPriv)
        }

        guard let ckr = st.ckr else { throw Error.noReceivingChain }
        if n < st.nr { throw Error.replayOfConsumedIndex }
        if n > st.nr {
            if Int(n &- st.nr) > maxSkip { throw Error.maxSkipExceeded }
            var ck = ckr
            var nr = st.nr
            var skipped = st.mkskipped
            while nr < n {
                let (ckNext, mkI) = try ATSAMHybridRatchetV2.kdfCK(ck: ck)
                try insertSkipped(&skipped, key: mkKey(dhPub: st.dhrPub!, n: nr), mkI: mkI)
                ck = ckNext
                nr &+= 1
            }
            st = EcDrState(
                rk: st.rk,
                dhsPriv: st.dhsPriv,
                dhsPub: st.dhsPub,
                dhrPub: st.dhrPub,
                cks: st.cks,
                ckr: ck,
                ns: st.ns,
                nr: nr,
                pn: st.pn,
                mkskipped: skipped
            )
        }

        let (ck2, mk) = try ATSAMHybridRatchetV2.kdfCK(ck: st.ckr!)
        let out = EcDrState(
            rk: st.rk,
            dhsPriv: st.dhsPriv,
            dhsPub: st.dhsPub,
            dhrPub: st.dhrPub,
            cks: st.cks,
            ckr: ck2,
            ns: st.ns,
            nr: st.nr &+ 1,
            pn: st.pn,
            mkskipped: st.mkskipped
        )
        return (out, mk)
    }

    static func runEcDhRatchetMatrix(
        rk0: Data,
        alicePriv0: Data,
        bobPriv0: Data,
        bobPriv1: Data,
        alicePriv1: Data
    ) throws -> [String: Any] {
        var alice = try ecDrInitAlice(rk0: rk0, alicePriv: alicePriv0, bobPub: try x25519Public(bobPriv0))
        var bob = try ecDrInitBob(rk0: rk0, bobPriv: bobPriv0)

        struct Sealed {
            var header: EcDrHeader
            var mk: Data
        }
        var sealed: [Sealed] = []
        for _ in 0..<2 {
            let (a, hdr, mk) = try ecDrEncrypt(alice)
            alice = a
            sealed.append(Sealed(header: hdr, mk: mk))
        }

        var mk1: Data
        (bob, mk1) = try ecDrDecrypt(
            bob,
            header: sealed[1].header,
            newLocalPriv: bobPriv1
        )
        precondition(mk1 == sealed[1].mk)

        var mk0: Data
        (bob, mk0) = try ecDrDecrypt(bob, header: sealed[0].header)
        precondition(mk0 == sealed[0].mk)

        var bobHdr: EcDrHeader
        var bobMk: Data
        (bob, bobHdr, bobMk) = try ecDrEncrypt(bob)

        var amk: Data
        (alice, amk) = try ecDrDecrypt(alice, header: bobHdr, newLocalPriv: alicePriv1)
        precondition(amk == bobMk)

        var neg: [String: String] = [:]
        do {
            _ = try x25519DH(alicePriv0, Data(count: 32))
            neg["all_zero_pub"] = "accepted"
        } catch {
            neg["all_zero_pub"] = negativeX25519Message(error as? Error ?? .invalidX25519)
        }
        do {
            _ = try x25519Public(Data(count: 32))
            neg["all_zero_priv"] = "accepted"
        } catch {
            neg["all_zero_priv"] = negativeX25519Message(error as? Error ?? .invalidX25519)
        }

        let headers: [[String: Any]] = sealed.map {
            [
                "dh_pub_hex": $0.header.dhPub.hexString,
                "pn": Int($0.header.pn),
                "n": Int($0.header.n),
            ] as [String: Any]
        }

        return [
            "alice_pub0_hex": try x25519Public(alicePriv0).hexString,
            "bob_pub0_hex": try x25519Public(bobPriv0).hexString,
            "bob_pub1_hex": try x25519Public(bobPriv1).hexString,
            "alice_pub1_hex": try x25519Public(alicePriv1).hexString,
            "recv_order": [1, 0],
            "alice_mks_hex": sealed.map { $0.mk.hexString },
            "bob_recovered_mks_hex": [mk0.hexString, mk1.hexString],
            "bob_send_mk_hex": bobMk.hexString,
            "alice_recovered_bob_mk_hex": amk.hexString,
            "cross_boundary_ok": true,
            "headers": headers,
            "bob_header": [
                "dh_pub_hex": bobHdr.dhPub.hexString,
                "pn": Int(bobHdr.pn),
                "n": Int(bobHdr.n),
            ] as [String: Any],
            "negatives": neg,
            "final_alice_fp_hex": alice.fingerprint().hexString,
            "final_bob_fp_hex": bob.fingerprint().hexString,
        ]
    }

    // MARK: - Braid chunk codec

    struct BraidChunk: Equatable {
        var epoch: UInt64
        var type: UInt8
        var chunkIndex: UInt32
        var payload: Data
        var sessionId: Data
        var bindingDigest: Data = Data()
    }

    static func braidBinding(_ chunk: BraidChunk) throws -> Data {
        try requireSessionId(chunk.sessionId)
        var epochBE = chunk.epoch.bigEndian
        var idxBE = chunk.chunkIndex.bigEndian
        return Data(
            SHA256.hash(
                data: braidChunkDomain
                    + Data(bytes: &epochBE, count: 8)
                    + Data([chunk.type & 0xFF])
                    + Data(bytes: &idxBE, count: 4)
                    + chunk.payload
                    + chunk.sessionId
            )
        )
    }

    static func encodeBraidChunk(_ chunk: BraidChunk) throws -> Data {
        try requireSessionId(chunk.sessionId)
        try validateBraidPayloadRules(type: chunk.type, payload: chunk.payload, chunkIndex: chunk.chunkIndex)
        guard chunk.payload.count <= braidMaxPayload else { throw Error.braidPayloadExceedsMax }
        let dig = try braidBinding(chunk)
        var epochBE = chunk.epoch.bigEndian
        var idxBE = chunk.chunkIndex.bigEndian
        var plenBE = UInt16(chunk.payload.count).bigEndian
        var out = braidMagic
        out.append(Data(bytes: &epochBE, count: 8))
        out.append(chunk.type)
        out.append(Data(bytes: &idxBE, count: 4))
        out.append(Data(bytes: &plenBE, count: 2))
        out.append(chunk.payload)
        out.append(dig)
        return out
    }

    static func decodeBraidChunk(_ wire: Data, sessionId: Data) throws -> BraidChunk {
        // Fail-closed: wire.count == braidHeaderLen + plen + braidDigestLen
        try requireSessionId(sessionId)
        guard wire.count >= braidHeaderLen + braidDigestLen else { throw Error.shortBraidChunk }
        guard wire.prefix(8) == braidMagic else { throw Error.badBraidMagic }
        let typ = wire[8 + 8]
        guard braidTypeAllowed(typ) else { throw Error.unknownBraidChunkType }
        let plenOff = 8 + 8 + 1 + 4
        let plen = Int(wire.subdata(in: plenOff..<(plenOff + 2)).reduce(0) { ($0 << 8) | UInt16($1) })
        let expected = braidHeaderLen + plen + braidDigestLen
        guard wire.count == expected else { throw Error.braidChunkLengthMismatch }
        guard plen <= braidMaxPayload else { throw Error.braidPayloadExceedsMax }
        var off = 8
        let epoch = wire.subdata(in: off..<(off + 8)).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        off += 8
        off += 1 // type
        let idx = wire.subdata(in: off..<(off + 4)).reduce(0) { ($0 << 8) | UInt32($1) }
        off += 4
        off += 2 // plen
        let payload = wire.subdata(in: off..<(off + plen))
        off += plen
        let dig = wire.subdata(in: off..<(off + braidDigestLen))
        try validateBraidPayloadRules(type: typ, payload: payload, chunkIndex: idx)
        let chunk = BraidChunk(
            epoch: epoch,
            type: typ,
            chunkIndex: idx,
            payload: payload,
            sessionId: sessionId,
            bindingDigest: dig
        )
        guard try braidBinding(chunk) == dig else { throw Error.braidChunkTamper }
        return chunk
    }

    struct BraidReassembly {
        var epoch: UInt64
        var expectedCount: Int
        var parts: [UInt32: Data] = [:]
        private(set) var promoted = false
        private(set) var deletedPrevDk = false
        private(set) var prevDk: Data?
        var totalPayloadBytes = 0
        var maxChunks = braidMaxChunksPerEpoch
        var maxTotalBytes = braidMaxTotalPayloadBytes

        init(epoch: UInt64, expectedCount: Int) throws {
            guard expectedCount > 0, expectedCount <= braidMaxChunksPerEpoch else {
                throw Error.braidExpectedCountOutOfBounds
            }
            self.epoch = epoch
            self.expectedCount = expectedCount
        }

        mutating func ingest(_ chunk: BraidChunk) -> String {
            if chunk.epoch != epoch { return "epoch_mismatch" }
            if !braidTypeAllowed(chunk.type) { return "unknown_type" }
            if Int(chunk.chunkIndex) >= expectedCount { return "index_out_of_range" }
            if parts[chunk.chunkIndex] != nil { return "duplicate_chunk" }
            if parts.count >= maxChunks { return "chunk_cap_exceeded" }
            let nxt = totalPayloadBytes + chunk.payload.count
            if nxt > maxTotalBytes { return "byte_cap_exceeded" }
            parts[chunk.chunkIndex] = chunk.payload
            totalPayloadBytes = nxt
            return "stored"
        }

        func tryComplete() -> Data? {
            for i in 0..<expectedCount {
                guard parts[UInt32(i)] != nil else { return nil }
            }
            var out = Data()
            for i in 0..<expectedCount {
                out.append(parts[UInt32(i)]!)
            }
            return out
        }

        mutating func promoteWithSS(_ ss: Data, prevDk: Data) throws -> Data {
            if promoted { throw Error.alreadyPromoted }
            guard tryComplete() != nil else { throw Error.incompleteBraid }
            self.prevDk = Data(count: prevDk.count)
            deletedPrevDk = true
            promoted = true
            return ss
        }
    }

    static func loadMlkem768HybridKat(from vectorsRoot: URL) throws -> (ek: Data, ct: Data, zPQ: Data) {
        let url = vectorsRoot.appendingPathComponent("mlkem768_hybrid_kat_001.json")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let expected = json?["expected"] as? [String: Any]
        guard let exp = expected,
              let ekHex = exp["mlkem_ek_hex"] as? String,
              let ctHex = exp["mlkem_ct_hex"] as? String,
              let zHex = exp["z_pq_hex"] as? String else {
            throw Error.badLength
        }
        return (hexData(ekHex), hexData(ctHex), hexData(zHex))
    }

    static func runBraidKemChunkMatrix(sessionId: Data, skScka: Data, vectorsRoot: URL) throws -> [String: Any] {
        let kat = try loadMlkem768HybridKat(from: vectorsRoot)
        let ek = kat.ek
        let ct = kat.ct
        let zPQ = kat.zPQ

        let pieces = stride(from: 0, to: ct.count, by: chunkSize).map {
            ct.subdata(in: $0..<min($0 + chunkSize, ct.count))
        }

        var wires: [Data] = []
        for (i, payload) in pieces.enumerated() {
            let typ: UInt8 = i == pieces.count - 1 ? chunkCT2 : chunkCT1
            let ch = BraidChunk(epoch: 1, type: typ, chunkIndex: UInt32(i), payload: payload, sessionId: sessionId)
            wires.append(try encodeBraidChunk(ch))
        }

        var order = Array(0..<pieces.count)
        order = Array(order[2...] + order[..<2])

        var reb = try BraidReassembly(epoch: 1, expectedCount: pieces.count)
        for idx in order {
            let ch = try decodeBraidChunk(wires[idx], sessionId: sessionId)
            precondition(reb.ingest(ch) == "stored")
        }
        let body = reb.tryComplete()
        precondition(body == ct)

        var tamperResult = "accepted"
        do {
            var tampered = Data(wires[0])
            tampered[tampered.count - 1] ^= 0x01
            _ = try decodeBraidChunk(tampered, sessionId: sessionId)
        } catch Error.braidChunkTamper {
            tamperResult = "braid chunk tamper"
        } catch {
            tamperResult = "\(error)"
        }

        let prevDk = Data(SHA256.hash(data: Data("prev-epoch-dk".utf8)))
        let ss = try reb.promoteWithSS(zPQ, prevDk: prevDk)

        var alice = try ATSAMHybridRatchetV2State.sckaFromInit(alice: true, skScka: skScka)
        var bob = try ATSAMHybridRatchetV2State.sckaFromInit(alice: false, skScka: skScka)
        let aliceP = try ATSAMHybridRatchetV2State.sckaEpochPromoteInitiator(alice, ss: ss)
        let bobP = try ATSAMHybridRatchetV2State.sckaEpochPromoteResponder(bob, ss: ss)
        _ = alice
        _ = bob

        return [
            "mlkem_source": "atsam/mlkem768_hybrid_kat_001.json",
            "ek_len": ek.count,
            "ct_len": ct.count,
            "z_pq_hex": zPQ.hexString,
            "chunk_count": pieces.count,
            "chunk_size": chunkSize,
            "deliver_order": order,
            "reassembled_ct_ok": body == ct,
            "tamper_result": tamperResult,
            "epoch_promoted": reb.promoted,
            "prev_dk_zeroed": reb.deletedPrevDk,
            "scka_rk_hex": aliceP.rk.hexString,
            "alice_ck_send_hex": aliceP.ckSend.hexString,
            "bob_ck_recv_hex": bobP.ckRecv.hexString,
            "first_chunk_wire_hex": wires[0].hexString,
            "hdr_chunk_type": Int(chunkHdr),
            "ct1_chunk_type": Int(chunkCT1),
            "ct2_chunk_type": Int(chunkCT2),
        ]
    }

    static func runBraidCodecNegatives(sessionId: Data) throws -> [String: Any] {
        var cases: [[String: Any]] = []

        let good = try encodeBraidChunk(
            BraidChunk(epoch: 1, type: chunkCT1, chunkIndex: 0, payload: Data("abc".utf8), sessionId: sessionId)
        )

        do {
            _ = try decodeBraidChunk(Data(good.prefix(good.count - 5)), sessionId: sessionId)
            cases.append(["name": "truncated_plen", "result": "accepted"])
        } catch let err as Error {
            cases.append(["name": "truncated_plen", "result": "reject", "reason": errorMessage(err)])
        }

        do {
            var trailing = good
            trailing.append(0)
            _ = try decodeBraidChunk(trailing, sessionId: sessionId)
            cases.append(["name": "trailing_bytes", "result": "accepted"])
        } catch let err as Error {
            cases.append(["name": "trailing_bytes", "result": "reject", "reason": errorMessage(err)])
        }

        // Oversized plen field vs actual bytes present
        var over = Data()
        over.append(braidMagic)
        var epochBE = UInt64(1).bigEndian
        over.append(Data(bytes: &epochBE, count: 8))
        over.append(chunkCT1)
        var idxBE = UInt32(0).bigEndian
        over.append(Data(bytes: &idxBE, count: 4))
        var plenBE = UInt16(1000).bigEndian
        over.append(Data(bytes: &plenBE, count: 2))
        over.append(0x78) // "x"
        let tmp = BraidChunk(epoch: 1, type: chunkCT1, chunkIndex: 0, payload: Data([0x78]), sessionId: sessionId)
        over.append(try braidBinding(tmp))
        do {
            _ = try decodeBraidChunk(over, sessionId: sessionId)
            cases.append(["name": "oversized_plen_field", "result": "accepted"])
        } catch let err as Error {
            cases.append(["name": "oversized_plen_field", "result": "reject", "reason": errorMessage(err)])
        }

        do {
            _ = try encodeBraidChunk(
                BraidChunk(epoch: 1, type: 99, chunkIndex: 0, payload: Data([0x78]), sessionId: sessionId)
            )
            cases.append(["name": "encode_unknown_type", "result": "accepted"])
        } catch let err as Error {
            cases.append(["name": "encode_unknown_type", "result": "reject", "reason": errorMessage(err)])
        }

        do {
            _ = try encodeBraidChunk(
                BraidChunk(
                    epoch: 1,
                    type: chunkCT1,
                    chunkIndex: 0,
                    payload: Data(count: braidMaxPayload + 1),
                    sessionId: sessionId
                )
            )
            cases.append(["name": "encode_payload_gt_max", "result": "accepted"])
        } catch let err as Error {
            cases.append(["name": "encode_payload_gt_max", "result": "reject", "reason": errorMessage(err)])
        }

        do {
            _ = try encodeBraidChunk(
                BraidChunk(
                    epoch: 1,
                    type: chunkCT1,
                    chunkIndex: 0,
                    payload: Data([0x78]),
                    sessionId: Data("short".utf8)
                )
            )
            cases.append(["name": "session_id_bad_len", "result": "accepted"])
        } catch let err as Error {
            cases.append(["name": "session_id_bad_len", "result": "reject", "reason": errorMessage(err)])
        }

        do {
            _ = try encodeBraidChunk(
                BraidChunk(
                    epoch: 1,
                    type: chunkCt1Ack,
                    chunkIndex: 0,
                    payload: Data([0x78]),
                    sessionId: sessionId
                )
            )
            cases.append(["name": "empty_type_nonempty_payload", "result": "accepted"])
        } catch let err as Error {
            cases.append(["name": "empty_type_nonempty_payload", "result": "reject", "reason": errorMessage(err)])
        }

        do {
            _ = try encodeBraidChunk(
                BraidChunk(
                    epoch: 1,
                    type: chunkCT1,
                    chunkIndex: 0,
                    payload: Data(),
                    sessionId: sessionId
                )
            )
            cases.append(["name": "data_type_empty_payload", "result": "accepted"])
        } catch let err as Error {
            cases.append(["name": "data_type_empty_payload", "result": "reject", "reason": errorMessage(err)])
        }

        do {
            _ = try encodeBraidChunk(
                BraidChunk(
                    epoch: 1,
                    type: chunkNone,
                    chunkIndex: 1,
                    payload: Data(),
                    sessionId: sessionId
                )
            )
            cases.append(["name": "empty_type_nonzero_index", "result": "accepted"])
        } catch let err as Error {
            cases.append(["name": "empty_type_nonzero_index", "result": "reject", "reason": errorMessage(err)])
        }

        var reb = try BraidReassembly(epoch: 1, expectedCount: 2)
        let ch = BraidChunk(epoch: 1, type: chunkCT1, chunkIndex: 2, payload: Data([0x7A]), sessionId: sessionId)
        cases.append(["name": "ingest_index_oob", "result": reb.ingest(ch)])

        var reb2 = try BraidReassembly(epoch: 1, expectedCount: 2)
        reb2.maxTotalBytes = 10
        let a = BraidChunk(epoch: 1, type: chunkCT1, chunkIndex: 0, payload: Data(count: 8), sessionId: sessionId)
        let b = BraidChunk(epoch: 1, type: chunkCT1, chunkIndex: 1, payload: Data(count: 8), sessionId: sessionId)
        precondition(reb2.ingest(a) == "stored")
        cases.append(["name": "ingest_byte_cap", "result": reb2.ingest(b)])

        cases.append([
            "name": "binding_digest_role",
            "result": "canonical_binding_only",
            "note": "auth via outer signature then AEAD; SHA-256 binding is not a MAC",
        ] as [String: Any])

        cases.append([
            "name": "epoch_width_policy",
            "result": "u64be_no_wrap",
            "note": "EPOCH_TYPE=u64; ToBytes=big-endian; MUST NOT wrap on increment",
        ] as [String: Any])

        let alicePriv = Data(SHA256.hash(data: Data("atsam-v2/mkskip-cap/a0".utf8)))
        let bobPriv = Data(SHA256.hash(data: Data("atsam-v2/mkskip-cap/b0".utf8)))
        let bobPriv2 = Data(SHA256.hash(data: Data("atsam-v2/mkskip-cap/b1".utf8)))
        let rk0 = Data(SHA256.hash(data: Data("atsam-v2/mkskip-cap/rk".utf8)))
        var alice = try ecDrInitAlice(rk0: rk0, alicePriv: alicePriv, bobPub: try x25519Public(bobPriv))
        let bob = try ecDrInitBob(rk0: rk0, bobPriv: bobPriv)
        var sealed: [(EcDrHeader, Data)] = []
        for _ in 0..<5 {
            var hdr: EcDrHeader
            var mk: Data
            (alice, hdr, mk) = try ecDrEncrypt(alice)
            sealed.append((hdr, mk))
        }
        do {
            _ = try ecDrDecrypt(bob, header: sealed[4].0, newLocalPriv: bobPriv2, maxMkskipped: 2)
            cases.append(["name": "mkskipped_global_cap", "result": "accepted"])
        } catch let err as Error {
            cases.append(["name": "mkskipped_global_cap", "result": "reject", "reason": errorMessage(err)])
        }

        return [
            "braid_header_len": braidHeaderLen,
            "braid_digest_len": braidDigestLen,
            "braid_max_payload": braidMaxPayload,
            "braid_max_chunks": braidMaxChunksPerEpoch,
            "braid_max_total_bytes": braidMaxTotalPayloadBytes,
            "max_mkskipped_retained": maxMkskippedRetained,
            "epoch_type": "u64",
            "mlkem768_header_size": braidMlkem768HeaderSize,
            "mlkem768_ek_vector_size": braidMlkem768EkVectorSize,
            "mlkem768_ek_fips_size": braidMlkem768EkFipsSize,
            "mlkem768_ct1_size": braidMlkem768Ct1Size,
            "mlkem768_ct2_size": braidMlkem768Ct2Size,
            "cases": cases,
        ]
    }

    static func runTrComboMatrix(
        skEc: Data,
        skScka: Data,
        sessionId: Data,
        alicePriv0: Data,
        bobPriv0: Data,
        bobPriv1: Data,
        alicePriv1: Data,
        ssScka1: Data,
        ssScka2: Data
    ) throws -> [String: Any] {
        var alice = try ecDrInitAlice(rk0: skEc, alicePriv: alicePriv0, bobPub: try x25519Public(bobPriv0))
        var bob = try ecDrInitBob(rk0: skEc, bobPriv: bobPriv0)
        var aScka = try ATSAMHybridRatchetV2State.sckaFromInit(alice: true, skScka: skScka)
        var bScka = try ATSAMHybridRatchetV2State.sckaFromInit(alice: false, skScka: skScka)
        var steps: [[String: Any]] = []

        var h0: EcDrHeader
        var mkA0: Data
        (alice, h0, mkA0) = try ecDrEncrypt(alice)
        var h1: EcDrHeader
        var mkA1: Data
        (alice, h1, mkA1) = try ecDrEncrypt(alice)

        var mk1: Data
        (bob, mk1) = try ecDrDecrypt(bob, header: h1, newLocalPriv: bobPriv1)
        var mk0: Data
        (bob, mk0) = try ecDrDecrypt(bob, header: h0)
        precondition(mk0 == mkA0 && mk1 == mkA1)

        var pq0: Data
        (aScka, pq0) = try ATSAMHybridRatchetV2State.sckaNextSendMk(aScka)
        var pq0b: Data
        (bScka, pq0b) = try ATSAMHybridRatchetV2State.sckaNextRecvMk(bScka)
        let (hy0, _) = try ATSAMHybridRatchetV2.kdfHybrid(ecMk: mk0, sckaMk: pq0)
        steps.append(["phase": "ec0_ooo", "hybrid_key_hex": hy0.hexString])

        aScka = try ATSAMHybridRatchetV2State.sckaEpochPromoteInitiator(aScka, ss: ssScka1)
        bScka = try ATSAMHybridRatchetV2State.sckaEpochPromoteResponder(bScka, ss: ssScka1)
        steps.append([
            "phase": "scka1",
            "rk_hex": aScka.rk.hexString,
            "alice_send_equals_bob_recv": aScka.ckSend == bScka.ckRecv,
        ] as [String: Any])

        var hb: EcDrHeader
        var mkB: Data
        (bob, hb, mkB) = try ecDrEncrypt(bob)
        var mkb: Data
        (alice, mkb) = try ecDrDecrypt(alice, header: hb, newLocalPriv: alicePriv1)
        precondition(mkb == mkB)

        let bScka2 = try ATSAMHybridRatchetV2State.sckaEpochPromoteInitiator(bScka, ss: ssScka2)
        let aScka2 = try ATSAMHybridRatchetV2State.sckaEpochPromoteResponder(aScka, ss: ssScka2)
        var bScka2Mut = bScka2
        var pqB: Data
        (bScka2Mut, pqB) = try ATSAMHybridRatchetV2State.sckaNextSendMk(bScka2)
        var aScka2Mut = aScka2
        var pqA: Data
        (aScka2Mut, pqA) = try ATSAMHybridRatchetV2State.sckaNextRecvMk(aScka2)
        precondition(pqB == pqA)
        let (hy1, _) = try ATSAMHybridRatchetV2.kdfHybrid(ecMk: mkb, sckaMk: pqB)
        steps.append([
            "phase": "ec1_scka2",
            "hybrid_key_hex": hy1.hexString,
            "bob_send_equals_alice_recv": bScka2Mut.ckSend == aScka2Mut.ckRecv,
            "alice_dh_pub1_hex": alice.dhsPub.hexString,
            "bob_dh_pub1_hex": bob.dhsPub.hexString,
        ] as [String: Any])

        return [
            "dh_epochs": 2,
            "scka_epochs": 2,
            "session_id_hex": sessionId.hexString,
            "steps": steps,
            "final_alice_ec_fp_hex": alice.fingerprint().hexString,
            "final_bob_ec_fp_hex": bob.fingerprint().hexString,
        ]
    }

    private static func hexData(_ value: String) -> Data {
        precondition(value.count.isMultiple(of: 2))
        var result = Data(capacity: value.count / 2)
        var cursor = value.startIndex
        while cursor < value.endIndex {
            let next = value.index(cursor, offsetBy: 2)
            result.append(UInt8(value[cursor..<next], radix: 16)!)
            cursor = next
        }
        return result
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
