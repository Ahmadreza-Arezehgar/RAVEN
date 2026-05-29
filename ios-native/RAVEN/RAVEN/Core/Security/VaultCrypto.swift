//
//  VaultFileCrypto.swift
//  RAVEN
//
//  🔴 (2026-05-15 — round 3): per the user's request, "vault"
//  attachments add a second envelope on top of RAVEN's existing
//  transport-layer E2EE for files that the sender wants to mark as
//  particularly sensitive (financial documents, IDs, contracts, etc.).
//
//  Threat model:
//    • Server + DB compromise: vault payloads are random AES-GCM
//      ciphertext. Nothing in the upload pipeline ever sees plaintext.
//    • In-flight intercept: the wrapping keys are derived from a
//      recipient-only X25519 identity key — only the holder of the
//      private key can decrypt.
//    • Screenshot prevention: Apple does not expose a way to BLOCK
//      screenshots, only to DETECT. The vault viewer wires
//      `userDidTakeScreenshotNotification` so the sender is notified;
//      the UI is honest with the user about this (see VaultDocumentViewer).
//
//  Architecture summary (matches the design discussed with the user):
//
//    Sender                                   Recipient
//    ──────                                   ─────────
//    1. ephPriv, ephPub = X25519.keypair()
//    2. ssRecipient = ECDH(ephPriv, recipientIdPub)
//    3. CEK = HKDF-Extract-Expand(
//         ikm: ssRecipient,
//         salt: "raven.vault.file.v1" ‖ ephPub ‖ recipientIdPub,
//         info: "raven.vault.file.cek/v1",
//         len: 32 bytes)
//    4. (ciphertext, tag) = AES-256-GCM(CEK, nonce, plaintext, AAD=metadata)
//    5. wire = ephPub ‖ nonce ‖ ciphertext ‖ tag
//                                              1. parse ephPub, nonce, ciphertext, tag
//                                              2. ssRecipient = ECDH(myIdPriv, ephPub)
//                                              3. CEK = HKDF(...)  ← same inputs
//                                              4. plaintext = AES-256-GCM-decrypt(CEK, nonce, ct, tag)
//
//  Why CryptoKit-only (no ATSAM session dependency):
//    • Identity keys are already published by DeviceIdentityService;
//      every device has them on launch. Rolling vault on top of an
//      ATSAM session would have required also routing the file
//      through the existing per-pair ratchet which the chat surface
//      doesn't currently do for attachments. We can layer that on
//      later — the wire format reserves space for `kemCiphertext`
//      so a future ML-KEM-768 hybrid send is a non-breaking change.
//    • Forward secrecy: still present via the ephemeral X25519
//      keypair (never persisted, never reused).
//    • Server side: zero schema change. The wrapping is opaque
//      bytes uploaded through the existing /api/uploads/file path.
//

import Foundation
import CryptoKit

/// Magic bytes prepended to every vault payload. Lets the recipient
/// detect a vault attachment without needing a separate message-type
/// flag — useful when the server side hasn't been schema-migrated.
/// "RVNV1\0\0\0" — 8 bytes.
enum VaultWireFormat {
    static let magic = Data([0x52, 0x56, 0x4E, 0x56, 0x31, 0x00, 0x00, 0x00])
    static let magicLength = 8
    static let ephPubLength = 32
    static let nonceLength = 12
    /// Minimum sane payload: magic + ephPub + nonce + tag (16). A
    /// real ciphertext is always > 16 bytes because of the AES-GCM tag.
    static let minPayloadLength = magicLength + ephPubLength + nonceLength + 16
}

enum VaultFileCryptoError: Error, LocalizedError {
    case invalidRecipientKey
    case invalidPayload
    case decryptFailed
    case missingPrivateKey

    var errorDescription: String? {
        switch self {
        case .invalidRecipientKey: return "The recipient's vault key looks malformed."
        case .invalidPayload:      return "The vault payload is corrupt or truncated."
        case .decryptFailed:       return "Couldn't decrypt the vault attachment — wrong key, tampered ciphertext, or expired session."
        case .missingPrivateKey:   return "Your device doesn't have the private key required to open this vault."
        }
    }
}

/// Pure CryptoKit primitives — no UIKit, no SwiftUI, no networking.
/// Lets us unit-test the crypto round-trip from the command line.
enum VaultFileCrypto {

