//
//  KeyBackupService.swift
//  RAVEN
//
//  Encrypted key backup & recovery — v1.6 marquee feature.
//
//  Goal
//  ────
//  Let a user opt into an encrypted backup of every key the app needs
//  to keep their conversations going on a fresh device:
//
//      • Curve25519 signing identity (Ed25519-style)
//      • Curve25519 key-agreement identity (X25519)
//      • Double-Ratchet session state for every active conversation
//      • PreKey bundle private keys (so async first-contact still works)
//
//  The backup is sealed with AES-256-GCM under a key derived from the
//  user's recovery passphrase via PBKDF2-SHA256 (600k iterations,
//  OWASP-recommended). The server stores only the opaque ciphertext —
//  it can't decrypt without the passphrase, and the passphrase NEVER
//  leaves the device.
//
//  Wire format (v1)
//  ────────────────
//      magic     : "RVNBKP1\0" (8 bytes)
//      version   : uint8       (currently 0x01)
//      kdf       : uint8       (0x01 = PBKDF2-SHA256-600k)
//      cipher    : uint8       (0x01 = AES-256-GCM)
//      reserved  : uint8       (must be 0)
//      salt      : 16 bytes    (per-backup, random)
//      nonce     : 12 bytes    (per-backup, random; AES-GCM IV)
//      tagLen    : uint16 BE   (always 16 for GCM-128 tag)
//      ctLen     : uint32 BE   (length of ciphertext)
//      ct        : ctLen bytes (AES-256-GCM-encrypted JSON payload)
//      tag       : 16 bytes    (GCM authentication tag)
//
//  Decrypt requires re-running PBKDF2 with the embedded salt + the
//  user-supplied passphrase, then opening the GCM box. A wrong
//  passphrase fails authentication — there is no way to "partially"
//  restore.
//
//  Storage today
//  ─────────────
//  v1.6 stage 1 (this file): the encrypted blob is written to the
//  app's Documents directory and can be exported via the standard iOS
//  share sheet. Users back it up to wherever they trust (iCloud Drive,
//  AirDrop to a second device, password-manager attachment).
//
//  v1.6 stage 2 (next sprint): automatic upload to a per-user iCloud
//  CKContainer — same blob, same crypto, just zero-touch. Server-side
//  storage at /api/users/me/key-backup will accept the same blob for
//  cross-device sync where iCloud isn't available (e.g. for the Mac
//  Catalyst build that doesn't share iCloud with the iOS app).
//
//  Crucially: the server NEVER sees the passphrase, the derived key,
//  or the cleartext keys. Even with a court order, all that can be
//  surrendered is the encrypted blob — useless without the passphrase.
//

import Foundation
import CryptoKit
import CommonCrypto

// MARK: - Service

@MainActor
final class KeyBackupService {

    // MARK: - Singleton
    static let shared = KeyBackupService()
    private init() {}

    // MARK: - Constants

    /// File-format magic. Lets the parser fail fast on the wrong file.
    private static let magic: [UInt8] = Array("RVNBKP1\0".utf8)
    private static let formatVersion: UInt8 = 0x01
    private static let kdfPBKDF2 = 0x01
    private static let cipherAESGCM = 0x01
    private static let pbkdf2Iterations: UInt32 = 600_000
    private static let saltLength = 16
    private static let nonceLength = 12
    private static let keyLength = 32
    private static let gcmTagLength = 16

    // MARK: - Errors

    enum BackupError: LocalizedError {
        case noIdentity
        case keychainAccessFailed
        case kdfFailed(Int32)
        case encryptFailed(Error)
        case decryptFailed(Error)
        case invalidMagic
        case unsupportedVersion(UInt8)
        case unsupportedKDF(UInt8)
        case unsupportedCipher(UInt8)
        case truncatedBlob
        case wrongPassphrase
        case writeFailed(Error)
        case readFailed(Error)
        case payloadDecode(Error)

