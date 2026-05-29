// KeyBackupServiceTests.swift
//
// Round-trip + negative-path tests for KeyBackupService. The service
// owns the v1.6 "encrypted key backup & recovery" feature; these tests
// nail down the wire-format invariants and the passphrase-failure
// behaviour so a regression in the cryptographic boundary surfaces
// immediately rather than at restore time on a real user's device.

import XCTest
import CryptoKit
@testable import RAVEN

@MainActor
final class KeyBackupServiceTests: XCTestCase {

    // ─── Round trip ────────────────────────────────────────────────────

    /// The headline contract: encrypt with a passphrase, decrypt with
    /// the same passphrase, recover identical keys. If this ever
    /// breaks the feature is dead — keys cannot be restored.
    func testBackupRestoreRoundTrip() throws {
        // Seed Keychain with two known Curve25519 keys (signing + agreement).
        let signing = Curve25519.Signing.PrivateKey()
        let agreement = Curve25519.KeyAgreement.PrivateKey()
        try seedKeychain(signing: signing, agreement: agreement)

        let svc = KeyBackupService.shared
        let passphrase = "correct horse battery staple"

        // Encrypt
        let blob = try svc.makeBackup(passphrase: passphrase, userId: "u1")
        XCTAssertGreaterThan(blob.count, 64, "Blob too small to contain header + ct + tag")
        XCTAssertEqual(Array(blob.prefix(8)), Array("RVNBKP1\0".utf8), "Magic bytes wrong")

        // Decrypt with the SAME passphrase
        let restored = try svc.openBackup(blob: blob, passphrase: passphrase)
        XCTAssertEqual(restored.userId, "u1")
        XCTAssertEqual(restored.identitySigningPrivKey, signing.rawRepresentation)
        XCTAssertEqual(restored.identitySigningPubKey, signing.publicKey.rawRepresentation)
        XCTAssertEqual(restored.agreementPrivKey, agreement.rawRepresentation)
        XCTAssertEqual(restored.agreementPubKey, agreement.publicKey.rawRepresentation)
    }

    // ─── Negative: wrong passphrase ───────────────────────────────────

    /// A wrong passphrase MUST fail with `wrongPassphrase` — never
    /// return garbage. AES-GCM authenticates so this is enforced by
    /// the cipher, but the test ensures the service maps the error
    /// correctly (so the UI can show "wrong passphrase" not a generic
    /// crypto error).
    func testWrongPassphraseRejected() throws {
        let signing = Curve25519.Signing.PrivateKey()
        let agreement = Curve25519.KeyAgreement.PrivateKey()
        try seedKeychain(signing: signing, agreement: agreement)

        let svc = KeyBackupService.shared
        let blob = try svc.makeBackup(passphrase: "right-pass", userId: "u1")

        XCTAssertThrowsError(try svc.openBackup(blob: blob, passphrase: "WRONG-pass")) { err in
            guard case KeyBackupService.BackupError.wrongPassphrase = err else {
                XCTFail("Expected .wrongPassphrase, got \(err)")
                return
            }
        }
    }

    // ─── Negative: tampered ciphertext ────────────────────────────────

    /// Flipping any byte in the ciphertext must trip GCM auth. This
    /// guards against a server that swaps blobs around — the user's
    /// passphrase verifies the bytes weren't substituted.
    func testTamperedCiphertextRejected() throws {
        let signing = Curve25519.Signing.PrivateKey()
        let agreement = Curve25519.KeyAgreement.PrivateKey()
        try seedKeychain(signing: signing, agreement: agreement)

        let svc = KeyBackupService.shared
        let pw = "the-right-pass"
        var blob = try svc.makeBackup(passphrase: pw, userId: "u1")

        // Flip a byte deep in the ciphertext (after the 32-byte header
        // + salt + nonce so we don't accidentally hit the magic).
        let flipIndex = blob.count - 32
        blob[flipIndex] ^= 0xFF

        XCTAssertThrowsError(try svc.openBackup(blob: blob, passphrase: pw)) { err in
            // Accept either wrongPassphrase (CryptoKitError) or decryptFailed
            switch err {
            case KeyBackupService.BackupError.wrongPassphrase,
                 KeyBackupService.BackupError.decryptFailed:
                break
            default:
                XCTFail("Expected wrongPassphrase or decryptFailed, got \(err)")
            }
        }
    }

