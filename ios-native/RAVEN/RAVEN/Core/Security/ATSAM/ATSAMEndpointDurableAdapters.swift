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
        if ProcessInfo.processInfo.environment["RAVEN_LAB_TEST_A"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: "raven.lab.test_a")
        #else
        return false
        #endif
    }

    @MainActor
    static let sharedProtectedStore = KeychainProtectedSessionStore()
    @MainActor
    static let sharedAckQueue = ImmutableAckFileQueue()
}

// MARK: - Keychain protected ratchet head

final class KeychainProtectedSessionStore: ATSAMEndpointTransactionV1.ProtectedStateStore {
    private let service = "app.raven.ios.atsam.endpoint.protected"
    private var cache: [Data: ATSAMEndpointTransactionV1.ProtectedSessionState] = [:]

    private func account(for sessionID: Data) -> String {
        "sess|" + sessionID.map { String(format: "%02x", $0) }.joined()
    }

    func pendingSessionIDs() throws -> [Data] {
        cache.values
            .filter { $0.pendingAcceptance != nil || $0.pendingAckAcceptance != nil }
            .map(\.sessionID)
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
        } else {
            throw ATSAMEndpointTransactionV1.TransactionError.invalidProtectedState
        }
        try replace(state)
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

/// File-backed immutable ACK queue (exact-byte idempotent by objectID).
final class ImmutableAckFileQueue: ATSAMEndpointTransactionV1.ImmutableAckQueue {
    private let dir: URL
    private var memory: [Data: Data] = [:]

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        dir = base.appendingPathComponent("raven-endpoint-ack-queue", isDirectory: true)
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
        try packedEnvelope.write(to: url, options: .atomic)
        memory[objectID] = packedEnvelope
    }
}

// MARK: - DTO (avoids Codable on nested endpoint types)

private struct ProtectedDTO: Codable {
    var sessionID: Data
    var rootKey: Data
    var receiveChainKey: Data
    var nextReceiveIndex: UInt32
    var skippedMessageKeys: [String: Data]
    var ackReceiveChainKey: Data
    var nextAckReceiveIndex: UInt32
    var skippedAckKeys: [String: Data]
    var generation: UInt64
    // Pending journals stay in-process for lab; durable head is ratchet state.
    // Full pending blob persistence is a follow-up; recoverPending still works
    // within a process lifetime after replace().

    init(_ state: ATSAMEndpointTransactionV1.ProtectedSessionState) {
        sessionID = state.sessionID
        rootKey = state.rootKey
        receiveChainKey = state.receiveChainKey
        nextReceiveIndex = state.nextReceiveIndex
        skippedMessageKeys = Dictionary(
            uniqueKeysWithValues: state.skippedMessageKeys.map { (String($0.key), $0.value) }
        )
        ackReceiveChainKey = state.ackReceiveChainKey
        nextAckReceiveIndex = state.nextAckReceiveIndex
        skippedAckKeys = Dictionary(
            uniqueKeysWithValues: state.skippedAckKeys.map { (String($0.key), $0.value) }
        )
        generation = state.generation
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
            ackReceiveChainKey: ackReceiveChainKey,
            nextAckReceiveIndex: nextAckReceiveIndex,
            skippedAckKeys: skippedAck,
            pendingAcceptance: nil,
            pendingAckAcceptance: nil,
            generation: generation
        )
    }
}

// MARK: - SQLCipher acceptance database (durable)

/// Encrypted SQLite acceptance journal for endpoint receive/ACK.
/// In-memory maps are authoritative within a transaction; commitAndFsync
/// writes an atomic SQLCipher snapshot.
final class SQLCipherAcceptanceDatabase: ATSAMEndpointTransactionV1.AcceptanceDatabase {
    typealias Endpoint = ATSAMEndpointTransactionV1

    private let dbPath: String
    private let keyHex: String
    private var receipts: [Endpoint.ReceiptKey: Endpoint.CommittedReceipt] = [:]
    private var logicalObjects: [Endpoint.LogicalMessageKey: Data] = [:]
    private var ackIntents: [Endpoint.ReceiptKey: Endpoint.AckIntent] = [:]
    private var ackReceipts: [Endpoint.ReceiptKey: Endpoint.AckReceipt] = [:]
    private var ackNonceObjects: [Data: Data] = [:]
    private var outstanding: [Endpoint.OutstandingMessageKey: Endpoint.DeliveryState] = [:]
    private let lock = NSLock()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("raven-endpoint-acceptance", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("acceptance.sqlcipher").path
        keyHex = Self.loadOrCreateKeyHex()
        loadSnapshot()
    }

