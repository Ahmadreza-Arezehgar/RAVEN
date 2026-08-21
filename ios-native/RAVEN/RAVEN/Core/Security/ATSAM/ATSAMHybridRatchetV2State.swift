//
//  ATSAMHybridRatchetV2State.swift
//  RAVEN
//
//  Stateful KATs for hybrid-ratchet/v2 (production disabled). No live callsites.
//

import CryptoKit
import Foundation

enum ATSAMHybridRatchetV2State {
    static let productionEnabled = false
    static let msPerDay: Int64 = 86_400_000
    static let routeTagDomain = Data("ATSAM/v2/route".utf8)
    static let mailboxTagDomain = Data("ATSAM/v2/mailbox".utf8)
    static let storeTagDomain = Data("raven/relay-tag/v1".utf8)

    enum Error: Swift.Error, Equatable {
        case badLength, maxSkipExceeded, behind, replay, badState, crashForbidden
    }

    struct SckaEpochState: Equatable {
        var rk: Data
        var ckSend: Data
        var ckRecv: Data
        var sendingEpoch: UInt32 = 0
        var receivingEpoch: UInt32 = 0
        var sendCtr: UInt32 = 0
        var recvCtr: UInt32 = 0
    }

    static func kdfSckaRK(rk: Data, ss: Data) throws -> (Data, Data) {
        guard rk.count == 32, ss.count == 32 else { throw Error.badLength }
        guard ss != Data(count: 32) else { throw Error.badLength }
        let okm = ATSAMHybridRatchetV2.hkdf(
            ikm: ss,
            salt: rk,
            info: ATSAMHybridRatchetV2.spqrProtocolInfo,
            length: 64
        )
        return (Data(okm.prefix(32)), Data(okm.suffix(32)))
    }

    static func sckaFromInit(alice: Bool, skScka: Data) throws -> SckaEpochState {
        let boot = alice
            ? try ATSAMHybridRatchetV2.ratchetInitAliceSCKA(skScka: skScka)
            : try ATSAMHybridRatchetV2.ratchetInitBobSCKA(skScka: skScka)
        return SckaEpochState(rk: boot.rk, ckSend: boot.ckSend, ckRecv: boot.ckRecv)
    }

    static func sckaEpochPromoteInitiator(_ state: SckaEpochState, ss: Data) throws -> SckaEpochState {
        let (rk2, ck) = try kdfSckaRK(rk: state.rk, ss: ss)
        return SckaEpochState(
            rk: rk2,
            ckSend: ck,
            ckRecv: state.ckRecv,
            sendingEpoch: state.sendingEpoch &+ 1,
            receivingEpoch: state.receivingEpoch,
            sendCtr: 0,
            recvCtr: state.recvCtr
        )
    }

    static func sckaEpochPromoteResponder(_ state: SckaEpochState, ss: Data) throws -> SckaEpochState {
        let (rk2, ck) = try kdfSckaRK(rk: state.rk, ss: ss)
        return SckaEpochState(
            rk: rk2,
            ckSend: state.ckSend,
            ckRecv: ck,
            sendingEpoch: state.sendingEpoch,
            receivingEpoch: state.receivingEpoch &+ 1,
            sendCtr: state.sendCtr,
            recvCtr: 0
        )
    }

    static func sckaNextSendMk(_ state: SckaEpochState) throws -> (SckaEpochState, Data) {
        let (ck2, mk) = try ATSAMHybridRatchetV2.kdfCK(ck: state.ckSend)
        var out = state
        out.ckSend = ck2
        out.sendCtr &+= 1
        return (out, mk)
    }

    static func sckaNextRecvMk(_ state: SckaEpochState) throws -> (SckaEpochState, Data) {
        let (ck2, mk) = try ATSAMHybridRatchetV2.kdfCK(ck: state.ckRecv)
        var out = state
        out.ckRecv = ck2
        out.recvCtr &+= 1
        return (out, mk)
    }

