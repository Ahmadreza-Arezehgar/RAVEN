//
//  PeerKeyDirectoryKeychainTests.swift
//  RAVENTests — §14 PeerKeyDirectory Keychain persistence + UserDefaults migration.
//

import XCTest
@testable import RAVEN

final class PeerKeyDirectoryKeychainTests: XCTestCase {

    private var testUserId = ""

    override func setUp() async throws {
        testUserId = "pkd-test-user-\(UUID().uuidString.prefix(8))"
    }

    override func tearDown() async throws {
        await PeerKeyDirectory.shared.clearAgreementKey(for: testUserId)
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where
            key.hasPrefix("raven.peerKey.agreement.v1.") || key.hasPrefix("raven.peerKey.identity.v1.") {
            if key.contains("pkd-mig-") || key.contains(testUserId) {
                defaults.removeObject(forKey: key)
            }
        }
        try await super.tearDown()
    }

    func testSetVerifiedIdentityPersistsInKeychainNotUserDefaults() async {
        let identity = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let agreement = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

        await PeerKeyDirectory.shared.setVerifiedIdentity(
            identityKey: identity,
            agreementKey: agreement,
            for: testUserId
        )

        let loadedAgreement = await PeerKeyDirectory.shared.agreementKey(for: testUserId)
        let loadedIdentity = await PeerKeyDirectory.shared.identityKey(for: testUserId)
        XCTAssertEqual(loadedAgreement, agreement)
        XCTAssertEqual(loadedIdentity, identity)

        // Must not leave trust pins in UserDefaults.
        XCTAssertNil(UserDefaults.standard.data(forKey: "raven.peerKey.agreement.v1.\(testUserId)"))
        XCTAssertNil(UserDefaults.standard.data(forKey: "raven.peerKey.identity.v1.\(testUserId)"))

        let peers = await PeerKeyDirectory.shared.allKnownPeers()
        XCTAssertTrue(peers.contains(testUserId))

        let candidates = await PeerKeyDirectory.shared.identityCandidates()
        XCTAssertTrue(candidates.contains(where: { $0.userId == testUserId && $0.pub == identity }))
    }

    func testClearRemovesPins() async {
        let identity = Data(repeating: 0xAB, count: 32)
        let agreement = Data(repeating: 0xCD, count: 32)
        await PeerKeyDirectory.shared.setVerifiedIdentity(
            identityKey: identity,
            agreementKey: agreement,
            for: testUserId
        )
        await PeerKeyDirectory.shared.clearAgreementKey(for: testUserId)
        let clearedAgreement = await PeerKeyDirectory.shared.agreementKey(for: testUserId)
        let clearedIdentity = await PeerKeyDirectory.shared.identityKey(for: testUserId)
        XCTAssertNil(clearedAgreement)
        XCTAssertNil(clearedIdentity)
    }

    func testNewWritesNeverUseUserDefaults() async {
        let migUser = "pkd-mig-\(UUID().uuidString.prefix(8))"
        let agreement = Data(repeating: 0x11, count: 32)
        let identity = Data(repeating: 0x22, count: 32)
        let defaults = UserDefaults.standard

        await PeerKeyDirectory.shared.setVerifiedIdentity(
            identityKey: identity,
            agreementKey: agreement,
            for: migUser
        )
        XCTAssertNil(defaults.data(forKey: "raven.peerKey.agreement.v1.\(migUser)"))
        XCTAssertNil(defaults.data(forKey: "raven.peerKey.identity.v1.\(migUser)"))
        let loaded = await PeerKeyDirectory.shared.agreementKey(for: migUser)
        XCTAssertEqual(loaded, agreement)
        await PeerKeyDirectory.shared.clearAgreementKey(for: migUser)
    }

    func testRecordObservedKeyDoesNotBootstrap() async {
        let observed = Data(repeating: 0x55, count: 32)
        let ok = await PeerKeyDirectory.shared.recordObservedKey(observed, for: testUserId)
        XCTAssertFalse(ok)
        let pinned = await PeerKeyDirectory.shared.agreementKey(for: testUserId)
        XCTAssertNil(pinned)
    }
}