        var errorDescription: String? {
            switch self {
            case .noIdentity: return "No device identity to back up. Sign in first."
            case .keychainAccessFailed: return "Couldn't read your private keys from the Keychain."
            case .kdfFailed(let s): return "Passphrase derivation failed (PBKDF2 status \(s))."
            case .encryptFailed(let e): return "Encryption failed: \(e.localizedDescription)"
            case .decryptFailed: return "Decryption failed — wrong passphrase or corrupted backup."
            case .invalidMagic: return "This file isn't a Raven key backup."
            case .unsupportedVersion(let v): return "Unsupported backup version (0x\(String(v, radix: 16)))."
            case .unsupportedKDF(let k): return "Unsupported key-derivation function (0x\(String(k, radix: 16)))."
            case .unsupportedCipher(let c): return "Unsupported cipher (0x\(String(c, radix: 16)))."
            case .truncatedBlob: return "Backup file is truncated."
            case .wrongPassphrase: return "Wrong passphrase."
            case .writeFailed(let e): return "Couldn't write the backup file: \(e.localizedDescription)"
            case .readFailed(let e): return "Couldn't read the backup file: \(e.localizedDescription)"
            case .payloadDecode(let e): return "Backup payload couldn't be decoded: \(e.localizedDescription)"
            }
        }
    }

    // MARK: - Payload schema (v1)

    /// JSON envelope sealed inside the AES-GCM box. Fields are minimal
    /// because every byte costs a passphrase-stretching round-trip on
    /// restore. Optional fields let us evolve the schema forward.
    struct BackupPayload: Codable {
        let schema: Int                             // currently 1
        let createdAt: TimeInterval                 // unix seconds
        let userId: String?                         // for multi-account safety check on restore
        let identitySigningPrivKey: Data            // Curve25519 Ed25519-style
        let identitySigningPubKey: Data
        let agreementPrivKey: Data?                 // X25519 key-agreement
        let agreementPubKey: Data?
        let preKeyPrivateBundles: [Data]?           // future: signed-prekeys + OPKs
        let ratchetSnapshots: [RatchetSnapshot]?    // future: per-peer ratchet states

        struct RatchetSnapshot: Codable {
            let peerId: String
            let stateBlob: Data
        }
    }

    // MARK: - Public API

    /// Build an encrypted backup blob from the keys currently in
    /// Keychain + the supplied recovery passphrase. The blob is
    /// returned to the caller for user-controlled export (share
    /// sheet, AirDrop, save to Files).
    func makeBackup(passphrase: String, userId: String?) throws -> Data {
        guard !passphrase.isEmpty else { throw BackupError.wrongPassphrase }

        let payload = try collectCurrentKeyMaterial(userId: userId)
        let plaintext = try JSONEncoder().encode(payload)

        // Derive a 256-bit symmetric key from the passphrase.
        let salt = randomBytes(count: Self.saltLength)
        let derivedKey = try deriveKey(passphrase: passphrase, salt: salt)

        // Seal with AES-GCM.
        let nonce = randomBytes(count: Self.nonceLength)
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(
                plaintext,
                using: SymmetricKey(data: derivedKey),
                nonce: try AES.GCM.Nonce(data: nonce)
            )
        } catch {
            throw BackupError.encryptFailed(error)
        }