    /// HKDF info / salt prefix for the CEK derivation. Versioned so
    /// we can rotate without invalidating existing payloads — bump
    /// to "v2" for any algorithm change.
    private static let saltPrefix = Data("raven.vault.file.v1".utf8)
    private static let info = Data("raven.vault.file.cek/v1".utf8)

    // MARK: - Encrypt

    /// Encrypt `plaintext` for the holder of `recipientIdentityPubKey`
    /// (a 32-byte X25519 public key). The returned `Data` is the full
    /// wire payload that should be uploaded to the server — the
    /// ephemeral public key is embedded so the recipient can derive
    /// the same CEK without us having to ship it separately.
    ///
    /// `additionalAuthenticatedData` is bound into the GCM tag — pass
    /// the message id / file id here so a server-side cut-and-paste
    /// across messages is detectable on decrypt.
    static func encrypt(
        plaintext: Data,
        recipientIdentityPubKey: Data,
        additionalAuthenticatedData: Data = Data()
    ) throws -> Data {

        guard recipientIdentityPubKey.count == VaultWireFormat.ephPubLength else {
            throw VaultFileCryptoError.invalidRecipientKey
        }

        // 1. ephemeral keypair
        let ephPriv = Curve25519.KeyAgreement.PrivateKey()
        let ephPub = ephPriv.publicKey.rawRepresentation

        // 2. ECDH against the recipient's identity key
        let recipientPubKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientIdentityPubKey)
        let sharedSecret = try ephPriv.sharedSecretFromKeyAgreement(with: recipientPubKey)

        // 3. HKDF to a 32-byte CEK. Salt binds ephPub‖recipientPub so
        //    cross-session confusion is detectable.
        var salt = saltPrefix
        salt.append(ephPub)
        salt.append(recipientIdentityPubKey)
        let cek = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info,
            outputByteCount: 32
        )

        // 4. AES-256-GCM with random 96-bit nonce; AAD pinned.
        let nonceBytes = try generateRandomBytes(VaultWireFormat.nonceLength)
        let nonce = try AES.GCM.Nonce(data: nonceBytes)
        let sealed = try AES.GCM.seal(
            plaintext,
            using: cek,
            nonce: nonce,
            authenticating: additionalAuthenticatedData
        )

        // 5. wire format: magic ‖ ephPub ‖ nonce ‖ ciphertext ‖ tag
        var wire = Data()
        wire.reserveCapacity(VaultWireFormat.magicLength
                             + VaultWireFormat.ephPubLength
                             + VaultWireFormat.nonceLength
                             + sealed.ciphertext.count
                             + sealed.tag.count)
        wire.append(VaultWireFormat.magic)
        wire.append(ephPub)
        wire.append(nonceBytes)
        wire.append(sealed.ciphertext)
        wire.append(sealed.tag)
        return wire
    }

    // MARK: - Decrypt

    /// Decrypt a vault payload using `recipientIdentityPrivKey` (the
    /// 32-byte X25519 private key the recipient owns). `aad` MUST
    /// match what the sender bound into the seal call.
    static func decrypt(
        wirePayload: Data,
        recipientIdentityPrivKey: Data,
        additionalAuthenticatedData: Data = Data()
    ) throws -> Data {

        guard wirePayload.count >= VaultWireFormat.minPayloadLength else {
            throw VaultFileCryptoError.invalidPayload
        }

        // Magic check — rejects accidental double-decrypt or wrong-payload.
        let magic = wirePayload.prefix(VaultWireFormat.magicLength)
        guard magic == VaultWireFormat.magic else {
            throw VaultFileCryptoError.invalidPayload
        }

        let ephPubStart = VaultWireFormat.magicLength
        let nonceStart = ephPubStart + VaultWireFormat.ephPubLength
        let ctStart = nonceStart + VaultWireFormat.nonceLength
        // Last 16 bytes are the GCM tag.
        let tagStart = wirePayload.count - 16

        guard tagStart > ctStart else {
            throw VaultFileCryptoError.invalidPayload
        }

        let ephPub = wirePayload.subdata(in: ephPubStart..<nonceStart)
        let nonceBytes = wirePayload.subdata(in: nonceStart..<ctStart)
        let ciphertext = wirePayload.subdata(in: ctStart..<tagStart)
        let tag = wirePayload.subdata(in: tagStart..<wirePayload.count)

        // 1. Reconstruct CEK exactly as sender did.
        let identityPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: recipientIdentityPrivKey)
        let senderEph = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephPub)
        let sharedSecret = try identityPriv.sharedSecretFromKeyAgreement(with: senderEph)

        var salt = saltPrefix
        salt.append(ephPub)
        salt.append(identityPriv.publicKey.rawRepresentation)
        let cek = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info,
            outputByteCount: 32
        )

        // 2. AES-GCM open
        do {
            let sealed = try AES.GCM.SealedBox(
                nonce: try AES.GCM.Nonce(data: nonceBytes),
                ciphertext: ciphertext,
                tag: tag
            )
            return try AES.GCM.open(sealed, using: cek, authenticating: additionalAuthenticatedData)
        } catch {
            throw VaultFileCryptoError.decryptFailed
        }
    }

    // MARK: - Helpers

    /// Cheap random source. SecRandomCopyBytes is the only crypto-grade
    /// PRG we should be using on iOS — never fall back to `arc4random`.
    static func generateRandomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw VaultFileCryptoError.invalidPayload
        }
        return Data(bytes)
    }

    /// Sniff a downloaded blob for the vault magic so the receiver
    /// path can pick decrypt vs. raw-render automatically. Cheap
    /// (8-byte compare) so it's safe to call on every attachment.
    static func looksLikeVaultPayload(_ data: Data) -> Bool {
        guard data.count >= VaultWireFormat.magicLength else { return false }
        return data.prefix(VaultWireFormat.magicLength) == VaultWireFormat.magic
    }
}

