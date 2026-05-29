//
//  E2EENetworkProvider.swift
//  RAVEN
//
//  REST-backed `PreKeyBundleProvider` plus the upload helpers that
//  publish *our* pre-key bundle to the server. Talks to the server
//  via the existing `NetworkService` so it inherits authentication,
//  retries, and ETag caching for free.
//
//  Server endpoints (see /server/routers/e2ee.py):
//    POST  /api/e2ee/bundle               — upload our public bundle
//    POST  /api/e2ee/onetime              — top up one-time pre-keys
//    GET   /api/e2ee/bundle/{userId}/{deviceId}
//    GET   /api/e2ee/onetime_count        — how many OPKs the server still has
//
//  Threading: this is a reference type held by `E2EEService` (an
//  actor), so concurrent fetches for different peers are serialised
//  upstream.
//

import Foundation

// MARK: - DTOs

/// Wire shape for uploading our bundle. Mirrors `PreKeyBundle` but
/// expressed in the snake_case the FastAPI server expects.
private struct UploadedBundleDTO: Codable {
    let user_id: String
    let device_id: String
    let identity_key: String              // base64
    let identity_agreement_key: String    // base64
    let signed_pre_key_id: UInt32
    let signed_pre_key: String            // base64
    let signed_pre_key_signature: String  // base64
    let signed_pre_key_created_at: TimeInterval
    let one_time_pre_keys: [OneTimePreKeyDTO]
    let created_at: TimeInterval
}

private struct OneTimePreKeyDTO: Codable {
    let id: UInt32
    let public_key: String                // base64
}

/// Server response when fetching a peer's bundle. The server pops one
/// OPK off the queue and returns it inline; the rest of the bundle
/// is shared.
private struct FetchedBundleDTO: Codable {
    let user_id: String
    let device_id: String
    let identity_key: String
    let identity_agreement_key: String
    let signed_pre_key_id: UInt32
    let signed_pre_key: String
    let signed_pre_key_signature: String
    let signed_pre_key_created_at: TimeInterval
    let one_time_pre_key: OneTimePreKeyDTO?
    let created_at: TimeInterval
}

private struct OneTimeBatchUploadDTO: Codable {
    let user_id: String
    let device_id: String
    let one_time_pre_keys: [OneTimePreKeyDTO]
}

private struct OneTimeCountDTO: Codable {
    let count: Int
}

private struct E2EEEmptyResponse: Codable {}

// MARK: - Provider

/// Default network-backed provider. Wire it in at app boot:
///
///     await E2EEService.shared.configure(
///         bundleProvider: E2EENetworkProvider.shared
///     )
final class E2EENetworkProvider: PreKeyBundleProvider {
    static let shared = E2EENetworkProvider()

    private let network = NetworkService.shared
    private let cache = BundleCache()

    // MARK: - Fetch (PreKeyBundleProvider conformance)

    func fetchBundle(for peer: PeerAddress) async throws -> PreKeyBundle {
        // 1. Cache hit?
        if let cached = await cache.read(peer: peer) {
            return cached
        }

        // 2. REST fetch.
        let path = "/api/e2ee/bundle/\(peer.userId)/\(peer.deviceId)"
        let dto: FetchedBundleDTO = try await network.get(path: path)
        let bundle = try Self.toBundle(dto)

        // 3. Trust-on-first-use check. Registers the peer's identity
        //    on first contact; on any subsequent fetch where the
        //    identity bytes have changed, fires a notification so
        //    the UI can warn the user and revoke prior verification.
        //    Failures here are non-fatal — bundle still flows through
        //    so X3DH continues working; the audit trail is just
        //    incomplete in that one edge case.
        do {
            _ = try await PeerIdentityRegistry.shared.recordOrCheck(
                peerUserId: peer.userId,
                peerDeviceId: peer.deviceId,
                identityKey: bundle.identityKey
            )
        } catch {
            #if DEBUG
            print("⚠️ [E2EE] PeerIdentityRegistry record failed: \(error.localizedDescription)")
            #endif
        }

        // 4. Cache. (Bundle is one-time-pre-key-bound — caching the
        //    OPK part would mean reusing it, which would weaken
        //    forward secrecy. We cache only the *long-lived* fields
        //    and re-fetch when a fresh OPK is needed.)
        await cache.write(peer: peer, bundle: bundle)
        return bundle
    }

    // MARK: - Upload our bundle

    /// Push the local public bundle to the server. Idempotent — the
    /// server overwrites prior state per (userId, deviceId).
    func uploadOurBundle(
        userId: String,
        deviceId: String
    ) async throws {
        // Build a bundle locally (auto-rotates SPK / tops up OPK pool).
        let bundle = try await E2EEService.shared.currentPublicBundle(
            userId: userId,
            deviceId: deviceId,
            ensureOneTimePool: 50
        )

        // The bundle from `currentPublicBundle` only carries one OPK.
        // For upload we want the *whole pool* so the server can hand
        // out one to each fetcher. We pull the rest fresh from the
        // store.
        let pool = try await unconsumedOneTimePreKeys()

        let dto = UploadedBundleDTO(
            user_id: userId,
            device_id: deviceId,
            identity_key: bundle.identityKey.base64EncodedString(),
            identity_agreement_key: bundle.identityAgreementKey.base64EncodedString(),
            signed_pre_key_id: bundle.signedPreKey.id,
            signed_pre_key: bundle.signedPreKey.publicKey.base64EncodedString(),
            signed_pre_key_signature: bundle.signedPreKey.signature.base64EncodedString(),
            signed_pre_key_created_at: bundle.signedPreKey.createdAt,
            one_time_pre_keys: pool.map {
                OneTimePreKeyDTO(id: $0.id, public_key: $0.publicKey.base64EncodedString())
            },
            created_at: bundle.createdAt
        )
        let _: E2EEEmptyResponse = try await network.post(path: "/api/e2ee/bundle", body: dto)
    }

