//
//  ATSAMEndpointDurableAdapters.swift
//  RAVEN — concrete Keychain + SQLCipher + immutable ACK queue adapters.
//
//  Promotes Memory* test stores for Test A (DEBUG lab via RAVEN_LAB_TEST_A).
//

import Foundation
import Security
import SQLCipher

enum ATSAMEndpointDurableAdapters {
    /// DEBUG lab unlock. Release always false.
    static var labTestAEnabled: Bool {
        #if DEBUG
        ATSAMLabGate.isEnabled
        #else
        false
        #endif
    }

    @MainActor
    static let sharedProtectedStore = KeychainProtectedSessionStore()

    #if DEBUG
    @MainActor
    static var sharedAckQueue: ImmutableAckFileQueue = ImmutableAckFileQueue()
    @MainActor
    static func rebindAckQueueForTesting(_ queue: ImmutableAckFileQueue) {
        sharedAckQueue = queue
    }
    #else
    @MainActor
    static let sharedAckQueue = ImmutableAckFileQueue()
    #endif
}

// MARK: - Keychain protected ratchet head

final class KeychainProtectedSessionStore: ATSAMEndpointTransactionV1.ProtectedStateStore {
    private let service = "app.raven.ios.atsam.endpoint.protected"
    private var cache: [Data: ATSAMEndpointTransactionV1.ProtectedSessionState] = [:]

    private func account(for sessionID: Data) -> String {
        "sess|" + sessionID.map { String(format: "%02x", $0) }.joined()
    }

    func pendingSessionIDs() throws -> [Data] {
        var seen = Set<Data>()
        var result: [Data] = []
        for state in cache.values where state.pendingAcceptance != nil
            || state.pendingAckAcceptance != nil
            || state.pendingOutbound != nil {
            if seen.insert(state.sessionID).inserted {
                result.append(state.sessionID)
            }
        }
        for account in try listKeychainAccounts() where account.hasPrefix("sess|") {
            let hex = String(account.dropFirst(5))
            guard let sessionID = Self.dataFromHex(hex), sessionID.count == 32 else { continue }
            guard !seen.contains(sessionID) else { continue }
            let state = try load(sessionID: sessionID)
            guard state.pendingAcceptance != nil
                || state.pendingAckAcceptance != nil
                || state.pendingOutbound != nil else { continue }
            seen.insert(sessionID)
            result.append(sessionID)
        }
        return result
    }

    func load(sessionID: Data) throws -> ATSAMEndpointTransactionV1.ProtectedSessionState {
        if let cached = cache[sessionID] { return cached }
        guard let data = try readKeychain(account: account(for: sessionID)),
              let dto = try? JSONDecoder().decode(ProtectedDTO.self, from: data) else {
            throw ATSAMEndpointTransactionV1.TransactionError.invalidProtectedState
        }
        let state = dto.toState()
        cache[sessionID] = state
        return state
    }

    func replace(_ state: ATSAMEndpointTransactionV1.ProtectedSessionState) throws {
        let data = try JSONEncoder().encode(ProtectedDTO(state))
        try writeKeychain(account: account(for: state.sessionID), data: data)
        cache[state.sessionID] = state
    }

    func clearPending(sessionID: Data, objectDigest: Data) throws {
        var state = try load(sessionID: sessionID)
        if state.pendingAcceptance?.receiptKey.objectDigest == objectDigest {
            state.pendingAcceptance = nil
        } else if state.pendingAckAcceptance?.receiptKey.objectDigest == objectDigest {
            state.pendingAckAcceptance = nil
        } else if state.pendingOutbound?.objectDigest == objectDigest {
            state.pendingOutbound = nil
        } else {
            throw ATSAMEndpointTransactionV1.TransactionError.invalidProtectedState
        }
        try replace(state)
    }

    #if DEBUG
    /// Simulates process relaunch: drop in-memory cache so the next load reads Keychain.
    func dropMemoryCacheForRelaunchSimulation() {
        cache.removeAll()
    }

    static func deleteAllSessionsForTesting() throws {
        let service = "app.raven.ios.atsam.endpoint.protected"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess,
              let entries = items as? [[String: Any]] else { return }
        for entry in entries {
            guard let account = entry[kSecAttrAccount as String] as? String,
                  account.hasPrefix("sess|") else { continue }
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
        var bytes = Data()
        bytes.reserveCapacity(hex.count / 2)
        var cursor = hex.startIndex
        while cursor < hex.endIndex {
            let next = hex.index(cursor, offsetBy: 2)
            guard let byte = UInt8(hex[cursor..<next], radix: 16) else { return nil }
            bytes.append(byte)
            cursor = next
        }
        return bytes
    }

    private func listKeychainAccounts() throws -> [String] {
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
            throw ATSAMEndpointTransactionV1.TransactionError.invalidProtectedState
        }
        return entries.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private func readKeychain(account: String) throws -> Data? {
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
            throw ATSAMEndpointTransactionV1.TransactionError.invalidProtectedState
        }
        return data
    }

    private func writeKeychain(account: String, data: Data) throws {
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
        guard status == errSecSuccess else {
            throw ATSAMEndpointTransactionV1.TransactionError.invalidProtectedState
        }
    }
}