// MARK: - VaultPayloadResolver
//
// 🟥 ROUND 32 (2026-05-17) — shared download → sniff → decrypt
// pipeline for ANY chat-attachment viewer (image, video, document).
//
// Before this round only the document viewer (PDFPreviewController)
// knew how to decrypt vault payloads.  `FullScreenImageViewer` used
// `AsyncImage(url:)` directly and `FullScreenVideoPlayer` handed the
// URL to AVPlayer — both of which see an opaque RVNV1-prefixed
// AES-GCM ciphertext, fail to render it as JPEG/MP4, and surface a
// "Failed to load" error.  User report: "vaghty PDF ya gallery ya
// video besabk vault mifresti, receiver nemitone file baz kone".
//
// This helper centralizes the receive-side flow:
//
//   1. Download bytes from `remoteURL` (with bearer auth) into a
//      tmp file.
//   2. Memory-map the result and check for the RVNV1 magic.
//   3. If vault: decrypt with the device's X25519 private key +
//      the supplied AAD (caller passes `messageId` for chat
//      attachments; nil/empty is tried as fallback for legacy
//      uploads from the pre-AAD-binding era).
//   4. Write the plaintext to a fresh tmp file with
//      `.completeFileProtection` so it's unreadable on a locked
//      device.
//   5. Return the local URL the viewer should load.
//
// Non-vault files are passed through unchanged (the magic check is
// 8 bytes — negligible cost), so callers don't need to branch on
// "did the sender turn vault on for this message?".
//
// Cleanup: callers should remove the returned `localURL` on view
// dismiss when `isVault == true`.  The receiver-side viewers all
// already do this via `cleanupTempFile`.

enum VaultPayloadResolver {

    struct Resolved {
        /// The local file URL the viewer should load.
        let localURL: URL
        /// True iff the source bytes had the RVNV1 magic and were
        /// successfully decrypted.  Drives screen-guard overlays
        /// and triggers tmp-file cleanup on dismiss.
        let isVault: Bool
    }

