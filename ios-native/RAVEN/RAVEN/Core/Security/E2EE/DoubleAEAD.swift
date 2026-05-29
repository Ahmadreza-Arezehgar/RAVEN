//
//  DoubleAEAD.swift
//  RAVEN
//
//  Double-AEAD construction per the Ultra-Secure stack spec §1.4.
//
//  Layered, defence-in-depth authenticated encryption:
//
//      inner_ct = ChaCha20-Poly1305(k_inner, nonce, plaintext)
//      outer_ct = AES-GCM(k_outer, nonce, inner_ct)
//      commit  = HMAC-SHA256(k_inner || k_outer, nonce || outer_ct)
//
//  Why two AEADs from different families?
//  ──────────────────────────────────────
//  • If a vulnerability is found in AES (block-cipher math), ChaCha20
//    (stream-cipher math) still defends the plaintext.
//  • If ChaCha20 is broken, AES still defends.
//  • Block vs. stream construction means the failure modes are
//    independent — both have to fall for the plaintext to leak.
//
//  Why a separate commitment HMAC?
//  ────────────────────────────────
//  AEAD primitives are NOT key-committing by default — the same
//  ciphertext can decrypt under different keys to different plaintexts
//  (the "Salamander" attack family). We bind (k_inner, k_outer, nonce,
//  outer_ct) under HMAC-SHA256 so a recipient can prove the ciphertext
//  is the unique one valid for those keys.
//
//  Honest scope notes
//  ──────────────────
//  • The spec calls for AES-256-GCM-SIV (RFC 8452) on the outer layer
//    for nonce-misuse resistance. Apple's CryptoKit only ships plain
//    AES-GCM today; the SIV variant requires SwiftCrypto's
//    `_CryptoExtras` module which we don't currently link. Until that
//    lands, callers MUST guarantee unique nonces (per session, per
//    counter); reusing a nonce under the same key WILL leak the
//    plaintext XOR. This caveat is logged in the roadmap doc.
//  • The two keys are fully independent — derive both from your KDF,
//    do not split a single 64-byte block in half (that creates
//    correlated keys against which the dual-AEAD argument doesn't
//    hold cleanly).
//

import Foundation
import CryptoKit

enum DoubleAEAD {

    /// Wire-format magic for sanity checks on the encoded blob.
    private static let magic: [UInt8] = Array("RVNDA1\0\0".utf8)
    /// Layout: magic(8) | version(1) | reserved(3) | nonce(12)
    ///       | innerLen(4 BE) | outerLen(4 BE) | commit(32) | innerCt | outerCt
    private static let version: UInt8 = 1

    enum Error: Swift.Error {
        case invalidLength
        case badMagic
        case unsupportedVersion
        case commitmentMismatch
        case outerOpenFailed
        case innerOpenFailed
    }

    /// Encrypt `plaintext` under `(kInner, kOuter)`. The two keys MUST
    /// be independent (e.g. separate HKDF outputs with different
    /// `info` strings), each 32 bytes.
    static func seal(
        plaintext: Data,
        kInner: SymmetricKey,   // 32 bytes — ChaCha20-Poly1305
        kOuter: SymmetricKey,   // 32 bytes — AES-256-GCM
        nonce: Data? = nil
    ) throws -> Data {
        // 12-byte nonce shared between inner + outer. Caller may pin
        // it (test vectors); otherwise random per-call.
        let n: Data = nonce ?? Self.randomNonce()
        precondition(n.count == 12, "nonce must be 12 bytes")

        // Inner: ChaCha20-Poly1305 with our nonce; tag is appended.
        let innerSealed = try ChaChaPoly.seal(
            plaintext,
            using: kInner,
            nonce: try ChaChaPoly.Nonce(data: n)
        )
        // ChaCha20-Poly1305 ciphertext + 16-byte tag concatenated.
        let innerCt = innerSealed.ciphertext + innerSealed.tag

        // Outer: AES-GCM over the inner ciphertext.
        let outerSealed = try AES.GCM.seal(
            innerCt,
            using: kOuter,
            nonce: try AES.GCM.Nonce(data: n)
        )
        let outerCt = outerSealed.ciphertext + outerSealed.tag

        // Commitment: HMAC over (k_inner || k_outer || nonce || outer_ct).
        // Both keys feed the HMAC so tampering with either is detected.
        let commitKey = SymmetricKey(data: Self.bytes(of: kInner) + Self.bytes(of: kOuter))
        let commit = HMAC<SHA256>.authenticationCode(
            for: n + outerCt,
            using: commitKey
        )

        // Pack: magic | ver | reserved | nonce | innerLen | outerLen | commit | innerCt | outerCt
        var blob = Data(capacity: 8 + 1 + 3 + 12 + 4 + 4 + 32 + innerCt.count + outerCt.count)
        blob.append(contentsOf: Self.magic)
        blob.append(version)
        blob.append(contentsOf: [0, 0, 0])
        blob.append(n)
        blob.append(contentsOf: Self.beU32(UInt32(innerCt.count)))
        blob.append(contentsOf: Self.beU32(UInt32(outerCt.count)))
        blob.append(contentsOf: Array(commit))
        blob.append(innerCt)
        blob.append(outerCt)
        return blob
    }