/// File-backed immutable ACK queue (exact-byte idempotent by `ack_object_digest`).
final class ImmutableAckFileQueue: ATSAMEndpointTransactionV1.ImmutableAckQueue {
    private let dir: URL
    private var memory: [Data: Data] = [:]

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        dir = base
            .appendingPathComponent("raven/atsam/ack-queue.v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Test-only root under a temp directory.
    init(testRoot: URL) {
        dir = testRoot.appendingPathComponent("ack-queue.v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func enqueueImmutable(objectID: Data, packedEnvelope: Data) throws {
        if let existing = memory[objectID] {
            guard existing == packedEnvelope else {
                throw ATSAMEndpointTransactionV1.TransactionError.stagedAckCollision
            }
            return
        }
        let name = objectID.map { String(format: "%02x", $0) }.joined()
        let url = dir.appendingPathComponent(name)
        if let onDisk = try? Data(contentsOf: url) {
            guard onDisk == packedEnvelope else {
                throw ATSAMEndpointTransactionV1.TransactionError.stagedAckCollision
            }
            memory[objectID] = onDisk
            return
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try packedEnvelope.write(to: url, options: .atomic)
        memory[objectID] = packedEnvelope
    }

    func contains(objectID: Data) throws -> Bool {
        if memory[objectID] != nil { return true }
        let name = objectID.map { String(format: "%02x", $0) }.joined()
        let url = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) {
            if let onDisk = try? Data(contentsOf: url) {
                memory[objectID] = onDisk
            }
            return true
        }
        return false
    }

    @discardableResult
    func deleteIfPresent(objectID: Data) throws -> Bool {
        memory.removeValue(forKey: objectID)
        let name = objectID.map { String(format: "%02x", $0) }.joined()
        let url = dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try FileManager.default.removeItem(at: url)
        return true
    }
}

// MARK: - DTO (avoids Codable on nested endpoint types)

private struct ProtectedDTO: Codable {
    var sessionID: Data
    var rootKey: Data
    var receiveChainKey: Data
    var nextReceiveIndex: UInt32
    var skippedMessageKeys: [String: Data]
    var sendChainKey: Data
    var nextSendIndex: UInt32
    var ackSendChainKey: Data
    var nextAckSendIndex: UInt32
    var ackReceiveChainKey: Data
    var nextAckReceiveIndex: UInt32
    var skippedAckKeys: [String: Data]
    var generation: UInt64
    private var pendingAcceptance: PendingAcceptanceDTO?
    private var pendingAckAcceptance: PendingAckAcceptanceDTO?
    private var pendingOutbound: PendingOutboundDTO?

    private struct ReceiptKeyDTO: Codable {
        var sessionID: Data
        var objectDigest: Data
    }

    private struct LogicalMessageKeyDTO: Codable {
        var sessionID: Data
        var senderDeviceID: Data
        var messageID: Data
    }

    private struct AckIntentDTO: Codable {
        var receiptKey: ReceiptKeyDTO
        var ackedMessageID: Data
        var expectedRemoteDeviceID: Data
        var status: UInt8
        var sessionGeneration: UInt64
        var stagedEnvelope: Data?
        var queueObjectID: Data?
        var isQueued: Bool
        var isAbandoned: Bool
    }

    private struct PendingAcceptanceDTO: Codable {
        var receiptKey: ReceiptKeyDTO
        var logicalKey: LogicalMessageKeyDTO
        var messageIndex: UInt32
        var sealedLocalInboxRow: Data
        var ackIntent: AckIntentDTO
        var sessionGeneration: UInt64
    }

    private struct PendingAckAcceptanceDTO: Codable {
        var receiptKey: ReceiptKeyDTO
        var outerMessageID: Data
        var remoteDeviceID: Data
        var ackedMessageID: Data
        var status: UInt8
        var ackNonce: Data
        var createdAtMs: UInt64
        var sessionGeneration: UInt64
    }

    private struct PendingOutboundDTO: Codable {
        var sessionID: Data
        var objectDigest: Data
        var messageID: Data
        var recipientDevice: Data
        var ratchetIndex: UInt32
        var immutableEnvelopeBytes: Data
        var sessionGeneration: UInt64
        var sourceAckIntent: Data?
    }

    init(_ state: ATSAMEndpointTransactionV1.ProtectedSessionState) {
        sessionID = state.sessionID
        rootKey = state.rootKey
        receiveChainKey = state.receiveChainKey
        nextReceiveIndex = state.nextReceiveIndex
        skippedMessageKeys = Dictionary(
            uniqueKeysWithValues: state.skippedMessageKeys.map { (String($0.key), $0.value) }
        )
        sendChainKey = state.sendChainKey
        nextSendIndex = state.nextSendIndex
        ackSendChainKey = state.ackSendChainKey
        nextAckSendIndex = state.nextAckSendIndex
        ackReceiveChainKey = state.ackReceiveChainKey
        nextAckReceiveIndex = state.nextAckReceiveIndex
        skippedAckKeys = Dictionary(
            uniqueKeysWithValues: state.skippedAckKeys.map { (String($0.key), $0.value) }
        )
        generation = state.generation
        pendingAcceptance = state.pendingAcceptance.map(Self.makePendingAcceptanceDTO)
        pendingAckAcceptance = state.pendingAckAcceptance.map(Self.makePendingAckAcceptanceDTO)
        pendingOutbound = state.pendingOutbound.map(Self.makePendingOutboundDTO)
    }

    private static func makePendingAcceptanceDTO(
        _ value: ATSAMEndpointTransactionV1.PendingAcceptance
    ) -> PendingAcceptanceDTO {
        PendingAcceptanceDTO(
            receiptKey: ReceiptKeyDTO(
                sessionID: value.receiptKey.sessionID,
                objectDigest: value.receiptKey.objectDigest
            ),
            logicalKey: LogicalMessageKeyDTO(
                sessionID: value.logicalKey.sessionID,
                senderDeviceID: value.logicalKey.senderDeviceID,
                messageID: value.logicalKey.messageID
            ),
            messageIndex: value.messageIndex,
            sealedLocalInboxRow: value.sealedLocalInboxRow,
            ackIntent: AckIntentDTO(
                receiptKey: ReceiptKeyDTO(
                    sessionID: value.ackIntent.receiptKey.sessionID,
                    objectDigest: value.ackIntent.receiptKey.objectDigest
                ),
                ackedMessageID: value.ackIntent.ackedMessageID,
                expectedRemoteDeviceID: value.ackIntent.expectedRemoteDeviceID,
                status: value.ackIntent.status.rawValue,
                sessionGeneration: value.ackIntent.sessionGeneration,
                stagedEnvelope: value.ackIntent.stagedEnvelope,
                queueObjectID: value.ackIntent.queueObjectID,
                isQueued: value.ackIntent.isQueued,
                isAbandoned: value.ackIntent.isAbandoned
            ),
            sessionGeneration: value.sessionGeneration
        )
    }

    private static func makePendingAckAcceptanceDTO(
        _ value: ATSAMEndpointTransactionV1.PendingAckAcceptance
    ) -> PendingAckAcceptanceDTO {
        PendingAckAcceptanceDTO(
            receiptKey: ReceiptKeyDTO(
                sessionID: value.receiptKey.sessionID,
                objectDigest: value.receiptKey.objectDigest
            ),
            outerMessageID: value.outerMessageID,
            remoteDeviceID: value.remoteDeviceID,
            ackedMessageID: value.ackedMessageID,
            status: value.status.rawValue,
            ackNonce: value.ackNonce,
            createdAtMs: value.createdAtMs,
            sessionGeneration: value.sessionGeneration
        )
    }

    private static func makePendingOutboundDTO(
        _ value: ATSAMEndpointTransactionV1.PendingOutbound
    ) -> PendingOutboundDTO {
        PendingOutboundDTO(
            sessionID: value.sessionID,
            objectDigest: value.objectDigest,
            messageID: value.messageID,
            recipientDevice: value.recipientDevice,
            ratchetIndex: value.ratchetIndex,
            immutableEnvelopeBytes: value.immutableEnvelopeBytes,
            sessionGeneration: value.sessionGeneration,
            sourceAckIntent: value.sourceAckIntent
        )
    }

    private static func receiptKey(_ dto: ReceiptKeyDTO) -> ATSAMEndpointTransactionV1.ReceiptKey {
        ATSAMEndpointTransactionV1.ReceiptKey(
            sessionID: dto.sessionID,
            objectDigest: dto.objectDigest
        )
    }

    private static func logicalKey(_ dto: LogicalMessageKeyDTO) -> ATSAMEndpointTransactionV1.LogicalMessageKey {
        ATSAMEndpointTransactionV1.LogicalMessageKey(
            sessionID: dto.sessionID,
            senderDeviceID: dto.senderDeviceID,
            messageID: dto.messageID
        )
    }

    private static func ackIntent(_ dto: AckIntentDTO) -> ATSAMEndpointTransactionV1.AckIntent {
        ATSAMEndpointTransactionV1.AckIntent(
            receiptKey: receiptKey(dto.receiptKey),
            ackedMessageID: dto.ackedMessageID,
            expectedRemoteDeviceID: dto.expectedRemoteDeviceID,
            status: ATSAMEndpointTransactionV1.AckStatus(rawValue: dto.status) ?? .delivered,
            sessionGeneration: dto.sessionGeneration,
            stagedEnvelope: dto.stagedEnvelope,
            queueObjectID: dto.queueObjectID,
            isQueued: dto.isQueued,
            isAbandoned: dto.isAbandoned
        )
    }

    func toState() -> ATSAMEndpointTransactionV1.ProtectedSessionState {
        var skipped: [UInt32: Data] = [:]
        for (k, v) in skippedMessageKeys {
            if let i = UInt32(k) { skipped[i] = v }
        }
        var skippedAck: [UInt32: Data] = [:]
        for (k, v) in skippedAckKeys {
            if let i = UInt32(k) { skippedAck[i] = v }
        }
        return ATSAMEndpointTransactionV1.ProtectedSessionState(
            sessionID: sessionID,
            rootKey: rootKey,
            receiveChainKey: receiveChainKey,
            nextReceiveIndex: nextReceiveIndex,
            skippedMessageKeys: skipped,
            sendChainKey: sendChainKey,
            nextSendIndex: nextSendIndex,
            ackSendChainKey: ackSendChainKey,
            nextAckSendIndex: nextAckSendIndex,
            ackReceiveChainKey: ackReceiveChainKey,
            nextAckReceiveIndex: nextAckReceiveIndex,
            skippedAckKeys: skippedAck,
            pendingAcceptance: pendingAcceptance.map {
                ATSAMEndpointTransactionV1.PendingAcceptance(
                    receiptKey: Self.receiptKey($0.receiptKey),
                    logicalKey: Self.logicalKey($0.logicalKey),
                    messageIndex: $0.messageIndex,
                    sealedLocalInboxRow: $0.sealedLocalInboxRow,
                    ackIntent: Self.ackIntent($0.ackIntent),
                    sessionGeneration: $0.sessionGeneration
                )
            },
            pendingAckAcceptance: pendingAckAcceptance.map {
                ATSAMEndpointTransactionV1.PendingAckAcceptance(
                    receiptKey: Self.receiptKey($0.receiptKey),
                    outerMessageID: $0.outerMessageID,
                    remoteDeviceID: $0.remoteDeviceID,
                    ackedMessageID: $0.ackedMessageID,
                    status: ATSAMEndpointTransactionV1.AckStatus(rawValue: $0.status) ?? .delivered,
                    ackNonce: $0.ackNonce,
                    createdAtMs: $0.createdAtMs,
                    sessionGeneration: $0.sessionGeneration
                )
            },
            pendingOutbound: pendingOutbound.map {
                ATSAMEndpointTransactionV1.PendingOutbound(
                    sessionID: $0.sessionID,
                    objectDigest: $0.objectDigest,
                    messageID: $0.messageID,
                    recipientDevice: $0.recipientDevice,
                    ratchetIndex: $0.ratchetIndex,
                    immutableEnvelopeBytes: $0.immutableEnvelopeBytes,
                    sessionGeneration: $0.sessionGeneration,
                    sourceAckIntent: $0.sourceAckIntent
                )
            },
            generation: generation
        )
    }
}

// MARK: - SQLCipher acceptance database (durable)

enum SQLCipherAcceptanceDatabaseError: Error, Equatable {
    case sqlCipherUnavailable
    case openFailed
    case encryptionKeyFailed
    case encryptionProbeFailed
    case schemaFailed
    case loadFailed
    case persistFailed
    case transactionFailed
}

/// Encrypted SQLite acceptance journal for endpoint receive/ACK/outbound.
/// Rows in `endpoint_*` tables are authoritative; in-memory maps mirror SQL
/// for fast reads within a transaction until commit/fsync.
final class SQLCipherAcceptanceDatabase: ATSAMEndpointTransactionV1.OutboundDatabase {
    typealias Endpoint = ATSAMEndpointTransactionV1

    static let schemaUserVersion: Int32 = 1
    static let productionFileName = "endpoint.v1.sqlite"

    #if DEBUG
    /// Test hook: `.some(nil)` simulates missing SQLCipher; `nil` uses real detection.
    static var _testCipherVersionOverride: String??
    #endif

    private let dbPath: String
    private let keyHex: String
    private var db: OpaquePointer?
    private var receipts: [Endpoint.ReceiptKey: Endpoint.CommittedReceipt] = [:]
    private var logicalObjects: [Endpoint.LogicalMessageKey: Data] = [:]
    private var ackIntents: [Endpoint.ReceiptKey: Endpoint.AckIntent] = [:]
    private var ackReceipts: [Endpoint.ReceiptKey: Endpoint.AckReceipt] = [:]
    private var ackNonceObjects: [Data: Data] = [:]
    private var outstanding: [Endpoint.OutstandingMessageKey: Endpoint.DeliveryState] = [:]
    private var outbox: Set<Data> = []
    private var sessionHeads: [Data: UInt64] = [:]
    private let lock = NSLock()

    convenience init() throws {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("raven/atsam", isDirectory: true)
        try self.init(directory: dir, keyHex: nil, databaseFileName: Self.productionFileName)
    }

    /// Isolated test root under a temp directory.
    convenience init(testRoot: URL, keyHex: String, databaseFileName: String = productionFileName) throws {
        let dir = testRoot.appendingPathComponent("atsam", isDirectory: true)
        try self.init(directory: dir, keyHex: keyHex, databaseFileName: databaseFileName)
    }

    private init(directory: URL, keyHex: String?, databaseFileName: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dbPath = directory.appendingPathComponent(databaseFileName).path
        self.keyHex = try keyHex ?? Self.loadOrCreateKeyHex()
        try openAndInitialize()
        try loadAllRows()
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func beginImmediate() throws -> any Endpoint.AcceptanceDatabaseTransaction {
        lock.lock()
        do {
            try exec("BEGIN IMMEDIATE;")
            return Transaction(database: self)
        } catch {
            lock.unlock()
            throw error
        }
    }

    #if DEBUG
    /// Simulates process relaunch by reloading authoritative SQL rows into memory.
    func dropMemoryCacheForRelaunchSimulation() throws {
        lock.lock()
        defer { lock.unlock() }
        receipts.removeAll()
        logicalObjects.removeAll()
        ackIntents.removeAll()
        ackReceipts.removeAll()
        ackNonceObjects.removeAll()
        outstanding.removeAll()
        outbox.removeAll()
        sessionHeads.removeAll()
        try loadAllRows()
    }
    #endif

    func loadSessionHead(sessionID: Data) throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return sessionHeads[sessionID] ?? 0
    }

    func upsertSessionHead(sessionID: Data, generation: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }
        let current = sessionHeads[sessionID] ?? 0
        guard generation >= current else { return }
        sessionHeads[sessionID] = generation
        try exec(
            """
            INSERT OR REPLACE INTO indexed_session_heads (session_id, generation)
            VALUES (?, ?);
            """,
            bind: { stmt in
                try Self.bindBlob(stmt, 1, sessionID)
                sqlite3_bind_int64(stmt, 2, Int64(generation))
            }
        )
        try fsyncLocked()
    }

    #if DEBUG
    /// Test hook: simulate crash before ACK bytes were staged in SQL.
    func clearAckStagedEnvelope(receiptKey: Endpoint.ReceiptKey) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var intent = ackIntents[receiptKey] else {
            throw Endpoint.TransactionError.noPendingAck
        }
        intent.stagedEnvelope = nil
        intent.queueObjectID = nil
        intent.isQueued = false
        ackIntents[receiptKey] = intent
        try persistAckIntentLocked(receiptKey: receiptKey, intent: intent)
        try fsyncLocked()
    }