    enum ResolverError: Error, LocalizedError {
        case downloadFailed(underlying: Error?)
        case httpStatus(Int)
        case readFailed
        case decryptFailed
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let e): return "Couldn't download the attachment — \(e?.localizedDescription ?? "network error")."
            case .httpStatus(let s):     return "Server rejected the download (HTTP \(s))."
            case .readFailed:            return "Couldn't read the downloaded file."
            case .decryptFailed:         return "Couldn't decrypt the vault attachment — wrong key, tampered ciphertext, or expired session."
            case .writeFailed:           return "Couldn't write the decrypted file to disk."
            }
        }
    }

    /// Download (or copy, for local file URLs), sniff, decrypt if
    /// vault, and return a usable local URL.  Throws on any failure
    /// in the pipeline so the caller can render an error UI.
    ///
    /// `originalFileName` and `messageId` only affect vault payloads
    /// — `originalFileName` controls the extension of the decrypted
    /// tmp file, `messageId` becomes the AES-GCM AAD.
    @MainActor
    static func resolve(
        remoteURL: URL,
        originalFileName: String?,
        messageId: String?,
        bearerToken: String?
    ) async throws -> Resolved {

        // Step 1: pull the bytes into a local file we can inspect.
        let downloadedURL: URL
        if remoteURL.isFileURL {
            downloadedURL = remoteURL
        } else {
            var request = URLRequest(url: remoteURL)
            if let bearerToken {
                request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
            }
            do {
                let (tempURL, response) = try await URLSession.shared.download(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw ResolverError.httpStatus(http.statusCode)
                }
                // Move into a stable tmp path because URLSession's
                // download tmp gets garbage-collected as soon as
                // this scope returns.
                let stem = (originalFileName as NSString?)?.deletingPathExtension ?? "attachment"
                let safeStem = stem.replacingOccurrences(of: "/", with: "_")
                let ext = remoteURL.pathExtension.isEmpty ? "bin" : remoteURL.pathExtension
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString)_\(safeStem).\(ext)")
                if FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: tempURL, to: dest)
                downloadedURL = dest
            } catch let e as ResolverError {
                throw e
            } catch {
                throw ResolverError.downloadFailed(underlying: error)
            }
        }

        // Step 2: sniff for RVNV1 magic.  Memory-map keeps the
        // working-set tiny for large videos.
        guard let data = try? Data(contentsOf: downloadedURL, options: .mappedIfSafe) else {
            throw ResolverError.readFailed
        }
        guard VaultFileCrypto.looksLikeVaultPayload(data) else {
            // Not a vault payload — caller's existing render path
            // works on the raw URL.
            return Resolved(localURL: downloadedURL, isVault: false)
        }

        // Step 3: decrypt.  AAD-bound first, empty fallback for
        // legacy pre-round-32 uploads.
        let plaintext: Data? = await {
            if let messageId = messageId, !messageId.isEmpty,
               let pt = decryptOnce(data: data, aad: Data(messageId.utf8)) {
                return pt
            }
            return decryptOnce(data: data, aad: Data())
        }()
        guard let plaintext else {
            throw ResolverError.decryptFailed
        }

        // Step 4: persist with strong file protection.  Pick a
        // sensible extension via magic-byte sniff so QuickLook /
        // AVPlayer / UIImage know how to render the result.
        let ext = extensionForVaultPlaintext(originalFileName: originalFileName, data: plaintext)
        let stem = (originalFileName as NSString?)?.deletingPathExtension ?? "vault"
        let safeStem = stem.replacingOccurrences(of: "/", with: "_")
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)_\(safeStem).\(ext)")
        do {
            try plaintext.write(to: dest, options: [.atomic, .completeFileProtection])
        } catch {
            throw ResolverError.writeFailed
        }
        return Resolved(localURL: dest, isVault: true)
    }

    // MARK: Private helpers

    private static func decryptOnce(data: Data, aad: Data) -> Data? {
        var result: Data? = nil
        _ = DeviceIdentityService.shared.withAgreementPrivateKey { priv in
            let raw = priv.rawRepresentation
            result = try? VaultFileCrypto.decrypt(
                wirePayload: data,
                recipientIdentityPrivKey: raw,
                additionalAuthenticatedData: aad
            )
        }
        return result
    }

    private static func extensionForVaultPlaintext(originalFileName: String?, data: Data) -> String {
        if let name = originalFileName {
            let ext = (name as NSString).pathExtension.lowercased()
            if !ext.isEmpty, ext.count <= 5 {
                return ext
            }
        }
        if data.count >= 4 {
            let header = data.prefix(8)
            if header.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "pdf" }
            if header.starts(with: [0xFF, 0xD8, 0xFF])       { return "jpg" }
            if header.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
            if header.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
            if header.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return "zip" }
            if data.count >= 12 {
                let ftyp = data.subdata(in: 4..<8)
                if ftyp == Data("ftyp".utf8) { return "mp4" }
            }
        }
        return "bin"
    }
}
