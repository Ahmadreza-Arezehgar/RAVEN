import Foundation
import Security
import CryptoKit
#if targetEnvironment(macCatalyst) || os(macOS)
import IOKit
#endif

// MARK: - Token Scope
enum TokenScope: String, Codable {
    case restricted  // Before email verification
    case full        // After email verification
}

// MARK: - Keychain Service
actor KeychainService {
    static let shared = KeychainService()
    
    private let service = "app.raven.ios"
    private let tokenKey = "auth_token"
    private let scopeKey = "token_scope"
    private let userIdKey = "user_id"
    private let refreshTokenKey = "refresh_token"
    
    // MARK: - Memory Cache (avoid repeated Keychain reads)
    private var cachedToken: String?
    private var cachedScope: TokenScope?
    private var cachedUserId: String?
    private var isCacheLoaded = false
    
    private init() {}
    
    // MARK: - Token Management
    
    func saveToken(_ token: String, scope: TokenScope, userId: String, refreshToken: String? = nil) throws {
        // Save access token
        try save(key: tokenKey, value: token)
        try save(key: scopeKey, value: scope.rawValue)
        try save(key: userIdKey, value: userId)

        // Save refresh token if provided
        if let refreshToken = refreshToken {
            try save(key: refreshTokenKey, value: refreshToken)
        }

        // ✅ Update memory cache
        cachedToken = token
        cachedScope = scope
        cachedUserId = userId
        isCacheLoaded = true

        // Mirror the bearer token into the shared App Group container
        // so the paired Apple Watch's standalone-LTE fallback can hit
        // the REST API directly when the iPhone is unreachable.
        Task { @MainActor in
            WatchSnapshotProjector.shared.publishAuthToken(token)
        }
    }
    
    func getToken() -> (token: String, scope: TokenScope)? {
        // ✅ Return cached token if available (fast path)
        if isCacheLoaded {
            if let token = cachedToken, let scope = cachedScope {
                return (token, scope)
            }
            return nil
        }
        
        // First read: load from Keychain and cache
        guard let token = load(key: tokenKey),
              let scopeString = load(key: scopeKey),
              let scope = TokenScope(rawValue: scopeString) else {
            isCacheLoaded = true  // Mark as loaded even if empty
            return nil
        }
        
        // Cache for next time
        cachedToken = token
        cachedScope = scope
        cachedUserId = load(key: userIdKey)
        isCacheLoaded = true
        
        return (token, scope)
    }
    
    /// Pre-load tokens from Keychain into memory (call on app launch)
    func warmUp() {
        if !isCacheLoaded {
            _ = getToken()  // This will populate cache
            #if DEBUG
            print("🔑 [Keychain] Token cache warmed up")
            #endif
        }
    }
    
    func getRefreshToken() -> String? {
        return load(key: refreshTokenKey)
    }
    
    func updateAccessToken(_ newToken: String) throws {
        try save(key: tokenKey, value: newToken)
        cachedToken = newToken  // ✅ Update cache
        // Keep the Watch's standalone-LTE auth file in sync after a
        // token rotation, otherwise the next 401 retry on the Watch
        // would use a stale token.
        Task { @MainActor in
            WatchSnapshotProjector.shared.publishAuthToken(newToken)
        }
    }
    
    /// Update refresh token (for token rotation)
    func updateRefreshToken(_ newToken: String) throws {
        try save(key: refreshTokenKey, value: newToken)
    }
    
    /// BUG FIX (2026-05-10): mirror the same in-memory cache the
    /// access token uses. The previous version did a fresh `load()`
    /// from the keychain on every call while `cachedToken` was the
    /// authoritative source for `getToken()` — after a `deleteAll()`
    /// race, `getToken()` returned nil while `getUserId()` still
    /// pulled a stale id from disk, signing background-service
    /// requests on behalf of the wrong user. Cache + load now move
    /// together so both views stay consistent.
    func getUserId() -> String? {
        if let cached = cachedUserId { return cached }
        let fromDisk = load(key: userIdKey)
        if let fromDisk { cachedUserId = fromDisk }
        return fromDisk
    }
    
    func upgradeToFullToken(_ newToken: String) throws {
        try save(key: tokenKey, value: newToken)
        try save(key: scopeKey, value: TokenScope.full.rawValue)
        
        // ✅ Update cache
        cachedToken = newToken
        cachedScope = .full
    }
    
    func isRestricted() -> Bool {
        guard let (_, scope) = getToken() else { return true }
        return scope == .restricted
    }
    
    func deleteAll() throws {
        try delete(key: tokenKey)
        try delete(key: scopeKey)
        try delete(key: userIdKey)
        try delete(key: refreshTokenKey)
        try? delete(key: pushTokenKey)  // Force re-registration on next login

        // ✅ Clear memory cache
        cachedToken = nil
        cachedScope = nil
        cachedUserId = nil
        isCacheLoaded = true  // Keep flag true, just mark as "loaded empty"

        // Sign-out also revokes the Watch's standalone-LTE access by
        // wiping the shared-container auth file.
        Task { @MainActor in
            WatchSnapshotProjector.shared.publishAuthToken(nil)
        }
    }
    
    // MARK: - Private Keychain Operations
    //
    // On Mac Catalyst ad-hoc-signed builds (the local DMG distribution path)
    // the system Keychain refuses every SecItem operation with
    // errSecMissingEntitlement (-34018) because there's no team-prefixed
    // application-identifier baked into the binary. On notarized Developer ID
    // builds the entitlement IS present and Keychain works normally.
    //
    // To keep the local-DMG flow usable, we fall back to a per-user
    // file-backed store when Keychain refuses us. The store lives at
    // ~/Library/Application Support/RAVEN/secrets.plist with file mode 0600
    // (owner-read-write only). This is functionally equivalent to the
    // Keychain's per-app default access group from a threat-model standpoint
    // for a non-sandboxed local app — both are protected by the user's login.

    private static let fallbackFileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("RAVEN", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                  withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("secrets.plist")
    }()

    /// Sticky flag — once any SecItem operation returns errSecMissingEntitlement
    /// we know the binary is in the broken-Keychain state and route every
    /// subsequent call to the fallback store. Avoids repeated -34018 logs.
    private var keychainUnavailable = false

    // MARK: - Fallback file format
    //
    // Round 17 (2026-05-16) — hacker-audit finding N2.
    //
    // The Catalyst fallback used to write `secrets.plist` as a raw
    // binary plist of `[String: String]`, base64 of each value.
    // Anyone with read access to `~/Library/Application Support/RAVEN/`
    // — or anyone who extracted the file from a Time Machine backup —
    // got every token in plaintext.
    //
    // We now wrap the plist with **AES-256-GCM under a key derived
    // from the Mac's IOPlatformUUID** (the immutable per-machine
    // identifier that lives in IORegistryEntry and is never written
    // to disk). A 64-byte salt is generated on first write and
    // stored alongside the ciphertext so HKDF reproduces the same
    // key across launches.
    //
    // Threat model:
    //   • An attacker who steals the file via Time Machine backup
    //     or by exfiltrating `~/Library/Application Support/RAVEN/`
    //     to another machine CANNOT decrypt — they don't have the
    //     source Mac's IOPlatformUUID.
    //   • An attacker who has root on the same machine CAN still
    //     read IOPlatformUUID via `ioreg -rd1 -c IOPlatformExpertDevice`
    //     and reproduce the key. This codepath is dev-only (ad-hoc-
    //     signed Catalyst builds — production iOS uses real
    //     Keychain) so the threat is bounded.
    //   • Switching from "plaintext base64 in a backup" → "an
    //     attacker needs the original hardware" is a real and
    //     meaningful improvement.
    //
    // On iOS / properly-signed Catalyst the fallback never fires,
    // so this code only matters on dev machines. We still log a
    // hard WARNING on every fallback write so the operator knows
    // they're using the degraded path.
    //
    // Wire format on disk:
    //   ┌─────────┬──────────────────────────────────────────────┐
    //   │ 4 bytes │ "RVNK" magic                                 │
    //   │ 1 byte  │ version (0x02 = AES-GCM-IOPlatformUUID-HKDF) │
    //   │ 64 bytes│ HKDF salt                                    │
    //   │ 12 bytes│ AES-GCM nonce                                │
    //   │ 16 bytes│ AES-GCM tag                                  │
    //   │ N bytes │ ciphertext (the binary-plist payload)        │
    //   └─────────┴──────────────────────────────────────────────┘
    //
    // Reading a legacy (round-≤16) plaintext plist: when the magic
    // doesn't match, we treat the bytes as the old format, decode,
    // and IMMEDIATELY re-write with the new encrypted format on
    // the next `writeFallbackDict` call.

    private static let fallbackMagic = Data([0x52, 0x56, 0x4E, 0x4B]) // "RVNK"
    private static let fallbackVersion: UInt8 = 0x02
    private static let fallbackSaltLen = 64
    private static let fallbackNonceLen = 12

    private func loadFallbackDict() -> [String: String] {
        guard let raw = try? Data(contentsOf: Self.fallbackFileURL) else {
            return [:]
        }

        // Round 17 — new envelope.
        if raw.count > Self.fallbackMagic.count + 1 + Self.fallbackSaltLen + Self.fallbackNonceLen + 16,
           raw.prefix(Self.fallbackMagic.count) == Self.fallbackMagic {
            let versionByte = raw[Self.fallbackMagic.count]
            guard versionByte == Self.fallbackVersion else {
                return [:]
            }
            var cursor = Self.fallbackMagic.count + 1
            let salt = raw.subdata(in: cursor..<(cursor + Self.fallbackSaltLen))
            cursor += Self.fallbackSaltLen
            let nonceBytes = raw.subdata(in: cursor..<(cursor + Self.fallbackNonceLen))
            cursor += Self.fallbackNonceLen
            let ctAndTag = raw.subdata(in: cursor..<raw.count)
            // Build the SealedBox from `nonce ‖ ct ‖ tag` —
            // `AES.GCM.SealedBox(combined:)` parses the three
            // sections for us, so we don't need to materialise a
            // separate `Nonce` instance.
            guard let key = Self.deriveFallbackKey(salt: salt),
                  let box = try? AES.GCM.SealedBox(combined: nonceBytes + ctAndTag),
                  let pt = try? AES.GCM.open(box, using: key) else {
                #if DEBUG
                print("⚠️ [Keychain.fallback] envelope decrypt failed — discarding cipher payload.")
                #endif
                return [:]
            }
            if let dict = try? PropertyListSerialization.propertyList(
                from: pt, format: nil
            ) as? [String: String] {
                return dict
            }
            return [:]
        }

        // Legacy (round ≤16) plaintext plist — read once, the next
        // write will upgrade us to the encrypted envelope.
        if let dict = try? PropertyListSerialization.propertyList(
            from: raw, format: nil
        ) as? [String: String] {
            #if DEBUG
            print("⚠️ [Keychain.fallback] legacy plaintext plist detected — will upgrade to encrypted envelope on next write.")
            #endif
            return dict
        }
        return [:]
    }

    private func writeFallbackDict(_ dict: [String: String]) {
        guard let plistData = try? PropertyListSerialization.data(
            fromPropertyList: dict, format: .binary, options: 0
        ) else { return }

        // Build the encrypted envelope. If the per-machine key
        // can't be derived (no IOKit access, broken hardware id),
        // refuse to write — better to lose the session token and
        // force a re-login than to write plaintext to the fallback
        // file.
        guard let envelope = Self.encryptFallbackPayload(plistData) else {
            #if DEBUG
            print("🚨 [Keychain.fallback] could not derive per-machine encryption key — refusing to write tokens to disk.")
            #endif
            // Best-effort: nuke any existing file so a stale
            // plaintext plist doesn't linger.
            try? FileManager.default.removeItem(at: Self.fallbackFileURL)
            return
        }

        try? envelope.write(to: Self.fallbackFileURL, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: Self.fallbackFileURL.path
        )

        #if DEBUG
        print("⚠️ [Keychain.fallback] wrote \(dict.count) item(s) under AES-GCM envelope (per-machine key).")
        #endif
    }

    // MARK: - Per-machine key derivation

    /// Generates a 64-byte random salt, derives the wrapping key via
    /// HKDF(IOPlatformUUID), encrypts the payload with AES-GCM, and
    /// returns the framed envelope ready for atomic-write.
    private static func encryptFallbackPayload(_ plistData: Data) -> Data? {
        var salt = Data(count: fallbackSaltLen)
        let saltStatus = salt.withUnsafeMutableBytes { buf -> Int32 in
            guard let base = buf.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, fallbackSaltLen, base)
        }
        guard saltStatus == errSecSuccess else { return nil }

        guard let key = deriveFallbackKey(salt: salt) else { return nil }
        guard let sealed = try? AES.GCM.seal(plistData, using: key) else { return nil }
        // AES.GCM.SealedBox.combined = nonce ‖ ciphertext ‖ tag
        guard let combined = sealed.combined else { return nil }

        var out = Data()
        out.append(fallbackMagic)
        out.append(fallbackVersion)
        out.append(salt)
        out.append(combined)
        return out
    }

    /// HKDF-SHA256(IKM = IOPlatformUUID, salt = per-file salt,
    /// info = "raven.keychain.fallback.v2") → 32 bytes.
    private static func deriveFallbackKey(salt: Data) -> SymmetricKey? {
        guard let uuid = platformUUID(), !uuid.isEmpty else { return nil }
        let ikm = SymmetricKey(data: Data(uuid.utf8))
        let info = Data("raven.keychain.fallback.v2".utf8)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        return derived
    }

    /// Read the Mac's hardware IOPlatformUUID. On iOS this returns
    /// nil (the codepath shouldn't fire — Keychain is always
    /// available on a properly-signed iOS build); the encryption
    /// helper refuses to write rather than fall back to plaintext.
    private static func platformUUID() -> String? {
        #if targetEnvironment(macCatalyst) || os(macOS)
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let key = "IOPlatformUUID" as CFString
        guard let cf = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0) else {
            return nil
        }
        return cf.takeRetainedValue() as? String
        #else
        return nil
        #endif
    }

    private func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.saveFailed(errSecParam)
        }

        if keychainUnavailable {
            var dict = loadFallbackDict()
            dict[key] = value
            writeFallbackDict(dict)
            return
        }

        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new — SECURITY:
        //   • AfterFirstUnlockThisDeviceOnly: device-bound, no backup,
        //     AND accessible after first unlock (critical for
        //     background push-token reads).
        //   • kSecAttrSynchronizable = false — round 13, hacker-audit
        //     finding S3. Without this flag every Keychain item could
        //     be opportunistically synced to iCloud Keychain on
        //     accounts that have it enabled, leaking session tokens,
        //     refresh tokens, push tokens, and contact-sync salt off
        //     the device.
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            // Switch to fallback for the rest of the process lifetime.
            keychainUnavailable = true
            #if DEBUG
            print("⚠️ [Keychain] errSecMissingEntitlement on save — falling back to file store")
            #endif
            var dict = loadFallbackDict()
            dict[key] = value
            writeFallbackDict(dict)
            return
        }
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    private func load(key: String) -> String? {
        if keychainUnavailable {
            return loadFallbackDict()[key]
        }

        // Round 13: include `kSecAttrSynchronizable: false` in
        // load/delete queries too, so the lookup matches the
        // non-synchronizable items we add. Without this, on a device
        // that already had a synchronizable item (from an older
        // build), lookups could return the iCloud-mirrored copy
        // instead of the local-only one.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecMissingEntitlement {
            keychainUnavailable = true
            #if DEBUG
            print("⚠️ [Keychain] errSecMissingEntitlement on load — falling back to file store")
            #endif
            return loadFallbackDict()[key]
        }

        if status == errSecSuccess,
           let data = result as? Data,
           let string = String(data: data, encoding: .utf8) {
            return string
        }

        // 🔴 ROUND 71 phase 3 — Catalyst legacy keychain migration.
        // Round 70 split the Catalyst keychain access group: the
        // entitlement now lists `app.raven.macos` FIRST (default for
        // new writes) and `app.raven.ios` second (kept readable
        // during the migration window). After the split, the primary
        // load above returns nothing for tokens written before the
        // entitlement bump — they live in `app.raven.ios`. Without
        // the fallback the user sees a force-logout on first launch
        // of the new Catalyst build.
        //
        // Fallback only runs on Catalyst, only after the primary
        // query failed, and only for the legacy iOS access group.
        // When a value is found we re-save under the default (macos)
        // group + delete the legacy row so subsequent reads stay on
        // the fast path. Team-ID prefix is omitted — the system
        // pre-pends $(AppIdentifierPrefix) automatically.
        return loadCatalystLegacyKeychainItem(key: key)
    }

    private func loadCatalystLegacyKeychainItem(key: String) -> String? {
        #if targetEnvironment(macCatalyst)
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecAttrAccessGroup as String: "app.raven.ios",
        ]
        var legacyResult: AnyObject?
        let legacyStatus = SecItemCopyMatching(legacyQuery as CFDictionary, &legacyResult)
        guard legacyStatus == errSecSuccess,
              let data = legacyResult as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        #if DEBUG
        print("🔄 [Keychain] Catalyst legacy migration: found '\(key)' in app.raven.ios; "
              + "re-saving to default (app.raven.macos) and removing legacy row")
        #endif
        // Re-save under the default (macos) access group via the
        // standard save() path — that's the source of truth going
        // forward. If the re-save fails we still return the value
        // so the user isn't force-logged-out, but log it so we know
        // the migration isn't permanent.
        do {
            try save(key: key, value: string)
        } catch {
            #if DEBUG
            print("⚠️ [Keychain] Catalyst legacy migration: re-save failed: \(error). "
                  + "Legacy row left in place; will retry next load.")
            #endif
            return string
        }
        // Re-save succeeded — purge the legacy row so the next load
        // skips the slow fallback path.
        let legacyDelete: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecAttrAccessGroup as String: "app.raven.ios",
        ]
        SecItemDelete(legacyDelete as CFDictionary)
        return string
        #else
        return nil
        #endif
    }

    private func delete(key: String) throws {
        if keychainUnavailable {
            var dict = loadFallbackDict()
            dict.removeValue(forKey: key)
            writeFallbackDict(dict)
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecMissingEntitlement {
            keychainUnavailable = true
            var dict = loadFallbackDict()
            dict.removeValue(forKey: key)
            writeFallbackDict(dict)
            return
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
    
    // MARK: - Push Token
    
    private let pushTokenKey = "push_token"
    
    func savePushToken(_ token: String) {
        try? save(key: pushTokenKey, value: token)
    }
    
    func getPushToken() -> String? {
        return load(key: pushTokenKey)
    }
    
    // MARK: - Contact Sync Salt
    
    private let contactSaltKey = "contact_sync_salt"
    
    func saveContactSyncSalt(_ salt: String) {
        try? save(key: contactSaltKey, value: salt)
    }
    
    func getContactSyncSalt() -> String? {
        return load(key: contactSaltKey)
    }
}

// MARK: - Keychain Error
enum KeychainError: Error {
    case saveFailed(OSStatus)
    case deleteFailed(OSStatus)
}
