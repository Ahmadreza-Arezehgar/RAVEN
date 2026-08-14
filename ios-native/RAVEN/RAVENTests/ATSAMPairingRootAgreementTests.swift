// ATSAMPairingRootAgreementTests.swift
//
// Regression guard for the 2026-07-18 ATSAM pairing defect.
//
// `ATSAMOnlinePairView.localUserId` read a UserDefaults key
// ("currentUserId") that nothing in the app ever wrote, so it always
// evaluated to the literal "me". Because `ATSAMTranscript` binds BOTH
// user ids (round 26) and each side supplies them swapped, the two
// peers hashed different transcripts:
//
//   initiator → (userIdInitiator: "me",  userIdResponder: bob)
//   responder → (userIdInitiator: alice, userIdResponder: "me")
//
// Different transcript → different root → every ATSAM message failed
// its AEAD check. The manual pairing flow was dead on arrival, and the
// same placeholder was also signed into the published prekey bundle,
// which no peer could then verify.
//
// The invariant these tests pin down is the correctness contract
// stated in `ATSAMPairingResult.root`: "Both A and B compute identical
// bytes". `testPlaceholderUserIdsDeriveDivergentRoots` deliberately
// reproduces the old behaviour so the bug cannot silently return.
//
// Naming follows the existing MeshInteropVectorsTests style.

import XCTest
import CryptoKit
@testable import RAVEN

final class ATSAMPairingRootAgreementTests: XCTestCase {

    private let context = Data("raven-online-v1".utf8)
    private let aliceId = "8f14e45f-ea1c-4b2a-9d33-alice"
    private let bobId   = "c9f0f895-fb98-4b71-8f1e-bob"

    /// ML-KEM-768 is iOS 26+/macOS 26+. On older hosts the hybrid path
    /// fails closed by design, so there is nothing meaningful to assert.
    private func makeHybridKeyPairs() throws -> (ATSAMPairingKeys, ATSAMPairingKeys) {
        let alice = try ATSAMPairingKeys.generate()
        let bob = try ATSAMPairingKeys.generate()
        try XCTSkipIf(alice.pqPub.isEmpty || bob.pqPub.isEmpty,
                      "ML-KEM-768 unavailable on this host; hybrid pairing cannot run.")
        return (alice, bob)
    }

    // ─── The invariant ───────────────────────────────────────────────

    /// Both sides MUST derive the same root when each binds its own
    /// real user id. This is the test that would have caught the bug.
    func testInitiatorAndResponderDeriveIdenticalRoot() throws {
        let (alice, bob) = try makeHybridKeyPairs()

        let initiator = try ATSAMHybridPairing.pairAsInitiator(
            local: alice,
            peerXPub: bob.xPub,
            peerPQPub: bob.pqPub,
            context: context,
            pairingNonce: nil,
            selfUserId: aliceId,
            peerUserId: bobId
        )

        let responder = try ATSAMHybridPairing.pairAsResponder(
            local: bob,
            peerXPub: alice.xPub,
            peerPQPub: alice.pqPub,
            incomingCiphertext: initiator.outgoingCiphertext,
            context: context,
            pairingNonce: initiator.transcript.pairingNonce,
            selfUserId: bobId,
            peerUserId: aliceId
        )

        XCTAssertEqual(initiator.root, responder.root,
                       "Pairing roots diverged — ATSAM messages will fail to decrypt.")
        XCTAssertEqual(initiator.transcript, responder.transcript)
        XCTAssertEqual(initiator.transcript.hash(), responder.transcript.hash())
    }

    /// The transcript must carry the real ids in initiator/responder
    /// order, from both sides' point of view.
    func testTranscriptBindsRealUserIdsInInitiatorOrder() throws {
        let (alice, bob) = try makeHybridKeyPairs()

        let initiator = try ATSAMHybridPairing.pairAsInitiator(
            local: alice, peerXPub: bob.xPub, peerPQPub: bob.pqPub,
            context: context, pairingNonce: nil,
            selfUserId: aliceId, peerUserId: bobId
        )
        let responder = try ATSAMHybridPairing.pairAsResponder(
            local: bob, peerXPub: alice.xPub, peerPQPub: alice.pqPub,
            incomingCiphertext: initiator.outgoingCiphertext,
            context: context, pairingNonce: initiator.transcript.pairingNonce,
            selfUserId: bobId, peerUserId: aliceId
        )

        XCTAssertEqual(initiator.transcript.userIdInitiator, Data(aliceId.utf8))
        XCTAssertEqual(initiator.transcript.userIdResponder, Data(bobId.utf8))
        // Responder is `self` on its own side but must still land in
        // the responder slot.
        XCTAssertEqual(responder.transcript.userIdInitiator, Data(aliceId.utf8))
        XCTAssertEqual(responder.transcript.userIdResponder, Data(bobId.utf8))
    }

