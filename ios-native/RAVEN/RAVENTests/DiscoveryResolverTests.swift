//
//  DiscoveryResolverTests.swift
//  RAVENTests — Discovery V1 model parity (no FastAPI when serverless).
//

import XCTest
@testable import RAVEN

final class DiscoveryResolverTests: XCTestCase {

    func testSchemaKeysStable() {
        let keys = DiscoveryResult.schemaKeys
        XCTAssertTrue(keys.contains("raven_id"))
        XCTAssertTrue(keys.contains("verification_state"))
        XCTAssertTrue(keys.contains("conflict_count"))
        XCTAssertTrue(keys.contains("source_set"))
    }

    func testExactAliasConflictSurfacesBoth() {
        let r = DiscoveryResolver()
        r.serverless = true
        r.nowMs = 1
        r.aliasClaims = [
            SignedAliasClaim(alias: "poline", identityAddress: "rvn1aaa", sequence: 1, expiresAt: 99, ed25519PubHex: "aa"),
            SignedAliasClaim(alias: "poline", identityAddress: "rvn1bbb", sequence: 1, expiresAt: 99, ed25519PubHex: "bb"),
        ]
        let hits = r.search(query: "@poline", scope: .exactAlias)
        XCTAssertEqual(hits.count, 2)
        XCTAssertTrue(hits.allSatisfy { $0.verificationState == .aliasConflict })
        XCTAssertTrue(hits.allSatisfy { $0.conflictCount >= 2 })
        XCTAssertFalse(hits.contains { $0.sourceSet.contains(.legacyServer) })
    }

    func testAliasCharsetNormalization() {
        XCTAssertEqual(DiscoveryResolver.normalizeAlias("@Poline"), "poline")
        XCTAssertNil(DiscoveryResolver.normalizeAlias("bad!"))
    }

    func testLocalOnlyBareTextNoFuzzyPublic() {
        let r = DiscoveryResolver()
        r.serverless = true
        r.contacts = [
            LocalDiscoveryContact(
                ravenId: "rvn1local", pubHex: "abcd", petname: "Poline Uni",
                publicTag: "poline", displayName: "Poline", pinned: true, directlyVerified: true
            ),
        ]
        let hits = r.search(query: "poline", scope: .local)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].verificationState, .directlyVerified)
        XCTAssertEqual(hits[0].sourceSet, [.localContacts])
    }

    func testServerlessNeverUsesLegacyServer() {
        let r = DiscoveryResolver()
        r.serverless = true
        r.publicProfileIndexEnabled = false
        let hits = r.search(query: "@nobody", scope: .all)
        XCTAssertFalse(hits.contains { $0.sourceSet.contains(.legacyServer) })
        XCTAssertFalse(hits.contains { $0.sourceSet.contains(.publicProfileIndex) })
    }

    func testLocalBlock() {
        let r = DiscoveryResolver()
        r.blockedPubHex = ["deadbeef"]
        r.contacts = [
            LocalDiscoveryContact(
                ravenId: "rvn1x", pubHex: "DEADBEEF", petname: "X",
                publicTag: "x", displayName: "X", pinned: false, directlyVerified: false
            ),
        ]
        let hits = r.search(query: "x", scope: .local)
        XCTAssertTrue(hits.contains { $0.verificationState == .blocked })
    }

    func testNearbyConfirmedBinding() {
        let r = DiscoveryResolver()
        r.serverless = true
        r.nearbyConfirmed = [
            NearbyConfirmBinding(
                ephemeralTokenHex: "aabb",
                peerRavenId: "rvn1near",
                peerPubHex: "cc",
                confirmedAtMs: 1
            ),
        ]
        let hits = r.search(query: "", scope: .nearby)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].verificationState, .nearbyVerified)
        XCTAssertEqual(hits[0].sourceSet, [.nearbyBle])
    }

    func testPetnameFirstLabel() {
        var hit = DiscoveryResult(
            ravenId: "rvn1z", displayName: "Zed", aliases: ["zed"],
            profileDigest: "", sourceSet: [.localContacts],
            verificationState: .trustedContact, introductions: [],
            conflictCount: 0, sequence: 0, expiresAt: 0
        )
        XCTAssertEqual(hit.primaryLabel, "Zed")
        XCTAssertEqual(hit.aliasSubtitle, "@zed")
        hit.displayName = ""
        XCTAssertEqual(hit.primaryLabel, "@zed")
    }
}
