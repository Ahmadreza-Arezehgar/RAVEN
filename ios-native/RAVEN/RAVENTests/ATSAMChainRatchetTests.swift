// ATSAMChainRatchetTests.swift
//
// Tests for ATSAM wire protocol v2 forward secrecy (ATSAMChainRatchet).
//
// The property under test is the one the protocol page publishes: a device
// compromised at chain index N must not be able to derive the message keys for
// indices 0…N-1. `testCompromisedStateCannotRecoverEarlierKeys` is the direct
// assertion of that claim; everything else guards the properties the ratchet
// needs in order to be usable in a delay-tolerant mesh without silently
// dropping real traffic.
//
// Naming follows the existing MeshInteropVectorsTests style.

import XCTest
import CryptoKit
@testable import RAVEN

final class ATSAMChainRatchetTests: XCTestCase {

    private let alice = "8f14e45f-alice"
    private let bob = "c9f0f895-bob"

    private func makeRoot() -> ATSAMRootKey {
        var bytes = Data(count: ATSAMConstants.Sizes.rootKeyBytes)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        return ATSAMRootKey(rootBytes: bytes)
    }

    private func chain(_ root: ATSAMRootKey, from s: String, to r: String) -> ATSAMChainState {
        ATSAMChainState(chainKey: ATSAMChainRatchet.initialChainKey(
            root: root, senderUserId: s, recipientUserId: r))
    }

    // ─── The forward-secrecy claim ───────────────────────────────────

    /// The headline property. Advancing the chain must destroy the ability to
    /// derive earlier keys — otherwise "forward secrecy" is not true and the
    /// public protocol page is wrong.
    func testCompromisedStateCannotRecoverEarlierKeys() throws {
        let root = makeRoot()
        var state = chain(root, from: alice, to: bob)

        // Capture the key for index 0, then ratchet well past it.
        let first = ATSAMChainRatchet.sendKey(state: state,
                                              senderUserId: alice, recipientUserId: bob)
        let key0 = first.key.withUnsafeBytes { Data($0) }
        state = first.next
        for _ in 0..<9 {
            state = ATSAMChainRatchet.sendKey(state: state,
                                              senderUserId: alice, recipientUserId: bob).next
        }
        XCTAssertEqual(state.index, 10)

        // The seized state must contain no copy of the retired key...
        XCTAssertNotEqual(state.chainKey, key0)
        XCTAssertFalse(state.skipped.values.contains(key0))

        // ...and must not be able to reproduce it.
        XCTAssertThrowsError(try ATSAMChainRatchet.openKey(
            state: state, index: 0, senderUserId: alice, recipientUserId: bob
        )) { error in
            XCTAssertEqual(error as? ATSAMRatchetError, .keyUnavailable(index: 0))
        }
    }

    /// The chain step must be one-way and deterministic.
    func testChainAdvanceIsOneWayAndDeterministic() {
        let root = makeRoot()
        let ck0 = ATSAMChainRatchet.initialChainKey(root: root,
                                                    senderUserId: alice, recipientUserId: bob)
        let ck1 = ATSAMChainRatchet.advanceChainKey(ck0)
        XCTAssertNotEqual(ck0, ck1)
        XCTAssertEqual(ATSAMChainRatchet.advanceChainKey(ck0), ck1, "advance must be deterministic")
        XCTAssertEqual(ck1.count, ATSAMConstants.Sizes.subKeyBytes)
    }

    // ─── Correctness: the two sides must agree ───────────────────────

    func testSenderAndReceiverDeriveMatchingKeysInOrder() throws {
        let root = makeRoot()
        var send = chain(root, from: alice, to: bob)
        var recv = chain(root, from: alice, to: bob)

        for _ in 0..<25 {
            let s = ATSAMChainRatchet.sendKey(state: send,
                                              senderUserId: alice, recipientUserId: bob)
            send = s.next
            let r = try ATSAMChainRatchet.openKey(state: recv, index: s.index,
                                                  senderUserId: alice, recipientUserId: bob)
            recv = r.next
            XCTAssertEqual(s.key, r.key, "key mismatch at index \(s.index)")
        }
        XCTAssertEqual(send.index, 25)
        XCTAssertEqual(recv.index, 25)
    }

    /// A→B and B→A must be independent chains, so a reflected ciphertext
    /// cannot authenticate.
    func testDirectionsAreSeparated() {
        let root = makeRoot()
        let ab = ATSAMChainRatchet.initialChainKey(root: root,
                                                   senderUserId: alice, recipientUserId: bob)
        let ba = ATSAMChainRatchet.initialChainKey(root: root,
                                                   senderUserId: bob, recipientUserId: alice)
        XCTAssertNotEqual(ab, ba)
    }

    func testDifferentRootsAndPeersYieldDifferentChains() {
        let root = makeRoot()
        let ab = ATSAMChainRatchet.initialChainKey(root: root,
                                                   senderUserId: alice, recipientUserId: bob)
        XCTAssertNotEqual(ab, ATSAMChainRatchet.initialChainKey(
            root: makeRoot(), senderUserId: alice, recipientUserId: bob))
        XCTAssertNotEqual(ab, ATSAMChainRatchet.initialChainKey(
            root: root, senderUserId: alice, recipientUserId: "carol"))
    }