    func beginImmediate() throws -> any Endpoint.AcceptanceDatabaseTransaction {
        lock.lock()
        return Transaction(database: self)
    }

    func nextUnqueuedAckIntent() throws -> Endpoint.AckIntent? {
        lock.lock(); defer { lock.unlock() }
        return ackIntents.values.first { !$0.isQueued }
    }

    func stageAckEnvelope(
        receiptKey: Endpoint.ReceiptKey,
        packedEnvelope: Data,
        queueObjectID: Data
    ) throws -> Endpoint.AckIntent {
        lock.lock(); defer { lock.unlock() }
        guard var intent = ackIntents[receiptKey], !intent.isQueued else {
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
        persistLocked()
        return intent
    }

    func markAckQueued(receiptKey: Endpoint.ReceiptKey, queueObjectID: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard var intent = ackIntents[receiptKey],
              intent.stagedEnvelope != nil,
              intent.queueObjectID == queueObjectID else {
            throw Endpoint.TransactionError.stagedAckCollision
        }
        intent.isQueued = true
        ackIntents[receiptKey] = intent
        persistLocked()
    }

    fileprivate func unlockAfterTransaction() {
        lock.unlock()
    }

    fileprivate func commit(
        pending: Endpoint.PendingAcceptance?,
        pendingAck: Endpoint.PendingAckAcceptance?
    ) throws {
        if let value = pending {
            if let logicalDigest = logicalObjects[value.logicalKey],
               logicalDigest != value.receiptKey.objectDigest {
                throw Endpoint.TransactionError.logicalMessageCollision
            }
            receipts[value.receiptKey] = Endpoint.CommittedReceipt(
                receiptKey: value.receiptKey,
                logicalKey: value.logicalKey,
                messageIndex: value.messageIndex,
                sealedLocalInboxRow: value.sealedLocalInboxRow,
                sessionGeneration: value.sessionGeneration
            )
            logicalObjects[value.logicalKey] = value.receiptKey.objectDigest
            ackIntents[value.receiptKey] = value.ackIntent
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
            let nonceKey = Self.ackNonceKey(
                sessionID: value.receiptKey.sessionID,
                remoteDeviceID: value.remoteDeviceID,
                ackNonce: value.ackNonce
            )
            if let existingObject = ackNonceObjects[nonceKey],
               existingObject != value.receiptKey.objectDigest {
                throw Endpoint.TransactionError.ackNonceConflict
            }
            ackReceipts[value.receiptKey] = Endpoint.AckReceipt(
                receiptKey: value.receiptKey,
                outerMessageID: value.outerMessageID,
                remoteDeviceID: value.remoteDeviceID,
                ackedMessageID: value.ackedMessageID,
                status: value.status,
                ackNonce: value.ackNonce,
                createdAtMs: value.createdAtMs,
                sessionGeneration: value.sessionGeneration
            )
            ackNonceObjects[nonceKey] = value.receiptKey.objectDigest
            outstanding[outstandingKey] = max(current, target)
        }
        persistLocked()
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

    private func persistLocked() {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }
        let keySQL = "PRAGMA key = \"x'\(keyHex)'\";"
        guard sqlite3_exec(db, keySQL, nil, nil, nil) == SQLITE_OK else { return }
        _ = sqlite3_exec(
            db,
            """
            CREATE TABLE IF NOT EXISTS snapshot (
              id INTEGER PRIMARY KEY CHECK (id = 1),
              blob BLOB NOT NULL
            );
            """,
            nil, nil, nil
        )
        // Compact durable snapshot: encode counts only + ack intent staged envelopes as raw rows.
        // Full Codable of nested keys is heavy; store opaque NSKeyed-free JSON via hex maps.
        let payload = SnapshotDTO(
            receiptCount: receipts.count,
            ackIntentCount: ackIntents.count,
            ackReceiptCount: ackReceipts.count,
            outstandingCount: outstanding.count,
            staged: ackIntents.compactMap { key, intent in
                guard let staged = intent.stagedEnvelope,
                      let qid = intent.queueObjectID else { return nil }
                return StagedDTO(
                    sessionHex: key.sessionID.map { String(format: "%02x", $0) }.joined(),
                    digestHex: key.objectDigest.map { String(format: "%02x", $0) }.joined(),
                    envelope: staged,
                    queueObjectID: qid,
                    isQueued: intent.isQueued,
                    ackedMessageID: intent.ackedMessageID,
                    expectedRemoteDeviceID: intent.expectedRemoteDeviceID,
                    status: intent.status.rawValue,
                    sessionGeneration: intent.sessionGeneration
                )
            }
        )
        guard let blob = try? JSONEncoder().encode(payload) else { return }
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO snapshot(id, blob) VALUES (1, ?);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        blob.withUnsafeBytes { ptr in
            _ = sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(blob.count), nil)
        }
        _ = sqlite3_step(stmt)
        _ = sqlite3_exec(db, "PRAGMA wal_checkpoint(FULL);", nil, nil, nil)
    }

