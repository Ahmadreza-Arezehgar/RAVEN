//
//  PeerKeyDirectory.swift
//  RAVEN
//
//  Local cache of peer X25519 agreement public keys keyed by userId.
//  Used by `MessageContentSealer` to resolve the recipient's pubkey
//  when sealing a DM.
//
//  Storage (2026-08-12 §14): Keychain (`AfterFirstUnlockThisDeviceOnly`,
//  non-synchronizable). Peer public keys are not private secrets, but
//  they *are* trust pins — a copied-database / backup attacker who can
//  rewrite UserDefaults could swap pins and redirect ciphertext. One-shot
//  migration copies legacy UserDefaults rows into Keychain then deletes them.
//
//  Round 13 (2026-05-16) — security hardening from the hacker audit:
//
//    • `storeFetchedBundle` no longer silently overwrites a pinned
//      identity key. If the server returns a bundle whose identity
//      key differs from the one we have on file, the new bundle is
//      REJECTED and the in-flight request returns nil — the
//      recipient pubkey we ship up to the sealer stays the trusted
//      one. The user must explicitly clear via the Safety Number
//      sheet to accept a rotation. (Audit C5.)
//
//    • `recordObservedKey` is now check-only: it never bootstraps
//      first trust from a mesh observation, only verifies that an
//      already-cached key matches what's on the wire and logs on
//      mismatch. First trust requires a server-signed bundle (or
//      the explicit `setAgreementKey` API used by the verified-
//      pairing UI). (Audit C6.)
//
//    • `ensureAgreementKey` now negative-caches failed fetches for
//      60 s so an attacker who briefly serves an invalid bundle
//      can't race a burst of seal calls into RVNP1 plaintext by
//      timing the rejection window. (Audit C9.)
//
//  Three populate paths remain:
//
//    1. **Lazy fetch** — `ensureAgreementKey(for:)` is what the
//       sealer/unsealer call. On cache miss we hit
//       `/api/atsam/prekey/{userId}`, verify the Ed25519 signature
//       over `xPub || pqPub`, then store. In-flight calls for the
//       same peer dedupe so a burst of sends only triggers one
//       network round-trip.
//
//    2. **Mesh observation (check only)** — `recordObservedKey`
//       called from `BLEMeshEngine` when a Noise handshake completes
//       AND we know the peer's `userId`. Performs a TOFU consistency
//       check ONLY: it neither writes a first-time entry nor
//       overwrites an existing one. Returns `true` only when the
//       observed key matches our cached entry. A mismatch surfaces
//       the discrepancy to logs so the operator can investigate.
//
//    3. **Explicit verified write** — `setAgreementKey(_, for:)` for
//       callers that have a trusted out-of-band key (e.g. a verified
//       pairing UI). Bypasses the TOFU guard intentionally; the
//       caller is claiming responsibility for the trust decision.
//
//  Security note: pubkey-vs-userid binding rests on TLS auth to the
//  server (only the authed user can publish for their id) plus the
//  Ed25519 signature defense-in-depth. The server-side signed
//  payload currently covers `xPub || pqPub` only — NOT the userId.
//  See audit finding C7: a compromised server could still serve
//  Alice's signed bundle as Bob's. The Safety Number sheet is the
//  user-facing check against this. Server-side signature must be
//  upgraded to cover `userId || xPub || pqPub` to fully close the
//  gap. (Round 16+ strong format binds userId; see VerifyStrength.)

import Foundation
import CryptoKit
import Security
import os

fileprivate let logger = Logger(subsystem: "app.raven.ios", category: "Security.PeerKeyDirectory")