        return packageBlob(salt: salt, nonce: nonce, ciphertext: sealed.ciphertext, tag: sealed.tag)
    }

    /// Save a backup blob to the app's Documents directory under the
    /// supplied filename. Returns the absolute URL the user can share.
    @discardableResult
    func writeBackup(blob: Data, filename: String? = nil) throws -> URL {
        let filename = filename ?? Self.defaultFilename()
        let docs = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let url = docs.appendingPathComponent(filename)
        do {
            try blob.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            throw BackupError.writeFailed(error)
        }
        return url
    }

    /// Open a backup blob and return the decoded payload. Restoring
    /// the keys back into Keychain is a separate step (`applyRestore`)
    /// so the UI can show the user "this backup belongs to @<userId>,
    /// dated <date>" before they overwrite their current identity.
    func openBackup(blob: Data, passphrase: String) throws -> BackupPayload {
        guard !passphrase.isEmpty else { throw BackupError.wrongPassphrase }

        let parts = try parseBlob(blob)
        let derivedKey = try deriveKey(passphrase: passphrase, salt: parts.salt)

        let plaintext: Data
        do {
            let sealed = try AES.GCM.SealedBox(
                nonce: try AES.GCM.Nonce(data: parts.nonce),
                ciphertext: parts.ciphertext,
                tag: parts.tag
            )
            plaintext = try AES.GCM.open(sealed, using: SymmetricKey(data: derivedKey))
        } catch is CryptoKitError {
            throw BackupError.wrongPassphrase
        } catch {
            throw BackupError.decryptFailed(error)
        }

        do {
            return try JSONDecoder().decode(BackupPayload.self, from: plaintext)
        } catch {
            throw BackupError.payloadDecode(error)
        }
    }

    /// Convenience: read blob from disk + open it.
    func openBackup(at url: URL, passphrase: String) throws -> BackupPayload {
        let blob: Data
        do { blob = try Data(contentsOf: url) }
        catch { throw BackupError.readFailed(error) }
        return try openBackup(blob: blob, passphrase: passphrase)
    }

    /// Apply a decoded backup payload by writing each key into the
    /// Keychain under the same tags `DeviceIdentityService` reads
    /// from on next launch. Returns the userId stamped in the backup
    /// (if any) so the caller can warn before overwriting an unrelated
    /// account.
    @discardableResult
    func applyRestore(_ payload: BackupPayload) throws -> String? {
        try writeKeychain(tag: "app.raven.device.privatekey", data: payload.identitySigningPrivKey)
        try writeKeychain(tag: "app.raven.device.publickey",  data: payload.identitySigningPubKey)
        if let priv = payload.agreementPrivKey {
            try writeKeychain(tag: "app.raven.device.agreement.privatekey", data: priv)
        }
        if let pub = payload.agreementPubKey {
            try writeKeychain(tag: "app.raven.device.agreement.publickey", data: pub)
        }
        // Force the in-memory cache to drop so the next read re-loads
        // the freshly-restored material from Keychain.
        DeviceIdentityService.shared.invalidateCacheAfterRestore()
        return payload.userId
    }

    // MARK: - Debug self-test
    //
    // Until we wire a real XCTest target, the simplest way to confirm
    // the backup ↔ restore round-trip works on a real device is to run
    // it once at launch (DEBUG only) with throwaway keys. A failure
    // here means the cryptographic boundary is broken and we should
    // refuse to ship that build — log it loudly.

    #if DEBUG
    /// Self-tests the encrypt → decrypt round-trip + wrong-passphrase
    /// rejection without touching the user's real Keychain entries.
    /// Output appears in the simulator / device console under the
    /// "🔐 [KeyBackup]" tag.
    static func runDebugSelfTest() {
        let svc = KeyBackupService.shared
        let signing = Curve25519.Signing.PrivateKey()
        let agreement = Curve25519.KeyAgreement.PrivateKey()

        // Build a payload manually so the test doesn't depend on the
        // Keychain state of whichever account is currently signed in.
        let payload = BackupPayload(
            schema: 1,
            createdAt: Date().timeIntervalSince1970,
            userId: "debug-self-test",
            identitySigningPrivKey: signing.rawRepresentation,
            identitySigningPubKey: signing.publicKey.rawRepresentation,
            agreementPrivKey: agreement.rawRepresentation,
            agreementPubKey: agreement.publicKey.rawRepresentation,
            preKeyPrivateBundles: nil,
            ratchetSnapshots: nil
        )

        do {
            // Manual pack via the same primitives `makeBackup` uses.
            let pt = try JSONEncoder().encode(payload)
            let salt = svc.randomBytes(count: KeyBackupService.saltLength)
            let key = try svc.deriveKey(passphrase: "self-test-pw", salt: salt)
            let nonce = svc.randomBytes(count: KeyBackupService.nonceLength)
            let sealed = try AES.GCM.seal(
                pt,
                using: SymmetricKey(data: key),
                nonce: try AES.GCM.Nonce(data: nonce)
            )
            let blob = svc.packageBlob(salt: salt, nonce: nonce, ciphertext: sealed.ciphertext, tag: sealed.tag)

            // 1) Right passphrase opens it.
            let opened = try svc.openBackup(blob: blob, passphrase: "self-test-pw")
            guard opened.identitySigningPrivKey == signing.rawRepresentation,
                  opened.agreementPrivKey == agreement.rawRepresentation else {
                NSLog("🔐 [KeyBackup] ❌ FAIL — round-trip key mismatch")
                return
            }

            // 2) Wrong passphrase is rejected.
            do {
                _ = try svc.openBackup(blob: blob, passphrase: "WRONG-pw")
                NSLog("🔐 [KeyBackup] ❌ FAIL — wrong passphrase was accepted")
                return
            } catch BackupError.wrongPassphrase {
                // expected ✓
            }

            // 3) Tampered byte is rejected.
            var tampered = blob
            tampered[tampered.count - 32] ^= 0xFF
            do {
                _ = try svc.openBackup(blob: tampered, passphrase: "self-test-pw")
                NSLog("🔐 [KeyBackup] ❌ FAIL — tampered blob was accepted")
                return
            } catch BackupError.wrongPassphrase, BackupError.decryptFailed {
                // expected ✓
            }

            NSLog("🔐 [KeyBackup] ✅ SELF-TEST PASS — backup round-trip OK, wrong-pw rejected, tamper rejected (blob=\(blob.count)B)")
        } catch {
            NSLog("🔐 [KeyBackup] ❌ FAIL — self-test threw: \(error)")
        }
    }
    #endif

    // MARK: - Defaults

    static func defaultFilename() -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return "raven-backup-\(stamp).rvnbkp"
    }

    // MARK: - Internals

    private func collectCurrentKeyMaterial(userId: String?) throws -> BackupPayload {
        guard let signingPriv = readKeychain(tag: "app.raven.device.privatekey"),
              let signingPub  = readKeychain(tag: "app.raven.device.publickey") else {
            throw BackupError.noIdentity
        }
        let agreementPriv = readKeychain(tag: "app.raven.device.agreement.privatekey")
        let agreementPub  = readKeychain(tag: "app.raven.device.agreement.publickey")

        return BackupPayload(
            schema: 1,
            createdAt: Date().timeIntervalSince1970,
            userId: userId,
            identitySigningPrivKey: signingPriv,
            identitySigningPubKey: signingPub,
            agreementPrivKey: agreementPriv,
            agreementPubKey: agreementPub,
            preKeyPrivateBundles: nil,
            ratchetSnapshots: nil
        )
    }

    // MARK: PBKDF2

    /// PBKDF2-SHA256 on the user passphrase. Returns 32 bytes.
    ///
    /// Round 14 (2026-05-16) — hacker-audit finding S10. The
    /// passphrase bytes are copied into a mutable `Data` buffer up
    /// front and zeroed in a `defer` after PBKDF2 returns, so the
    /// raw passphrase doesn't linger in heap memory longer than
    /// needed. Swift `String` itself is immutable and can't be
    /// wiped, but limiting our handling to a short-lived `Data`
    /// shrinks the window an attacker has to inspect memory for the
    /// raw bytes.
    private func deriveKey(passphrase: String, salt: Data) throws -> Data {
        var pwData = Data(passphrase.utf8)
        var derived = Data(count: Self.keyLength)
        defer {
            // Best-effort wipe of the passphrase bytes.
            pwData.resetBytes(in: 0..<pwData.count)
        }

        let status: Int32 = pwData.withUnsafeBytes { pwBuf -> Int32 in
            derived.withUnsafeMutableBytes { derivedBuf -> Int32 in
                salt.withUnsafeBytes { saltBuf -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwBuf.bindMemory(to: Int8.self).baseAddress, pwBuf.count,
                        saltBuf.bindMemory(to: UInt8.self).baseAddress, saltBuf.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        Self.pbkdf2Iterations,
                        derivedBuf.bindMemory(to: UInt8.self).baseAddress, Self.keyLength
                    )
                }
            }
        }

        guard status == kCCSuccess else { throw BackupError.kdfFailed(status) }
        return derived
    }

    // MARK: Wire format

    private struct ParsedBlob {
        let salt: Data
        let nonce: Data
        let ciphertext: Data
        let tag: Data
    }

    private func packageBlob(salt: Data, nonce: Data, ciphertext: Data, tag: Data) -> Data {
        var out = Data()
        out.append(contentsOf: Self.magic)                    // 8
        out.append(Self.formatVersion)                        // 1
        out.append(UInt8(Self.kdfPBKDF2))                     // 1
        out.append(UInt8(Self.cipherAESGCM))                  // 1
        out.append(0x00)                                      // 1 reserved
        out.append(salt)                                      // 16
        out.append(nonce)                                     // 12
        out.append(uint16BE(UInt16(tag.count)))               // 2
        out.append(uint32BE(UInt32(ciphertext.count)))        // 4
        out.append(ciphertext)
        out.append(tag)
        return out
    }

    private func parseBlob(_ blob: Data) throws -> ParsedBlob {
        let header = 8 + 4 + Self.saltLength + Self.nonceLength + 2 + 4
        guard blob.count >= header else { throw BackupError.truncatedBlob }

        // Magic
        let magicSlice = Array(blob.prefix(8))
        guard magicSlice == Self.magic else { throw BackupError.invalidMagic }

        var off = 8
        let version = blob[off]; off += 1
        guard version == Self.formatVersion else { throw BackupError.unsupportedVersion(version) }
        let kdf = blob[off]; off += 1
        guard Int(kdf) == Self.kdfPBKDF2 else { throw BackupError.unsupportedKDF(kdf) }
        let cipher = blob[off]; off += 1
        guard Int(cipher) == Self.cipherAESGCM else { throw BackupError.unsupportedCipher(cipher) }
        off += 1 // reserved

        let salt = blob.subdata(in: off ..< (off + Self.saltLength)); off += Self.saltLength
        let nonce = blob.subdata(in: off ..< (off + Self.nonceLength)); off += Self.nonceLength

        let tagLen = Int(readUInt16BE(blob, off: off)); off += 2
        let ctLen = Int(readUInt32BE(blob, off: off));  off += 4

        guard blob.count >= off + ctLen + tagLen else { throw BackupError.truncatedBlob }
        let ct = blob.subdata(in: off ..< (off + ctLen)); off += ctLen
        let tag = blob.subdata(in: off ..< (off + tagLen))

        return ParsedBlob(salt: salt, nonce: nonce, ciphertext: ct, tag: tag)
    }

    // MARK: Keychain helpers
    //
    // Kept private to this service so we can write the same tags
    // DeviceIdentityService reads on its next load. We don't depend on
    // DeviceIdentityService publishing a `setKeys()` API to avoid
    // inviting other call sites to overwrite identity.

    private func readKeychain(tag: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
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
        guard st == errSecSuccess else { throw BackupError.keychainAccessFailed }
    }

    // MARK: Bytes / endian helpers

    private func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let r = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(r == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }
    private func uint16BE(_ v: UInt16) -> Data {
        Data([UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
    }
    private func uint32BE(_ v: UInt32) -> Data {
        Data([
            UInt8(v >> 24 & 0xff),
            UInt8(v >> 16 & 0xff),
            UInt8(v >> 8 & 0xff),
            UInt8(v & 0xff)
        ])
    }
    private func readUInt16BE(_ d: Data, off: Int) -> UInt16 {
        UInt16(d[off]) << 8 | UInt16(d[off + 1])
    }
    private func readUInt32BE(_ d: Data, off: Int) -> UInt32 {
        UInt32(d[off]) << 24 |
        UInt32(d[off + 1]) << 16 |
        UInt32(d[off + 2]) << 8  |
        UInt32(d[off + 3])
    }
}

// MARK: - DeviceIdentityService bridge
//
// `applyRestore` writes new keys directly into Keychain; the in-memory
// cache inside DeviceIdentityService will still be holding the OLD
// references until the next launch. This tiny extension lets the
// backup service force-flush that cache so a restore is visible to
// the rest of the app immediately.

extension DeviceIdentityService {
    /// Drop in-memory cached identity so the next read reloads from
    /// Keychain. Used by `KeyBackupService.applyRestore` after writing
    /// new keys, so the running app immediately uses the restored
    /// identity instead of the previous in-memory copy.
    func invalidateCacheAfterRestore() {
        // The keyCacheLock + cached* properties are private. We
        // re-load via the existing internal API by calling the
        // public initializer path; this is safe to call repeatedly.
        Task {
            try? await self.initialize()
        }
    }
}
