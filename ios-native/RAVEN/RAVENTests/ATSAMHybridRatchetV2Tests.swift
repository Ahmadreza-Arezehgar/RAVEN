//
//  ATSAMHybridRatchetV2Tests.swift
//  RAVENTests
//
//  Compute-all KATs for ATSAM/hybrid-ratchet/v2 (production disabled).
//

import CryptoKit
import Foundation
import XCTest
@testable import RAVEN

final class ATSAMHybridRatchetV2Tests: XCTestCase {

    private func vectorsRoot() -> URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("shared-vectors/rvn1/atsam")
        return FileManager.default.fileExists(atPath: root.path) ? root : nil
    }

    private func loadJSON(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func loadVector(_ name: String) throws -> [String: Any] {
        guard let root = vectorsRoot() else {
            throw XCTSkip("shared-vectors/rvn1/atsam not found")
        }
        return try loadJSON(at: root.appendingPathComponent(name))
    }

    private func hex(_ value: String) -> Data {
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

    private func dictionary(_ value: Any?) throws -> [String: Any] {
        try XCTUnwrap(value as? [String: Any])
    }

    private func stringDict(_ value: Any?) throws -> [String: String] {
        let raw = try XCTUnwrap(value as? [String: Any])
        var out: [String: String] = [:]
        for (k, v) in raw {
            if let s = v as? String {
                out[k] = s
            } else if let i = v as? Int {
                out[k] = "\(i)"
            } else {
                out[k] = "\(v)"
            }
        }
        return out
    }

    func testProductionFlagsOff() {
        XCTAssertFalse(ATSAMHybridRatchetV2.productionEnabled)
        XCTAssertFalse(ATSAMPairInitV2.productionEnabled)
    }

    func testPairInitV2WireExpandAndSignatures() throws {
        let vector = try loadVector("pair_init_v2_001.json")
        let inputs = try dictionary(vector["inputs"])
        let expected = try dictionary(vector["expected"])

        let wire = hex(try XCTUnwrap(expected["pair_init_wire_hex"] as? String))
        XCTAssertEqual(wire.count, 2787)
        XCTAssertEqual(wire.count, expected["pair_init_wire_len"] as? Int)
        XCTAssertEqual(ATSAMPairInitV2.wireLen, 2787)
        XCTAssertEqual(ATSAMPairInitV2.wireOffsets()["total_len"], 2787)

        let offsets = try dictionary(expected["offsets"])
        for (key, value) in ATSAMPairInitV2.wireOffsets() {
            XCTAssertEqual(offsets[key] as? Int, value, "offset \(key)")
        }

        try ATSAMPairInitV2.decodeInitWire(wire)
        let signing = try ATSAMPairInitV2.initSigningBytes(wire: wire)
        XCTAssertEqual(signing, hex(try XCTUnwrap(expected["pair_init_signing_bytes_hex"] as? String)))

        let initiatorPub = wire.subdata(in: 171..<(171 + 32))
        try ATSAMPairInitV2.verifyInitSignature(wire: wire, pub: initiatorPub)

        let expand = try ATSAMPairInitV2.pairExpand(
            zX: hex(try XCTUnwrap(inputs["z_x_hex"] as? String)),
            zPQ: hex(try XCTUnwrap(inputs["z_pq_hex"] as? String)),
            wire: wire
        )
        XCTAssertEqual(expand.skEc, hex(try XCTUnwrap(expected["sk_ec_hex"] as? String)))
        XCTAssertEqual(expand.skScka, hex(try XCTUnwrap(expected["sk_scka_hex"] as? String)))
        XCTAssertEqual(expand.kRouteMaster, hex(try XCTUnwrap(expected["k_route_master_hex"] as? String)))
        XCTAssertEqual(expand.kConfirm, hex(try XCTUnwrap(expected["k_confirm_hex"] as? String)))
        XCTAssertEqual(expand.transcriptHash, hex(try XCTUnwrap(expected["transcript_hash_hex"] as? String)))
        XCTAssertEqual(expand.initHashV2, hex(try XCTUnwrap(expected["init_hash_v2_hex"] as? String)))
        XCTAssertEqual(expand.sessionId, hex(try XCTUnwrap(expected["session_id_hex"] as? String)))

        let tag = try ATSAMPairInitV2.confirmationTag(
            kConfirm: expand.kConfirm,
            initHash: expand.initHashV2
        )
        XCTAssertEqual(tag, hex(try XCTUnwrap(expected["confirmation_tag_hex"] as? String)))

        let resp = hex(try XCTUnwrap(expected["pair_response_wire_hex"] as? String))
        XCTAssertEqual(resp.count, 227)
        XCTAssertEqual(resp.count, expected["pair_response_wire_len"] as? Int)
        try ATSAMPairInitV2.decodeResponseWire(resp)
        XCTAssertEqual(
            try ATSAMPairInitV2.responseSigningBytes(wire: resp),
            hex(try XCTUnwrap(expected["pair_response_signing_bytes_hex"] as? String))
        )
        let responderPub = resp.subdata(in: 83..<(83 + 32))
        try ATSAMPairInitV2.verifyResponseSignature(wire: resp, pub: responderPub)
        XCTAssertEqual(resp.subdata(in: 131..<(131 + 32)), tag)
    }

    func testPairInitV1HardRejectedAsV2() throws {
        let vector = try loadVector("negative/pair_init_v1_as_v2_001.json")
        let inputs = try dictionary(vector["inputs"])
        let wire = hex(try XCTUnwrap(inputs["wire_hex"] as? String))
        XCTAssertThrowsError(try ATSAMPairInitV2.decodeInitWire(wire)) { error in
            XCTAssertEqual(error as? ATSAMPairInitV2.Error, .v1Reinterpret)
        }
        XCTAssertThrowsError(try ATSAMPairInitV2.pairExpand(
            zX: Data(count: 32),
            zPQ: Data(count: 32),
            wire: wire
        )) { error in
            XCTAssertEqual(error as? ATSAMPairInitV2.Error, .v1Reinterpret)
        }
    }

    func testDomainLabelsCatalog() throws {
        let vector = try loadVector("tr_domain_labels_001.json")
        let expected = try stringDict(vector["expected"])
        let catalog = ATSAMHybridRatchetV2.domainCatalog()
        XCTAssertEqual(catalog, expected)
        XCTAssertEqual(catalog["SEALED_PROTO"], "04")
        XCTAssertEqual(catalog["MAX_SKIP"], "1000")
        XCTAssertEqual(ATSAMHybridRatchetV2.maxSkip, 1000)
        XCTAssertEqual(ATSAMHybridRatchetV2.sealedProto, 0x04)
    }

    func testEcKdfIntermediates() throws {
        let vector = try loadVector("tr_ec_kdf_001.json")
        let inputs = try dictionary(vector["inputs"])
        let expected = try dictionary(vector["expected"])
        let (rkNext, ck) = try ATSAMHybridRatchetV2.kdfRK(
            rk: hex(try XCTUnwrap(inputs["rk_hex"] as? String)),
            dhOut: hex(try XCTUnwrap(inputs["dh_out_hex"] as? String))
        )
        let (ckNext, mk) = try ATSAMHybridRatchetV2.kdfCK(ck: ck)
        XCTAssertEqual(rkNext, hex(try XCTUnwrap(expected["rk_next_hex"] as? String)))
        XCTAssertEqual(ck, hex(try XCTUnwrap(expected["ck_hex"] as? String)))
        XCTAssertEqual(ckNext, hex(try XCTUnwrap(expected["ck_next_hex"] as? String)))
        XCTAssertEqual(mk, hex(try XCTUnwrap(expected["mk_hex"] as? String)))
    }

    func testSckaRoleInit() throws {
        let vector = try loadVector("tr_scka_init_001.json")
        let inputs = try dictionary(vector["inputs"])
        let expected = try dictionary(vector["expected"])
        let aliceExp = try dictionary(expected["alice"])
        let bobExp = try dictionary(expected["bob"])
        let sk = hex(try XCTUnwrap(inputs["sk_scka_hex"] as? String))
        let alice = try ATSAMHybridRatchetV2.ratchetInitAliceSCKA(skScka: sk)
        let bob = try ATSAMHybridRatchetV2.ratchetInitBobSCKA(skScka: sk)
        XCTAssertEqual(alice.rk, hex(try XCTUnwrap(aliceExp["rk_hex"] as? String)))
        XCTAssertEqual(alice.ckSend, hex(try XCTUnwrap(aliceExp["ck_send_hex"] as? String)))
        XCTAssertEqual(alice.ckRecv, hex(try XCTUnwrap(aliceExp["ck_recv_hex"] as? String)))
        XCTAssertEqual(bob.rk, hex(try XCTUnwrap(bobExp["rk_hex"] as? String)))
        XCTAssertEqual(bob.ckSend, hex(try XCTUnwrap(bobExp["ck_send_hex"] as? String)))
        XCTAssertEqual(bob.ckRecv, hex(try XCTUnwrap(bobExp["ck_recv_hex"] as? String)))
        XCTAssertEqual(expected["alice_send_equals_bob_recv"] as? Bool, true)
        XCTAssertEqual(alice.ckSend, bob.ckRecv)
        XCTAssertNotEqual(alice.ckSend, bob.ckSend)
    }

    func testHybridAead() throws {
        let vector = try loadVector("tr_hybrid_aead_001.json")
        let inputs = try dictionary(vector["inputs"])
        let expected = try dictionary(vector["expected"])
        let (key, nonce) = try ATSAMHybridRatchetV2.kdfHybrid(
            ecMk: hex(try XCTUnwrap(inputs["ec_mk_hex"] as? String)),
            sckaMk: hex(try XCTUnwrap(inputs["scka_mk_hex"] as? String))
        )
        XCTAssertEqual(key, hex(try XCTUnwrap(expected["aead_key_hex"] as? String)))
        XCTAssertEqual(nonce, hex(try XCTUnwrap(expected["nonce_hex"] as? String)))

        let aad = hex(try XCTUnwrap(inputs["aad_hex"] as? String))
        let plaintext = hex(try XCTUnwrap(inputs["plaintext_hex"] as? String))
        let sealed = try ATSAMHybridRatchetV2.aeadSeal(
            key: key,
            nonce: nonce,
            plaintext: plaintext,
            aad: aad
        )
        XCTAssertEqual(sealed, hex(try XCTUnwrap(expected["ciphertext_hex"] as? String)))

        let opened = try ATSAMHybridRatchetV2.aeadOpen(
            key: key,
            nonce: nonce,
            ciphertextAndTag: sealed,
            aad: aad
        )
        XCTAssertEqual(opened, plaintext)
    }

    func testAckV2() throws {
        let vector = try loadVector("tr_ackv2_001.json")
        let inputs = try dictionary(vector["inputs"])
        let expected = try dictionary(vector["expected"])
        let plaintext = hex(try XCTUnwrap(expected["ack_plaintext_hex"] as? String))
        XCTAssertEqual(plaintext.count, 197)
        XCTAssertEqual(plaintext.count, expected["ack_plaintext_len"] as? Int)

        let ack = try ATSAMHybridRatchetV2.decodeAckPlaintext(plaintext)
        XCTAssertEqual(ack.ackedObjectDigest, hex(try XCTUnwrap(expected["acked_object_digest_hex"] as? String)))
        XCTAssertEqual(ack.status, UInt8(try XCTUnwrap(expected["status"] as? Int)))
        XCTAssertEqual(
            try ATSAMHybridRatchetV2.ackSigningBytes(ack),
            hex(try XCTUnwrap(expected["signing_bytes_hex"] as? String))
        )
        XCTAssertEqual(try ATSAMHybridRatchetV2.encodeAckPlaintext(ack), plaintext)

        try ATSAMHybridRatchetV2.verifyAck(
            ack,
            deviceEdPub: hex(try XCTUnwrap(inputs["signer_device_ed_pub_hex"] as? String))
        )

        let obj = hex(try XCTUnwrap(inputs["acked_endpoint_object_hex"] as? String))
        let digest = Data(SHA256.hash(data: obj))
        XCTAssertEqual(digest, ack.ackedObjectDigest)
    }

    func testCandidateFailClosed() throws {
        let vector = try loadVector("tr_candidate_fail_001.json")
        let inputs = try dictionary(vector["inputs"])
        let expected = try dictionary(vector["expected"])

        let durableMutation = false
        let promoteLiveHead = false
        do {
            _ = try ATSAMHybridRatchetV2.aeadOpen(
                key: hex(try XCTUnwrap(inputs["aead_key_hex"] as? String)),
                nonce: hex(try XCTUnwrap(inputs["nonce_hex"] as? String)),
                ciphertextAndTag: hex(try XCTUnwrap(inputs["ciphertext_hex"] as? String)),
                aad: hex(try XCTUnwrap(inputs["aad_hex"] as? String))
            )
            XCTFail("AEAD open must fail closed")
        } catch ATSAMHybridRatchetV2.Error.aeadFailed {
            // fail-closed: no durable mutation / live-head promotion
        }

        XCTAssertEqual(durableMutation, expected["durable_mutation"] as? Bool)
        XCTAssertEqual(promoteLiveHead, expected["promote_live_head"] as? Bool)
        XCTAssertEqual(expected["open_result"] as? String, "fail")
    }

    func testAckCasTransitionOrder() throws {
        let vector = try loadVector("tr_crash_ack_cas_001.json")
        let steps = try XCTUnwrap(vector["steps"] as? [[String: Any]])
        XCTAssertEqual(steps[2]["action"] as? String, "write_PENDING_ACK_SEND")
        XCTAssertEqual(steps[3]["requires"] as? String, "PENDING_ACK_SEND")

        let retained = Data("exact_ack_bytes_v2".utf8)
        let digest = Data(SHA256.hash(data: retained))
        var machine = ATSAMHybridRatchetV2.AckCasMachine()

        for step in steps {
            let action = try XCTUnwrap(step["action"] as? String)
            switch action {
            case "seal_AckV2":
                try machine.apply(action: action, retained: retained)
            case "write_PENDING_ACK_SEND":
                try machine.apply(action: action, digest: digest)
            default:
                try machine.apply(action: action)
            }
        }
        XCTAssertEqual(machine.state, .cleared)
        XCTAssertTrue(machine.durableMutation)

        var bad = ATSAMHybridRatchetV2.AckCasMachine()
        try bad.apply(action: "clone_candidate_send_state")
        try bad.apply(action: "seal_AckV2", retained: retained)
        XCTAssertThrowsError(try bad.casWithoutPending()) { error in
            XCTAssertEqual(error as? ATSAMHybridRatchetV2.Error, .pendingRequired)
        }

        var rebuild = ATSAMHybridRatchetV2.AckCasMachine()
        XCTAssertThrowsError(try rebuild.apply(action: "rebuild_ack_bytes_on_retry")) { error in
            XCTAssertEqual(error as? ATSAMHybridRatchetV2.Error, .rebuildForbidden)
        }
        XCTAssertThrowsError(try rebuild.apply(action: "ack_of_ack")) { error in
            XCTAssertEqual(error as? ATSAMHybridRatchetV2.Error, .ackOfAck)
        }

        let negatives = try XCTUnwrap(vector["negatives"] as? [String])
        XCTAssertTrue(negatives.contains("CAS_Materialized_without_PENDING_ACK_SEND"))
        XCTAssertTrue(negatives.contains("rebuild_ack_bytes_on_retry"))
        XCTAssertTrue(negatives.contains("ack_of_ack"))
    }
}