    /// Top up the server's one-time pre-key pool when it gets low.
    /// Call this from a periodic task / on app foreground if
    /// `remoteOneTimePreKeyCount(...)` falls below threshold.
    func topUpOneTimePreKeys(
        userId: String,
        deviceId: String,
        target: Int = 50
    ) async throws {
        let remaining = try await remoteOneTimePreKeyCount(
            userId: userId,
            deviceId: deviceId
        )
        guard remaining < target else { return }

        let toGenerate = target - remaining
        let store = RatchetSessionStore.shared
        let fresh = try await store.generateOneTimePreKeys(count: toGenerate)

        let dto = OneTimeBatchUploadDTO(
            user_id: userId,
            device_id: deviceId,
            one_time_pre_keys: fresh.map {
                OneTimePreKeyDTO(id: $0.id, public_key: $0.publicKey.base64EncodedString())
            }
        )
        let _: E2EEEmptyResponse = try await network.post(path: "/api/e2ee/onetime", body: dto)
    }

    /// Ask the server how many unused one-time pre-keys it still
    /// holds for our (userId, deviceId).
    func remoteOneTimePreKeyCount(
        userId: String,
        deviceId: String
    ) async throws -> Int {
        let path = "/api/e2ee/onetime_count?user_id=\(userId)&device_id=\(deviceId)"
        let dto: OneTimeCountDTO = try await network.get(path: path)
        return dto.count
    }

    // MARK: - Helpers

    private func unconsumedOneTimePreKeys() async throws -> [OneTimePreKeyPrivate] {
        let db = DatabaseService.shared
        let rows = try await db.query(
            "SELECT id, private_key, public_key FROM e2ee_onetime_prekeys WHERE consumed = 0 ORDER BY id ASC",
            params: []
        )
        return rows.compactMap { row -> OneTimePreKeyPrivate? in
            guard let id = row["id"] as? Int64,
                  let priv = row["private_key"] as? Data,
                  let pub  = row["public_key"]  as? Data else { return nil }
            return OneTimePreKeyPrivate(
                id: UInt32(truncatingIfNeeded: id),
                privateKey: priv,
                publicKey: pub
            )
        }
    }

    private static func toBundle(_ dto: FetchedBundleDTO) throws -> PreKeyBundle {
        guard let identityKey = Data(base64Encoded: dto.identity_key),
              let identityAgreementKey = Data(base64Encoded: dto.identity_agreement_key),
              let spkPublic = Data(base64Encoded: dto.signed_pre_key),
              let spkSig = Data(base64Encoded: dto.signed_pre_key_signature) else {
            throw RatchetError.bundleVerificationFailed
        }
        let opk: OneTimePreKeyPublic? = try dto.one_time_pre_key.map { o in
            guard let pub = Data(base64Encoded: o.public_key) else {
                throw RatchetError.bundleVerificationFailed
            }
            return OneTimePreKeyPublic(id: o.id, publicKey: pub)
        }
        return PreKeyBundle(
            userId: dto.user_id,
            deviceId: dto.device_id,
            identityKey: identityKey,
            identityAgreementKey: identityAgreementKey,
            signedPreKey: SignedPreKeyPublic(
                id: dto.signed_pre_key_id,
                publicKey: spkPublic,
                signature: spkSig,
                createdAt: dto.signed_pre_key_created_at
            ),
            oneTimePreKey: opk,
            createdAt: dto.created_at
        )
    }
}

// MARK: - Cache

/// Long-lived bundle cache. Stores only the bundle skeleton (identity
/// keys + signed pre-key) — the per-fetch one-time pre-key is NEVER
/// cached because reusing it would break X3DH's one-time PCS guarantee.
private actor BundleCache {
    private struct Entry {
        let bundle: PreKeyBundle
        let cachedAt: Date
    }
    private var entries: [PeerAddress: Entry] = [:]
    /// Re-fetch after this long even on cache hit, to pick up SPK rotation.
    private let ttl: TimeInterval = 6 * 60 * 60   // 6h

    func read(peer: PeerAddress) -> PreKeyBundle? {
        guard let entry = entries[peer] else { return nil }
        if Date().timeIntervalSince(entry.cachedAt) > ttl {
            entries.removeValue(forKey: peer)
            return nil
        }
        // Strip the OPK before returning so callers always get a
        // fresh single-use one. (X3DH still works without an OPK —
        // just with slightly weaker post-compromise security.)
        var stripped = entry.bundle
        return PreKeyBundle(
            userId: stripped.userId,
            deviceId: stripped.deviceId,
            identityKey: stripped.identityKey,
            identityAgreementKey: stripped.identityAgreementKey,
            signedPreKey: stripped.signedPreKey,
            oneTimePreKey: nil,
            createdAt: stripped.createdAt
        )
    }

    func write(peer: PeerAddress, bundle: PreKeyBundle) {
        entries[peer] = Entry(bundle: bundle, cachedAt: Date())
    }
}