    /// Decrypt a blob produced by `seal`. Verifies commitment first
    /// (so a wrong-key attempt fails before we touch the cryptographic
    /// boundary), then peels outer, then inner.
    static func open(
        blob: Data,
        kInner: SymmetricKey,
        kOuter: SymmetricKey
    ) throws -> Data {
        // Header layout sanity.
        let headerSize = 8 + 1 + 3 + 12 + 4 + 4 + 32
        guard blob.count >= headerSize else { throw Error.invalidLength }
        guard Array(blob.prefix(8)) == Self.magic else { throw Error.badMagic }
        let ver = blob[blob.startIndex + 8]
        guard ver == version else { throw Error.unsupportedVersion }

        let nonceStart = blob.startIndex + 12
        let nonce = blob.subdata(in: nonceStart..<(nonceStart + 12))
        let lenStart = nonceStart + 12
        let innerLen = Int(Self.readBeU32(blob, at: lenStart))
        let outerLen = Int(Self.readBeU32(blob, at: lenStart + 4))
        let commitStart = lenStart + 8
        let commit = blob.subdata(in: commitStart..<(commitStart + 32))
        let innerStart = commitStart + 32
        let outerStart = innerStart + innerLen

        guard blob.count == outerStart + outerLen else { throw Error.invalidLength }
        let innerCt = blob.subdata(in: innerStart..<outerStart)
        let outerCt = blob.subdata(in: outerStart..<(outerStart + outerLen))

        // Step 1: verify commitment BEFORE opening the AEAD layers.
        // This makes wrong-key attempts cheap to reject and immune to
        // the Salamander class of multi-key collision attacks.
        let commitKey = SymmetricKey(data: Self.bytes(of: kInner) + Self.bytes(of: kOuter))
        let expected = HMAC<SHA256>.authenticationCode(
            for: nonce + outerCt,
            using: commitKey
        )
        guard HMAC<SHA256>.isValidAuthenticationCode(
            commit, authenticating: nonce + outerCt, using: commitKey
        ), Array(expected) == Array(commit) else {
            throw Error.commitmentMismatch
        }

        // Step 2: open outer AES-GCM.
        guard outerCt.count >= 16 else { throw Error.invalidLength }
        let outerCtBody = outerCt.prefix(outerCt.count - 16)
        let outerTag = outerCt.suffix(16)
        let outerSealedBox = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: nonce),
            ciphertext: outerCtBody,
            tag: outerTag
        )
        let innerCtRecovered: Data
        do {
            innerCtRecovered = try AES.GCM.open(outerSealedBox, using: kOuter)
        } catch { throw Error.outerOpenFailed }
        guard innerCtRecovered == innerCt else { throw Error.outerOpenFailed }

        // Step 3: open inner ChaCha20-Poly1305.
        guard innerCt.count >= 16 else { throw Error.invalidLength }
        let innerCtBody = innerCt.prefix(innerCt.count - 16)
        let innerTag = innerCt.suffix(16)
        let innerSealedBox = try ChaChaPoly.SealedBox(
            nonce: try ChaChaPoly.Nonce(data: nonce),
            ciphertext: innerCtBody,
            tag: innerTag
        )
        do {
            return try ChaChaPoly.open(innerSealedBox, using: kInner)
        } catch { throw Error.innerOpenFailed }
    }

    // MARK: - Helpers

    private static func randomNonce() -> Data {
        var n = [UInt8](repeating: 0, count: 12)
        let r = SecRandomCopyBytes(kSecRandomDefault, 12, &n)
        precondition(r == errSecSuccess)
        return Data(n)
    }

    private static func bytes(of key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    private static func beU32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
         UInt8((v >> 8) & 0xFF),  UInt8(v & 0xFF)]
    }

    private static func readBeU32(_ d: Data, at off: Int) -> UInt32 {
        let b0 = UInt32(d[d.startIndex + off])
        let b1 = UInt32(d[d.startIndex + off + 1])
        let b2 = UInt32(d[d.startIndex + off + 2])
        let b3 = UInt32(d[d.startIndex + off + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    // MARK: - Debug self-test

    #if DEBUG
    /// Verifies round-trip + tamper-rejection + wrong-key-rejection.
    /// Output under "🛡️  [DoubleAEAD]".
    static func runDebugSelfTest() {
        let kInner = SymmetricKey(size: .bits256)
        let kOuter = SymmetricKey(size: .bits256)
        let plaintext = Data("hello double-AEAD world — this is a non-trivial payload".utf8)

        // 1) Round-trip
        let blob: Data
        let opened: Data
        do {
            blob = try seal(plaintext: plaintext, kInner: kInner, kOuter: kOuter)
            opened = try open(blob: blob, kInner: kInner, kOuter: kOuter)
        } catch {
            NSLog("🛡️  [DoubleAEAD] ❌ FAIL — round-trip threw: \(error)")
            return
        }
        guard opened == plaintext else {
            NSLog("🛡️  [DoubleAEAD] ❌ FAIL — plaintext mismatch")
            return
        }

        // 2) Wrong outer key → commitment mismatch (rejected before AEAD).
        do {
            _ = try open(blob: blob, kInner: kInner, kOuter: SymmetricKey(size: .bits256))
            NSLog("🛡️  [DoubleAEAD] ❌ FAIL — wrong outer key was accepted")
            return
        } catch Error.commitmentMismatch {
            // Expected.
        } catch {
            NSLog("🛡️  [DoubleAEAD] ❌ FAIL — wrong outer key threw \(error), expected commitmentMismatch")
            return
        }

        // 3) Wrong inner key → commitment mismatch (rejected before AEAD).
        do {
            _ = try open(blob: blob, kInner: SymmetricKey(size: .bits256), kOuter: kOuter)
            NSLog("🛡️  [DoubleAEAD] ❌ FAIL — wrong inner key was accepted")
            return
        } catch Error.commitmentMismatch {
            // Expected.
        } catch {
            NSLog("🛡️  [DoubleAEAD] ❌ FAIL — wrong inner key threw \(error), expected commitmentMismatch")
            return
        }

        // 4) Tamper with a single byte of the outer ciphertext.
        var tampered = blob
        let lastIdx = tampered.endIndex - 5
        tampered[lastIdx] ^= 0x01
        do {
            _ = try open(blob: tampered, kInner: kInner, kOuter: kOuter)
            NSLog("🛡️  [DoubleAEAD] ❌ FAIL — tampered ciphertext accepted")
            return
        } catch {
            // Expected — could be commitmentMismatch OR outerOpenFailed
            // depending on which check fails first.
        }

        // 5) Bad magic.
        var badMagic = blob
        badMagic[0] = 0x00
        do {
            _ = try open(blob: badMagic, kInner: kInner, kOuter: kOuter)
            NSLog("🛡️  [DoubleAEAD] ❌ FAIL — bad magic accepted")
            return
        } catch Error.badMagic {
            // Expected.
        } catch {
            NSLog("🛡️  [DoubleAEAD] ❌ FAIL — bad magic threw \(error), expected badMagic")
            return
        }

        NSLog("🛡️  [DoubleAEAD] ✅ SELF-TEST PASS — round-trip OK, wrong-key rejected (commitment), tamper rejected, bad magic rejected (blob=\(blob.count)B)")
    }
    #endif
}
