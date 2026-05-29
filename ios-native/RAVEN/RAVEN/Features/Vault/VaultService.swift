//
//  VaultService.swift
//  RAVEN
//
//  Core service for Vault — creation, mesh broadcast, unlock —
//  handles creation, mesh broadcast, unlock attempts.
//

import Foundation
import CryptoKit

// MARK: - Vault Service

@MainActor
final class VaultService: ObservableObject {
    static let shared = VaultService()
    
    @Published private(set) var nearbyContent: [VaultedContent] = []
    @Published private(set) var unlockedContent: [String: String] = [:] // contentId → plaintext

    /// 🔐 Map of vault contentId → 32-byte creatorSecret. Populated
    /// (a) for self-created vaults at create time and
    /// (b) for received vaults when a sealed-sender DM delivers the
    /// secret from the creator.
    /// Local-only — never leaves the device. PERSISTED to UserDefaults
    /// per-account so the creator can still decrypt their own vault
    /// content after relaunch (RE-AUDIT FIX 2026-05-10: previously
    /// in-memory only, which made self-created vaults permanently
    /// undecryptable across launches — silently lost data).
    private var vaultCreatorSecrets: [String: Data] = [:] {
        didSet { persistVaultCreatorSecrets() }
    }

    private static let vaultSecretsDefaultsKey = "raven.vault.creator_secrets.v1"

    private init() {
        // Restore persisted creator secrets at init so self-created
        // vaults survive relaunch.
        if let blob = UserDefaults.standard.data(forKey: Self.vaultSecretsDefaultsKey),
           let map = try? JSONDecoder().decode([String: Data].self, from: blob) {
            self.vaultCreatorSecrets = map
        }
    }

    private func persistVaultCreatorSecrets() {
        guard let data = try? JSONEncoder().encode(vaultCreatorSecrets) else { return }
        UserDefaults.standard.set(data, forKey: Self.vaultSecretsDefaultsKey)
    }
    
    // MARK: - Registration
    
    func registerMeshHandlers() {
        guard FeatureFlag.isVaultEnabled else { return }
        
        BLEMeshEngine.shared.register(for: .vaultContent) { [weak self] data, deviceId in
            await self?.handleIncoming(data: data, from: deviceId)
        }
        
        #if DEBUG
        print("🔒 [Vault] Mesh handlers registered")
        #endif
    }
    
    // MARK: - Create Proximity Content
    
    func createContent(
        plaintext: String,
        title: String,
        targetLat: Double,
        targetLng: Double,
        resolution: Int = 7,         // ~1.2km
        ttlHours: Int = 24,
        unlockDistanceMeters: Int = 1200
    ) async -> VaultedContent? {
        guard FeatureFlag.isVaultEnabled else { return nil }
        guard !plaintext.isEmpty, !title.isEmpty else { return nil }
        
        let contentId = UUID().uuidString
        let userId = await KeychainService.shared.getUserId() ?? ""
        let pseudonym = Echo.generatePseudonym(for: userId)
        
        // Get target H3 cell(s)
        let targetCell = H3Lite.latLngToCell(lat: targetLat, lng: targetLng, resolution: resolution)
        let targetCellStr = H3Lite.cellToString(targetCell)
        
        // Also include k=1 neighbors for slightly larger unlock radius
        let targetCells = H3Lite.gridDisk(origin: targetCell, k: 1).map {
            H3Lite.cellToString($0)
        }
        
        // 🔐 Generate a fresh per-vault creator secret (32 bytes).
        // This must be distributed to authorised recipients via E2EE
        // DM out-of-band of the public broadcast — see VaultCrypto.
        let creatorSecret = VaultCrypto.generateCreatorSecret()
        vaultCreatorSecrets[contentId] = creatorSecret

        // Encrypt using the center cell + creator secret
        guard let encrypted = try? VaultCrypto.encrypt(
            plaintext: plaintext,
            targetCell: targetCellStr,
            contentId: contentId,
            creatorSecret: creatorSecret
        ) else {
            return nil
        }
        
        let now = Date()
        let content = VaultedContent(
            id: contentId,
            creatorId: userId,
            creatorPseudonym: pseudonym,
            title: String(title.prefix(60)),
            encryptedPayload: encrypted.ciphertext,
            nonce: encrypted.nonce,
            tag: encrypted.tag,
            targetH3Cells: targetCells,
            resolution: resolution,
            createdAt: now,
            expiresAt: now.addingTimeInterval(TimeInterval(ttlHours * 3600)),
            isUnlocked: false,
            unlockDistance: unlockDistanceMeters,
            receivedAt: now
        )
        
        // Persist
        try? await VaultRepository.shared.insertContent(content)
        nearbyContent.insert(content, at: 0)
        
        // Broadcast via mesh
        let payload = VaultContentPayload(
            contentId: content.id,
            creatorId: content.creatorId,
            creatorPseudonym: content.creatorPseudonym,
            title: content.title,
            encryptedPayload: encrypted.ciphertext.base64EncodedString(),
            nonce: encrypted.nonce.base64EncodedString(),
            tag: encrypted.tag.base64EncodedString(),
            targetH3Cells: targetCells,
            resolution: resolution,
            createdAtMs: Int64(now.timeIntervalSince1970 * 1000),
            expiresAtMs: Int64(content.expiresAt.timeIntervalSince1970 * 1000),
            unlockDistanceMeters: unlockDistanceMeters
        )
        
        let frame = MeshMessageFrame(
            kind: .vaultContent,
            payload: payload,
            senderId: userId,
            hopLimit: 10,
            sprayCounter: 100,
            ttlSeconds: ttlHours * 3600
        )
        
        // FIX: Broadcast the actual signed frame data directly.
        // Previously, the frame data was computed but discarded — an empty
        // MeshEnvelope (text: nil) was broadcast instead, so receivers
        // never received the Vault payload.
        if let data = frame.toData() {
            await BLEMeshEngine.shared.broadcastPostData(data)
        }
        
        #if DEBUG
        print("🔒 [Vault] Created: \(title) at \(targetCellStr.prefix(8))")
        #endif
        
        return content
    }
    
