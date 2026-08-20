//
//  ATSAMOutboundBodyStage.swift
//  RAVEN
//
//  Durable outbound plaintext stage (RVNOSTG1) before SQL outbox / dial.
//  AEAD domain: raven/outbound-stage/v1. G2 orphan delete rewrites the
//  authenticated manifest and fsyncs file + parent directory (fail-closed).
//

import CryptoKit
import Darwin
import Foundation
import Security

enum ATSAMOutboundBodyStage {

    static let magic = Data("RVNOSTG1".utf8)
    static let aadDomain = Data("raven/outbound-stage/v1".utf8)
    static let fileName = "outbound_body_stage.bin"
    static let maximumEntries = 256
    static let maximumBodyCharacters = 48 * 1024
    static let maximumHexCharacters = 128
    /// Serialized JSON budget before MAGIC + AEAD overhead.
    static let maximumSerializedBytes = 4 * 1024 * 1024 - 36
    static let maximumFileBytes = 4 * 1024 * 1024

    enum StageError: Error, Equatable {
        case tooLarge
        case corrupt
        case authenticationFailed
        case ioFailed
        case fsyncFailed
        case bindingMismatch
        case orphanDeleted(messageID: Data)
    }

    struct StagedOutboundBody: Codable, Equatable {
        let peerPubHex: String
        let sessionIDHex: String
        let objectDigestHex: String
        let messageIDHex: String
        let body: String
        let createdAtMs: UInt64

        enum CodingKeys: String, CodingKey {
            case peerPubHex = "peer_pub_hex"
            case sessionIDHex = "session_id_hex"
            case objectDigestHex = "object_digest_hex"
            case messageIDHex = "message_id_hex"
            case body
            case createdAtMs = "created_at_ms"
        }
    }

    private struct StageFile: Codable, Equatable {
        var entries: [StagedOutboundBody]
    }

    /// Keychain-backed random AEAD key (never derived from a fixed source string).
    enum KeychainStageKey {
        private static let service = "app.raven.ios.atsam.lab.outbound-stage-key"
        private static let account = "lab-outbound-stage-v1"

        enum KeyError: Error {
            case keychainUnavailable
            case randomFailed
        }

