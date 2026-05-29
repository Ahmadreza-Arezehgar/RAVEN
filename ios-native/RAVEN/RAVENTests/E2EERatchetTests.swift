// E2EERatchetTests.swift
//
// Round-trip and property tests for the RAVEN E2EE module. These do
// NOT exercise persistence (RatchetSessionStore) or the network layer
// — they validate the pure cryptographic state machines so we can
// trust the foundation before wiring it into the message hot path.
//
// Naming follows the existing MeshInteropVectorsTests style.

import XCTest
import CryptoKit
@testable import RAVEN

final class E2EERatchetTests: XCTestCase {

    // ─── KDF_RK ──────────────────────────────────────────────────────

    func testKdfRootKeyDeterministic() throws {
        // Same inputs → same outputs.
        let rk = SymmetricKey(size: .bits256)
        let alice = Curve25519.KeyAgreement.PrivateKey()
        let bob = Curve25519.KeyAgreement.PrivateKey()
        let dh = try alice.sharedSecretFromKeyAgreement(with: bob.publicKey)

        let (rk1, ck1) = RatchetCrypto.kdfRootKey(rootKey: rk, dhOutput: dh)
        let (rk2, ck2) = RatchetCrypto.kdfRootKey(rootKey: rk, dhOutput: dh)

        XCTAssertEqual(rk1.dataRepresentation, rk2.dataRepresentation)
        XCTAssertEqual(ck1.dataRepresentation, ck2.dataRepresentation)
    }

    func testKdfRootKeyOutputsAre32Bytes() throws {
        let rk = SymmetricKey(size: .bits256)
        let alice = Curve25519.KeyAgreement.PrivateKey()
        let bob = Curve25519.KeyAgreement.PrivateKey()
        let dh = try alice.sharedSecretFromKeyAgreement(with: bob.publicKey)

        let (newRk, ck) = RatchetCrypto.kdfRootKey(rootKey: rk, dhOutput: dh)
        XCTAssertEqual(newRk.dataRepresentation.count, 32)
        XCTAssertEqual(ck.dataRepresentation.count, 32)
        // Root output and chain output must differ.
        XCTAssertNotEqual(newRk.dataRepresentation, ck.dataRepresentation)
    }

    // ─── KDF_CK ──────────────────────────────────────────────────────

    func testKdfChainKeySeparation() {
        // chain key and message key derived from the same chain key
        // must always differ (different HMAC constants).
        let ck = SymmetricKey(size: .bits256)
        let (newChain, msg) = RatchetCrypto.kdfChainKey(ck)
        XCTAssertEqual(newChain.dataRepresentation.count, 32)
        XCTAssertEqual(msg.dataRepresentation.count, 32)
        XCTAssertNotEqual(newChain.dataRepresentation, msg.dataRepresentation)
        // And neither equals the input.
        XCTAssertNotEqual(newChain.dataRepresentation, ck.dataRepresentation)
        XCTAssertNotEqual(msg.dataRepresentation, ck.dataRepresentation)
    }

    func testKdfChainKeyDeterminism() {
        let ck = SymmetricKey(data: Data(repeating: 0xAB, count: 32))
        let (a1, m1) = RatchetCrypto.kdfChainKey(ck)
        let (a2, m2) = RatchetCrypto.kdfChainKey(ck)
        XCTAssertEqual(a1.dataRepresentation, a2.dataRepresentation)
        XCTAssertEqual(m1.dataRepresentation, m2.dataRepresentation)
    }

    // ─── AEAD round-trip + tag binding ───────────────────────────────

    func testAeadRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data("hello mesh".utf8)
        let ad = Data("ad-bytes".utf8)

