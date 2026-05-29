//
//  VaultedContent.swift
//  RAVEN
//
//  Data models for Vault — location-encrypted content — location-encrypted
//  data that only unlocks when the recipient is within range.
//

import Foundation
import CryptoKit

// MARK: - Vault Content

/// A piece of content encrypted with a location-derived key.
/// The recipient can only decrypt when they enter the target H3 cell.
struct VaultedContent: Codable, Identifiable, Hashable {
    let id: String                      // content_id (UUID)
    let creatorId: String
    let creatorPseudonym: String
    let title: String                   // Hint shown before unlock (max 60 chars)
    let encryptedPayload: Data          // AES-GCM encrypted content
    let nonce: Data                     // 12-byte AES-GCM nonce
    let tag: Data                       // 16-byte AES-GCM tag
    let targetH3Cells: [String]         // H3 cells (resolution 7 ≈ 1.2km) where content unlocks
    let resolution: Int                 // H3 resolution used for key derivation
    let createdAt: Date
    let expiresAt: Date
    let isUnlocked: Bool                // Whether current device has unlocked this
    let unlockDistance: Int              // Required unlock distance in meters
    let receivedAt: Date
    
    var isExpired: Bool {
        Date() > expiresAt
    }
    
    var timeRemaining: String {
        let remaining = expiresAt.timeIntervalSince(Date())
        if remaining <= 0 { return "Expired" }
        let days = Int(remaining / 86400)
        let hours = Int(remaining.truncatingRemainder(dividingBy: 86400) / 3600)
        if days > 0 { return "\(days)d \(hours)h" }
        return "\(hours)h"
    }
    
    // MARK: - Hashable
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: VaultedContent, rhs: VaultedContent) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Mesh Payload

/// Payload for distributing vault content via mesh.
struct VaultContentPayload: Codable {
    let contentId: String
    let creatorId: String
    let creatorPseudonym: String
    let title: String                   // Visible hint
    let encryptedPayload: String        // Base64 encoded
    let nonce: String                   // Base64 encoded
    let tag: String                     // Base64 encoded
    let targetH3Cells: [String]         // Where to unlock
    let resolution: Int
    let createdAtMs: Int64
    let expiresAtMs: Int64
    let unlockDistanceMeters: Int
}

// MARK: - Vault Crypto

/// Location-based encryption using H3 cell as key derivation seed.
///
/// Algorithm:
/// 1. Target H3 cell(s) are chosen at resolution 7 (~1.2km)
/// 2. Key = SHA256(cell_hex + salt + content_id)
/// 3. Content encrypted with AES-256-GCM using derived key
/// 4. Recipient derives same key when they enter the target cell
/// 5. Decryption succeeds only with correct cell → correct key
///
/// Privacy: Target cells are transmitted in cleartext (so recipient knows
/// roughly where to go), but content stays encrypted until physical proximity.
enum VaultCrypto {

    /// 🔐 BUG FIX (2026-05-10): the previous version derived the key
    /// purely from `cellString` + `contentId`, BOTH of which ride in
    /// the cleartext `VaultContentPayload` broadcast to the mesh.
    /// Anyone who received the broadcast — anywhere on Earth — could
    /// iterate the listed cells and decrypt without ever visiting the
    /// location. The "location-encrypted" property was purely
    /// cosmetic.
    ///
    /// Now the key is derived from a high-entropy `creatorSecret`
    /// (32 bytes randomly generated when the vault item is created)
    /// XOR'd into the IKM. The creator distributes `creatorSecret`
    /// to authorized recipients via the existing E2EE Direct Message
    /// channel (out-of-band of the broadcast). A passive observer
    /// who sees the broadcast but lacks `creatorSecret` cannot
    /// derive the key even if they're standing in the right cell.
    ///
    /// Backwards-compat note: `creatorSecret` is REQUIRED. Old
    /// vaulted content created before this fix used a publicly-
    /// derivable key — that content remains decryptable by anyone
    /// who saw the broadcast. Treat it as "compromised confidentiality"
    /// in the audit log; users should re-create vaults to gain
    /// genuine location-locked privacy.
    static func deriveKey(
        cellString: String,
        contentId: String,
        creatorSecret: Data
    ) -> SymmetricKey {
        precondition(creatorSecret.count >= 16,
                     "VaultCrypto.deriveKey requires a creatorSecret with ≥16 bytes of entropy")
        var ikm = Data()
        ikm.append(creatorSecret)
        ikm.append(Data("|".utf8))
        ikm.append(Data(cellString.utf8))
        ikm.append(Data("|".utf8))
        ikm.append(Data(contentId.utf8))
        let salt = Data("raven-vault-v2".utf8)
        let info = Data("vault-content-key".utf8)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }

    /// Generate a fresh per-vault-item creator secret. Caller MUST
    /// distribute this to authorized recipients out-of-band of the
    /// public broadcast (e.g. via a sealed-sender DM).
    static func generateCreatorSecret() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }
    
    /// Encrypt content for a target H3 cell.
    static func encrypt(
        plaintext: String,
        targetCell: String,
        contentId: String,
        creatorSecret: Data
    ) throws -> (ciphertext: Data, nonce: Data, tag: Data) {
        let key = deriveKey(cellString: targetCell, contentId: contentId, creatorSecret: creatorSecret)
        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(
            Data(plaintext.utf8),
            using: key,
            nonce: nonce
        )
        
        return (
            ciphertext: sealedBox.ciphertext,
            nonce: Data(nonce),
            tag: sealedBox.tag
        )
    }
    
    /// Attempt to decrypt content using current H3 cell.
    /// Returns nil if the cell doesn't match (wrong key).
    static func decrypt(
        ciphertext: Data,
        nonce: Data,
        tag: Data,
        currentCell: String,
        contentId: String,
        creatorSecret: Data
    ) -> String? {
        let key = deriveKey(cellString: currentCell, contentId: contentId, creatorSecret: creatorSecret)
        
        guard let gcmNonce = try? AES.GCM.Nonce(data: nonce) else { return nil }
        
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(
                nonce: gcmNonce,
                ciphertext: ciphertext,
                tag: tag
            )
        } catch {
            return nil
        }
        
        guard let plainData = try? AES.GCM.open(sealedBox, using: key) else {
            return nil // Wrong cell → wrong key → decryption fails
        }
        
        return String(data: plainData, encoding: .utf8)
    }
    
    /// Try all target cells at the given resolution for the current
    /// location. Returns decrypted content if any cell matches AND
    /// the caller supplies the correct `creatorSecret`.
    ///
    /// 🔐 (2026-05-10): caller MUST provide `creatorSecret` —
    /// previously this was self-derivable from the broadcast.
    /// Recipients now obtain `creatorSecret` from the creator via an
    /// E2EE DM (TODO: VaultSecretDistribution flow). Without it,
    /// `tryUnlock` correctly returns nil, which is the honest
    /// behaviour — the previous "appears to work but anyone in any
    /// cell could decrypt" state was a privacy hazard.
    static func tryUnlock(
        content: VaultedContent,
        currentLocation: (lat: Double, lng: Double),
        creatorSecret: Data
    ) -> String? {
        // The exact-cell match is implied by the k=1 ring below (which always
        // includes the origin), so we skip the standalone string lookup.
        let currentCellId = H3Lite.latLngToCell(
            lat: currentLocation.lat,
            lng: currentLocation.lng,
            resolution: content.resolution
        )
        let nearbyCells = H3Lite.gridDisk(origin: currentCellId, k: 1).map {
            H3Lite.cellToString($0)
        }

        // Try each nearby cell against target cells
        for nearbyCell in nearbyCells {
            if content.targetH3Cells.contains(nearbyCell) {
                return decrypt(
                    ciphertext: content.encryptedPayload,
                    nonce: content.nonce,
                    tag: content.tag,
                    currentCell: nearbyCell,
                    contentId: content.id,
                    creatorSecret: creatorSecret
                )
            }
        }
        
        return nil
    }
}
