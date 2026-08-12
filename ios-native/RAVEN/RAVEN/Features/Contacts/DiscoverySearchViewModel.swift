//
//  DiscoverySearchViewModel.swift
//  RAVEN — FindContacts / discovery UI behind ravenEnvelopeV1.
//
//  Scopes: All / My Network / Public (exact alias) / Nearby.
//  Never silent pick on alias conflicts; never FastAPI when serverless ON.
//

import Foundation
import CryptoKit
import Observation
import Security

/// UI scopes for Discovery V1 search (docs/RAVEN_DISCOVERY_V1.md).
enum DiscoveryUIScope: String, CaseIterable, Identifiable {
    case all = "All"
    case myNetwork = "My Network"
    case publicExact = "Public"
    case nearby = "Nearby"

    var id: String { rawValue }

    var discoveryScope: DiscoveryScope {
        switch self {
        case .all: return .all
        case .myNetwork: return .myNetwork
        case .publicExact: return .publicScope // exact ID + exact alias; PublicProfileIndex OFF
        case .nearby: return .nearby
        }
    }

    var hint: String {
        switch self {
        case .all: return "Local + exact @alias / rvn1… + nearby"
        case .myNetwork: return "Petnames and trusted contacts only"
        case .publicExact: return "Exact @alias or rvn1… — no fuzzy public index"
        case .nearby: return "BLE-confirmed nearby (ephemeral until confirm)"
        }
    }
}

/// On-device alias claim bag (DHT stand-in until Kad is live).
enum DiscoveryAliasClaimStore {
    private static let key = "raven.discovery.alias_claims.v1"

    static func load() -> [SignedAliasClaim] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let rows = try? JSONDecoder().decode([Row].self, from: data) else {
            return []
        }
        return rows.map {
            SignedAliasClaim(
                alias: $0.alias,
                identityAddress: $0.identityAddress,
                sequence: $0.sequence,
                expiresAt: $0.expiresAt,
                ed25519PubHex: $0.ed25519PubHex
            )
        }
    }

    static func save(_ claims: [SignedAliasClaim]) {
        let rows = claims.map {
            Row(
                alias: $0.alias,
                identityAddress: $0.identityAddress,
                sequence: $0.sequence,
                expiresAt: $0.expiresAt,
                ed25519PubHex: $0.ed25519PubHex
            )
        }
        if let data = try? JSONEncoder().encode(rows) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func upsert(_ claim: SignedAliasClaim) {
        var all = load()
        all.removeAll {
            DiscoveryResolver.normalizeAlias($0.alias) == DiscoveryResolver.normalizeAlias(claim.alias)
                && $0.identityAddress == claim.identityAddress
        }
        all.append(claim)
        save(all)
    }

    private struct Row: Codable {
        var alias: String
        var identityAddress: String
        var sequence: UInt64
        var expiresAt: UInt64
        var ed25519PubHex: String
    }
}

enum DiscoveryNearbyStore {
    private static let key = "raven.discovery.nearby_confirmed.v1"

    static func load() -> [NearbyConfirmBinding] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let rows = try? JSONDecoder().decode([Row].self, from: data) else {
            return []
        }
        return rows.map {
            NearbyConfirmBinding(
                ephemeralTokenHex: $0.ephemeralTokenHex,
                peerRavenId: $0.peerRavenId,
                peerPubHex: $0.peerPubHex,
                confirmedAtMs: $0.confirmedAtMs
            )
        }
    }

    static func save(_ bindings: [NearbyConfirmBinding]) {
        let rows = bindings.map {
            Row(
                ephemeralTokenHex: $0.ephemeralTokenHex,
                peerRavenId: $0.peerRavenId,
                peerPubHex: $0.peerPubHex,
                confirmedAtMs: $0.confirmedAtMs
            )
        }
        if let data = try? JSONEncoder().encode(rows) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func confirm(_ binding: NearbyConfirmBinding) {
        var all = load()
        all.removeAll { $0.ephemeralTokenHex == binding.ephemeralTokenHex }
        all.append(binding)
        save(all)
    }

    private struct Row: Codable {
        var ephemeralTokenHex: String
        var peerRavenId: String
        var peerPubHex: String
        var confirmedAtMs: UInt64
    }
}

