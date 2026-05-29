//
//  PVPadStore.swift
//  RAVEN — PROXIMA-VAULT persistence
//
//  Stores PV pads at rest with Secure-Enclave-protected key wrap.
//
//  Storage model
//  ─────────────
//   • One pad per conversation pair, stored as an AES-GCM
//     ciphertext file in the app's container.
//   • The AES key (the "Pad Wrap Key", PWK) is itself wrapped by a
//     Vault Master Key (VMK) which lives in the iOS Keychain with
//     `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. The VMK
//     never leaves the device and is not synced to iCloud.
//   • The cursor (counter + replay bitmap + cipher offset) is
//     stored next to the pad ciphertext, encrypted under the same
//     PWK. It is persisted on every successful encode/decode.
//
//   File layout under `Library/PROXIMA-VAULT/`:
//     {padId}.pad        AES-GCM(PWK, padBytes)
//     {padId}.fwd.cur    AES-GCM(PWK, cursor_forward_blob)
//     {padId}.rev.cur    AES-GCM(PWK, cursor_reverse_blob)
//
//  Atomicity
//  ─────────
//  Cursor writes go through a "write-tmp + atomic rename" pattern
//  so a crash mid-write cannot leave us with a partial cursor that
//  would silently let the next encrypt reuse pad bytes. Pad bytes
//  themselves are never overwritten (pads are immutable once
//  provisioned — only the cursor advances).
//
//  Honest scope
//  ────────────
//  PWK-in-Keychain is COMPUTATIONAL security, not
//  information-theoretic. If iOS Keychain itself is compromised
//  (jailbreak + root + bypassing Secure Enclave attestation), the
//  PWK is exposed and the attacker can decrypt pads at rest. This
//  is the same trust model as Signal's local DB encryption.
//
//  We never claim "pads cannot be extracted" — only "pads at rest
//  are protected by the same hardware-backed key the rest of iOS
//  trusts".
//

import Foundation
import CryptoKit
import Security