        static func loadOrCreate() throws -> SymmetricKey {
            if let existing = try readKeychain(), existing.count == 32 {
                return SymmetricKey(data: existing)
            }
            var bytes = Data(count: 32)
            let status = bytes.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return errSecAllocate }
                return SecRandomCopyBytes(kSecRandomDefault, 32, base)
            }
            guard status == errSecSuccess else { throw KeyError.randomFailed }
            try writeKeychain(bytes)
            return SymmetricKey(data: bytes)
        }

        #if DEBUG
        private static var testOverride: SymmetricKey?

        static func setTestOverride(_ key: SymmetricKey?) {
            testOverride = key
        }
        #endif

        static func resolvedKey() throws -> SymmetricKey {
            #if DEBUG
            if let testOverride { return testOverride }
            #endif
            return try loadOrCreate()
        }

        private static func readKeychain() throws -> Data? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = item as? Data else {
                throw KeyError.keychainUnavailable
            }
            return data
        }

        private static func writeKeychain(_ data: Data) throws {
            let identityQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            ]
            let updateStatus = SecItemUpdate(
                identityQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            if updateStatus == errSecSuccess { return }
            guard updateStatus == errSecItemNotFound else {
                throw KeyError.keychainUnavailable
            }
            var addQuery = identityQuery
            addQuery.merge([
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecValueData as String: data,
            ]) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
                throw KeyError.keychainUnavailable
            }
            if addStatus == errSecDuplicateItem,
               SecItemUpdate(
                   identityQuery as CFDictionary,
                   [kSecValueData as String: data] as CFDictionary
               ) != errSecSuccess {
                throw KeyError.keychainUnavailable
            }
        }

        #if DEBUG
        static func deleteForTesting() {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(query as CFDictionary)
            testOverride = nil
        }
        #endif
    }

    /// Injectable AEAD boundary for headless tests and future platform keys.
    protocol Protector: Sendable {
        func protect(dataDirectory: URL, plaintext: Data) throws -> Data
        func unprotect(dataDirectory: URL, ciphertext: Data) throws -> Data
    }

    /// ChaCha20-Poly1305 with scoped AAD matching the Rust chat-history profile.
    struct ScopedAeadProtector: Protector {
        let key: SymmetricKey

        init(key: SymmetricKey) {
            self.key = key
        }

        init(fixedKeyBytes: Data) {
            self.key = SymmetricKey(data: fixedKeyBytes)
        }

        func protect(dataDirectory: URL, plaintext: Data) throws -> Data {
            let aad = Self.scopedAAD(dataDirectory: dataDirectory)
            let nonce = try freshNonce12()
            let box = try ChaChaPoly.seal(
                plaintext,
                using: key,
                nonce: ChaChaPoly.Nonce(data: nonce),
                authenticating: aad
            )
            return box.combined
        }

        func unprotect(dataDirectory: URL, ciphertext: Data) throws -> Data {
            guard ciphertext.count >= 12 + 16 else {
                throw StageError.corrupt
            }
            let aad = Self.scopedAAD(dataDirectory: dataDirectory)
            do {
                let box = try ChaChaPoly.SealedBox(combined: ciphertext)
                return try ChaChaPoly.open(box, using: key, authenticating: aad)
            } catch {
                throw StageError.authenticationFailed
            }
        }

        static func scopedAAD(dataDirectory: URL) -> Data {
            let path: String
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            if realpath(dataDirectory.path, &buffer) != nil {
                path = String(cString: buffer)
            } else {
                path = dataDirectory.standardizedFileURL.path
            }
            var hasher = SHA256()
            hasher.update(data: aadDomain)
            hasher.update(data: Data("/".utf8))
            hasher.update(data: Data(path.utf8))
            return Data(hasher.finalize())
        }
    }

    /// File-backed stage store with an exclusive in-process lock.
    final class Store: @unchecked Sendable {
        private let directory: URL
        private let protector: any Protector
        private let lock = NSLock()

        init(directory: URL, protector: any Protector) {
            self.directory = directory
            self.protector = protector
        }

        var dataDirectory: URL { directory }

        func preflightCapacity(body: String, createdAtMs: UInt64) throws {
            try lock.withLock {
                let file = try loadLocked()
                try probeCapacity(file: file, body: body, createdAtMs: createdAtMs)
            }
        }

        func stage(
            peerPub: Data,
            sessionID: Data,
            objectDigest: Data,
            messageID: Data,
            createdAtMs: UInt64,
            body: String
        ) throws {
            try validateBindings(
                peerPub: peerPub,
                sessionID: sessionID,
                objectDigest: objectDigest,
                messageID: messageID
            )
            try lock.withLock {
                var file = try loadLocked()
                try probeCapacity(file: file, body: body, createdAtMs: createdAtMs)
                let midHex = normalizeHex(messageID.map { String(format: "%02x", $0) }.joined())
                file.entries.removeAll { $0.messageIDHex.caseInsensitiveCompare(midHex) == .orderedSame }
                file.entries.append(
                    StagedOutboundBody(
                        peerPubHex: normalizeHex(peerPub.map { String(format: "%02x", $0) }.joined()),
                        sessionIDHex: normalizeHex(sessionID.map { String(format: "%02x", $0) }.joined()),
                        objectDigestHex: normalizeHex(
                            objectDigest.map { String(format: "%02x", $0) }.joined()
                        ),
                        messageIDHex: midHex,
                        body: normalizeBody(body),
                        createdAtMs: createdAtMs
                    )
                )
                try saveLocked(file)
            }
        }

        func load(messageID: Data) throws -> StagedOutboundBody? {
            try lock.withLock {
                let file = try loadLocked()
                let midHex = normalizeHex(messageID.map { String(format: "%02x", $0) }.joined())
                return file.entries.first {
                    $0.messageIDHex.caseInsensitiveCompare(midHex) == .orderedSame
                }
            }
        }

        func list() throws -> [StagedOutboundBody] {
            try lock.withLock {
                try loadLocked().entries
            }
        }

        /// G2: rewrite manifest without the entry, fsync file + parent dir.
        func securelyDelete(messageID: Data) throws {
            try lock.withLock {
                var file = try loadLocked()
                let midHex = normalizeHex(messageID.map { String(format: "%02x", $0) }.joined())
                let before = file.entries.count
                file.entries.removeAll {
                    $0.messageIDHex.caseInsensitiveCompare(midHex) == .orderedSame
                }
                guard file.entries.count != before else { return }
                if file.entries.isEmpty {
                    try removeStageFileLocked()
                } else {
                    try saveLocked(file)
                }
            }
        }

        /// Orphan policy (G2): stage without matching outbox/pending journal → delete + report.
        func reconcileOrphans(
            hasOutbox: (Data, Data) throws -> Bool,
            hasPendingOutbound: (Data, Data, Data) throws -> Bool
        ) throws -> [StageError] {
            var failures: [StageError] = []
            let staged = try list()
            for entry in staged {
                guard let peer = parseHex32(entry.peerPubHex),
                      let sessionID = parseHex32(entry.sessionIDHex),
                      let objectDigest = parseHex32(entry.objectDigestHex),
                      let messageID = parseHex16(entry.messageIDHex) else {
                    if let messageID = parseHex16(entry.messageIDHex) {
                        try securelyDelete(messageID: messageID)
                        failures.append(.orphanDeleted(messageID: messageID))
                    }
                    continue
                }
                let outboxed = (try? hasOutbox(sessionID, objectDigest)) ?? false
                let pending = (try? hasPendingOutbound(sessionID, objectDigest, messageID)) ?? false
                if !outboxed && !pending {
                    try securelyDelete(messageID: messageID)
                    failures.append(.orphanDeleted(messageID: messageID))
                }
            }
            return failures
        }

        // MARK: - Private

        private func loadLocked() throws -> StageFile {
            let path = directory.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: path.path) else {
                return StageFile(entries: [])
            }
            let bytes = try Data(contentsOf: path)
            guard bytes.starts(with: magic) else {
                throw StageError.corrupt
            }
            let protected = bytes.suffix(from: magic.count)
            let plaintext = try protector.unprotect(dataDirectory: directory, ciphertext: protected)
            guard plaintext.count <= maximumSerializedBytes else {
                throw StageError.tooLarge
            }
            let file = try JSONDecoder().decode(StageFile.self, from: plaintext)
            try validateBudget(file)
            return file
        }

        private func saveLocked(_ file: StageFile) throws {
            try validateBudget(file)
            let plaintext = try JSONEncoder().encode(file)
            guard plaintext.count <= maximumSerializedBytes else {
                throw StageError.tooLarge
            }
            let protected = try protector.protect(dataDirectory: directory, plaintext: plaintext)
            let total = magic.count + protected.count
            guard total <= maximumFileBytes else {
                throw StageError.tooLarge
            }
            var encoded = Data()
            encoded.append(magic)
            encoded.append(protected)
            try atomicWritePrivate(path: directory.appendingPathComponent(fileName), contents: encoded)
        }

        private func removeStageFileLocked() throws {
            let path = directory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: path.path) {
                try FileManager.default.removeItem(at: path)
            }
            try fsyncParentDirectory(directory)
        }

        private func probeCapacity(
            file: StageFile,
            body: String,
            createdAtMs: UInt64
        ) throws {
            _ = createdAtMs
            var probe = file
            probe.entries.append(
                StagedOutboundBody(
                    peerPubHex: normalizeHex(String(repeating: "00", count: 64)),
                    sessionIDHex: normalizeHex(String(repeating: "00", count: 64)),
                    objectDigestHex: normalizeHex(String(repeating: "00", count: 64)),
                    messageIDHex: normalizeHex(String(repeating: "00", count: 32)),
                    body: normalizeBody(body),
                    createdAtMs: .max
                )
            )
            try validateBudget(probe)
            let plaintext = try JSONEncoder().encode(probe)
            guard plaintext.count <= maximumSerializedBytes else {
                throw StageError.tooLarge
            }
            let total = magic.count + 12 + 16 + plaintext.count
            guard total <= maximumFileBytes else {
                throw StageError.tooLarge
            }
        }

        private func validateBudget(_ file: StageFile) throws {
            guard file.entries.count <= maximumEntries else {
                throw StageError.tooLarge
            }
            let serialized = try JSONEncoder().encode(file)
            guard serialized.count <= maximumSerializedBytes else {
                throw StageError.tooLarge
            }
        }
    }

    // MARK: - Helpers

    static func validateBindings(
        peerPub: Data,
        sessionID: Data,
        objectDigest: Data,
        messageID: Data
    ) throws {
        guard peerPub.count == 32,
              sessionID.count == 32,
              objectDigest.count == 32,
              messageID.count == 16 else {
            throw StageError.bindingMismatch
        }
    }

    static func normalizeBody(_ body: String) -> String {
        String(
            body
                .unicodeScalars
                .map { scalar -> Character in
                    switch scalar.value {
                    case 0x09, 0x0A, 0x0D: return " "
                    default: return Character(scalar)
                    }
                }
                .prefix(maximumBodyCharacters)
        )
    }

    static func normalizeHex(_ value: String) -> String {
        String(value.lowercased().prefix(maximumHexCharacters))
    }

    static func parseHex32(_ hex: String) -> Data? {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 64, trimmed.allSatisfy({ $0.isHexDigit }) else { return nil }
        var out = Data()
        out.reserveCapacity(32)
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(index, offsetBy: 2)
            guard let byte = UInt8(trimmed[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }

    static func parseHex16(_ hex: String) -> Data? {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 32, trimmed.allSatisfy({ $0.isHexDigit }) else { return nil }
        var out = Data()
        out.reserveCapacity(16)
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(index, offsetBy: 2)
            guard let byte = UInt8(trimmed[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }

    /// Atomic replace + durable sync (file and parent directory). Fail-closed on fsync errors.
    static func atomicWritePrivate(path: URL, contents: Data) throws {
        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        do {
            try contents.write(to: path, options: .atomic)
            let committed = try FileHandle(forWritingTo: path)
            try committed.synchronize()
            try committed.close()
            try fsyncParentDirectory(parent)
        } catch {
            throw StageError.fsyncFailed
        }
    }

    static func fsyncParentDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else {
            throw StageError.fsyncFailed
        }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw StageError.fsyncFailed
        }
    }

    private static func freshNonce12() throws -> Data {
        var bytes = Data(count: 12)
        let status = bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, 12, base)
        }
        guard status == errSecSuccess else {
            throw StageError.ioFailed
        }
        return bytes
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