    private static func mkKey(dhPub: Data, n: UInt32) -> Data {
        var be = n.bigEndian
        return dhPub + Data(bytes: &be, count: 4)
    }

    struct EcRecvState {
        var ck: Data
        var n: UInt32
        var dhPub: Data
        var mkskipped: [Data: Data] = [:]

        func fingerprint() -> Data {
            var items = Data()
            for key in mkskipped.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                items.append(key)
                items.append(mkskipped[key]!)
            }
            var be = n.bigEndian
            return Data(SHA256.hash(data: ck + dhPub + Data(bytes: &be, count: 4) + items))
        }
    }

    struct EcSendState {
        var ck: Data
        var n: UInt32
        var dhPub: Data
    }

    static func ecSendMk(_ state: EcSendState) throws -> (EcSendState, Data) {
        let (ck2, mk) = try ATSAMHybridRatchetV2.kdfCK(ck: state.ck)
        return (EcSendState(ck: ck2, n: state.n &+ 1, dhPub: state.dhPub), mk)
    }

    static func ecSkipKeys(_ state: EcRecvState, untilN: UInt32, maxSkip: Int = ATSAMHybridRatchetV2.maxSkip) throws -> EcRecvState {
        if untilN < state.n { throw Error.behind }
        let skipCount = Int(untilN &- state.n)
        if skipCount > maxSkip { throw Error.maxSkipExceeded }
        var ck = state.ck
        var n = state.n
        var skipped = state.mkskipped
        while n < untilN {
            let (ck2, mk) = try ATSAMHybridRatchetV2.kdfCK(ck: ck)
            skipped[mkKey(dhPub: state.dhPub, n: n)] = mk
            ck = ck2
            n &+= 1
        }
        return EcRecvState(ck: ck, n: untilN, dhPub: state.dhPub, mkskipped: skipped)
    }

    static func ecTrySkipped(_ state: EcRecvState, dhPub: Data, n: UInt32) -> (Data?, EcRecvState) {
        let key = mkKey(dhPub: dhPub, n: n)
        var out = state
        guard let mk = out.mkskipped.removeValue(forKey: key) else { return (nil, out) }
        return (mk, out)
    }

    static func ecRecvInOrder(_ state: EcRecvState) throws -> (EcRecvState, Data) {
        let (ck2, mk) = try ATSAMHybridRatchetV2.kdfCK(ck: state.ck)
        return (EcRecvState(ck: ck2, n: state.n &+ 1, dhPub: state.dhPub, mkskipped: state.mkskipped), mk)
    }

    static func ecRecvMessage(_ state: EcRecvState, dhPub: Data, n: UInt32, maxSkip: Int = ATSAMHybridRatchetV2.maxSkip) throws -> (EcRecvState, Data) {
        guard dhPub == state.dhPub else { throw Error.badState }
        let (maybe, st0) = ecTrySkipped(state, dhPub: dhPub, n: n)
        if let mk = maybe { return (st0, mk) }
        if n < st0.n { throw Error.replay }
        let st = n > st0.n ? try ecSkipKeys(st0, untilN: n, maxSkip: maxSkip) : st0
        return try ecRecvInOrder(st)
    }

    struct AcceptKey {
        var sessionId: Data
        var dhPub: Data
        var n: UInt32
        var sckaEpoch: UInt32
        var sckaCtr: UInt32

        func packed() -> Data {
            var out = sessionId + dhPub
            var nBE = n.bigEndian
            var eBE = sckaEpoch.bigEndian
            var cBE = sckaCtr.bigEndian
            out.append(Data(bytes: &nBE, count: 4))
            out.append(Data(bytes: &eBE, count: 4))
            out.append(Data(bytes: &cBE, count: 4))
            return out
        }
    }

    struct CommitLedger {
        var acceptedKeys: Set<Data> = []
        var digestToAck: [Data: Data] = [:]
        var mutationCount: UInt64 = 0

        func fingerprint() -> Data {
            var keys = Data()
            for k in acceptedKeys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                keys.append(k)
            }
            var digests = Data()
            for k in digestToAck.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                digests.append(k)
                digests.append(digestToAck[k]!)
            }
            var be = mutationCount.bigEndian
            return Data(SHA256.hash(data: keys + digests + Data(bytes: &be, count: 8)))
        }
    }

    static func commitAccept(
        _ ledger: CommitLedger,
        key: AcceptKey,
        objectDigest: Data,
        retainedAck: Data
    ) -> (CommitLedger, String) {
        let packed = key.packed()
        if ledger.acceptedKeys.contains(packed) {
            return (ledger, "replay_no_mutation")
        }
        if ledger.digestToAck[objectDigest] != nil {
            return (ledger, "duplicate_committed")
        }
        var out = ledger
        out.acceptedKeys.insert(packed)
        out.digestToAck[objectDigest] = retainedAck
        out.mutationCount &+= 1
        return (out, "accepted")
    }

    static func duplicateAckExact(_ ledger: CommitLedger, objectDigest: Data) -> Data? {
        ledger.digestToAck[objectDigest]
    }

    static func kRoute(kRouteMaster: Data, direction: UInt8) throws -> Data {
        guard kRouteMaster.count == 32, direction <= 1 else { throw Error.badLength }
        var info = ATSAMHybridRatchetV2.profile
        info.append(contentsOf: [0x00] + Array("route".utf8) + [0x00, direction])
        return ATSAMHybridRatchetV2.hkdf(ikm: kRouteMaster, salt: Data(count: 32), info: info, length: 32)
    }

    static func routingTag(
        kRouteD: Data,
        createdAtMs: UInt64,
        n: UInt64,
        appType: UInt8,
        direction: UInt8,
        sessionId: Data
    ) -> Data {
        let epoch = createdAtMs / 1000
        let counter = (n << 8) | (UInt64(appType & 0x7F) << 1) | UInt64(direction & 1)
        var msg = routeTagDomain
        var eBE = epoch.bigEndian
        var cBE = counter.bigEndian
        msg.append(Data(bytes: &eBE, count: 8))
        msg.append(Data(bytes: &cBE, count: 8))
        msg.append(sessionId)
        let full = Data(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: kRouteD)))
        return Data(full.prefix(16))
    }

    static func mailboxTag(kRouteD: Data, unixMs: UInt64, direction: UInt64, sessionId: Data) -> Data {
        let dayEpoch = unixMs / UInt64(msPerDay)
        var msg = mailboxTagDomain
        var dBE = dayEpoch.bigEndian
        var dirBE = direction.bigEndian
        msg.append(Data(bytes: &dBE, count: 8))
        msg.append(Data(bytes: &dirBE, count: 8))
        msg.append(sessionId)
        let full = Data(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: kRouteD)))
        return Data(full.prefix(16))
    }

    static func storeTag(_ mailbox: Data) -> Data {
        Data(SHA256.hash(data: storeTagDomain + mailbox).prefix(16))
    }

    struct MailboxCatchupPlan {
        var today: Int64
        var ttlHorizon: Int64
        var lateArrivalFloor: Int64
        var historicalDays: [Int64]
        var alwaysRepollDays: [Int64]
    }

    static func mailboxCatchupPlan(
        nowMs: Int64,
        catchupCursorDay: Int64,
        mailboxTtlDays: Int64,
        lateArrivalDays: Int64 = Int64(ATSAMHybridRatchetV2.mailboxLateArrivalDays)
    ) -> MailboxCatchupPlan {
        let today = nowMs / msPerDay
        let ttlHorizon = today - mailboxTtlDays
        let lateArrivalFloor = today - lateArrivalDays
        let start = max(catchupCursorDay + 1, ttlHorizon)
        var historical: [Int64] = []
        if start < today {
            historical = Array(start..<today)
        }
        var always = Set<Int64>()
        for d in max(lateArrivalFloor, ttlHorizon)...today {
            always.insert(d)
        }
        return MailboxCatchupPlan(
            today: today,
            ttlHorizon: ttlHorizon,
            lateArrivalFloor: lateArrivalFloor,
            historicalDays: historical,
            alwaysRepollDays: always.sorted()
        )
    }

    static func candidateDecrypt(
        key: Data,
        nonce: Data,
        ciphertext: Data,
        aad: Data,
        liveFp: Data
    ) -> [String: Any] {
        do {
            let pt = try ATSAMHybridRatchetV2.aeadOpen(
                key: key,
                nonce: nonce,
                ciphertextAndTag: ciphertext,
                aad: aad
            )
            let after = Data(SHA256.hash(data: liveFp + Data([0x01])))
            return [
                "open_result": "ok",
                "plaintext_hex": pt.hexString,
                "durable_mutation": true,
                "promote_live_head": true,
                "live_fp_after_hex": after.hexString,
            ]
        } catch {
            return [
                "open_result": "fail",
                "durable_mutation": false,
                "promote_live_head": false,
                "live_fp_after_hex": liveFp.hexString,
            ]
        }
    }

    struct ReceiveCommitMachine {
        var state = "idle"
        var durableMutation = false
        var skippedPersisted = false
        var epochPromoted = false
        var epochOnCandidate = false
        var generation: UInt64 = 0

        mutating func apply(_ action: String) throws {
            switch action {
            case "clone_candidate":
                guard state == "idle" else { throw Error.badState }
                state = "candidate"
            case "derive_keys_on_candidate":
                guard state == "candidate" else { throw Error.badState }
                state = "derived"
            case "aead_ok":
                guard state == "derived" else { throw Error.badState }
                state = "aead_ok"
            case "write_PENDING_inbound":
                guard state == "aead_ok" else { throw Error.badState }
                state = "pending"
            case "sql_commit_receipt_dedup":
                guard state == "pending" else { throw Error.badState }
                state = "sql_committed"
                durableMutation = true
            case "persist_MKSKIPPED":
                guard state == "sql_committed" else { throw Error.badState }
                skippedPersisted = true
                state = "skipped_persisted"
            case "FINALIZE_head":
                guard state == "sql_committed" || state == "skipped_persisted" else {
                    throw Error.crashForbidden
                }
                guard !epochOnCandidate else { throw Error.crashForbidden }
                generation &+= 1
                state = "finalized"
            case "promote_scka_epoch_on_candidate":
                guard state == "derived" || state == "aead_ok" else { throw Error.badState }
                epochOnCandidate = true
            case "commit_epoch_with_finalize":
                guard state == "sql_committed" || state == "skipped_persisted" else {
                    throw Error.crashForbidden
                }
                guard epochOnCandidate, durableMutation else { throw Error.crashForbidden }
                epochPromoted = true
                generation &+= 1
                state = "finalized"
            case "clear_PENDING":
                guard state == "finalized" else { throw Error.badState }
                state = "cleared"
            case "FINALIZE_before_sql", "promote_epoch_before_sql":
                throw Error.crashForbidden
            default:
                throw Error.badState
            }
        }
    }

    static func runBraidEpochMatrix(skScka: Data, ss1: Data, ss2: Data) throws -> [String: Any] {
        let alice = try sckaFromInit(alice: true, skScka: skScka)
        let bob = try sckaFromInit(alice: false, skScka: skScka)
        let alice1i = try sckaEpochPromoteInitiator(alice, ss: ss1)
        let bob1r = try sckaEpochPromoteResponder(bob, ss: ss1)
        let (alice1, aMk) = try sckaNextSendMk(alice1i)
        let (bob1, bMk) = try sckaNextRecvMk(bob1r)
        precondition(aMk == bMk)
        let bob2i = try sckaEpochPromoteInitiator(bob1, ss: ss2)
        let alice2r = try sckaEpochPromoteResponder(alice1, ss: ss2)
        let (_, bMk2) = try sckaNextSendMk(bob2i)
        let (_, aMk2) = try sckaNextRecvMk(alice2r)
        precondition(bMk2 == aMk2)
        return [
            "directions_reordered": true,
            "epoch1": [
                "rk_hex": alice1i.rk.hexString,
                "alice_ck_send_hex": alice1i.ckSend.hexString,
                "bob_ck_recv_hex": bob1r.ckRecv.hexString,
                "alice_send_equals_bob_recv": alice1i.ckSend == bob1r.ckRecv,
                "mk_hex": aMk.hexString,
                "alice_sending_epoch": Int(alice1i.sendingEpoch),
                "bob_receiving_epoch": Int(bob1r.receivingEpoch),
            ] as [String: Any],
            "epoch2": [
                "rk_hex": bob2i.rk.hexString,
                "bob_ck_send_hex": bob2i.ckSend.hexString,
                "alice_ck_recv_hex": alice2r.ckRecv.hexString,
                "bob_send_equals_alice_recv": bob2i.ckSend == alice2r.ckRecv,
                "mk_hex": bMk2.hexString,
                "bob_sending_epoch": Int(bob2i.sendingEpoch),
                "alice_receiving_epoch": Int(alice2r.receivingEpoch),
            ] as [String: Any],
        ]
    }

    static func runEcOooMatrix(ck0: Data, dhPub: Data) throws -> [String: Any] {
        var send = EcSendState(ck: ck0, n: 0, dhPub: dhPub)
        var mks: [Data] = []
        for _ in 0..<4 {
            let (s, mk) = try ecSendMk(send)
            send = s
            mks.append(mk)
        }
        var recv = EcRecvState(ck: ck0, n: 0, dhPub: dhPub)
        let order: [UInt32] = [0, 3, 1, 2]
        var recovered: [String] = []
        for idx in order {
            let (st, mk) = try ecRecvMessage(recv, dhPub: dhPub, n: idx)
            recv = st
            precondition(mk == mks[Int(idx)])
            recovered.append(mk.hexString)
        }
        return [
            "send_mks_hex": mks.map(\.hexString),
            "receive_order": order.map { Int($0) },
            "recovered_mks_hex": recovered,
            "final_skipped_count": recv.mkskipped.count,
            "final_n": Int(recv.n),
            "ooo_ok": true,
        ]
    }

    static func runSkipBoundary(ck0: Data, dhPub: Data) -> [String: Any] {
        var cases: [[String: Any]] = []
        for count in [0, 1, 999, 1000, 1001] as [UInt32] {
            let base = EcRecvState(ck: ck0, n: 0, dhPub: dhPub)
            let fpBefore = base.fingerprint()
            do {
                let advanced = try ecSkipKeys(base, untilN: count)
                var first: String?
                var last: String?
                if count > 0 {
                    first = advanced.mkskipped[mkKey(dhPub: dhPub, n: 0)]!.hexString
                    last = advanced.mkskipped[mkKey(dhPub: dhPub, n: count &- 1)]!.hexString
                }
                cases.append([
                    "skip_count": Int(count),
                    "result": "ok",
                    "skipped_stored": Int(count),
                    "first_mk_hex": first as Any,
                    "last_mk_hex": last as Any,
                    "final_ck_hex": advanced.ck.hexString,
                    "final_n": Int(advanced.n),
                    "fp_before_hex": fpBefore.hexString,
                    "fp_after_hex": advanced.fingerprint().hexString,
                ])
            } catch {
                cases.append([
                    "skip_count": Int(count),
                    "result": "reject",
                    "reason": "MAX_SKIP exceeded",
                    "fp_before_hex": fpBefore.hexString,
                    "fp_after_hex": base.fingerprint().hexString,
                    "state_unchanged": base.fingerprint() == fpBefore,
                    "allocation": false,
                    "state_advance": false,
                ])
            }
        }
        return ["max_skip": ATSAMHybridRatchetV2.maxSkip, "cases": cases]
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