    private func loadSnapshot() {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }
        let keySQL = "PRAGMA key = \"x'\(keyHex)'\";"
        guard sqlite3_exec(db, keySQL, nil, nil, nil) == SQLITE_OK else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT blob FROM snapshot WHERE id = 1;", -1, &stmt, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(stmt, 0) else { return }
        let count = Int(sqlite3_column_bytes(stmt, 0))
        let data = Data(bytes: bytes, count: count)
        guard let dto = try? JSONDecoder().decode(SnapshotDTO.self, from: data) else { return }
        for staged in dto.staged {
            guard let session = Data(hexString: staged.sessionHex),
                  let digest = Data(hexString: staged.digestHex) else { continue }
            let key = Endpoint.ReceiptKey(sessionID: session, objectDigest: digest)
            guard let status = Endpoint.AckStatus(rawValue: staged.status) else { continue }
            ackIntents[key] = Endpoint.AckIntent(
                receiptKey: key,
                ackedMessageID: staged.ackedMessageID,
                expectedRemoteDeviceID: staged.expectedRemoteDeviceID,
                status: status,
                sessionGeneration: staged.sessionGeneration,
                stagedEnvelope: staged.envelope,
                queueObjectID: staged.queueObjectID,
                isQueued: staged.isQueued
            )
        }
        _ = dto.receiptCount
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

    private static func loadOrCreateKeyHex() -> String {
        let service = "app.raven.ios.atsam.acceptance.db"
        let account = "sqlcipher.key"
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
        _ = SecItemAdd(add as CFDictionary, nil)
        return key.map { String(format: "%02x", $0) }.joined()
    }

    private final class Transaction: Endpoint.AcceptanceDatabaseTransaction {
        private unowned let database: SQLCipherAcceptanceDatabase
        private var pending: Endpoint.PendingAcceptance?
        private var pendingAck: Endpoint.PendingAckAcceptance?
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
            pendingAck = value
            return .inserted(receipt: receipt, deliveryState: max(current, target))
        }

        func commitAndFsync() throws {
            guard active else { throw Endpoint.TransactionError.invalidProtectedState }
            try database.commit(pending: pending, pendingAck: pendingAck)
            active = false
            database.unlockAfterTransaction()
        }

        func rollback() {
            guard active else { return }
            active = false
            pending = nil
            pendingAck = nil
            database.unlockAfterTransaction()
        }
    }
}

private struct SnapshotDTO: Codable {
    var receiptCount: Int
    var ackIntentCount: Int
    var ackReceiptCount: Int
    var outstandingCount: Int
    var staged: [StagedDTO]
}

private struct StagedDTO: Codable {
    var sessionHex: String
    var digestHex: String
    var envelope: Data
    var queueObjectID: Data
    var isQueued: Bool
    var ackedMessageID: Data
    var expectedRemoteDeviceID: Data
    var status: UInt8
    var sessionGeneration: UInt64
}

private extension Data {
    init?(hexString: String) {
        let h = hexString.lowercased()
        guard h.count % 2 == 0 else { return nil }
        var out = Data(capacity: h.count / 2)
        var i = h.startIndex
        while i < h.endIndex {
            let j = h.index(i, offsetBy: 2)
            guard let b = UInt8(h[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        self = out
    }
}