        let ct = try RatchetCrypto.aeadEncrypt(
            plaintext: plaintext, messageKey: key, associatedData: ad
        )
        let pt = try RatchetCrypto.aeadDecrypt(
            ciphertext: ct, messageKey: key, associatedData: ad
        )
        XCTAssertEqual(pt, plaintext)
    }

    func testAeadTagFailsOnWrongAD() throws {
        let key = SymmetricKey(size: .bits256)
        let ct = try RatchetCrypto.aeadEncrypt(
            plaintext: Data("x".utf8),
            messageKey: key,
            associatedData: Data("right".utf8)
        )
        XCTAssertThrowsError(try RatchetCrypto.aeadDecrypt(
            ciphertext: ct,
            messageKey: key,
            associatedData: Data("WRONG".utf8)
        ))
    }

    func testAeadTagFailsOnTamperedCiphertext() throws {
        let key = SymmetricKey(size: .bits256)
        var ct = try RatchetCrypto.aeadEncrypt(
            plaintext: Data("hello".utf8),
            messageKey: key,
            associatedData: Data()
        )
        // Flip one bit somewhere in the body.
        ct[ct.count - 1] ^= 0x01
        XCTAssertThrowsError(try RatchetCrypto.aeadDecrypt(
            ciphertext: ct,
            messageKey: key,
            associatedData: Data()
        ))
    }

    // ─── X3DH symmetry ───────────────────────────────────────────────

    func testX3DHInitiatorAndResponderDeriveSameSecret() throws {
        // Bob's long-term keys.
        let bobIdentityAgreement = Curve25519.KeyAgreement.PrivateKey()
        let bobSignedPreKey = Curve25519.KeyAgreement.PrivateKey()
        let bobOneTime = Curve25519.KeyAgreement.PrivateKey()

        // Alice's long-term key.
        let aliceIdentityAgreement = Curve25519.KeyAgreement.PrivateKey()

        // Alice fetches Bob's bundle (signature step is exercised in
        // the bundle test below; here we feed raw keys directly).
        let bundle = PreKeyBundle(
            userId: "bob",
            deviceId: "bob-device",
            identityKey: Data(repeating: 0, count: 32),  // unused for X3DH math
            identityAgreementKey: bobIdentityAgreement.publicKey.rawRepresentation,
            signedPreKey: SignedPreKeyPublic(
                id: 1,
                publicKey: bobSignedPreKey.publicKey.rawRepresentation,
                signature: Data(repeating: 0, count: 64),
                createdAt: 0
            ),
            oneTimePreKey: OneTimePreKeyPublic(
                id: 2,
                publicKey: bobOneTime.publicKey.rawRepresentation
            ),
            createdAt: 0
        )

        let aliceResult = try X3DH.initiate(
            ourIdentityAgreementPrivateKey: aliceIdentityAgreement,
            peerBundle: bundle
        )

        let bobSecret = try X3DH.respond(
            ourIdentityAgreementPrivateKey: bobIdentityAgreement,
            ourSignedPreKeyPrivate: bobSignedPreKey,
            ourOneTimePreKeyPrivate: bobOneTime,
            peerIdentityAgreementKey: aliceIdentityAgreement.publicKey.rawRepresentation,
            peerEphemeralKey: aliceResult.ephemeralPublicKey
        )

        XCTAssertEqual(
            aliceResult.sharedSecret.dataRepresentation,
            bobSecret.dataRepresentation,
            "X3DH must produce identical SK on both sides"
        )
    }

    func testX3DHWorksWithoutOneTimePreKey() throws {
        // Bundles can run dry; X3DH is still secure (just without
        // the one-time post-compromise contribution).
        let bobIA = Curve25519.KeyAgreement.PrivateKey()
        let bobSPK = Curve25519.KeyAgreement.PrivateKey()
        let aliceIA = Curve25519.KeyAgreement.PrivateKey()

        let bundle = PreKeyBundle(
            userId: "bob",
            deviceId: "bob-device",
            identityKey: Data(repeating: 0, count: 32),
            identityAgreementKey: bobIA.publicKey.rawRepresentation,
            signedPreKey: SignedPreKeyPublic(
                id: 1,
                publicKey: bobSPK.publicKey.rawRepresentation,
                signature: Data(repeating: 0, count: 64),
                createdAt: 0
            ),
            oneTimePreKey: nil,
            createdAt: 0
        )

        let aliceResult = try X3DH.initiate(
            ourIdentityAgreementPrivateKey: aliceIA,
            peerBundle: bundle
        )
        let bobSecret = try X3DH.respond(
            ourIdentityAgreementPrivateKey: bobIA,
            ourSignedPreKeyPrivate: bobSPK,
            ourOneTimePreKeyPrivate: nil,
            peerIdentityAgreementKey: aliceIA.publicKey.rawRepresentation,
            peerEphemeralKey: aliceResult.ephemeralPublicKey
        )
        XCTAssertEqual(
            aliceResult.sharedSecret.dataRepresentation,
            bobSecret.dataRepresentation
        )
    }

    // ─── Double Ratchet round-trips ──────────────────────────────────

    /// Build a fresh paired session for tests. Skips X3DH (we just
    /// inject a known shared secret) so we can isolate the ratchet.
    private func freshPair() throws -> (alice: RatchetState, bob: RatchetState, bobSPK: Curve25519.KeyAgreement.PrivateKey) {
        let sk = SymmetricKey(size: .bits256)
        let bobSPK = Curve25519.KeyAgreement.PrivateKey()

        let alice = try RatchetState.initialiseAsInitiator(
            sharedSecret: sk,
            peerSignedPreKey: bobSPK.publicKey.rawRepresentation
        )
        let bob = RatchetState.initialiseAsResponder(
            sharedSecret: sk,
            ourSignedPreKeyPrivate: bobSPK
        )
        return (alice, bob, bobSPK)
    }

    func testDoubleRatchetSingleRoundTrip() throws {
        var (alice, bob, _) = try freshPair()

        let ct = try DoubleRatchet.encrypt(
            state: &alice,
            plaintext: Data("hi bob".utf8),
            associatedData: Data()
        )
        let pt = try DoubleRatchet.decrypt(
            state: &bob,
            ciphertext: ct,
            associatedData: Data()
        )
        XCTAssertEqual(pt, Data("hi bob".utf8))
    }

    func testDoubleRatchetPingPong() throws {
        var (alice, bob, _) = try freshPair()

        // Alice → Bob × 3
        for i in 0..<3 {
            let plaintext = Data("a→b #\(i)".utf8)
            let ct = try DoubleRatchet.encrypt(state: &alice, plaintext: plaintext, associatedData: Data())
            let pt = try DoubleRatchet.decrypt(state: &bob, ciphertext: ct, associatedData: Data())
            XCTAssertEqual(pt, plaintext)
        }
        // Bob → Alice × 3 (triggers Bob's first send DH ratchet)
        for i in 0..<3 {
            let plaintext = Data("b→a #\(i)".utf8)
            let ct = try DoubleRatchet.encrypt(state: &bob, plaintext: plaintext, associatedData: Data())
            let pt = try DoubleRatchet.decrypt(state: &alice, ciphertext: ct, associatedData: Data())
            XCTAssertEqual(pt, plaintext)
        }
        // And back to Alice → Bob to confirm chain rotated cleanly.
        let final = Data("post-rotation".utf8)
        let ct = try DoubleRatchet.encrypt(state: &alice, plaintext: final, associatedData: Data())
        let pt = try DoubleRatchet.decrypt(state: &bob, ciphertext: ct, associatedData: Data())
        XCTAssertEqual(pt, final)
    }

    func testDoubleRatchetOutOfOrderDelivery() throws {
        var (alice, bob, _) = try freshPair()

        // Alice sends 3 messages.
        let p0 = Data("zero".utf8)
        let p1 = Data("one".utf8)
        let p2 = Data("two".utf8)
        let c0 = try DoubleRatchet.encrypt(state: &alice, plaintext: p0, associatedData: Data())
        let c1 = try DoubleRatchet.encrypt(state: &alice, plaintext: p1, associatedData: Data())
        let c2 = try DoubleRatchet.encrypt(state: &alice, plaintext: p2, associatedData: Data())

        // Bob receives them out of order: 2, 0, 1.
        let r2 = try DoubleRatchet.decrypt(state: &bob, ciphertext: c2, associatedData: Data())
        let r0 = try DoubleRatchet.decrypt(state: &bob, ciphertext: c0, associatedData: Data())
        let r1 = try DoubleRatchet.decrypt(state: &bob, ciphertext: c1, associatedData: Data())

        XCTAssertEqual(r0, p0)
        XCTAssertEqual(r1, p1)
        XCTAssertEqual(r2, p2)
    }

    func testDoubleRatchetReplayFails() throws {
        var (alice, bob, _) = try freshPair()
        let ct = try DoubleRatchet.encrypt(
            state: &alice,
            plaintext: Data("once".utf8),
            associatedData: Data()
        )
        XCTAssertNoThrow(try DoubleRatchet.decrypt(
            state: &bob,
            ciphertext: ct,
            associatedData: Data()
        ))
        // Replaying the same ciphertext should fail — the message
        // key was consumed, no skipped entry exists.
        XCTAssertThrowsError(try DoubleRatchet.decrypt(
            state: &bob,
            ciphertext: ct,
            associatedData: Data()
        ))
    }

    func testDoubleRatchetWrongAssociatedDataFails() throws {
        var (alice, bob, _) = try freshPair()
        let ct = try DoubleRatchet.encrypt(
            state: &alice,
            plaintext: Data("bound".utf8),
            associatedData: Data("right-AD".utf8)
        )
        XCTAssertThrowsError(try DoubleRatchet.decrypt(
            state: &bob,
            ciphertext: ct,
            associatedData: Data("wrong-AD".utf8)
        ))
    }

    func testDoubleRatchetSkippedKeyLimit() throws {
        var (alice, bob, _) = try freshPair()
        // Alice sends one message just to advance her counter
        // baseline; we'll fabricate a header with absurdly large `n`.
        let _ = try DoubleRatchet.encrypt(
            state: &alice,
            plaintext: Data("a".utf8),
            associatedData: Data()
        )
        // Hand Bob a forged ciphertext with n above the cap. The
        // ciphertext won't decrypt either way, but the bound check
        // should fail FIRST so we never try to derive a million keys.
        let aliceDH = alice.DHs.publicKey.rawRepresentation
        let bogus = RatchetCiphertext(
            header: RatchetHeader(
                dh: aliceDH,
                pn: 0,
                n: UInt32(RatchetState.maxSkippedKeysPerSession + 1)
            ),
            body: Data(repeating: 0, count: 32)
        )
        XCTAssertThrowsError(try DoubleRatchet.decrypt(
            state: &bob,
            ciphertext: bogus,
            associatedData: Data()
        )) { err in
            guard case RatchetError.skippedKeyLimitExceeded = err else {
                XCTFail("expected skippedKeyLimitExceeded, got \(err)")
                return
            }
        }
    }

    // ─── Wire codable round-trip ─────────────────────────────────────

    func testE2EEWirePacketCodableRoundTrip_Message() throws {
        let header = RatchetHeader(
            dh: Data(repeating: 7, count: 32),
            pn: 5,
            n: 42
        )
        let ct = RatchetCiphertext(header: header, body: Data([1,2,3,4,5]))
        let original = E2EEWirePacket.message(ct)

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(E2EEWirePacket.self, from: encoded)
        XCTAssertEqual(original, decoded)
    }

    func testE2EEWirePacketCodableRoundTrip_X3DH() throws {
        let header = RatchetHeader(dh: Data(repeating: 9, count: 32), pn: 0, n: 0)
        let ct = RatchetCiphertext(header: header, body: Data([0xAB, 0xCD]))
        let initMsg = X3DHInitialMessage(
            identityKey:           Data(repeating: 1, count: 32),
            identityAgreementKey:  Data(repeating: 2, count: 32),
            ephemeralKey:          Data(repeating: 3, count: 32),
            signedPreKeyId:        7,
            oneTimePreKeyId:       11,
            firstCiphertext:       ct
        )
        let original = E2EEWirePacket.x3dh(initMsg)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(E2EEWirePacket.self, from: encoded)
        XCTAssertEqual(original, decoded)
    }

    // ─── PreKey bundle signature ─────────────────────────────────────

    func testPreKeyBundleSignatureVerifyRejectsTampered() async throws {
        // Verify path needs a real device identity. Spin one up via
        // the existing service so we exercise the same code path the
        // app uses on first launch.
        try await DeviceIdentityService.shared.initialize()

        guard let identity = DeviceIdentityService.shared.publicKeyData,
              let agreement = DeviceIdentityService.shared.agreementPublicKeyData else {
            return XCTFail("Identity not initialised")
        }
        let spkPublic = Data(repeating: 0xAA, count: 32)
        guard let sig = DeviceIdentityService.shared.sign(spkPublic) else {
            return XCTFail("Sign failed")
        }

        let bundle = PreKeyBundle(
            userId: "u",
            deviceId: "d",
            identityKey: identity,
            identityAgreementKey: agreement,
            signedPreKey: SignedPreKeyPublic(
                id: 1,
                publicKey: spkPublic,
                signature: sig,
                createdAt: 0
            ),
            oneTimePreKey: nil,
            createdAt: 0
        )
        XCTAssertTrue(bundle.verifySignature())

        // Tamper with the public key — signature should no longer
        // match.
        let tampered = PreKeyBundle(
            userId: "u",
            deviceId: "d",
            identityKey: identity,
            identityAgreementKey: agreement,
            signedPreKey: SignedPreKeyPublic(
                id: 1,
                publicKey: Data(repeating: 0xBB, count: 32),
                signature: sig,
                createdAt: 0
            ),
            oneTimePreKey: nil,
            createdAt: 0
        )
        XCTAssertFalse(tampered.verifySignature())
    }
}