    // ─── The bug, pinned so it cannot return ─────────────────────────

    /// Reproduces the pre-fix behaviour: both sides bind the "me"
    /// placeholder in their own slot. Roots MUST diverge — this test
    /// documents why `localUserId()` has to resolve a real identity
    /// and fail closed when it cannot.
    func testPlaceholderUserIdsDeriveDivergentRoots() throws {
        let (alice, bob) = try makeHybridKeyPairs()

        let initiator = try ATSAMHybridPairing.pairAsInitiator(
            local: alice, peerXPub: bob.xPub, peerPQPub: bob.pqPub,
            context: context, pairingNonce: nil,
            selfUserId: "me", peerUserId: bobId
        )
        let responder = try ATSAMHybridPairing.pairAsResponder(
            local: bob, peerXPub: alice.xPub, peerPQPub: alice.pqPub,
            incomingCiphertext: initiator.outgoingCiphertext,
            context: context, pairingNonce: initiator.transcript.pairingNonce,
            selfUserId: "me", peerUserId: aliceId
        )

        XCTAssertNotEqual(initiator.root, responder.root,
                          "Placeholder ids must not accidentally agree.")
        XCTAssertNotEqual(initiator.transcript, responder.transcript)
    }

    // ─── The security property the binding exists for ────────────────

    /// Round 26 bound the user ids to defeat cross-pair replay. A
    /// substituted peer identity must still change the root.
    func testSubstitutedPeerIdentityChangesRoot() throws {
        let (alice, bob) = try makeHybridKeyPairs()

        let initiator = try ATSAMHybridPairing.pairAsInitiator(
            local: alice, peerXPub: bob.xPub, peerPQPub: bob.pqPub,
            context: context, pairingNonce: nil,
            selfUserId: aliceId, peerUserId: bobId
        )
        let honest = try ATSAMHybridPairing.pairAsResponder(
            local: bob, peerXPub: alice.xPub, peerPQPub: alice.pqPub,
            incomingCiphertext: initiator.outgoingCiphertext,
            context: context, pairingNonce: initiator.transcript.pairingNonce,
            selfUserId: bobId, peerUserId: aliceId
        )
        let substituted = try ATSAMHybridPairing.pairAsResponder(
            local: bob, peerXPub: alice.xPub, peerPQPub: alice.pqPub,
            incomingCiphertext: initiator.outgoingCiphertext,
            context: context, pairingNonce: initiator.transcript.pairingNonce,
            selfUserId: bobId, peerUserId: "mallory"
        )

        XCTAssertEqual(initiator.root, honest.root)
        XCTAssertNotEqual(initiator.root, substituted.root,
                          "Cross-pair binding is not enforcing the initiator identity.")
    }

    /// A differing pairing context must not yield a shared root.
    func testDifferentContextDivergesRoot() throws {
        let (alice, bob) = try makeHybridKeyPairs()

        let initiator = try ATSAMHybridPairing.pairAsInitiator(
            local: alice, peerXPub: bob.xPub, peerPQPub: bob.pqPub,
            context: context, pairingNonce: nil,
            selfUserId: aliceId, peerUserId: bobId
        )
        let otherContext = try ATSAMHybridPairing.pairAsResponder(
            local: bob, peerXPub: alice.xPub, peerPQPub: alice.pqPub,
            incomingCiphertext: initiator.outgoingCiphertext,
            context: Data("raven-mac-companion".utf8),
            pairingNonce: initiator.transcript.pairingNonce,
            selfUserId: bobId, peerUserId: aliceId
        )

        XCTAssertNotEqual(initiator.root, otherContext.root)
    }
}
