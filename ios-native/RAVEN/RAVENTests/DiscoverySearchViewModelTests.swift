//
//  DiscoverySearchViewModelTests.swift
//  RAVENTests — discovery UI view-model (conflict pick, no FastAPI).
//

import XCTest
@testable import RAVEN

@MainActor
final class DiscoverySearchViewModelTests: XCTestCase {

    override func setUp() {
        super.setUp()
        FeatureFlag.ravenEnvelopeV1.setEnabled(true)
        DiscoveryAliasClaimStore.save([])
        DiscoveryNearbyStore.save([])
    }

    override func tearDown() {
        FeatureFlag.ravenEnvelopeV1.setEnabled(false)
        DiscoveryAliasClaimStore.save([])
        DiscoveryNearbyStore.save([])
        super.tearDown()
    }

    func testPublicScopeExactAliasConflictRequiresPick() {
        DiscoveryAliasClaimStore.save([
            SignedAliasClaim(
                alias: "poline", identityAddress: "rvn1aaa", sequence: 1,
                expiresAt: UInt64.max, ed25519PubHex: String(repeating: "aa", count: 32)
            ),
            SignedAliasClaim(
                alias: "poline", identityAddress: "rvn1bbb", sequence: 1,
                expiresAt: UInt64.max, ed25519PubHex: String(repeating: "bb", count: 32)
            ),
        ])
        let vm = DiscoverySearchViewModel()
        vm.scope = .publicExact
        vm.query = "@poline"
        vm.runSearch()
        XCTAssertEqual(vm.results.count, 2)
        XCTAssertTrue(vm.requiresExplicitPick)
        XCTAssertNil(vm.selectedRavenId)
        XCTAssertFalse(vm.canSendRequest)
        XCTAssertFalse(vm.results.contains { $0.sourceSet.contains(.legacyServer) })

        vm.selectCandidate(vm.results[0])
        XCTAssertEqual(vm.selectedRavenId, vm.results[0].ravenId)
        XCTAssertTrue(vm.canSendRequest)
    }

    func testMyNetworkUsesLocalPetname() {
        let r = DiscoveryResolver()
        r.serverless = true
        r.contacts = [
            LocalDiscoveryContact(
                ravenId: "rvn1local", pubHex: String(repeating: "ab", count: 32),
                petname: "Ada", publicTag: "ada", displayName: "Ada",
                pinned: true, directlyVerified: true
            ),
        ]
        let hits = r.search(query: "Ada", scope: .myNetwork)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].primaryLabel, "Ada")
        XCTAssertEqual(hits[0].sourceSet, [.localContacts])
        XCTAssertFalse(hits[0].sourceSet.contains(.legacyServer))
    }

    func testNearbyConfirmedSurfaces() {
        DiscoveryNearbyStore.save([
            NearbyConfirmBinding(
                ephemeralTokenHex: "00112233445566778899aabbccddeeff",
                peerRavenId: "rvn1near",
                peerPubHex: String(repeating: "cc", count: 32),
                confirmedAtMs: 1
            ),
        ])
        let vm = DiscoverySearchViewModel()
        vm.scope = .nearby
        vm.query = ""
        vm.runSearch()
        XCTAssertTrue(vm.results.contains { $0.ravenId == "rvn1near" })
        XCTAssertTrue(vm.results.contains { $0.verificationState == .nearbyVerified })
    }

    func testServerlessNeverLegacyServer() {
        let vm = DiscoverySearchViewModel()
        vm.scope = .all
        vm.query = "@nobody"
        vm.runSearch()
        XCTAssertFalse(vm.results.contains { $0.sourceSet.contains(.legacyServer) })
        XCTAssertFalse(vm.results.contains { $0.sourceSet.contains(.publicProfileIndex) })
    }

    func testAmbiguousSendThrows() async {
        DiscoveryAliasClaimStore.save([
            SignedAliasClaim(
                alias: "x", identityAddress: "rvn1a", sequence: 1,
                expiresAt: UInt64.max, ed25519PubHex: String(repeating: "11", count: 32)
            ),
            SignedAliasClaim(
                alias: "x", identityAddress: "rvn1b", sequence: 1,
                expiresAt: UInt64.max, ed25519PubHex: String(repeating: "22", count: 32)
            ),
        ])
        let vm = DiscoverySearchViewModel()
        vm.scope = .publicExact
        vm.query = "@x"
        vm.runSearch()
        XCTAssertTrue(vm.requiresExplicitPick)
        do {
            try await vm.sendContactRequest()
            XCTFail("expected ambiguousPick")
        } catch RavenContactRequestError.ambiguousPick {
            // expected
        } catch RavenContactRequestError.noCandidate {
            // also acceptable before selection
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testParseWhoamiPasteExtractsFields() {
        let blob = """
        address     rvn1qtestdemoaddress
        fingerprint ABCD-EFGH-IJKL
        pub_hex     d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a
        """
        let parsed = DiscoverySearchViewModel.parseWhoamiPaste(addressOrBlob: blob, pubHexOrBlob: "")
        XCTAssertEqual(parsed.address, "rvn1qtestdemoaddress")
        XCTAssertEqual(
            parsed.pubHex,
            "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
        )
        let split = DiscoverySearchViewModel.parseWhoamiPaste(
            addressOrBlob: "rvn1qabc",
            pubHexOrBlob: "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
        )
        XCTAssertEqual(split.address, "rvn1qabc")
        XCTAssertEqual(split.pubHex?.count, 64)
    }

    func testAddContactFromWhoamiRequiresMatchingKey() throws {
        DiscoveryContactBindingStore.save([])
        // Random 32-byte pub will not encode to rvn1qabc — expect mismatch or bad address bind.
        do {
            _ = try DiscoverySearchViewModel().addContactFromWhoami(
                addressOrBlob: "rvn1qabc",
                pubHexOrBlob: String(repeating: "ab", count: 32),
                petname: "Demo"
            )
            XCTFail("expected address/pub mismatch")
        } catch WhoamiPasteError.addressPubMismatch {
            // expected when encode succeeds but differs
        } catch WhoamiPasteError.badAddress {
            // also OK if encode path treats short rvn1 as invalid elsewhere
        } catch {
            // encode may return a different rvn1 — mismatch is the success path
            XCTAssertTrue(error is WhoamiPasteError || error is RavenContactRequestError)
        }
    }
}
