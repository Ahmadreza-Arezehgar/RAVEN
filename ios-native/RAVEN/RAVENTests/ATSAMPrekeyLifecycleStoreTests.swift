//
//  ATSAMPrekeyLifecycleStoreTests.swift
//  RAVENTests — PairInit persistence, ClaimJournal roll-forward, PairResponse cache.
//

#if DEBUG

import CryptoKit
import Foundation
import XCTest
@testable import RAVEN

@MainActor
final class ATSAMPrekeyLifecycleStoreTests: XCTestCase {

    private typealias Codec = ATSAMPairInitV1
    private let store = ATSAMPrekeyLifecycleStore.shared

    private var cacheRoot: URL!
    private var priorLabGate: Bool?

    override func setUpWithError() throws {
        cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("prekey-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        ATSAMPairResponseCache.setTestRoot(cacheRoot)
        store.resetForTesting(memoryOnly: true)
        priorLabGate = UserDefaults.standard.object(forKey: "raven.lab.test_a") as? Bool
        UserDefaults.standard.set(true, forKey: "raven.lab.test_a")
    }

    override func tearDownWithError() throws {
        ATSAMPairResponseCache.setTestRoot(nil)
        store.resetForTesting(memoryOnly: true)
        if let priorLabGate {
            UserDefaults.standard.set(priorLabGate, forKey: "raven.lab.test_a")
        } else {
            UserDefaults.standard.removeObject(forKey: "raven.lab.test_a")
        }
        try? FileManager.default.removeItem(at: cacheRoot)
    }

    // MARK: - Fixtures

    private func vectorInitWire() throws -> Data {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot.appendingPathComponent(
            "shared-vectors/rvn1/atsam/pair_init_v1_001.json"
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("shared PairInit vector not found in this checkout")
        }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let expected = json["expected"] as! [String: Any]
        return hex(expected["pair_init_wire_hex"] as! String)
    }

    private func hex(_ value: String) -> Data {
        var result = Data()
        var cursor = value.startIndex
        while cursor < value.endIndex {
            let next = value.index(cursor, offsetBy: 2)
            result.append(UInt8(value[cursor..<next], radix: 16)!)
            cursor = next
        }
        return result
    }

    private func trust(for initValue: Codec.PairInit) throws -> Codec.TrustContext {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot.appendingPathComponent(
            "shared-vectors/rvn1/atsam/pair_init_v1_001.json"
        )
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let input = json["input"] as! [String: Any]
        return Codec.TrustContext(
            initiatorCertificate: Codec.SignedDeviceCertificate(
                identityEd25519PublicKey: hex(input["initiator_identity_ed_pub_hex"] as! String),
                signingBytes: hex(input["initiator_device_cert_signing_bytes_hex"] as! String),
                signature: hex(input["initiator_device_cert_signature_hex"] as! String)
            ),
            responderCertificate: Codec.SignedDeviceCertificate(
                identityEd25519PublicKey: hex(input["responder_identity_ed_pub_hex"] as! String),
                signingBytes: hex(input["responder_device_cert_signing_bytes_hex"] as! String),
                signature: hex(input["responder_device_cert_signature_hex"] as! String)
            ),
            responderPrekeyBundle: Codec.SignedPrekeyBundle(
                signingBytes: hex(input["responder_prekey_signing_bytes_hex"] as! String),
                signature: hex(input["responder_prekey_signature_hex"] as! String)
            )
        )
    }

    private func vectorRoot() throws -> Data {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot.appendingPathComponent(
            "shared-vectors/rvn1/atsam/pair_init_v1_001.json"
        )
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let expected = json["expected"] as! [String: Any]
        return hex(expected["provisional_k_root_hex"] as! String)
    }

    // MARK: - PairResponse cache

    func testPairResponseCacheAtomicStoreVerifyAndTamperEviction() throws {
        let initWire = try vectorInitWire()
        let initValue = try Codec.decodeInit(initWire)
        let localDeviceEd = initValue.responderDeviceEd25519PublicKey
        let packed = try samplePackedResponse(initValue: initValue)

        try ATSAMPairResponseCache.store(initID: initValue.initID, packed: packed)
        let loaded = try ATSAMPairResponseCache.loadVerified(
            initValue: initValue,
            localDeviceEd: localDeviceEd
        )
        XCTAssertEqual(loaded, packed)

        let path = ATSAMPairResponseCache.path(forInitID: initValue.initID)
        var corrupted = try Data(contentsOf: path)
        guard case .pairResponse(var wire) = RavenPairInitLanOob.classifyPackedEnvelope(corrupted) else {
            return XCTFail("expected PairResponse OOB")
        }
        wire[wire.count - 1] ^= 0x01
        let signingKey = Curve25519.Signing.PrivateKey()
        corrupted = try RavenPairInitLanOob.wrapOobWire(
            wire,
            isPairInit: false,
            signingKey: signingKey,
            nowMs: initValue.createdAtMs
        )
        try corrupted.write(to: path, options: .atomic)

        XCTAssertThrowsError(
            try ATSAMPairResponseCache.loadVerified(
                initValue: initValue,
                localDeviceEd: localDeviceEd
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    // MARK: - Claim journal roll-forward

    func testClaimJournalRollsForwardAfterClaimJournalCrash() throws {
        let initWire = try vectorInitWire()
        let initValue = try Codec.decodeInit(initWire)
        let trust = try trust(for: initValue)
        let root = try vectorRoot()
        let nowMs = initValue.createdAtMs &+ 100

        store.injectFault(.claimJournal)
        XCTAssertThrowsError(
            try store.claimPairInit(
                pairInitWire: initWire,
                initValue: initValue,
                trust: trust,
                root: root,
                nowMs: nowMs
            )
        ) { error in
            guard case ATSAMPrekeyLifecycleStore.StoreError.injectedCrash(let label) = error else {
                return XCTFail("expected injected crash, got \(error)")
            }
            XCTAssertEqual(label, "claim journal")
        }

        let recovered = try store.claimPairInit(
            pairInitWire: initWire,
            initValue: initValue,
            trust: trust,
            root: root,
            nowMs: nowMs &+ 1
        )
        guard case .duplicatePending = recovered else {
            return XCTFail("expected duplicate pending after roll-forward")
        }
        XCTAssertEqual(try store.acceptedClaimCount(), 1)
    }

    func testClaimJournalRollsForwardAfterClaimCommitCrash() throws {
        let initWire = try vectorInitWire()
        let initValue = try Codec.decodeInit(initWire)
        let trust = try trust(for: initValue)
        let root = try vectorRoot()
        let nowMs = initValue.createdAtMs &+ 100

        store.injectFault(.claimCommit)
        XCTAssertThrowsError(
            try store.claimPairInit(
                pairInitWire: initWire,
                initValue: initValue,
                trust: trust,
                root: root,
                nowMs: nowMs
            )
        )

        var recovered = try store.claimPairInit(
            pairInitWire: initWire,
            initValue: initValue,
            trust: trust,
            root: root,
            nowMs: nowMs &+ 1
        )
        guard case .duplicatePending(var claim) = recovered else {
            return XCTFail("expected duplicate pending")
        }
        XCTAssertNotNil(claim.takeProvisionalRoot())
        XCTAssertEqual(try store.acceptedClaimCount(), 1)
    }

    func testCompleteClaimIsIdempotentAndClearsHandoff() throws {
        let initWire = try vectorInitWire()
        let initValue = try Codec.decodeInit(initWire)
        let trust = try trust(for: initValue)
        let root = try vectorRoot()
        let nowMs = initValue.createdAtMs &+ 100

        guard case .accepted(var claim) = try store.claimPairInit(
            pairInitWire: initWire,
            initValue: initValue,
            trust: trust,
            root: root,
            nowMs: nowMs
        ) else {
            return XCTFail("expected accepted claim")
        }
        _ = claim.takeProvisionalRoot()

        XCTAssertEqual(
            try store.completeClaim(claimID: claim.claimID, sessionID: claim.sessionID),
            .completed
        )
        XCTAssertEqual(
            try store.completeClaim(claimID: claim.claimID, sessionID: claim.sessionID),
            .alreadyCompleted
        )
    }

    func testInitIdConflictRejected() throws {
        let initWire = try vectorInitWire()
        let initValue = try Codec.decodeInit(initWire)
        let trust = try trust(for: initValue)
        let root = try vectorRoot()
        let nowMs = initValue.createdAtMs &+ 100

        _ = try store.claimPairInit(
            pairInitWire: initWire,
            initValue: initValue,
            trust: trust,
            root: root,
            nowMs: nowMs
        )

        var conflictWire = initWire
        conflictWire[conflictWire.count - 1] ^= 0x01
        let conflict = try Codec.decodeInit(conflictWire)

        XCTAssertThrowsError(
            try store.claimPairInit(
                pairInitWire: conflictWire,
                initValue: conflict,
                trust: trust,
                root: root,
                nowMs: nowMs
            )
        ) { error in
            XCTAssertEqual(error as? ATSAMPrekeyLifecycleStore.StoreError, .initIdConflict)
        }
    }

    // MARK: - Initiator packed-init persistence

    func testInitiatorPersistsExactPackedBytesForResend() throws {
        let initWire = try vectorInitWire()
        let initValue = try Codec.decodeInit(initWire)
        let sessionID = try Codec.sessionID(initValue)
        let packedInit = Data(repeating: 0xAB, count: 64)

        try store.persistInitiatorOutbound(
            initID: initValue.initID,
            packedWire: packedInit,
            initWire: initWire,
            sessionID: sessionID,
            provisionalRoot: Data(repeating: 0xCD, count: 32),
            createdAtMs: initValue.createdAtMs
        )

        let loaded = try XCTUnwrap(store.loadInitiatorOutbound(initID: initValue.initID))
        XCTAssertEqual(loaded.packedWire, packedInit)
        XCTAssertEqual(loaded.initWire, initWire)
        XCTAssertEqual(loaded.sessionID, sessionID)
    }

    // MARK: - Helpers

    private func samplePackedResponse(initValue: Codec.PairInit) throws -> Data {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot.appendingPathComponent(
            "shared-vectors/rvn1/atsam/pair_init_v1_001.json"
        )
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let expected = json["expected"] as! [String: Any]
        let responseWire = hex(expected["pair_response_wire_hex"] as! String)
        let signingKey = Curve25519.Signing.PrivateKey()
        return try RavenPairInitLanOob.wrapOobWire(
            responseWire,
            isPairInit: false,
            signingKey: signingKey,
            nowMs: initValue.createdAtMs
        )
    }
}

#endif