@MainActor
@Observable
final class DiscoverySearchViewModel {
    var query: String = ""
    var scope: DiscoveryUIScope = .all
    var results: [DiscoveryResult] = []
    /// Explicit user pick — required when conflicts / multi-hit alias. Never silent.
    var selectedRavenId: String?
    var statusMessage: String?
    var isLoading: Bool = false
    var lastRequestIdHex: String?
    var requestNote: String = ""
    /// Live BLE peers (ephemeral — not yet confirmed to Raven ID).
    var liveNearbyPeers: [(deviceId: String, displayName: String, userId: String?)] = []

    /// Injected resolver for tests; production builds a fresh one per search.
    var resolverFactory: () -> DiscoveryResolver = { DiscoveryResolver() }

    /// Pubhex lookup for sealing contact requests (ravenId → 32-byte hex).
    private(set) var pubHexByRavenId: [String: String] = [:]
    private(set) var contactsCache: [LocalDiscoveryContact] = []

    var requiresExplicitPick: Bool {
        let conflicts = results.filter { $0.verificationState == .aliasConflict }
        if conflicts.count > 1 { return true }
        if results.contains(where: { $0.conflictCount > 1 }) && results.count > 1 { return true }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.hasPrefix("@"), results.count > 1 { return true }
        return false
    }

    var canSendRequest: Bool {
        guard FeatureFlag.isRavenEnvelopeV1Enabled else { return false }
        guard let chosen = chosenResult, chosen.verificationState != .blocked else { return false }
        if requiresExplicitPick {
            return selectedRavenId != nil
        }
        return results.count == 1 || selectedRavenId != nil
    }

    var chosenResult: DiscoveryResult? {
        if let id = selectedRavenId {
            return results.first { $0.ravenId == id }
        }
        if results.count == 1 { return results.first }
        return nil
    }

    func selectCandidate(_ result: DiscoveryResult) {
        selectedRavenId = result.ravenId
        statusMessage = "Selected \(result.primaryLabel) — \(shortId(result.ravenId))"
    }

    func clearSelection() {
        selectedRavenId = nil
    }

    /// Reload local contacts / alias claims / nearby; then search.
    func refreshAndSearch() async {
        isLoading = true
        defer { isLoading = false }
        await loadSources()
        runSearch()
    }