    // ─── Negative: malformed blob ─────────────────────────────────────

    func testInvalidMagicRejected() throws {
        let svc = KeyBackupService.shared
        let bogus = Data(repeating: 0xAB, count: 256)
        XCTAssertThrowsError(try svc.openBackup(blob: bogus, passphrase: "x")) { err in
            guard case KeyBackupService.BackupError.invalidMagic = err else {
                XCTFail("Expected .invalidMagic, got \(err)")
                return
            }
        }
    }

    func testTruncatedBlobRejected() throws {
        let svc = KeyBackupService.shared
        var blob = Data("RVNBKP1\0".utf8)
        blob.append(0x01) // version
        // Stop here — too short for header.
        XCTAssertThrowsError(try svc.openBackup(blob: blob, passphrase: "x")) { err in
            guard case KeyBackupService.BackupError.truncatedBlob = err else {
                XCTFail("Expected .truncatedBlob, got \(err)")
                return
            }
        }
    }

    // ─── Property: each backup is unique even with same input ─────────

    /// Salt + nonce are random per backup, so the same passphrase + the
    /// same keys MUST produce a different ciphertext every time. Without
    /// this, an attacker with two backups could detect that the user
    /// rolled the same passphrase.
    func testBackupsAreNonceUnique() throws {
        let signing = Curve25519.Signing.PrivateKey()
        let agreement = Curve25519.KeyAgreement.PrivateKey()
        try seedKeychain(signing: signing, agreement: agreement)

        let svc = KeyBackupService.shared
        let blob1 = try svc.makeBackup(passphrase: "pw", userId: "u1")
        let blob2 = try svc.makeBackup(passphrase: "pw", userId: "u1")
        XCTAssertNotEqual(blob1, blob2, "Two backups with same input must differ (salt/nonce randomness)")
    }

    // ─── File round trip ───────────────────────────────────────────────

    /// `writeBackup` + `openBackup(at:)` should round-trip through
    /// disk identically to in-memory.
    func testFileRoundTrip() throws {
        let signing = Curve25519.Signing.PrivateKey()
        let agreement = Curve25519.KeyAgreement.PrivateKey()
        try seedKeychain(signing: signing, agreement: agreement)

        let svc = KeyBackupService.shared
        let pw = "disk-test-pw"
        let blob = try svc.makeBackup(passphrase: pw, userId: "u-disk")
        let url = try svc.writeBackup(blob: blob, filename: "test-roundtrip.rvnbkp")
        defer { try? FileManager.default.removeItem(at: url) }

        let restored = try svc.openBackup(at: url, passphrase: pw)
        XCTAssertEqual(restored.userId, "u-disk")
        XCTAssertEqual(restored.identitySigningPrivKey, signing.rawRepresentation)
    }

    // ─── Helpers ───────────────────────────────────────────────────────

    /// Write a freshly-generated key pair into the same Keychain tags
    /// `KeyBackupService` reads from. Done at the test boundary so we
    /// don't rely on `DeviceIdentityService.initialize()` (which has
    /// other side effects we don't want in unit tests).
    private func seedKeychain(
        signing: Curve25519.Signing.PrivateKey,
        agreement: Curve25519.KeyAgreement.PrivateKey
    ) throws {
        try writeKeychain(tag: "app.raven.device.privatekey", data: signing.rawRepresentation)
        try writeKeychain(tag: "app.raven.device.publickey",  data: signing.publicKey.rawRepresentation)
        try writeKeychain(tag: "app.raven.device.agreement.privatekey", data: agreement.rawRepresentation)
        try writeKeychain(tag: "app.raven.device.agreement.publickey", data: agreement.publicKey.rawRepresentation)
    }

    private func writeKeychain(tag: String, data: Data) throws {
        let del: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8),
        ]
        SecItemDelete(del as CFDictionary)

        let add: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let st = SecItemAdd(add as CFDictionary, nil)
        XCTAssertEqual(st, errSecSuccess, "Keychain write failed (\(st)) — test environment broken")
    }
}