actor PVPadStore {

    // MARK: - Public outcomes

    enum StoreError: Error, Equatable {
        case notFound(padId: Data)
        case decryptFailed
        case keychainFailed(OSStatus)
        case ioFailed(String)
        case corruptedOnDisk
    }

    // MARK: - Singleton

    /// Shared store. Actor-isolated so concurrent send + receive
    /// can't interleave a half-written cursor.
    static let shared = PVPadStore()

    // MARK: - Private state

    /// The Vault Master Key — fetched once on first access from
    /// Keychain. Held only in this actor's memory.
    private var vmkCache: SymmetricKey?

    /// In-memory cache for recently-loaded pads. Pads are large
    /// (~7.5 MiB) so we cap the cache at 4 entries to bound memory.
    /// LRU eviction via insertion-order tracking.
    private var padCache: [Data: PVPad] = [:]
    private var padCacheOrder: [Data] = []
    private static let padCacheLimit = 4

    private init() {}

    // MARK: - Keychain helpers

    /// Keychain account / service identifiers. Stable strings so
    /// future builds can find the same key. NEVER renamed.
    private static let kKeychainService = "com.raven.proximavault.vmk"
    private static let kKeychainAccount = "v1"

    private func loadOrCreateVMK() throws -> SymmetricKey {
        if let cached = vmkCache { return cached }

        // Try to read.
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.kKeychainService,
            kSecAttrAccount as String: Self.kKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let readStatus = SecItemCopyMatching(query as CFDictionary, &item)
        if readStatus == errSecSuccess, let data = item as? Data, data.count == 32 {
            let key = SymmetricKey(data: data)
            vmkCache = key
            return key
        }
        if readStatus != errSecItemNotFound {
            throw StoreError.keychainFailed(readStatus)
        }

        // Create a new one with hardware-backed protection.
        var keyBytes = Data(count: 32)
        let rndStatus = keyBytes.withUnsafeMutableBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return -1 }
            return SecRandomCopyBytes(kSecRandomDefault, 32, base)
        }
        guard rndStatus == errSecSuccess else {
            throw StoreError.keychainFailed(rndStatus)
        }

        let addAttrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.kKeychainService,
            kSecAttrAccount as String: Self.kKeychainAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: keyBytes,
        ]
        query = addAttrs
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw StoreError.keychainFailed(addStatus)
        }
        let key = SymmetricKey(data: keyBytes)
        vmkCache = key
        return key
    }

    // MARK: - Filesystem layout

    private func storeDirectoryURL() throws -> URL {
        let fm = FileManager.default
        guard let support = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            throw StoreError.ioFailed("no library directory")
        }
        let dir = support.appendingPathComponent("PROXIMA-VAULT", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // Belt-and-suspenders: protect the directory from
            // iCloud backup. iOS already encrypts the app sandbox
            // at rest, but excluding from backup means a restored
            // backup of an OLD device cannot bring back consumed
            // pad bytes (backup-rollback defense).
            var rv = URLResourceValues()
            rv.isExcludedFromBackup = true
            var mutableDir = dir
            try? mutableDir.setResourceValues(rv)
        }
        return dir
    }

    private func padFileURL(forPadId padId: Data) throws -> URL {
        try storeDirectoryURL().appendingPathComponent("\(padId.hex).pad")
    }
    private func cursorFileURL(forPadId padId: Data,
                               direction: PVDirection) throws -> URL {
        let suffix = direction == .forward ? "fwd" : "rev"
        return try storeDirectoryURL().appendingPathComponent("\(padId.hex).\(suffix).cur")
    }

    // MARK: - AEAD wrap helpers (PWK ≡ VMK in v1; can split later)

    private func sealedBytes(plaintext: Data, key: SymmetricKey, aad: Data) throws -> Data {
        var nonceBytes = Data(count: 12)
        let s = nonceBytes.withUnsafeMutableBytes { ptr -> Int32 in
            guard let b = ptr.baseAddress else { return -1 }
            return SecRandomCopyBytes(kSecRandomDefault, 12, b)
        }
        guard s == errSecSuccess else { throw StoreError.ioFailed("nonce gen failed") }
        let nonce = try AES.GCM.Nonce(data: nonceBytes)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        // Pack: nonce(12) || tag(16) || ciphertext
        var out = Data()
        out.reserveCapacity(12 + 16 + (sealed.ciphertext.count))
        out.append(nonceBytes)
        out.append(sealed.tag)
        out.append(sealed.ciphertext)
        return out
    }

    private func openSealed(packed: Data, key: SymmetricKey, aad: Data) throws -> Data {
        guard packed.count > 12 + 16 else { throw StoreError.corruptedOnDisk }
        let nonceBytes = packed.prefix(12)
        let tagBytes = packed.dropFirst(12).prefix(16)
        let ct = packed.dropFirst(12 + 16)
        let nonce = try AES.GCM.Nonce(data: nonceBytes)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: Data(ct), tag: Data(tagBytes))
        return try AES.GCM.open(box, using: key, authenticating: aad)
    }

    // MARK: - Public API

    /// Persist a freshly-provisioned pad to disk for the first
    /// time. Overwrites any existing pad with the same id (which
    /// would only happen on re-provision after exhaustion).
    func savePad(_ pad: PVPad) throws {
        let key = try loadOrCreateVMK()
        let url = try padFileURL(forPadId: pad.padId)
        let aad = "PROXIMA-VAULT-pad-aad-v1".data(using: .utf8)!
        let sealed = try sealedBytes(plaintext: pad.rawBytes, key: key, aad: aad)
        try atomicWrite(sealed, to: url)

        // Reset cursors on first save.
        let fwd = PVPadCursor.freshCursor(padId: pad.padId, direction: .forward)
        let rev = PVPadCursor.freshCursor(padId: pad.padId, direction: .reverse)
        try saveCursor(fwd, padId: pad.padId, direction: .forward)
        try saveCursor(rev, padId: pad.padId, direction: .reverse)

        cachePadInMemory(pad)
    }

    /// Load a pad from disk (or in-memory cache). Throws if the
    /// pad does not exist locally — caller should surface "pair
    /// required" UI.
    func loadPad(padId: Data) throws -> PVPad {
        if let hit = padCache[padId] { return hit }
        let key = try loadOrCreateVMK()
        let url = try padFileURL(forPadId: padId)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StoreError.notFound(padId: padId)
        }
        let sealed = try Data(contentsOf: url)
        let aad = "PROXIMA-VAULT-pad-aad-v1".data(using: .utf8)!
        let rawBytes = try openSealed(packed: sealed, key: key, aad: aad)

        // Reconstruct pseudonyms + provisionedAt from the pad header.
        guard rawBytes.count >= 64 else { throw StoreError.corruptedOnDisk }
        let pad = PVPad(
            padId: rawBytes.subdata(in: 0..<16),
            pseudonymForward: rawBytes.subdata(in: 16..<32),
            pseudonymReverse: rawBytes.subdata(in: 32..<48),
            provisionedAt: provisionedAt(from: rawBytes),
            rawBytes: rawBytes
        )
        cachePadInMemory(pad)
        return pad
    }

    /// Load the per-direction cursor for `padId`. Returns a fresh
    /// cursor if none exists yet (callers typically still need to
    /// have a pad on disk for this to make sense).
    func loadCursor(padId: Data, direction: PVDirection) throws -> PVPadCursor {
        let key = try loadOrCreateVMK()
        let url = try cursorFileURL(forPadId: padId, direction: direction)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PVPadCursor.freshCursor(padId: padId, direction: direction)
        }
        let sealed = try Data(contentsOf: url)
        let aad = "PROXIMA-VAULT-cur-aad-v1".data(using: .utf8)!
        let plain = try openSealed(packed: sealed, key: key, aad: aad)
        let cursor = try JSONDecoder().decode(PVPadCursor.self, from: plain)
        return cursor
    }

    /// Persist the cursor for `padId` in the given direction.
    /// MUST be called BEFORE the envelope is handed to the
    /// transport layer — that ordering is the OTP-correctness
    /// invariant (Stage 6 / §24).
    func saveCursor(_ cursor: PVPadCursor,
                    padId: Data,
                    direction: PVDirection) throws {
        let key = try loadOrCreateVMK()
        let url = try cursorFileURL(forPadId: padId, direction: direction)
        let plain = try JSONEncoder().encode(cursor)
        let aad = "PROXIMA-VAULT-cur-aad-v1".data(using: .utf8)!
        let sealed = try sealedBytes(plaintext: plain, key: key, aad: aad)
        try atomicWrite(sealed, to: url)
    }

    // MARK: - LRU cache helpers

    private func cachePadInMemory(_ pad: PVPad) {
        if padCache[pad.padId] == nil {
            padCacheOrder.append(pad.padId)
        }
        padCache[pad.padId] = pad
        while padCacheOrder.count > Self.padCacheLimit {
            let evict = padCacheOrder.removeFirst()
            padCache[evict] = nil
        }
    }

    // MARK: - Atomic write

    private func atomicWrite(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".tmp")
        do {
            try data.write(to: tmp, options: [.atomic])
            // Move tmp -> url with replaceItem so a crash between
            // these lines leaves the OLD file intact, not zero
            // bytes.
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw StoreError.ioFailed(String(describing: error))
        }
    }

    // MARK: - Header parsing

    private func provisionedAt(from rawBytes: Data) -> Date {
        // Bytes 48..55 hold provisioned_at as big-endian uint64.
        guard rawBytes.count >= 56 else { return Date(timeIntervalSince1970: 0) }
        let slice = rawBytes.subdata(in: 48..<56)
        let bytes = Array(slice)
        var v: UInt64 = 0
        for b in bytes { v = (v << 8) | UInt64(b) }
        return Date(timeIntervalSince1970: TimeInterval(v))
    }
}

private extension Data {
    /// Hex string (lowercase, no separator). Used for filenames.
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