    /// Test hook: force durable head (role-flip harnesses).
    func setSessionHeadForTesting(sessionID: Data, generation: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }
        sessionHeads[sessionID] = generation
        try exec(
            """
            INSERT OR REPLACE INTO indexed_session_heads (session_id, generation)
            VALUES (?, ?);
            """,
            bind: { stmt in
                try Self.bindBlob(stmt, 1, sessionID)
                sqlite3_bind_int64(stmt, 2, Int64(generation))
            }
        )
        try fsyncLocked()
    }
    #endif

    func ackReceiptCount() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        return ackReceipts.count
    }

        func nextUnqueuedAckIntent() throws -> Endpoint.AckIntent? {
            lock.lock(); defer { lock.unlock() }
            return ackIntents.values.first { !$0.isQueued && !$0.isAbandoned }
        }

        func allAckIntents() throws -> [Endpoint.AckIntent] {
            lock.lock(); defer { lock.unlock() }
            return Array(ackIntents.values)
        }

        func markAckAbandoned(receiptKey: Endpoint.ReceiptKey) throws {
            lock.lock(); defer { lock.unlock() }
            guard var intent = ackIntents[receiptKey] else {
                throw Endpoint.TransactionError.noPendingAck
            }
            intent.isAbandoned = true
            intent.isQueued = false
            ackIntents[receiptKey] = intent
            try persistAckIntentLocked(receiptKey: receiptKey, intent: intent)
            try fsyncLocked()
        }

    func stageAckEnvelope(
        receiptKey: Endpoint.ReceiptKey,
        packedEnvelope: Data,
        queueObjectID: Data
    ) throws -> Endpoint.AckIntent {
        lock.lock(); defer { lock.unlock() }
        guard var intent = ackIntents[receiptKey], !intent.isQueued, !intent.isAbandoned else {
            throw Endpoint.TransactionError.noPendingAck
        }
        if let existingEnvelope = intent.stagedEnvelope {
            guard existingEnvelope == packedEnvelope,
                  intent.queueObjectID == queueObjectID else {
                throw Endpoint.TransactionError.stagedAckCollision
            }
            return intent
        }
        intent.stagedEnvelope = packedEnvelope
        intent.queueObjectID = queueObjectID
        ackIntents[receiptKey] = intent
        try persistAckIntentLocked(receiptKey: receiptKey, intent: intent)
        try fsyncLocked()
        return intent
    }

    func markAckQueued(receiptKey: Endpoint.ReceiptKey, queueObjectID: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard var intent = ackIntents[receiptKey],
              !intent.isAbandoned,
              intent.stagedEnvelope != nil,
              intent.queueObjectID == queueObjectID else {
            throw Endpoint.TransactionError.stagedAckCollision
        }
        intent.isQueued = true
        ackIntents[receiptKey] = intent
        try persistAckIntentLocked(receiptKey: receiptKey, intent: intent)
        try fsyncLocked()
    }

    func hasOutboxRow(sessionID: Data, objectDigest: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        var key = Data()
        key.append(sessionID)
        key.append(objectDigest)
        return outbox.contains(key)
    }

    // MARK: - Test seeding

    func outstandingDeliveryStatesForTesting() throws -> [Endpoint.OutstandingMessageKey: Endpoint.DeliveryState] {
        lock.lock(); defer { lock.unlock() }
        return outstanding
    }

    func seedOutstandingRow(
        key: Endpoint.OutstandingMessageKey,
        state: Endpoint.DeliveryState
    ) throws {
        lock.lock(); defer { lock.unlock() }
        outstanding[key] = state
        try exec(
            """
            INSERT OR REPLACE INTO endpoint_outstanding_messages
              (session_id, message_id, recipient_device, delivery_state)
            VALUES (?, ?, ?, ?);
            """,
            bind: { stmt in
                try Self.bindBlob(stmt, 1, key.sessionID)
                try Self.bindBlob(stmt, 2, key.messageID)
                try Self.bindBlob(stmt, 3, key.recipientDeviceID)
                sqlite3_bind_int(stmt, 4, Int32(state.rawValue))
            }
        )
        try fsyncLocked()
    }

    // MARK: - Transaction internals

    fileprivate func unlockAfterTransaction() {
        lock.unlock()
    }

    fileprivate func commitTransaction(
        pending: Endpoint.PendingAcceptance?,
        pendingAck: Endpoint.PendingAckAcceptance?,
        pendingOutbound: Endpoint.PendingOutbound? = nil,
        pendingAckMaterialization: (
            receiptKey: Endpoint.ReceiptKey,
            packedEnvelope: Data,
            ackObjectDigest: Data
        )? = nil
    ) throws {
        if let value = pending {
            if let logicalDigest = logicalObjects[value.logicalKey],
               logicalDigest != value.receiptKey.objectDigest {
                throw Endpoint.TransactionError.logicalMessageCollision
            }
            let receipt = Endpoint.CommittedReceipt(
                receiptKey: value.receiptKey,
                logicalKey: value.logicalKey,
                messageIndex: value.messageIndex,
                sealedLocalInboxRow: value.sealedLocalInboxRow,
                sessionGeneration: value.sessionGeneration
            )
            receipts[value.receiptKey] = receipt
            logicalObjects[value.logicalKey] = value.receiptKey.objectDigest
            ackIntents[value.receiptKey] = value.ackIntent
            try persistAcceptanceLocked(pending: value, receipt: receipt)
        }
        if let value = pendingAck {
            let outstandingKey = Endpoint.OutstandingMessageKey(
                sessionID: value.receiptKey.sessionID,
                messageID: value.ackedMessageID,
                recipientDeviceID: value.remoteDeviceID
            )
            guard let current = outstanding[outstandingKey] else {
                throw Endpoint.TransactionError.ackOutstandingMismatch
            }
            let target = Endpoint.DeliveryState(rawValue: value.status.rawValue)!
            let finalState = max(current, target)
            let nonceKey = Self.ackNonceKey(
                sessionID: value.receiptKey.sessionID,
                remoteDeviceID: value.remoteDeviceID,
                ackNonce: value.ackNonce
            )
            if let existingObject = ackNonceObjects[nonceKey],
               existingObject != value.receiptKey.objectDigest {
                throw Endpoint.TransactionError.ackNonceConflict
            }
            let ackReceipt = Endpoint.AckReceipt(
                receiptKey: value.receiptKey,
                outerMessageID: value.outerMessageID,
                remoteDeviceID: value.remoteDeviceID,
                ackedMessageID: value.ackedMessageID,
                status: value.status,
                ackNonce: value.ackNonce,
                createdAtMs: value.createdAtMs,
                sessionGeneration: value.sessionGeneration
            )
            if let existing = ackReceipts[value.receiptKey], existing != ackReceipt {
                throw Endpoint.TransactionError.receiptCollision
            }
            let insertReceipt = ackReceipts[value.receiptKey] == nil
            ackReceipts[value.receiptKey] = ackReceipt
            ackNonceObjects[nonceKey] = value.receiptKey.objectDigest
            outstanding[outstandingKey] = finalState
            try persistAckAcceptanceLocked(
                pending: value,
                receipt: ackReceipt,
                deliveryState: finalState,
                insertReceipt: insertReceipt
            )
        }
        if let value = pendingOutbound {
            var key = Data()
            key.append(value.sessionID)
            key.append(value.objectDigest)
            outbox.insert(key)
            try exec(
                """
                INSERT OR REPLACE INTO endpoint_outbox
                  (session_id, object_digest)
                VALUES (?, ?);
                """,
                bind: { stmt in
                    try Self.bindBlob(stmt, 1, value.sessionID)
                    try Self.bindBlob(stmt, 2, value.objectDigest)
                }
            )
            // Message outbounds register an exact outstanding Sent row (Rust parity).
            // ACK outbounds bind via sourceAckIntent and must not create outstanding.
            if value.sourceAckIntent == nil {
                let outstandingKey = Endpoint.OutstandingMessageKey(
                    sessionID: value.sessionID,
                    messageID: value.messageID,
                    recipientDeviceID: value.recipientDevice
                )
                try exec(
                    """
                    INSERT INTO endpoint_outstanding_messages
                      (session_id, message_id, recipient_device, delivery_state)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(session_id, message_id, recipient_device) DO NOTHING;
                    """,
                    bind: { stmt in
                        try Self.bindBlob(stmt, 1, outstandingKey.sessionID)
                        try Self.bindBlob(stmt, 2, outstandingKey.messageID)
                        try Self.bindBlob(stmt, 3, outstandingKey.recipientDeviceID)
                        sqlite3_bind_int(stmt, 4, Int32(Endpoint.DeliveryState.sent.rawValue))
                    }
                )
                if outstanding[outstandingKey] == nil {
                    outstanding[outstandingKey] = .sent
                }
                guard outstanding[outstandingKey] == .sent else {
                    throw Endpoint.TransactionError.outboundPending
                }
            }
            if let materialization = pendingAckMaterialization {
                guard var intent = ackIntents[materialization.receiptKey],
                      !intent.isQueued,
                      !intent.isAbandoned else {
                    throw Endpoint.TransactionError.noPendingAck
                }
                if let existing = intent.stagedEnvelope {
                    guard existing == materialization.packedEnvelope,
                          intent.queueObjectID == materialization.ackObjectDigest else {
                        throw Endpoint.TransactionError.stagedAckCollision
                    }
                } else {
                    intent.stagedEnvelope = materialization.packedEnvelope
                    intent.queueObjectID = materialization.ackObjectDigest
                }
                ackIntents[materialization.receiptKey] = intent
                try persistAckIntentLocked(
                    receiptKey: materialization.receiptKey,
                    intent: intent
                )
            }
        }
        try exec("COMMIT;")
        try fsyncLocked()
    }

    fileprivate func rollbackTransaction() throws {
        try exec("ROLLBACK;")
    }

    fileprivate func existingReceiptLocked(
        receiptKey: Endpoint.ReceiptKey,
        logicalKey: Endpoint.LogicalMessageKey
    ) throws -> Endpoint.CommittedReceipt? {
        if let receipt = receipts[receiptKey] {
            guard receipt.logicalKey == logicalKey else {
                throw Endpoint.TransactionError.receiptCollision
            }
            return receipt
        }
        if let digest = logicalObjects[logicalKey] {
            guard digest == receiptKey.objectDigest else {
                throw Endpoint.TransactionError.logicalMessageCollision
            }
            throw Endpoint.TransactionError.receiptCollision
        }
        return nil
    }

    fileprivate func snapshotMaps() -> (
        receipts: [Endpoint.ReceiptKey: Endpoint.CommittedReceipt],
        logicalObjects: [Endpoint.LogicalMessageKey: Data],
        ackIntents: [Endpoint.ReceiptKey: Endpoint.AckIntent],
        ackReceipts: [Endpoint.ReceiptKey: Endpoint.AckReceipt],
        ackNonceObjects: [Data: Data],
        outstanding: [Endpoint.OutstandingMessageKey: Endpoint.DeliveryState]
    ) {
        (receipts, logicalObjects, ackIntents, ackReceipts, ackNonceObjects, outstanding)
    }

    // MARK: - Open / schema

    private func openAndInitialize() throws {
        if FileManager.default.fileExists(atPath: dbPath) {
            try Self.rejectPlaintextSQLiteFile(at: dbPath)
        }
        var handle: OpaquePointer?
        guard sqlite3_open(dbPath, &handle) == SQLITE_OK, let handle else {
            throw SQLCipherAcceptanceDatabaseError.openFailed
        }
        do {
            try Self.applyEncryption(to: handle, keyHex: keyHex)
            db = handle
            try ensureSchema()
            _ = sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    private static func rejectPlaintextSQLiteFile(at path: String) throws {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let header = handle.readData(ofLength: 16)
        guard header.count >= 15 else { return }
        if header.starts(with: Data("SQLite format 3".utf8)) {
            throw SQLCipherAcceptanceDatabaseError.encryptionProbeFailed
        }
    }

    private static func applyEncryption(to db: OpaquePointer, keyHex: String) throws {
        guard let version = detectSQLCipherVersion(on: db), !version.isEmpty else {
            throw SQLCipherAcceptanceDatabaseError.sqlCipherUnavailable
        }
        _ = version

        var errorMessage: UnsafeMutablePointer<CChar>?
        let keySQL = "PRAGMA key = \"x'\(keyHex)'\";"
        guard sqlite3_exec(db, keySQL, nil, nil, &errorMessage) == SQLITE_OK else {
            if let errorMessage {
                sqlite3_free(errorMessage)
            }
            throw SQLCipherAcceptanceDatabaseError.encryptionKeyFailed
        }

        let hardenSQL = "PRAGMA cipher_compatibility = 4;"
        guard sqlite3_exec(db, hardenSQL, nil, nil, &errorMessage) == SQLITE_OK else {
            if let errorMessage {
                sqlite3_free(errorMessage)
            }
            throw SQLCipherAcceptanceDatabaseError.encryptionKeyFailed
        }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let probe = sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master;", -1, &stmt, nil)
        guard probe == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else {
            throw SQLCipherAcceptanceDatabaseError.encryptionProbeFailed
        }
    }

    private static func detectSQLCipherVersion(on db: OpaquePointer) -> String? {
        #if DEBUG
        if let override = _testCipherVersionOverride {
            return override
        }
        #endif
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA cipher_version;", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let valuePtr = sqlite3_column_text(stmt, 0) else {
            return nil
        }
        let version = String(cString: valuePtr).trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    private func ensureSchema() throws {
        guard let db else { throw SQLCipherAcceptanceDatabaseError.schemaFailed }

        var userVersion: Int32 = 0
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else {
            throw SQLCipherAcceptanceDatabaseError.schemaFailed
        }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            userVersion = sqlite3_column_int(stmt, 0)
        }
        sqlite3_finalize(stmt)
        stmt = nil

        if userVersion == 0 {
            try exec(Self.createSchemaV1SQL)
            try exec("PRAGMA user_version = \(Self.schemaUserVersion);")
        } else if userVersion != Self.schemaUserVersion {
            throw SQLCipherAcceptanceDatabaseError.schemaFailed
        }
    }

    private static let createSchemaV1SQL = """
        CREATE TABLE IF NOT EXISTS indexed_session_heads (
          session_id BLOB NOT NULL PRIMARY KEY CHECK(length(session_id) = 32),
          generation INTEGER NOT NULL CHECK(generation >= 0)
        );
        CREATE TABLE IF NOT EXISTS endpoint_receipts (
          session_id BLOB NOT NULL CHECK(length(session_id) = 32),
          object_digest BLOB NOT NULL CHECK(length(object_digest) = 32),
          message_id BLOB NOT NULL CHECK(length(message_id) = 16),
          sender_device BLOB NOT NULL CHECK(length(sender_device) = 32),
          message_index INTEGER NOT NULL CHECK(message_index >= 0),
          session_generation INTEGER NOT NULL CHECK(session_generation >= 0),
          PRIMARY KEY(session_id, object_digest),
          UNIQUE(session_id, sender_device, message_id)
        );
        CREATE TABLE IF NOT EXISTS endpoint_inbox (
          session_id BLOB NOT NULL CHECK(length(session_id) = 32),
          object_digest BLOB NOT NULL CHECK(length(object_digest) = 32),
          sealed_local_row BLOB NOT NULL,
          PRIMARY KEY(session_id, object_digest)
        );
        CREATE TABLE IF NOT EXISTS endpoint_ack_intents (
          session_id BLOB NOT NULL CHECK(length(session_id) = 32),
          object_digest BLOB NOT NULL CHECK(length(object_digest) = 32),
          message_id BLOB NOT NULL CHECK(length(message_id) = 16),
          remote_device BLOB NOT NULL CHECK(length(remote_device) = 32),
          status INTEGER NOT NULL CHECK(status IN (1, 2)),
          state INTEGER NOT NULL CHECK(state IN (0, 1, 2)),
          immutable_ack_bytes BLOB,
          queue_object_id BLOB,
          session_generation INTEGER NOT NULL CHECK(session_generation >= 0),
          PRIMARY KEY(session_id, object_digest)
        );
        CREATE TABLE IF NOT EXISTS endpoint_ack_receipts (
          session_id BLOB NOT NULL CHECK(length(session_id) = 32),
          object_digest BLOB NOT NULL CHECK(length(object_digest) = 32),
          outer_message_id BLOB NOT NULL CHECK(length(outer_message_id) = 16),
          remote_device BLOB NOT NULL CHECK(length(remote_device) = 32),
          acked_message_id BLOB NOT NULL CHECK(length(acked_message_id) = 16),
          status INTEGER NOT NULL CHECK(status IN (1, 2)),
          ack_nonce BLOB NOT NULL CHECK(length(ack_nonce) = 12),
          created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
          session_generation INTEGER NOT NULL CHECK(session_generation >= 0),
          PRIMARY KEY(session_id, object_digest),
          UNIQUE(session_id, remote_device, ack_nonce)
        );
        CREATE TABLE IF NOT EXISTS endpoint_outstanding_messages (
          session_id BLOB NOT NULL CHECK(length(session_id) = 32),
          message_id BLOB NOT NULL CHECK(length(message_id) = 16),
          recipient_device BLOB NOT NULL CHECK(length(recipient_device) = 32),
          delivery_state INTEGER NOT NULL CHECK(delivery_state IN (0, 1, 2)),
          PRIMARY KEY(session_id, message_id, recipient_device)
        );
        CREATE TABLE IF NOT EXISTS endpoint_outbox (
          session_id BLOB NOT NULL CHECK(length(session_id) = 32),
          object_digest BLOB NOT NULL CHECK(length(object_digest) = 32),
          PRIMARY KEY(session_id, object_digest)
        );
        """

    // MARK: - Load

    private func loadAllRows() throws {
        receipts.removeAll(keepingCapacity: true)
        logicalObjects.removeAll(keepingCapacity: true)
        ackIntents.removeAll(keepingCapacity: true)
        ackReceipts.removeAll(keepingCapacity: true)
        ackNonceObjects.removeAll(keepingCapacity: true)
        outstanding.removeAll(keepingCapacity: true)
        outbox.removeAll(keepingCapacity: true)
        sessionHeads.removeAll(keepingCapacity: true)

        try query(
            """
            SELECT session_id, generation FROM indexed_session_heads;
            """
        ) { stmt in
            let sessionID = try Self.columnBlob(stmt, 0)
            let generation = UInt64(sqlite3_column_int64(stmt, 1))
            sessionHeads[sessionID] = generation
        }

        try query(
            """
            SELECT r.session_id, r.object_digest, r.message_id, r.sender_device,
                   r.message_index, r.session_generation, i.sealed_local_row
            FROM endpoint_receipts r
            JOIN endpoint_inbox i
              ON r.session_id = i.session_id AND r.object_digest = i.object_digest;
            """
        ) { stmt in
            let sessionID = try Self.columnBlob(stmt, 0)
            let objectDigest = try Self.columnBlob(stmt, 1)
            let messageID = try Self.columnBlob(stmt, 2)
            let senderDevice = try Self.columnBlob(stmt, 3)
            let messageIndex = UInt32(sqlite3_column_int(stmt, 4))
            let sessionGeneration = UInt64(sqlite3_column_int64(stmt, 5))
            let sealedRow = try Self.columnBlob(stmt, 6)

            let receiptKey = Endpoint.ReceiptKey(sessionID: sessionID, objectDigest: objectDigest)
            let logicalKey = Endpoint.LogicalMessageKey(
                sessionID: sessionID,
                senderDeviceID: senderDevice,
                messageID: messageID
            )
            let receipt = Endpoint.CommittedReceipt(
                receiptKey: receiptKey,
                logicalKey: logicalKey,
                messageIndex: messageIndex,
                sealedLocalInboxRow: sealedRow,
                sessionGeneration: sessionGeneration
            )
            receipts[receiptKey] = receipt
            logicalObjects[logicalKey] = objectDigest
        }

        try query(
            """
            SELECT session_id, object_digest, message_id, remote_device, status, state,
                   immutable_ack_bytes, queue_object_id, session_generation
            FROM endpoint_ack_intents;
            """
        ) { stmt in
            let sessionID = try Self.columnBlob(stmt, 0)
            let objectDigest = try Self.columnBlob(stmt, 1)
            let messageID = try Self.columnBlob(stmt, 2)
            let remoteDevice = try Self.columnBlob(stmt, 3)
            guard let status = Endpoint.AckStatus(rawValue: UInt8(sqlite3_column_int(stmt, 4))) else {
                throw SQLCipherAcceptanceDatabaseError.loadFailed
            }
            let stateRaw = sqlite3_column_int(stmt, 5)
            let staged = Self.optionalColumnBlob(stmt, 6)
            let queueObjectID = Self.optionalColumnBlob(stmt, 7)
            let sessionGeneration = UInt64(sqlite3_column_int64(stmt, 8))
            let receiptKey = Endpoint.ReceiptKey(sessionID: sessionID, objectDigest: objectDigest)
            ackIntents[receiptKey] = Endpoint.AckIntent(
                receiptKey: receiptKey,
                ackedMessageID: messageID,
                expectedRemoteDeviceID: remoteDevice,
                status: status,
                sessionGeneration: sessionGeneration,
                stagedEnvelope: staged,
                queueObjectID: queueObjectID,
                isQueued: stateRaw == 1,
                isAbandoned: stateRaw == 2
            )
        }

        try query(
            """
            SELECT session_id, object_digest, outer_message_id, remote_device,
                   acked_message_id, status, ack_nonce, created_at_ms, session_generation
            FROM endpoint_ack_receipts;
            """
        ) { stmt in
            let sessionID = try Self.columnBlob(stmt, 0)
            let objectDigest = try Self.columnBlob(stmt, 1)
            let outerMessageID = try Self.columnBlob(stmt, 2)
            let remoteDevice = try Self.columnBlob(stmt, 3)
            let ackedMessageID = try Self.columnBlob(stmt, 4)
            guard let status = Endpoint.AckStatus(rawValue: UInt8(sqlite3_column_int(stmt, 5))) else {
                throw SQLCipherAcceptanceDatabaseError.loadFailed
            }
            let ackNonce = try Self.columnBlob(stmt, 6)
            let createdAtMs = UInt64(sqlite3_column_int64(stmt, 7))
            let sessionGeneration = UInt64(sqlite3_column_int64(stmt, 8))
            let receiptKey = Endpoint.ReceiptKey(sessionID: sessionID, objectDigest: objectDigest)
            ackReceipts[receiptKey] = Endpoint.AckReceipt(
                receiptKey: receiptKey,
                outerMessageID: outerMessageID,
                remoteDeviceID: remoteDevice,
                ackedMessageID: ackedMessageID,
                status: status,
                ackNonce: ackNonce,
                createdAtMs: createdAtMs,
                sessionGeneration: sessionGeneration
            )
            let nonceKey = Self.ackNonceKey(
                sessionID: sessionID,
                remoteDeviceID: remoteDevice,
                ackNonce: ackNonce
            )
            ackNonceObjects[nonceKey] = objectDigest
        }

        try query(
            """
            SELECT session_id, message_id, recipient_device, delivery_state
            FROM endpoint_outstanding_messages;
            """
        ) { stmt in
            let sessionID = try Self.columnBlob(stmt, 0)
            let messageID = try Self.columnBlob(stmt, 1)
            let recipientDevice = try Self.columnBlob(stmt, 2)
            guard let state = Endpoint.DeliveryState(rawValue: UInt8(sqlite3_column_int(stmt, 3))) else {
                throw SQLCipherAcceptanceDatabaseError.loadFailed
            }
            outstanding[Endpoint.OutstandingMessageKey(
                sessionID: sessionID,
                messageID: messageID,
                recipientDeviceID: recipientDevice
            )] = state
        }

        try query(
            """
            SELECT session_id, object_digest FROM endpoint_outbox;
            """
        ) { stmt in
            let sessionID = try Self.columnBlob(stmt, 0)
            let objectDigest = try Self.columnBlob(stmt, 1)
            var key = Data()
            key.append(sessionID)
            key.append(objectDigest)
            outbox.insert(key)
        }
    }

    // MARK: - Persist rows

    private func persistAcceptanceLocked(
        pending: Endpoint.PendingAcceptance,
        receipt: Endpoint.CommittedReceipt
    ) throws {
        try exec(
            """
            INSERT OR REPLACE INTO endpoint_receipts
              (session_id, object_digest, message_id, sender_device, message_index, session_generation)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            bind: { stmt in
                try Self.bindBlob(stmt, 1, pending.receiptKey.sessionID)
                try Self.bindBlob(stmt, 2, pending.receiptKey.objectDigest)
                try Self.bindBlob(stmt, 3, pending.logicalKey.messageID)
                try Self.bindBlob(stmt, 4, pending.logicalKey.senderDeviceID)
                sqlite3_bind_int(stmt, 5, Int32(pending.messageIndex))
                sqlite3_bind_int64(stmt, 6, Int64(pending.sessionGeneration))
            }
        )
        try exec(
            """
            INSERT OR REPLACE INTO endpoint_inbox
              (session_id, object_digest, sealed_local_row)
            VALUES (?, ?, ?);
            """,
            bind: { stmt in
                try Self.bindBlob(stmt, 1, pending.receiptKey.sessionID)
                try Self.bindBlob(stmt, 2, pending.receiptKey.objectDigest)
                try Self.bindBlob(stmt, 3, pending.sealedLocalInboxRow)
            }
        )
        try persistAckIntentLocked(receiptKey: pending.receiptKey, intent: pending.ackIntent)
    }

    private func persistAckIntentLocked(
        receiptKey: Endpoint.ReceiptKey,
        intent: Endpoint.AckIntent
    ) throws {
        try exec(
            """
            INSERT OR REPLACE INTO endpoint_ack_intents
              (session_id, object_digest, message_id, remote_device, status, state,
               immutable_ack_bytes, queue_object_id, session_generation)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bind: { stmt in
                try Self.bindBlob(stmt, 1, receiptKey.sessionID)
                try Self.bindBlob(stmt, 2, receiptKey.objectDigest)
                try Self.bindBlob(stmt, 3, intent.ackedMessageID)
                try Self.bindBlob(stmt, 4, intent.expectedRemoteDeviceID)
                sqlite3_bind_int(stmt, 5, Int32(intent.status.rawValue))
                let stateValue: Int32
                if intent.isAbandoned {
                    stateValue = 2
                } else if intent.isQueued {
                    stateValue = 1
                } else {
                    stateValue = 0
                }
                sqlite3_bind_int(stmt, 6, stateValue)
                if let staged = intent.stagedEnvelope {
                    try Self.bindBlob(stmt, 7, staged)
                } else {
                    sqlite3_bind_null(stmt, 7)
                }
                if let queueObjectID = intent.queueObjectID {
                    try Self.bindBlob(stmt, 8, queueObjectID)
                } else {
                    sqlite3_bind_null(stmt, 8)
                }
                sqlite3_bind_int64(stmt, 9, Int64(intent.sessionGeneration))
            }
        )
    }

    private func persistAckAcceptanceLocked(
        pending: Endpoint.PendingAckAcceptance,
        receipt: Endpoint.AckReceipt,
        deliveryState: Endpoint.DeliveryState,
        insertReceipt: Bool
    ) throws {
        if insertReceipt {
            try exec(
                """
                INSERT INTO endpoint_ack_receipts
                  (session_id, object_digest, outer_message_id, remote_device, acked_message_id,
                   status, ack_nonce, created_at_ms, session_generation)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                bind: { stmt in
                    try Self.bindBlob(stmt, 1, pending.receiptKey.sessionID)
                    try Self.bindBlob(stmt, 2, pending.receiptKey.objectDigest)
                    try Self.bindBlob(stmt, 3, pending.outerMessageID)
                    try Self.bindBlob(stmt, 4, pending.remoteDeviceID)
                    try Self.bindBlob(stmt, 5, pending.ackedMessageID)
                    sqlite3_bind_int(stmt, 6, Int32(pending.status.rawValue))
                    try Self.bindBlob(stmt, 7, pending.ackNonce)
                    sqlite3_bind_int64(stmt, 8, Int64(pending.createdAtMs))
                    sqlite3_bind_int64(stmt, 9, Int64(pending.sessionGeneration))
                }
            )
        }
        try exec(
            """
            UPDATE endpoint_outstanding_messages
            SET delivery_state = ?
            WHERE session_id = ?
              AND message_id = ?
              AND recipient_device = ?
              AND delivery_state <= ?;
            """,
            bind: { stmt in
                sqlite3_bind_int(stmt, 1, Int32(deliveryState.rawValue))
                try Self.bindBlob(stmt, 2, pending.receiptKey.sessionID)
                try Self.bindBlob(stmt, 3, pending.ackedMessageID)
                try Self.bindBlob(stmt, 4, pending.remoteDeviceID)
                sqlite3_bind_int(stmt, 5, Int32(deliveryState.rawValue))
            }
        )
        guard sqlite3_changes(db) == 1 else {
            throw Endpoint.TransactionError.ackOutstandingMismatch
        }
        _ = receipt
    }

    private func fsyncLocked() throws {
        try exec("PRAGMA wal_checkpoint(FULL);")
    }

    // MARK: - SQLite helpers

    private func exec(
        _ sql: String,
        bind: ((OpaquePointer) throws -> Void)? = nil
    ) throws {
        guard let db else { throw SQLCipherAcceptanceDatabaseError.persistFailed }
        if let bind {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw SQLCipherAcceptanceDatabaseError.persistFailed
            }
            defer { sqlite3_finalize(stmt) }
            try bind(stmt)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw SQLCipherAcceptanceDatabaseError.persistFailed
            }
        } else {
            var errorMessage: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
                if let errorMessage {
                    sqlite3_free(errorMessage)
                }
                throw SQLCipherAcceptanceDatabaseError.persistFailed
            }
        }
    }

    private func query(
        _ sql: String,
        row: (OpaquePointer) throws -> Void
    ) throws {
        guard let db else { throw SQLCipherAcceptanceDatabaseError.loadFailed }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLCipherAcceptanceDatabaseError.loadFailed
        }
        defer { sqlite3_finalize(stmt) }
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw SQLCipherAcceptanceDatabaseError.loadFailed
            }
            try row(stmt)
        }
    }

    private static func bindBlob(_ stmt: OpaquePointer, _ index: Int32, _ data: Data) throws {
        let rc = data.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, index, ptr.baseAddress, Int32(data.count), nil)
        }
        guard rc == SQLITE_OK else {
            throw SQLCipherAcceptanceDatabaseError.persistFailed
        }
    }

    private static func columnBlob(_ stmt: OpaquePointer, _ index: Int32) throws -> Data {
        guard let bytes = sqlite3_column_blob(stmt, index) else {
            throw SQLCipherAcceptanceDatabaseError.loadFailed
        }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, index)))
    }

    private static func optionalColumnBlob(_ stmt: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(stmt, index) else {
            return nil
        }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, index)))
    }

    private static func ackNonceKey(
        sessionID: Data,
        remoteDeviceID: Data,
        ackNonce: Data
    ) -> Data {
        var out = Data()
        out.append(sessionID)
        out.append(remoteDeviceID)
        out.append(ackNonce)
        return out
    }

    private static func loadOrCreateKeyHex() throws -> String {
        let service = "app.raven.ios.atsam.endpoint.db"
        let account = "sqlcipher.key.v1"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, data.count == 32 {
            return data.map { String(format: "%02x", $0) }.joined()
        }
        var key = Data(count: 32)
        key.withUnsafeMutableBytes { buf in
            _ = SecRandomCopyBytes(kSecRandomDefault, 32, buf.baseAddress!)
        }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: key,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SQLCipherAcceptanceDatabaseError.encryptionKeyFailed
        }
        return key.map { String(format: "%02x", $0) }.joined()
    }

    private final class Transaction: Endpoint.OutboundDatabaseTransaction {
        private unowned let database: SQLCipherAcceptanceDatabase
        private var pending: Endpoint.PendingAcceptance?
        private var pendingAck: Endpoint.PendingAckAcceptance?
        private var pendingOutbound: Endpoint.PendingOutbound?
        private var pendingAckMaterialization: (
            receiptKey: Endpoint.ReceiptKey,
            packedEnvelope: Data,
            ackObjectDigest: Data
        )?
        private var active = true

        init(database: SQLCipherAcceptanceDatabase) {
            self.database = database
        }

        func existingReceipt(
            receiptKey: Endpoint.ReceiptKey,
            logicalKey: Endpoint.LogicalMessageKey
        ) throws -> Endpoint.CommittedReceipt? {
            guard active else { throw Endpoint.TransactionError.invalidProtectedState }
            return try database.existingReceiptLocked(receiptKey: receiptKey, logicalKey: logicalKey)
        }

        func existingAckReceipt(
            receiptKey: Endpoint.ReceiptKey,
            outerMessageID: Data,
            remoteDeviceID: Data
        ) throws -> Endpoint.AckReceipt? {
            guard active else { throw Endpoint.TransactionError.invalidProtectedState }
            let maps = database.snapshotMaps()
            guard let receipt = maps.ackReceipts[receiptKey] else { return nil }
            guard receipt.outerMessageID == outerMessageID,
                  receipt.remoteDeviceID == remoteDeviceID else {
                throw Endpoint.TransactionError.receiptCollision
            }
            return receipt
        }

        func outstandingDeliveryState(
            _ key: Endpoint.OutstandingMessageKey
        ) throws -> Endpoint.DeliveryState? {
            guard active else { throw Endpoint.TransactionError.invalidProtectedState }
            return database.snapshotMaps().outstanding[key]
        }

        func ackNonceObjectDigest(
            sessionID: Data,
            remoteDeviceID: Data,
            ackNonce: Data
        ) throws -> Data? {
            guard active else { throw Endpoint.TransactionError.invalidProtectedState }
            let k = SQLCipherAcceptanceDatabase.ackNonceKey(
                sessionID: sessionID,
                remoteDeviceID: remoteDeviceID,
                ackNonce: ackNonce
            )
            return database.snapshotMaps().ackNonceObjects[k]
        }

        func insertAcceptance(
            _ value: Endpoint.PendingAcceptance
        ) throws -> Endpoint.InsertOutcome {
            if let existing = try existingReceipt(
                receiptKey: value.receiptKey,
                logicalKey: value.logicalKey
            ) {
                return .exactDuplicate(existing)
            }
            guard pending == nil else {
                throw Endpoint.TransactionError.receiptCollision
            }
            pending = value
            return .inserted(
                Endpoint.CommittedReceipt(
                    receiptKey: value.receiptKey,
                    logicalKey: value.logicalKey,
                    messageIndex: value.messageIndex,
                    sealedLocalInboxRow: value.sealedLocalInboxRow,
                    sessionGeneration: value.sessionGeneration
                )
            )
        }

        func insertAckAcceptance(
            _ value: Endpoint.PendingAckAcceptance
        ) throws -> Endpoint.AckInsertOutcome {
            guard active else { throw Endpoint.TransactionError.receiptCollision }
            let outstandingKey = Endpoint.OutstandingMessageKey(
                sessionID: value.receiptKey.sessionID,
                messageID: value.ackedMessageID,
                recipientDeviceID: value.remoteDeviceID
            )
            guard let current = try outstandingDeliveryState(outstandingKey) else {
                throw Endpoint.TransactionError.ackOutstandingMismatch
            }
            let receipt = Endpoint.AckReceipt(
                receiptKey: value.receiptKey,
                outerMessageID: value.outerMessageID,
                remoteDeviceID: value.remoteDeviceID,
                ackedMessageID: value.ackedMessageID,
                status: value.status,
                ackNonce: value.ackNonce,
                createdAtMs: value.createdAtMs,
                sessionGeneration: value.sessionGeneration
            )
            let target = Endpoint.DeliveryState(rawValue: value.status.rawValue)!
            if let existing = try existingAckReceipt(
                receiptKey: value.receiptKey,
                outerMessageID: value.outerMessageID,
                remoteDeviceID: value.remoteDeviceID
            ) {
                guard existing == receipt else {
                    throw Endpoint.TransactionError.receiptCollision
                }
                let finalState = max(current, target)
                if finalState != current {
                    guard pendingAck == nil else { throw Endpoint.TransactionError.receiptCollision }
                    pendingAck = value
                }
                return .exactDuplicate(receipt: existing, deliveryState: finalState)
            }
            if let existingObject = try ackNonceObjectDigest(
                sessionID: value.receiptKey.sessionID,
                remoteDeviceID: value.remoteDeviceID,
                ackNonce: value.ackNonce
            ), existingObject != value.receiptKey.objectDigest {
                throw Endpoint.TransactionError.ackNonceConflict
            }
            guard pendingAck == nil else { throw Endpoint.TransactionError.receiptCollision }
            pendingAck = value
            return .inserted(receipt: receipt, deliveryState: max(current, target))
        }

        func insertPreparedOutbound(_ value: Endpoint.PendingOutbound) throws {
            guard active else { throw Endpoint.TransactionError.invalidProtectedState }
            guard pendingOutbound == nil else {
                throw Endpoint.TransactionError.receiptCollision
            }
            pendingOutbound = value
        }

        func insertAckMaterialization(
            pending: Endpoint.PendingOutbound,
            intentReceiptKey: Endpoint.ReceiptKey,
            packedEnvelope: Data,
            ackObjectDigest: Data
        ) throws {
            guard active else { throw Endpoint.TransactionError.invalidProtectedState }
            guard pendingOutbound == nil, pendingAckMaterialization == nil else {
                throw Endpoint.TransactionError.receiptCollision
            }
            guard pending.objectDigest == ackObjectDigest,
                  pending.immutableEnvelopeBytes == packedEnvelope,
                  pending.sourceAckIntent == intentReceiptKey.objectDigest else {
                throw Endpoint.TransactionError.stagedAckCollision
            }
            let maps = database.snapshotMaps()
            guard let intent = maps.ackIntents[intentReceiptKey],
                  !intent.isQueued,
                  !intent.isAbandoned else {
                throw Endpoint.TransactionError.noPendingAck
            }
            if let existing = intent.stagedEnvelope {
                guard existing == packedEnvelope,
                      intent.queueObjectID == ackObjectDigest else {
                    throw Endpoint.TransactionError.stagedAckCollision
                }
            }
            pendingOutbound = pending
            pendingAckMaterialization = (intentReceiptKey, packedEnvelope, ackObjectDigest)
        }

        func commitAndFsync() throws {
            guard active else { throw Endpoint.TransactionError.invalidProtectedState }
            do {
                try database.commitTransaction(
                    pending: pending,
                    pendingAck: pendingAck,
                    pendingOutbound: pendingOutbound,
                    pendingAckMaterialization: pendingAckMaterialization
                )
            } catch let error as Endpoint.TransactionError {
                try? database.rollbackTransaction()
                throw error
            } catch {
                try? database.rollbackTransaction()
                throw Endpoint.TransactionError.invalidProtectedState
            }
            active = false
            database.unlockAfterTransaction()
        }

        func rollback() {
            guard active else { return }
            try? database.rollbackTransaction()
            active = false
            pending = nil
            pendingAck = nil
            pendingOutbound = nil
            pendingAckMaterialization = nil
            database.unlockAfterTransaction()
        }
    }
}