    // ─── Delay tolerance ─────────────────────────────────────────────

    /// RAVEN is a DTN: messages arrive badly out of order. If this fails, the
    /// ratchet silently eats real user messages.
    func testHeavilyReorderedDeliveryStillOpens() throws {
        let root = makeRoot()
        var send = chain(root, from: alice, to: bob)
        var sent: [(UInt32, SymmetricKey)] = []
        for _ in 0..<10 {
            let s = ATSAMChainRatchet.sendKey(state: send,
                                              senderUserId: alice, recipientUserId: bob)
            send = s.next
            sent.append((s.index, s.key))
        }

        var recv = chain(root, from: alice, to: bob)
        for idx in [9, 7, 3, 0, 1, 2, 4, 5, 6, 8] {
            let r = try ATSAMChainRatchet.openKey(state: recv, index: UInt32(idx),
                                                  senderUserId: alice, recipientUserId: bob)
            recv = r.next
            XCTAssertEqual(r.key, sent[idx].1, "key mismatch for late message \(idx)")
        }
    }

    // ─── Replay ──────────────────────────────────────────────────────

    /// Using a key must consume it, so the same index cannot be opened twice.
    func testReplayOfSameIndexIsRejected() throws {
        let root = makeRoot()
        var recv = chain(root, from: alice, to: bob)

        recv = try ATSAMChainRatchet.openKey(state: recv, index: 5,
                                             senderUserId: alice, recipientUserId: bob).next
        XCTAssertThrowsError(try ATSAMChainRatchet.openKey(
            state: recv, index: 5, senderUserId: alice, recipientUserId: bob))

        // A cached (skipped) key is likewise single-use.
        recv = try ATSAMChainRatchet.openKey(state: recv, index: 2,
                                             senderUserId: alice, recipientUserId: bob).next
        XCTAssertThrowsError(try ATSAMChainRatchet.openKey(
            state: recv, index: 2, senderUserId: alice, recipientUserId: bob))
    }

    // ─── DoS bounds ──────────────────────────────────────────────────

    /// An unbounded forward jump would let one frame force billions of HKDF
    /// invocations.
    func testHugeForwardJumpIsRejected() {
        let root = makeRoot()
        let recv = chain(root, from: alice, to: bob)
        XCTAssertThrowsError(try ATSAMChainRatchet.openKey(
            state: recv, index: 4_000_000_000,
            senderUserId: alice, recipientUserId: bob
        )) { error in
            guard case .forwardJumpTooLarge = (error as? ATSAMRatchetError) else {
                return XCTFail("expected forwardJumpTooLarge, got \(error)")
            }
        }
    }

    /// The skipped-key cache must stay bounded no matter how many gaps arrive.
    func testSkippedKeyCacheStaysBounded() throws {
        let root = makeRoot()
        var recv = chain(root, from: alice, to: bob)
        var cursor: UInt32 = 0
        for _ in 0..<12 {
            cursor += 200
            recv = try ATSAMChainRatchet.openKey(state: recv, index: cursor,
                                                 senderUserId: alice, recipientUserId: bob).next
            XCTAssertLessThanOrEqual(recv.skipped.count, ATSAMChainRatchet.maxSkippedKeys)
        }
    }

    // ─── Concurrency ─────────────────────────────────────────────────

    /// Every reserved send index must be unique, even under parallel sends.
    ///
    /// RAVEN fans sends out concurrently (DeliveryJobRunner, outbox drain), and
    /// two sends that both take index N are not a keystream break — the nonces
    /// differ — but the receiver consumes N for whichever lands first and
    /// rejects the other, so a message silently disappears. `reserveSendStep`
    /// is non-async precisely so no other call can interleave between read,
    /// advance and persist.
    func testConcurrentSendReservationsNeverCollide() async throws {
        let root = makeRoot()
        let peer = "concurrency-peer-\(UUID().uuidString)"
        let me = "concurrency-self"
        let storage = ATSAMRootStorage.shared
        try await storage.setRoot(root, transcript: makeTranscript(), for: peer)
        defer { Task { await storage.purge(for: peer) } }

        let count = 64
        var indices: [UInt32] = []
        try await withThrowingTaskGroup(of: UInt32.self) { group in
            for _ in 0..<count {
                group.addTask {
                    try await storage.reserveSendStep(
                        peerUserId: peer, selfUserId: me, root: root
                    ).index
                }
            }
            for try await idx in group { indices.append(idx) }
        }

        XCTAssertEqual(indices.count, count)
        XCTAssertEqual(Set(indices).count, count,
                       "duplicate send index reserved — a message would be silently dropped")
        XCTAssertEqual(Set(indices), Set(0..<UInt32(count)),
                       "reserved indices are not the contiguous range 0..<\(count)")
    }

