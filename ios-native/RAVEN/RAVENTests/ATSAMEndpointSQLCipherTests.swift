//
//  ATSAMEndpointSQLCipherTests.swift
//  RAVENTests
//
//  SQLCipher endpoint acceptance DB: fail-closed open + row persistence.
//

#if DEBUG

import CryptoKit
import Foundation
import SQLCipher
import XCTest
@testable import RAVEN

private typealias Endpoint = ATSAMEndpointTransactionV1
private typealias DBError = SQLCipherAcceptanceDatabaseError

final class ATSAMEndpointSQLCipherTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("atsam-sqlcipher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        SQLCipherAcceptanceDatabase._testCipherVersionOverride = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try super.tearDownWithError()
    }

    // MARK: - Fail-closed open

    func testOpenFailsWhenCipherVersionMissing() throws {
        SQLCipherAcceptanceDatabase._testCipherVersionOverride = .some(nil)
        defer { SQLCipherAcceptanceDatabase._testCipherVersionOverride = nil }

        XCTAssertThrowsError(
            try SQLCipherAcceptanceDatabase(testRoot: tempRoot, keyHex: Self.testKeyHex())
        ) { error in
            XCTAssertEqual(error as? DBError, .sqlCipherUnavailable)
        }
    }

    func testPlainSQLiteFileRejectedOnOpen() throws {
        let atsamDir = tempRoot.appendingPathComponent("atsam", isDirectory: true)
        try FileManager.default.createDirectory(at: atsamDir, withIntermediateDirectories: true)
        let dbURL = atsamDir.appendingPathComponent("plain.sqlite")
        var plainDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &plainDB), SQLITE_OK)
        defer { sqlite3_close(plainDB) }
        XCTAssertEqual(
            sqlite3_exec(plainDB, "CREATE TABLE t(x INTEGER);", nil, nil, nil),
            SQLITE_OK
        )

        XCTAssertThrowsError(
            try SQLCipherAcceptanceDatabase(
                testRoot: tempRoot,
                keyHex: Self.testKeyHex(),
                databaseFileName: "plain.sqlite"
            )
        ) { error in
            XCTAssertEqual(error as? DBError, .encryptionProbeFailed)
        }
    }

    // MARK: - Persist / reopen

    func testCommitPersistsAndReopenRestoresFullState() throws {
        let keyHex = Self.testKeyHex()
        let db = try SQLCipherAcceptanceDatabase(testRoot: tempRoot, keyHex: keyHex)
        let fixture = try PersistFixture()

        try db.seedOutstanding(fixture.outstandingKey, state: .sent)

        let tx = try db.beginImmediate()
        let insertOutcome = try tx.insertAcceptance(fixture.pendingAcceptance)
        guard case .inserted = insertOutcome else {
            return XCTFail("Expected inserted acceptance")
        }
        try tx.commitAndFsync()

        let stagedEnvelope = Data(repeating: 0xAC, count: 128)
        let queueObjectID = Data(SHA256.hash(data: Data("queue-object".utf8)))
        let stagedIntent = try db.stageAckEnvelope(
            receiptKey: fixture.receiptKey,
            packedEnvelope: stagedEnvelope,
            queueObjectID: queueObjectID
        )
        XCTAssertEqual(stagedIntent.stagedEnvelope, stagedEnvelope)
        XCTAssertEqual(stagedIntent.queueObjectID, queueObjectID)

        let ackTx = try db.beginImmediate()
        let ackOutcome = try ackTx.insertAckAcceptance(fixture.pendingAckAcceptance)
        guard case let .inserted(receipt: ackReceipt, deliveryState: deliveryState) = ackOutcome else {
            return XCTFail("Expected inserted ack acceptance")
        }
        try ackTx.commitAndFsync()

        let reopened = try SQLCipherAcceptanceDatabase(testRoot: tempRoot, keyHex: keyHex)

        let readTx = try reopened.beginImmediate()
        let restoredReceipt = try readTx.existingReceipt(
            receiptKey: fixture.receiptKey,
            logicalKey: fixture.logicalKey
        )
        XCTAssertEqual(restoredReceipt, fixture.expectedReceipt)

        let restoredAck = try readTx.existingAckReceipt(
            receiptKey: fixture.ackReceiptKey,
            outerMessageID: fixture.pendingAckAcceptance.outerMessageID,
            remoteDeviceID: fixture.pendingAckAcceptance.remoteDeviceID
        )
        XCTAssertEqual(restoredAck, ackReceipt)

        let restoredOutstanding = try readTx.outstandingDeliveryState(fixture.outstandingKey)
        XCTAssertEqual(restoredOutstanding, deliveryState)

        let restoredNonce = try readTx.ackNonceObjectDigest(
            sessionID: fixture.sessionID,
            remoteDeviceID: fixture.pendingAckAcceptance.remoteDeviceID,
            ackNonce: fixture.pendingAckAcceptance.ackNonce
        )
        XCTAssertEqual(restoredNonce, fixture.ackReceiptKey.objectDigest)
        readTx.rollback()

        let restoredIntent = try reopened.nextUnqueuedAckIntent()
        XCTAssertNotNil(restoredIntent)
        XCTAssertEqual(restoredIntent?.stagedEnvelope, stagedEnvelope)
        XCTAssertEqual(restoredIntent?.queueObjectID, queueObjectID)
        XCTAssertFalse(restoredIntent?.isQueued ?? true)
        XCTAssertEqual(restoredIntent?.status, .delivered)
        XCTAssertEqual(restoredIntent?.sessionGeneration, fixture.sessionGeneration)
    }

    func testMarkAckQueuedPersistsState() throws {
        let keyHex = Self.testKeyHex()
        let db = try SQLCipherAcceptanceDatabase(testRoot: tempRoot, keyHex: keyHex)
        let fixture = try PersistFixture()

        let tx = try db.beginImmediate()
        _ = try tx.insertAcceptance(fixture.pendingAcceptance)
        try tx.commitAndFsync()

        let stagedEnvelope = Data(repeating: 0xBE, count: 64)
        let queueObjectID = Data(SHA256.hash(data: Data("queued-object".utf8)))
        _ = try db.stageAckEnvelope(
            receiptKey: fixture.receiptKey,
            packedEnvelope: stagedEnvelope,
            queueObjectID: queueObjectID
        )
        try db.markAckQueued(receiptKey: fixture.receiptKey, queueObjectID: queueObjectID)

        let reopened = try SQLCipherAcceptanceDatabase(testRoot: tempRoot, keyHex: keyHex)
        XCTAssertNil(try reopened.nextUnqueuedAckIntent())
    }

    // MARK: - Helpers

    private static func testKeyHex() -> String {
        Data((0..<32).map { UInt8($0) }).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Test fixture

private struct PersistFixture {
    let sessionID: Data
    let sessionGeneration: UInt64
    let receiptKey: Endpoint.ReceiptKey
    let ackReceiptKey: Endpoint.ReceiptKey
    let logicalKey: Endpoint.LogicalMessageKey
    let outstandingKey: Endpoint.OutstandingMessageKey
    let pendingAcceptance: Endpoint.PendingAcceptance
    let pendingAckAcceptance: Endpoint.PendingAckAcceptance
    let expectedReceipt: Endpoint.CommittedReceipt

    init() throws {
        sessionID = Data(repeating: 0x51, count: 32)
        sessionGeneration = 42
        let objectDigest = Data(repeating: 0xAA, count: 32)
        let ackObjectDigest = Data(repeating: 0xBB, count: 32)
        let messageID = Data(repeating: 0x22, count: 16)
        let senderDevice = Data(repeating: 0x33, count: 32)
        let remoteDevice = Data(repeating: 0x44, count: 32)

        receiptKey = Endpoint.ReceiptKey(sessionID: sessionID, objectDigest: objectDigest)
        ackReceiptKey = Endpoint.ReceiptKey(sessionID: sessionID, objectDigest: ackObjectDigest)
        logicalKey = Endpoint.LogicalMessageKey(
            sessionID: sessionID,
            senderDeviceID: senderDevice,
            messageID: messageID
        )
        outstandingKey = Endpoint.OutstandingMessageKey(
            sessionID: sessionID,
            messageID: messageID,
            recipientDeviceID: remoteDevice
        )

        let sealedRow = Data(repeating: 0x55, count: 96)
        let ackIntent = Endpoint.AckIntent(
            receiptKey: receiptKey,
            ackedMessageID: messageID,
            expectedRemoteDeviceID: senderDevice,
            status: .delivered,
            sessionGeneration: sessionGeneration,
            stagedEnvelope: nil,
            queueObjectID: nil,
            isQueued: false,
            isAbandoned: false
        )
        pendingAcceptance = Endpoint.PendingAcceptance(
            receiptKey: receiptKey,
            logicalKey: logicalKey,
            messageIndex: 7,
            sealedLocalInboxRow: sealedRow,
            ackIntent: ackIntent,
            sessionGeneration: sessionGeneration
        )
        expectedReceipt = Endpoint.CommittedReceipt(
            receiptKey: receiptKey,
            logicalKey: logicalKey,
            messageIndex: 7,
            sealedLocalInboxRow: sealedRow,
            sessionGeneration: sessionGeneration
        )
        pendingAckAcceptance = Endpoint.PendingAckAcceptance(
            receiptKey: ackReceiptKey,
            outerMessageID: Data(repeating: 0x66, count: 16),
            remoteDeviceID: remoteDevice,
            ackedMessageID: messageID,
            status: .delivered,
            ackNonce: Data(repeating: 0x77, count: 12),
            createdAtMs: 1_786_579_200_000,
            sessionGeneration: sessionGeneration
        )
    }
}

// MARK: - Test-only database helpers

extension SQLCipherAcceptanceDatabase {
    func seedOutstanding(
        _ key: Endpoint.OutstandingMessageKey,
        state: Endpoint.DeliveryState
    ) throws {
        try seedOutstandingRow(key: key, state: state)
    }
}

#endif