    // MARK: - Try Unlock
    
    func tryUnlock(contentId: String) async -> String? {
        guard let content = nearbyContent.first(where: { $0.id == contentId }) else { return nil }
        guard !content.isExpired else { return nil }
        
        guard let location = LocationPrivacyService.shared.currentLocation else { return nil }
        
        // 🔐 Look up the per-vault `creatorSecret` the recipient
        // received via E2EE DM. If we don't have one, decryption MUST
        // fail — see VaultedContent.tryUnlock comment.
        // TODO(vault-secret-distribution): wire the DM channel that
        // delivers `creatorSecret` from creator to recipient and
        // persists it to a local-only `vault_creator_secrets` table.
        // Until that ships, recipients see "🔒 Locked — secret not
        // received yet" instead of decrypted content.
        guard let creatorSecret = vaultCreatorSecrets[contentId] else {
            #if DEBUG
            print("🔒 [Vault] No creatorSecret for \(contentId.prefix(8)) — recipient must receive it via DM")
            #endif
            return nil
        }
        let plaintext = VaultCrypto.tryUnlock(
            content: content,
            currentLocation: (lat: location.latitude, lng: location.longitude),
            creatorSecret: creatorSecret
        )
        
        if let plaintext = plaintext {
            unlockedContent[contentId] = plaintext
            try? await VaultRepository.shared.markUnlocked(contentId: contentId)
            
            // Update local array
            if let idx = nearbyContent.firstIndex(where: { $0.id == contentId }) {
                let updated = nearbyContent[idx]
                // Can't mutate directly since it's a struct, recreate
                nearbyContent[idx] = VaultedContent(
                    id: updated.id,
                    creatorId: updated.creatorId,
                    creatorPseudonym: updated.creatorPseudonym,
                    title: updated.title,
                    encryptedPayload: updated.encryptedPayload,
                    nonce: updated.nonce,
                    tag: updated.tag,
                    targetH3Cells: updated.targetH3Cells,
                    resolution: updated.resolution,
                    createdAt: updated.createdAt,
                    expiresAt: updated.expiresAt,
                    isUnlocked: true,
                    unlockDistance: updated.unlockDistance,
                    receivedAt: updated.receivedAt
                )
            }
            
            #if DEBUG
            print("🔒 [Vault] Unlocked: \(content.title)")
            #endif
        }
        
        return plaintext
    }
    
    // MARK: - Load
    
    func loadNearbyContent() async {
        // Cleanup expired content on each load
        try? await VaultRepository.shared.cleanupExpired()
        nearbyContent = (try? await VaultRepository.shared.getActiveContent()) ?? []
    }
    
    // MARK: - Incoming Handler
    
    private func handleIncoming(data: Data, from deviceId: String) async {
        guard FeatureFlag.isVaultEnabled else { return }
        
        // 🔐 Verify Ed25519 signature
        let sig = MeshSignatureVerifier.extractSignatureFields(from: data)
        guard MeshSignatureVerifier.verify(data: data, signature: sig.signature, signerPublicKey: sig.signerPublicKey) else { return }
        
        guard let frame = try? JSONDecoder().decode(
            MeshMessageFrame<VaultContentPayload>.self,
            from: data
        ) else { return }
        
        let payload = frame.payload
        
        // Dedup
        let exists = try? await VaultRepository.shared.exists(contentId: payload.contentId)
        guard exists != true else { return }
        
        // Validate
        let expiresAt = Date(timeIntervalSince1970: TimeInterval(payload.expiresAtMs) / 1000.0)
        guard expiresAt > Date() else { return }
        
        guard let ciphertext = Data(base64Encoded: payload.encryptedPayload),
              let nonce = Data(base64Encoded: payload.nonce),
              let tag = Data(base64Encoded: payload.tag) else { return }
        
        let content = VaultedContent(
            id: payload.contentId,
            creatorId: payload.creatorId,
            creatorPseudonym: payload.creatorPseudonym,
            title: payload.title,
            encryptedPayload: ciphertext,
            nonce: nonce,
            tag: tag,
            targetH3Cells: payload.targetH3Cells,
            resolution: payload.resolution,
            createdAt: Date(timeIntervalSince1970: TimeInterval(payload.createdAtMs) / 1000.0),
            expiresAt: expiresAt,
            isUnlocked: false,
            unlockDistance: payload.unlockDistanceMeters,
            receivedAt: Date()
        )
        
        try? await VaultRepository.shared.insertContent(content)
        
        await MainActor.run {
            nearbyContent.insert(content, at: 0)
        }
    }
}

// MARK: - LocationPrivacyService Extension

extension LocationPrivacyService {
    /// Get current CLLocation coordinate (for proximity unlock).
    /// Returns nil if location is not available.
    ///
    /// FIX: Uses the actual GPS coordinate from CLLocationManager instead of
    /// round-tripping through H3 cell-center. The old approach computed an H3
    /// cell at resolution 7, then converted back to lat/lng (cell center),
    /// losing precision and introducing ~600m positioning error for unlock checks.
    var currentLocation: (latitude: Double, longitude: Double)? {
        guard let loc = currentCLLocation else { return nil }
        return (latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
    }
}