    /// Re-pairing MUST reset the ratchet.
    ///
    /// Chains are seeded from the root but persist independently of it. If a
    /// new root did not clear them, a re-pair would be silently ignored: one
    /// side would seed fresh chains from the new root while the other kept
    /// using chains derived from the old one, so every message would fail its
    /// AEAD in both directions — permanently, since re-pairing again would hit
    /// the same stale rows. It would also make a post-compromise safety-number
    /// rotation useless, as message keys would still descend from the
    /// compromised root.
    func testRePairingResetsChainState() async throws {
        let peer = "repair-peer-\(UUID().uuidString)"
        let me = "repair-self"
        let storage = ATSAMRootStorage.shared

        let rootA = makeRoot()
        try await storage.setRoot(rootA, transcript: makeTranscript(), for: peer)
        defer { Task { await storage.purge(for: peer) } }

        // Burn several indices under the first root.
        var lastKeyUnderA: SymmetricKey?
        for _ in 0..<5 {
            lastKeyUnderA = try await storage.reserveSendStep(
                peerUserId: peer, selfUserId: me, root: rootA).key
        }
        let nextUnderA = try await storage.reserveSendStep(
            peerUserId: peer, selfUserId: me, root: rootA)
        XCTAssertEqual(nextUnderA.index, 5, "chain did not advance under the first root")

        // Re-pair with a DIFFERENT root.
        let rootB = makeRoot()
        try await storage.setRoot(rootB, transcript: makeTranscript(), for: peer)

        let afterRePair = try await storage.reserveSendStep(
            peerUserId: peer, selfUserId: me, root: rootB)
        XCTAssertEqual(afterRePair.index, 0,
                       "chain survived a re-pair — the new root is being ignored")
        XCTAssertEqual(
            afterRePair.key,
            ATSAMChainRatchet.messageKey(
                chainKey: ATSAMChainRatchet.initialChainKey(
                    root: rootB, senderUserId: me, recipientUserId: peer),
                senderUserId: me, recipientUserId: peer),
            "chain was not re-seeded from the NEW root"
        )
        XCTAssertNotEqual(afterRePair.key, nextUnderA.key)
        XCTAssertNotEqual(afterRePair.key, lastKeyUnderA)
    }

    private func makeTranscript() -> ATSAMTranscript {
        // Minimal well-formed transcript; only its hash is stored.
        try! ATSAMTranscript(
            protocolVersion: ATSAMConstants.formatVersion,
            cipherSuite: ATSAMConstants.cipherSuite,
            pkAX: Data(repeating: 0x01, count: 32),
            pkBX: Data(repeating: 0x02, count: 32),
            pkAPQ: Data(), pkBPQ: Data(), ctPQ: Data(),
            context: Data("test".utf8),
            pairingNonce: Data(repeating: 0x03, count: 32)
        )
    }

    /// Shared vector `rvn1/atsam/chain_kdf_001.json` — must match Rust `atsam_kdf`.
    func testSharedVectorChainKdf001() {
        let root = ATSAMRootKey(rootBytes: Data(repeating: 0x11, count: 32))
        let ck0 = ATSAMChainRatchet.initialChainKey(root: root, senderUserId: "alice", recipientUserId: "bob")
        XCTAssertEqual(
            ck0.map { String(format: "%02x", $0) }.joined(),
            "39f17981af60a336e251a8febf51c70f559c536fad19875776cc87fd7f76781d"
        )
        let ck1 = ATSAMChainRatchet.advanceChainKey(ck0)
        XCTAssertEqual(
            ck1.map { String(format: "%02x", $0) }.joined(),
            "6aaed354f7111c07091980aaa6c700464439f7b9d2033f59178f960261a4a0cd"
        )
        let kmsg = ATSAMChainRatchet.messageKey(chainKey: ck0, senderUserId: "alice", recipientUserId: "bob")
        let kmsgHex = kmsg.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(kmsgHex, "d74716298bd6d3a7211ace359f053f6417f9ad6d6b485257a0846d14da9cd5a0")
    }

    // ─── Persistence ─────────────────────────────────────────────────

    func testChainStateEncodeDecodeRoundTrip() throws {
        let root = makeRoot()
        var recv = chain(root, from: alice, to: bob)
        // Populate skipped keys so the variable-length part is exercised.
        recv = try ATSAMChainRatchet.openKey(state: recv, index: 7,
                                             senderUserId: alice, recipientUserId: bob).next

        let blob = recv.encode()
        let decoded = try XCTUnwrap(ATSAMChainState.decode(blob))
        XCTAssertEqual(decoded.chainKey, recv.chainKey)
        XCTAssertEqual(decoded.index, recv.index)
        XCTAssertEqual(decoded.skipped, recv.skipped)
    }

    /// A truncated or corrupt Keychain blob must decode to nil rather than a
    /// half-initialised chain.
    func testCorruptChainBlobIsRejected() throws {
        let root = makeRoot()
        let state = chain(root, from: alice, to: bob)
        let blob = state.encode()

        XCTAssertNil(ATSAMChainState.decode(Data()))
        XCTAssertNil(ATSAMChainState.decode(blob.prefix(10)))
        XCTAssertNil(ATSAMChainState.decode(blob + Data([0x00])))
    }
}