actor PeerKeyDirectory {
    static let shared = PeerKeyDirectory()

    // MARK: - Legacy UserDefaults keys (migration only)

    private let legacyDefaults = UserDefaults.standard
    private let legacyKeyPrefix = "raven.peerKey.agreement.v1."
    private let legacyIdentityPrefix = "raven.peerKey.identity.v1."
    private let migrationFlagKey = "raven.peerKey.migratedToKeychain.v1"

    // MARK: - Keychain layout

    /// Distinct service from ATSAM roots / session tokens.
    private static let kcService = "app.raven.ios.peerKey"
    private static let indexAccount = "index.v1"

    private static func agreementAccount(_ userId: String) -> String { "agreement|\(userId)" }
    private static func identityAccount(_ userId: String) -> String { "identity|\(userId)" }

    /// In-memory caches — Keychain remains canonical.
    private var agreementCache: [String: Data] = [:]
    private var identityCache: [String: Data] = [:]
    /// Sorted unique peer ids that have either an agreement or identity pin.
    private var peerIndex: Set<String> = []
    private var didLoadIndex = false
    private var didMigrate = false

    /// In-flight server fetches, keyed by userId. Lets multiple
    /// concurrent `ensureAgreementKey` calls share one network round-
    /// trip — avoids a thundering herd when the chat surface fans out
    /// dozens of unseal calls on a fresh sync.
    private var inflight: [String: Task<Data?, Never>] = [:]

    /// Negative cache: userId → wall-clock Date when we last returned
    /// nil for it. Subsequent fetches inside the window short-circuit
    /// without re-hitting the server. Stops a server-side flake from
    /// being raced into a brief RVNP1 window.
    private var negativeCache: [String: Date] = [:]
    private let negativeCacheTTL: TimeInterval = 60

    /// Peers whose pinned identity key disagreed with a fresh server
    /// bundle this session. The chat surface can read this to surface
    /// an "identity changed — re-verify" banner. Cleared on explicit
    /// `clearAgreementKey` (which is the act of accepting a rotation).
    private var pendingIdentityChanges: Set<String> = []

    private init() {}

    // MARK: - Read

    /// Synchronous cache read. Callers MUST be prepared for nil and
    /// either go to `ensureAgreementKey` or fall back to RVNP1.
    func agreementKey(for userId: String) -> Data? {
        guard !userId.isEmpty else { return nil }
        ensureMigratedAndIndexLoaded()
        if let cached = agreementCache[userId] { return cached }
        guard let data = Self.kcGetData(account: Self.agreementAccount(userId)),
              data.count == 32 else { return nil }
        agreementCache[userId] = data
        return data
    }

    func identityKey(for userId: String) -> Data? {
        guard !userId.isEmpty else { return nil }
        ensureMigratedAndIndexLoaded()
        if let cached = identityCache[userId] { return cached }
        guard let data = Self.kcGetData(account: Self.identityAccount(userId)),
              data.count == 32 else { return nil }
        identityCache[userId] = data
        return data
    }

    /// True when the most recent server bundle for `userId` had an
    /// identity key that disagreed with the cached pin. The chat
    /// surface can show "identity changed — re-verify before sending"
    /// based on this.
    func hasPendingIdentityChange(_ userId: String) -> Bool {
        pendingIdentityChanges.contains(userId)
    }

    /// Cache-then-network. On miss we fetch the peer's ATSAM prekey
    /// bundle, verify the embedded Ed25519 signature, then cache.
    /// Returns nil if the peer doesn't have a published bundle (cold
    /// contact), if the signature check fails (likely MITM /
    /// tampering — in which case the sealer falls back to RVNP1 and
    /// the receiver surfaces the "not E2EE" badge), or if the
    /// identity key disagrees with a previously-pinned one (TOFU
    /// rotation rejection).
    func ensureAgreementKey(for userId: String) async -> Data? {
        if let cached = agreementKey(for: userId) {
            return cached
        }
        if let task = inflight[userId] {
            return await task.value
        }
        // Negative cache: don't re-fetch within the cooldown window.
        if let lastFail = negativeCache[userId],
           Date().timeIntervalSince(lastFail) < negativeCacheTTL {
            return nil
        }

        let task = Task<Data?, Never> { [weak self] in
            guard let self else { return nil }
            let fetched = await Self.fetchAndVerifyFromServer(userId: userId)
            let stored: Data? = await self.applyFetchedBundle(fetched, for: userId)
            await self.clearInflight(for: userId)
            if stored == nil {
                await self.markNegative(userId: userId)
            }
            return stored
        }
        inflight[userId] = task
        return await task.value
    }

    // MARK: - Write paths

    /// Trusted out-of-band write. Used by explicit pairing flows.
    /// Bypasses TOFU consistency check on purpose — the caller is
    /// vouching for the key. Clears any pending-rotation flag because
    /// the user has explicitly accepted this key.
    func setAgreementKey(_ data: Data, for userId: String) {
        guard data.count == 32, !userId.isEmpty else { return }
        ensureMigratedAndIndexLoaded()
        persistAgreement(data, for: userId)
        pendingIdentityChanges.remove(userId)
        negativeCache.removeValue(forKey: userId)
    }

    /// Trusted out-of-band pin of BOTH the Ed25519 identity key and the
    /// X25519 agreement key, from a user-verified QR scan (FriendQRPayload
    /// .parseAndVerify has already proven `userId == deriveFingerprint(identityKey)`,
    /// so the identity is authenticated — no server bundle needed). This is what
    /// lets a purely serverless contact-add seed every consumer that reads the
    /// directory: the mesh sealer (`ensureAgreementKey`), the libp2p bridge PeerID
    /// resolver (`identityKey`), and the Safety Number sheet. Without it those
    /// readers miss and fall through to the (turned-off) server fetch.
    func setVerifiedIdentity(identityKey: Data, agreementKey: Data?, for userId: String) {
        guard identityKey.count == 32, !userId.isEmpty else { return }
        ensureMigratedAndIndexLoaded()
        persistIdentity(identityKey, for: userId)
        if let agreementKey, agreementKey.count == 32 {
            persistAgreement(agreementKey, for: userId)
        }
        pendingIdentityChanges.remove(userId)
        negativeCache.removeValue(forKey: userId)
    }

    /// CHECK-ONLY observation API for the mesh handshake completion
    /// path. NEVER bootstraps first trust from a mesh-observed key —
    /// returns `false` when no cached key exists and the caller must
    /// route through the server-fetch path. Returns `true` when the
    /// observed key matches our cached entry, `false` (with a log)
    /// when it doesn't.
    @discardableResult
    func recordObservedKey(_ data: Data, for userId: String) -> Bool {
        guard data.count == 32, !userId.isEmpty else { return false }
        guard let existing = agreementKey(for: userId) else {
            // Audit C6: refuse to bootstrap first trust from the
            // mesh path. A peer could otherwise claim any unowned
            // userId once. Caller must instead go through
            // `ensureAgreementKey` (server-signed) or
            // `setAgreementKey` (explicit verified pairing).
            logger.debug("refusing mesh-only first trust for \(userId, privacy: .private); requires server-fetched bundle.")
            return false
        }
        if existing == data { return true }
        logger.debug("TOFU mismatch for \(userId, privacy: .private): on-wire key differs from cached. Not overwriting.")
        pendingIdentityChanges.insert(userId)
        return false
    }

    /// Used by the rotation path / unit tests / the user explicitly
    /// re-trusting a peer from the Safety Number sheet. Wipes both
    /// the agreement key AND the pinned identity key.
    func clearAgreementKey(for userId: String) {
        guard !userId.isEmpty else { return }
        ensureMigratedAndIndexLoaded()
        agreementCache.removeValue(forKey: userId)
        identityCache.removeValue(forKey: userId)
        Self.kcDelete(account: Self.agreementAccount(userId))
        Self.kcDelete(account: Self.identityAccount(userId))
        if peerIndex.remove(userId) != nil {
            persistPeerIndex()
        }
        pendingIdentityChanges.remove(userId)
        negativeCache.removeValue(forKey: userId)
    }

    /// Snapshot of every cached peer — useful for a future
    /// "Encryption" settings pane that lists who you have keys for.
    func allKnownPeers() -> [String] {
        ensureMigratedAndIndexLoaded()
        return peerIndex.sorted()
    }

    /// Reverse lookup candidates: pinned identity pub → userId (envelope sender resolve).
    func identityCandidates() -> [(userId: String, pub: Data)] {
        ensureMigratedAndIndexLoaded()
        var out: [(String, Data)] = []
        for userId in peerIndex {
            if let pub = identityKey(for: userId) {
                out.append((userId, pub))
            }
        }
        return out
    }

    // MARK: - Test / sign-out helpers

    /// Wipe every peer pin (Keychain + caches). Used by unit tests and
    /// can be wired into sign-out if product policy requires it.
    func purgeAllPins() {
        ensureMigratedAndIndexLoaded()
        for userId in peerIndex {
            Self.kcDelete(account: Self.agreementAccount(userId))
            Self.kcDelete(account: Self.identityAccount(userId))
        }
        peerIndex.removeAll()
        persistPeerIndex()
        agreementCache.removeAll()
        identityCache.removeAll()
        pendingIdentityChanges.removeAll()
        negativeCache.removeAll()
    }

    // MARK: - Private helpers

    private func applyFetchedBundle(_ fetched: VerifiedBundle?, for userId: String) -> Data? {
        guard let fetched else { return nil }
        ensureMigratedAndIndexLoaded()

        // TOFU on the identity key — see audit finding C5. If we
        // already have a pinned identity and it disagrees with the
        // bundle, REJECT the bundle. Don't overwrite either field.
        // The user must explicitly accept via the Safety Number sheet
        // (which calls `clearAgreementKey`).
        if let pinned = identityKey(for: userId), pinned != fetched.signedBy {
            logger.debug("identity rotation REJECTED for \(userId, privacy: .private). Pinned identity differs from server bundle; user must re-verify Safety Number to accept.")
            pendingIdentityChanges.insert(userId)
            return nil
        }

        // Round 16 (audit C7): a `.weakLegacy` bundle can be used to
        // CONFIRM an already-pinned identity, but never to
        // BOOTSTRAP a new one. Otherwise a compromised server can
        // serve Alice's signed-but-userId-less bundle as Bob's on
        // first contact and we'd silently start encrypting to Alice.
        if fetched.strength == .weakLegacy {
            let alreadyPinned = identityKey(for: userId) != nil
            guard alreadyPinned else {
                logger.notice("first-trust REFUSED for \(userId, privacy: .private): bundle verified with weak legacy format only; sender must upgrade to round-16+ for first-trust.")
                return nil
            }
            // Existing pinned identity matches the new bundle's
            // signed_by (else we'd have hit the rotation reject
            // above). Allow the refresh.
        }

        persistAgreement(fetched.xPub, for: userId)
        persistIdentity(fetched.signedBy, for: userId)
        // Successful application clears any prior pending flag — the
        // identity is consistent with the pin now.
        pendingIdentityChanges.remove(userId)
        return fetched.xPub
    }

    private func clearInflight(for userId: String) {
        inflight.removeValue(forKey: userId)
    }

    private func markNegative(userId: String) {
        negativeCache[userId] = Date()
    }

    private func persistAgreement(_ data: Data, for userId: String) {
        agreementCache[userId] = data
        try? Self.kcSetData(data, account: Self.agreementAccount(userId))
        if peerIndex.insert(userId).inserted {
            persistPeerIndex()
        }
    }

    private func persistIdentity(_ data: Data, for userId: String) {
        identityCache[userId] = data
        try? Self.kcSetData(data, account: Self.identityAccount(userId))
        if peerIndex.insert(userId).inserted {
            persistPeerIndex()
        }
    }

    private func ensureMigratedAndIndexLoaded() {
        if !didMigrate {
            migrateLegacyUserDefaultsIfNeeded()
            didMigrate = true
        }
        if !didLoadIndex {
            loadPeerIndex()
            didLoadIndex = true
        }
    }

    private func migrateLegacyUserDefaultsIfNeeded() {
        if legacyDefaults.bool(forKey: migrationFlagKey) { return }

        let all = legacyDefaults.dictionaryRepresentation()
        var migrated = 0
        for (key, value) in all {
            guard let data = value as? Data, data.count == 32 else { continue }
            if key.hasPrefix(legacyKeyPrefix) {
                let userId = String(key.dropFirst(legacyKeyPrefix.count))
                guard !userId.isEmpty else { continue }
                do {
                    try Self.kcSetData(data, account: Self.agreementAccount(userId))
                    agreementCache[userId] = data
                    peerIndex.insert(userId)
                    legacyDefaults.removeObject(forKey: key)
                    migrated += 1
                } catch {
                    logger.error("PeerKeyDirectory migration failed for agreement \(userId, privacy: .private); leaving UserDefaults row")
                }
            } else if key.hasPrefix(legacyIdentityPrefix) {
                let userId = String(key.dropFirst(legacyIdentityPrefix.count))
                guard !userId.isEmpty else { continue }
                do {
                    try Self.kcSetData(data, account: Self.identityAccount(userId))
                    identityCache[userId] = data
                    peerIndex.insert(userId)
                    legacyDefaults.removeObject(forKey: key)
                    migrated += 1
                } catch {
                    logger.error("PeerKeyDirectory migration failed for identity \(userId, privacy: .private); leaving UserDefaults row")
                }
            }
        }
        if !peerIndex.isEmpty {
            persistPeerIndex()
        }
        // Only mark migrated when no legacy rows remain (failed Keychain
        // writes leave rows so a later launch can retry).
        let leftover = legacyDefaults.dictionaryRepresentation().keys.contains {
            $0.hasPrefix(legacyKeyPrefix) || $0.hasPrefix(legacyIdentityPrefix)
        }
        if !leftover {
            legacyDefaults.set(true, forKey: migrationFlagKey)
        }
        if migrated > 0 {
            logger.notice("migrated \(migrated, privacy: .public) PeerKeyDirectory rows from UserDefaults → Keychain")
        }
    }

    private func loadPeerIndex() {
        if let raw = Self.kcGetData(account: Self.indexAccount),
           let ids = try? JSONDecoder().decode([String].self, from: raw) {
            peerIndex.formUnion(ids)
        }
    }

    private func persistPeerIndex() {
        let ids = peerIndex.sorted()
        guard let raw = try? JSONEncoder().encode(ids) else { return }
        try? Self.kcSetData(raw, account: Self.indexAccount)
    }

    // MARK: - Keychain helpers

    private static func kcSetData(_ data: Data, account: String) throws {
        kcDelete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kcService,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw PeerKeyDirectoryError.keychainWriteFailed(status: status)
        }
    }

    private static func kcGetData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kcService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func kcDelete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kcService,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Server fetch + signature verify

    /// Bundle verdict + the assurance level we were able to derive
    /// from the signature. Round 16 — hacker-audit finding C7.
    private enum VerifyStrength {
        /// Signature covers `"raven-bundle-v2" || 0x00 || userId ||
        /// 0x00 || xPub || pqPub`. A compromised server cannot serve
        /// a different user's bundle and have the signature verify.
        /// Safe for first-trust.
        case strong
        /// Signature only covers `xPub || pqPub` (the legacy
        /// pre-round-16 publish format). A server-side substitution
        /// attack succeeds against this format because the signed
        /// bytes don't bind the userId. Confirms existing pinned
        /// entries; refused for FIRST-trust to stop bootstrap
        /// impersonation.
        case weakLegacy
    }

    private struct VerifiedBundle {
        let xPub: Data
        let pqPub: Data
        let signedBy: Data
        let strength: VerifyStrength
    }

    /// Domain string mixed into the round-16 strong-format signed
    /// payload. Mirrors the prefix used in `MessageContentSealer.aadDomain`
    /// to keep all "bind userId into a signed transcript" decisions
    /// using the same naming.
    private static let bundleDomainV2 = Data("raven-bundle-v2".utf8)

    /// Build the strong-format signed payload that `publishLocalBundle`
    /// in round 16+ writes and that we verify here first. Exposed
    /// `internal` so the publish side can call into the exact same
    /// canonicalisation function — avoids two divergent
    /// implementations.
    static func strongSignedPayload(
        userId: String,
        xPub: Data,
        pqPub: Data
    ) -> Data {
        var out = Data()
        out.append(bundleDomainV2)
        out.append(0x00)
        out.append(Data(userId.utf8))
        out.append(0x00)
        out.append(xPub)
        out.append(pqPub)
        return out
    }

    /// Fetch + verify on a background task. Returns nil if anything
    /// in the chain is suspicious — the sealer will fall back to
    /// RVNP1 rather than trust a bad bundle.
    private static func fetchAndVerifyFromServer(userId: String) async -> VerifiedBundle? {
        do {
            let bundle = try await ATSAMPrekeyService.fetchBundle(userId: userId)
            guard bundle.xPub.count == 32 else {
                logger.debug("fetched bundle for \(userId, privacy: .private) has non-32-byte xPub (\(bundle.xPub.count, privacy: .public)).")
                return nil
            }

            // 🔴 ROUND 65 (2026-05-20) — hacker-audit ATSAM C9
            // (HIGH: cross-user bundle substitution → E2EE bypass).
            //
            // THE BUG: the round-16 C7 fix bound `userId` into the
            // signed bundle payload SPECIFICALLY so a malicious
            // server can't serve Charlie's bundle in answer to a
            // request for Bob. But the verification below used
            // `bundle.userId` — the userId field copied straight out
            // of the SERVER's JSON response — when rebuilding the
            // signed payload. That field is 100% attacker-controlled.
            //
            // Concrete attack:
            //   1. Alice wants to message Bob; client calls
            //      fetchBundle(userId: "bob").
            //   2. Malicious server returns Charlie's REAL, validly
            //      `.strong`-signed bundle (signature covers
            //      "...||charlie||xPub_charlie||...").
            //   3. Verification rebuilt `strongPayload` with
            //      `bundle.userId` == "charlie" → Charlie's genuine
            //      signature verifies → result tagged `.strong`.
            //   4. `applyFetchedBundle(fetched, for: "bob")` pins
            //      Charlie's key under identity:"bob".
            //   5. Every message Alice sends to "Bob" is now sealed
            //      to Charlie's key. Charlie decrypts; Bob can't.
            //   The round-16 binding was completely bypassed because
            //   we verified against the attacker's claimed userId,
            //   not the userId we actually asked for.
            //
            // FIX: pin the userId to the REQUESTED value. The
            // response's `userId` field must equal what we asked for,
            // and the signed payload must be rebuilt with the trusted
            // request parameter — never the server echo.
            guard bundle.userId == userId else {
                logger.notice("bundle userId mismatch — requested \(userId, privacy: .private), server returned a different userId. Rejecting (possible cross-user substitution).")
                return nil
            }

            guard let signingPub = try? Curve25519.Signing.PublicKey(
                rawRepresentation: bundle.signedBy
            ) else {
                logger.debug("bundle for \(userId, privacy: .private) has malformed signed_by.")
                return nil
            }

            // Round 16 (audit C7): try the strong (userId-bound)
            // format FIRST. A round-16+ sender always writes this
            // format; if it verifies we know the server can't have
            // substituted bundles across users.
            //
            // 🔴 ROUND 65 — rebuild the payload with the REQUESTED
            // `userId`, not `bundle.userId`. Combined with the
            // equality guard above this is belt-and-suspenders: even
            // if the guard were ever removed, a swapped bundle now
            // fails signature verification outright.
            let strongPayload = Self.strongSignedPayload(
                userId: userId,
                xPub: bundle.xPub,
                pqPub: bundle.pqPub
            )
            if signingPub.isValidSignature(bundle.signature, for: strongPayload) {
                return VerifiedBundle(
                    xPub: bundle.xPub,
                    pqPub: bundle.pqPub,
                    signedBy: bundle.signedBy,
                    strength: .strong
                )
            }

            // Fallback: legacy `xPub || pqPub` payload (round 12-15
            // publishers). Verifies that whoever published DID hold
            // the identity key, but doesn't prove the bundle belongs
            // to this userId. Marked `.weakLegacy` so the caller can
            // refuse first-trust.
            let legacyPayload = bundle.xPub + bundle.pqPub
            if signingPub.isValidSignature(bundle.signature, for: legacyPayload) {
                logger.notice("bundle for \(bundle.userId, privacy: .private) verified with LEGACY payload format — first-trust refused. Sender should upgrade to round-16+.")
                return VerifiedBundle(
                    xPub: bundle.xPub,
                    pqPub: bundle.pqPub,
                    signedBy: bundle.signedBy,
                    strength: .weakLegacy
                )
            }

            logger.notice("SIGNATURE INVALID for \(userId, privacy: .private) — refusing to cache.")
            return nil
        } catch {
            logger.debug("fetchBundle(\(userId, privacy: .private)) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

enum PeerKeyDirectoryError: Error {
    case keychainWriteFailed(status: OSStatus)
}
