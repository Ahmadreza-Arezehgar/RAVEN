// MeshCryptoService — AES-256-GCM end-to-end encryption + Ed25519
// signing for the BLE mesh.
//
// Wire format matches `ios-native/RAVEN/RAVEN/Core/Security/MeshCryptoService.swift`
// for interop, but we strip out the trusted-device registry and the
// rotation-grace path that the iOS build uses — neither is wired up
// on the Mac App Store edition yet. A signature is accepted iff it
// validates against the `signerPublicKey` carried in the payload.
// Identity binding (signerPublicKey ↔ user account) lives one layer up
// in the chat store, where we already trust the FastAPI account graph.

import Foundation
import CryptoKit

actor MeshCryptoService {
    static let shared = MeshCryptoService()

    private static let nonceSize = 12
    private var usedNonces: Set<Data> = []
    private var nonceCleanupAt: Date = Date()
    private static let nonceLifetime: TimeInterval = 7 * 24 * 60 * 60

    private init() {}

    // MARK: - Encrypt / decrypt

    func encryptEnvelope(_ envelope: MeshEnvelope, sharedKey: SymmetricKey) throws -> EncryptedMeshPayload {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let plaintext = try encoder.encode(envelope)

        var nonceBytes = [UInt8](repeating: 0, count: Self.nonceSize)
        guard SecRandomCopyBytes(kSecRandomDefault, Self.nonceSize, &nonceBytes) == errSecSuccess else {
            throw MeshError.encryptionFailed
        }
        let nonce = try AES.GCM.Nonce(data: Data(nonceBytes))
        let sealedBox = try AES.GCM.seal(plaintext, using: sharedKey, nonce: nonce)
        guard let ciphertext = sealedBox.combined else {
            throw MeshError.encryptionFailed
        }

        let signingData = envelope.signingData()
        guard let signature = DeviceIdentityService.shared.sign(signingData) else {
            throw MeshError.identityUnavailable
        }

        return EncryptedMeshPayload(
            ciphertext: ciphertext.base64EncodedString(),
            nonce: Data(nonceBytes).base64EncodedString(),
            senderPublicKey: DeviceIdentityService.shared.agreementPublicKeyBase64 ?? "",
            version: 1,
            signature: signature.base64EncodedString(),
            signerPublicKey: DeviceIdentityService.shared.publicKeyBase64
        )
    }

    func decryptEnvelope(_ payload: EncryptedMeshPayload, sharedKey: SymmetricKey) throws -> MeshEnvelope {
        guard let ciphertext = Data(base64Encoded: payload.ciphertext) else {
            throw MeshError.decryptionFailed
        }
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        let plaintext = try AES.GCM.open(sealedBox, using: sharedKey)

        let authenticNonce = sealedBox.nonce.withUnsafeBytes { Data($0) }
        if usedNonces.contains(authenticNonce) {
            throw MeshError.duplicateMessage
        }
        usedNonces.insert(authenticNonce)
        cleanupNoncesIfNeeded()

        let decoder = JSONDecoder()
        return try decoder.decode(MeshEnvelope.self, from: plaintext)
    }

    /// Verify the signature attached to an `EncryptedMeshPayload` against
    /// the envelope it just decrypted.
    func verifySignature(envelope: MeshEnvelope, payload: EncryptedMeshPayload) -> Bool {
        guard let sigStr = payload.signature,
              let signerStr = payload.signerPublicKey,
              let signature = Data(base64Encoded: sigStr),
              let publicKey = Data(base64Encoded: signerStr)
        else { return false }
        return DeviceIdentityService.shared.verify(
            signature: signature,
            data: envelope.signingData(),
            publicKey: publicKey
        )
    }

    // MARK: - Internal

    private func cleanupNoncesIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(nonceCleanupAt) > 3600 else { return }
        nonceCleanupAt = now
        // The nonce set is bounded by message volume × 7 days. If it
        // grows past 100k entries we drop everything — the worst case
        // is a one-week regression of the dedup window for envelopes
        // that arrive after the wipe.
        if usedNonces.count > 100_000 {
            usedNonces.removeAll(keepingCapacity: false)
        }
    }
}

// MARK: - Wire types

/// Encrypted payload sent over BLE. Identical CodingKeys to the iOS
/// `EncryptedMeshPayload` struct so interop on the wire works.
struct EncryptedMeshPayload: Codable {
    let ciphertext: String        // base64
    let nonce: String             // base64 — purely informational; the
                                  // authentic nonce is read out of the
                                  // sealed box on the decrypt side.
    let senderPublicKey: String   // X25519 agreement public key, base64
    let version: Int
    let signature: String?        // Ed25519 signature, base64
    let signerPublicKey: String?  // Ed25519 public key, base64

    enum CodingKeys: String, CodingKey {
        // EXACT keys from iOS so the wire format interops 1:1.
        case ciphertext = "c"
        case nonce = "n"
        case senderPublicKey = "spk"
        case version = "v"
        case signature = "s"
        case signerPublicKey = "ssk"
    }
}