    func runSearch() {
        guard FeatureFlag.isRavenEnvelopeV1Enabled else {
            results = []
            statusMessage = "Enable RavenEnvelopeV1 for serverless discovery"
            return
        }
        let resolver = makeResolver()
        let hits = resolver.search(query: query, scope: scope.discoveryScope)
        // Guard: never surface legacy server provenance when serverless.
        results = hits.filter { !$0.sourceSet.contains(.legacyServer) }
        if requiresExplicitPick {
            selectedRavenId = nil
            statusMessage = "Alias conflict — pick one candidate (never silent)"
        } else if results.isEmpty {
            selectedRavenId = nil
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                statusMessage = scope == .nearby
                    ? (liveNearbyPeers.isEmpty
                        ? "No confirmed nearby peers — scan BLE or confirm a session"
                        : "\(liveNearbyPeers.count) BLE peer(s) nearby — confirm before binding")
                    : scope.hint
            } else {
                statusMessage = "No results for this scope"
            }
        } else {
            if results.count == 1 {
                selectedRavenId = results[0].ravenId
            }
            statusMessage = "\(results.count) candidate(s)"
        }
    }

    /// Build + seal RavenContactRequestV1 and deliver via LAN/BLE when available.
    /// Never FastAPI.
    func sendContactRequest() async throws {
        guard FeatureFlag.isRavenEnvelopeV1Enabled else {
            throw RavenContactRequestError.missingKeys
        }
        guard let chosen = chosenResult else {
            throw RavenContactRequestError.noCandidate
        }
        if requiresExplicitPick, selectedRavenId == nil {
            throw RavenContactRequestError.ambiguousPick
        }
        if chosen.verificationState == .blocked {
            throw RavenContactRequestError.blocked
        }
        guard let pubHex = pubHexByRavenId[chosen.ravenId] ?? lookupPubHex(for: chosen),
              let recipientPub = Data(ravenHex: pubHex),
              recipientPub.count == 32 else {
            throw RavenContactRequestError.missingKeys
        }
        guard let seed = DeviceIdentityService.shared.deviceSigningSeed,
              let signingKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
            throw RavenContactRequestError.missingKeys
        }
        let senderPub = signingKey.publicKey.rawRepresentation
        let senderAddr = RavenAddressV1.encode(ed25519PublicKey: senderPub) ?? ""
        var requestId = Data(count: 16)
        requestId.withUnsafeMutableBytes { buf in
            _ = SecRandomCopyBytes(kSecRandomDefault, 16, buf.baseAddress!)
        }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let inner = ContactRequestInner(
            requestId: requestId,
            senderRavenId: senderAddr,
            senderDisplayName: AuthService.shared.currentUser?.displayName ?? "",
            senderAliases: [],
            senderProfileDigest: Data(count: 32),
            optionalMessage: requestNote,
            createdAt: now,
            expiresAt: now &+ 7 * 24 * 3600 * 1000
        )
        let req = try RavenContactRequestV1.create(
            senderSigningKey: signingKey,
            recipientPub: recipientPub,
            recipientAddr: chosen.ravenId,
            inner: inner
        )
        try req.verifyOuter(nowMs: now)
        precondition(req.isCiphertextOnly)

        lastRequestIdHex = requestId.ravenHex
        await deliverContactRequest(req, signingKey: signingKey)
        statusMessage = "Contact request sealed → \(shortId(chosen.ravenId))"
    }

    /// Confirm nearby peer → Raven ID only after safety phrase match.
    func confirmNearbyPeer(
        deviceId: String,
        displayName: String,
        userId: String?,
        enteredPhrase: String
    ) throws {
        guard FeatureFlag.isRavenEnvelopeV1Enabled else {
            throw RavenContactRequestError.missingKeys
        }
        let (token, commitment) = Self.nearbyMaterial(deviceId: deviceId)
        let expected = NearbySafetyPhrase.phrase(token: token, commitment: commitment)
        guard NearbySafetyPhrase.matches(expected: expected, entered: enteredPhrase) else {
            throw RavenContactRequestError.badSignature // reuse: phrase mismatch
        }
        guard let seed = DeviceIdentityService.shared.deviceSigningSeed,
              let pub = liveNearbyPeerPub(deviceId: deviceId, userId: userId) else {
            throw RavenContactRequestError.missingKeys
        }
        let ravenId = RavenAddressV1.encode(ed25519PublicKey: pub)
            ?? userId
            ?? deviceId
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        DiscoveryNearbyStore.confirm(NearbyConfirmBinding(
            ephemeralTokenHex: token.ravenHex,
            peerRavenId: ravenId,
            peerPubHex: pub.ravenHex,
            confirmedAtMs: now
        ))
        // Also bind a local petname row (unverified until Accept/QR pin).
        let pet = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        DiscoveryContactBindingStore.upsert(LocalDiscoveryContact(
            ravenId: ravenId,
            pubHex: pub.ravenHex,
            petname: pet.isEmpty ? shortId(ravenId) : pet,
            publicTag: "",
            displayName: pet,
            pinned: false,
            directlyVerified: false
        ))
        pubHexByRavenId[ravenId] = pub.ravenHex
        statusMessage = "Nearby confirmed — \(pet.isEmpty ? shortId(ravenId) : pet)"
        runSearch()
    }

    func nearbySafetyPhrase(forDeviceId deviceId: String) -> String {
        let (token, commitment) = Self.nearbyMaterial(deviceId: deviceId)
        return NearbySafetyPhrase.phrase(token: token, commitment: commitment)
    }

    private static func nearbyMaterial(deviceId: String) -> (Data, Data) {
        let dig = Data(SHA256.hash(data: Data(deviceId.utf8)))
        let token = Data(dig.prefix(16))
        var commitIn = Data("raven/nearby/v1".utf8)
        commitIn.append(token)
        commitIn.append(Data("confirm-local".utf8))
        let commitment = Data(SHA256.hash(data: commitIn))
        return (token, commitment)
    }

    private func liveNearbyPeerPub(deviceId: String, userId: String?) -> Data? {
        let peers = BLEMeshEngine.shared.discoveredPeers + BLEMeshEngine.shared.connectedPeers
        if let p = peers.first(where: { $0.deviceId == deviceId }),
           let key = p.publicKey, key.count == 32 {
            return key
        }
        // Fallback: if we already know pub for userId via contacts/alias.
        if let uid = userId, let hex = pubHexByRavenId[uid], let d = Data(ravenHex: hex) {
            return d
        }
        return nil
    }

    // MARK: - Sources

    private func loadSources() async {
        let devices = await FriendDeviceRepository.shared.getAllTrustedDevices()
        let myId = AuthService.shared.currentUser?.id
        var byUser: [String: LocalDiscoveryContact] = [:]
        var pubs: [String: String] = [:]
        for d in devices where d.friendUserId != myId && !d.friendUserId.isEmpty {
            let addr = RavenAddressV1.encode(ed25519PublicKey: d.publicKey) ?? d.friendUserId
            let pet = d.deviceName ?? ""
            let pubHex = d.publicKey.ravenHex
            pubs[addr] = pubHex
            pubs[d.friendUserId] = pubHex
            if byUser[addr] == nil {
                byUser[addr] = LocalDiscoveryContact(
                    ravenId: addr,
                    pubHex: pubHex,
                    petname: pet,
                    publicTag: "",
                    displayName: pet,
                    pinned: d.trustState == .trusted,
                    directlyVerified: d.trustState == .trusted && d.verifiedAt != nil
                )
            }
        }
        // Merge Accept bindings (petname-first local contacts).
        for b in DiscoveryContactBindingStore.load() {
            pubs[b.ravenId] = b.pubHex
            byUser[b.ravenId] = b
        }
        contactsCache = Array(byUser.values)
        pubHexByRavenId = pubs

        let peers = BLEMeshEngine.shared.discoveredPeers + BLEMeshEngine.shared.connectedPeers
        liveNearbyPeers = peers.map {
            (deviceId: $0.deviceId, displayName: $0.displayName ?? $0.deviceId, userId: $0.userId)
        }
    }

    private func makeResolver() -> DiscoveryResolver {
        let r = resolverFactory()
        r.serverless = FeatureFlag.isRavenEnvelopeV1Enabled
        r.publicProfileIndexEnabled = false
        r.nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        // Prefer live contact cache; allow tests to seed via resolverFactory.
        if !contactsCache.isEmpty {
            r.contacts = contactsCache
        }
        r.aliasClaims = DiscoveryAliasClaimStore.load()
        r.nearbyConfirmed = DiscoveryNearbyStore.load()
        r.blockedPubHex = DiscoveryBlockStore.load()
        // Seed pubhex from alias claims / nearby.
        for c in r.aliasClaims {
            pubHexByRavenId[c.identityAddress] = c.ed25519PubHex
        }
        for b in r.nearbyConfirmed {
            pubHexByRavenId[b.peerRavenId] = b.peerPubHex
        }
        for c in r.contacts {
            pubHexByRavenId[c.ravenId] = c.pubHex
        }
        return r
    }

    private func lookupPubHex(for result: DiscoveryResult) -> String? {
        if let hex = pubHexByRavenId[result.ravenId] { return hex }
        for c in DiscoveryAliasClaimStore.load() where c.identityAddress == result.ravenId {
            return c.ed25519PubHex
        }
        for b in DiscoveryNearbyStore.load() where b.peerRavenId == result.ravenId {
            return b.peerPubHex
        }
        for c in DiscoveryContactBindingStore.load() where c.ravenId == result.ravenId {
            return c.pubHex
        }
        return nil
    }

    private func deliverContactRequest(
        _ req: RavenContactRequestV1,
        signingKey: Curve25519.Signing.PrivateKey
    ) async {
        // Full wire object as opaque body — Bridge/store see ciphertext field only, never open.
        let wire = req.encodeWire()
        precondition(req.isCiphertextOnly)
        let messageId = req.requestId
        let routingTag = Data(SHA256.hash(data: wire.prefix(64) + messageId)).prefix(16)
        let env = RavenServerlessLanPath.packSealedMessage(
            sealedBody: wire,
            messageId: messageId,
            routingTag: Data(routingTag),
            signingKey: signingKey
        )
        let packed = env.pack()

        // BLE when peers nearby.
        if BLEMeshEngine.shared.hasActiveConnections {
            await BLEMeshEngine.shared.enqueueRawRavenEnvelopeV1(packed)
        }

        // Optional LAN peer.
        if let cfg = RavenServerlessLanConfig.stored {
            do {
                _ = try await RavenServerlessLanPath.sendEnvelope(env, host: cfg.host, port: cfg.port)
            } catch {
                // Best-effort — request remains sealed locally.
            }
        }

        // Persist outbound pending metadata (wire, not plaintext).
        let pendingKey = "raven.discovery.pending_contact_req.\(req.requestId.ravenHex)"
        UserDefaults.standard.set(wire, forKey: pendingKey)
    }

    private func shortId(_ id: String) -> String {
        if id.count <= 16 { return id }
        return String(id.prefix(10)) + "…" + String(id.suffix(4))
    }
}
