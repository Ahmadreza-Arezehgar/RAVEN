//
//  ATSAMLabSessionMetaStore.swift
//  RAVEN — Keychain-backed lab session metadata (no plaintext rootKey JSON).
//

import Foundation
import Security

/// Durable lab session metadata without root key material.
/// Root / ratchet head lives in `KeychainProtectedSessionStore` (SQLCipher journal separately).
enum ATSAMLabSessionMetaStore {

    private static let service = "app.raven.ios.atsam.lab.session.meta"
    private static let legacyDirName = "raven-lab-sessions"
    private static let quarantineDirName = "raven-lab-sessions-quarantine"

    struct PersistedMeta: Codable, Equatable {
        var initiatorAddress: String
        var responderAddress: String
        var remoteDeviceEd: Data
        var senderCertIdentity: Data
        var senderCertSigning: Data
        var senderCertSig: Data
        var pairInitSenderCertHash: Data
        var sessionCreatedAtMs: UInt64
        var sessionExpiresAtMs: UInt64
        var localDeviceEd: Data
        /// 0 = initiatorToResponder inbound, 1 = responderToInitiator inbound
        var inboundDirectionRaw: UInt8
    }

    enum StoreError: Error, Equatable {
        case keychainFailed
        case legacyPlaintextRefused(count: Int)
    }

    static func account(for sessionID: Data) -> String {
        "lab-meta|" + sessionID.map { String(format: "%02x", $0) }.joined()
    }

    static func save(_ meta: PersistedMeta, sessionID: Data) throws {
        let data = try JSONEncoder().encode(meta)
        try writeKeychain(account: account(for: sessionID), data: data)
    }

    static func load(sessionID: Data) throws -> PersistedMeta? {
        guard let raw = try readKeychain(account: account(for: sessionID)) else { return nil }
        return try JSONDecoder().decode(PersistedMeta.self, from: raw)
    }

    static func allSessionIDs() throws -> [Data] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess,
              let entries = items as? [[String: Any]] else {
            throw StoreError.keychainFailed
        }
        var result: [Data] = []
        for entry in entries {
            guard let account = entry[kSecAttrAccount as String] as? String,
                  account.hasPrefix("lab-meta|") else { continue }
            let hex = String(account.dropFirst("lab-meta|".count))
            guard let sid = dataFromHex(hex), sid.count == 32 else { continue }
            result.append(sid)
        }
        return result
    }

    /// Fail-closed: refuse legacy plaintext JSON roots; quarantine files and require re-pair.
    @discardableResult
    static func quarantineLegacyPlaintextSessionsIfPresent() throws -> Int {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return 0 }
        let legacy = base.appendingPathComponent(legacyDirName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return 0 }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: legacy,
            includingPropertiesForKeys: nil
        )) ?? []
        let jsonFiles = files.filter { $0.pathExtension.lowercased() == "json" }
        guard !jsonFiles.isEmpty else { return 0 }

        let stamp = ISO8601DateFormatter().string(from: Date())
        let quarantine = base
            .appendingPathComponent(quarantineDirName, isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        for file in jsonFiles {
            let dest = quarantine.appendingPathComponent(file.lastPathComponent)
            try? FileManager.default.moveItem(at: file, to: dest)
        }
        try? FileManager.default.removeItem(at: legacy)
        throw StoreError.legacyPlaintextRefused(count: jsonFiles.count)
    }

    #if DEBUG
    static func deleteAllForTesting() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        guard status == errSecSuccess,
              let entries = items as? [[String: Any]] else { return }
        for entry in entries {
            guard let account = entry[kSecAttrAccount as String] as? String else { continue }
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(deleteQuery as CFDictionary)
        }
    }
    #endif

    private static func dataFromHex(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var cursor = hex.startIndex
        while cursor < hex.endIndex {
            let next = hex.index(cursor, offsetBy: 2)
            guard let byte = UInt8(hex[cursor..<next], radix: 16) else { return nil }
            out.append(byte)
            cursor = next
        }
        return out
    }

    private static func readKeychain(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw StoreError.keychainFailed
        }
        return data
    }

    private static func writeKeychain(account: String, data: Data) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StoreError.keychainFailed }
    }
}
