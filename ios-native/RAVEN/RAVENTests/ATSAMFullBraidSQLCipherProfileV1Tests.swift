import Darwin
import Foundation
import XCTest
@testable import RAVEN

#if !targetEnvironment(macCatalyst)

final class ATSAMFullBraidSQLCipherProfileV1Tests: XCTestCase {
    private typealias Profile = ATSAMFullBraidSQLCipherProfileV1
    private static let suiteLock = NSLock()
    private static let interopKey = Data(repeating: 0x61, count: 32)
    private static let interopSalt = Data(repeating: 0x73, count: 16)
    private static let sentinel = Data("RAVEN-0A4-HIGH-ENTROPY-SENTINEL-04f65e46b7d8803a9c0289d9c70663d9".utf8)

    override func invokeTest() {
        Self.suiteLock.lock()
        defer { Self.suiteLock.unlock() }
        super.invokeTest()
    }

    func testProductionRemainsDisabled() {
        XCTAssertFalse(Profile.productionEnabled)
    }

    func testLabLinkageProbeAcceptsOfficialCommonCryptoPin() throws {
        XCTAssertTrue(Profile.consumerSqliteHasCodecDefined)
        let report = try Profile.runLabLinkageProbe()
        XCTAssertTrue(Profile.isAllowedCipherVersion(report.cipherVersion))
        XCTAssertEqual(report.sqliteVersion, "3.53.3")
        XCTAssertEqual(report.provider, "commoncrypto")
        XCTAssertFalse(report.providerVersion.isEmpty)
        XCTAssertTrue(report.consumerSqliteHasCodec)
        XCTAssertEqual(report.cipherPageSize, 4096)
        XCTAssertEqual(report.cipherHMACAlgorithm, "HMAC_SHA512")
        XCTAssertEqual(report.cipherKDFAlgorithm, "PBKDF2_HMAC_SHA512")
        XCTAssertTrue(report.cipherUseHMAC)
        XCTAssertEqual(report.cipherPlaintextHeaderSize, 32)
        XCTAssertTrue(report.cipherMemorySecurity)
        XCTAssertEqual(report.journalMode, "wal")
        XCTAssertEqual(report.synchronous, 2)
        XCTAssertTrue(report.foreignKeys)
        XCTAssertEqual(report.tempStore, 2)
        XCTAssertEqual(report.mmapSize, 0)
        XCTAssertEqual(report.lockingMode, "normal")
        XCTAssertEqual(report.busyTimeoutMS, 5_000)
        XCTAssertEqual(report.compileOptions, report.compileOptions.sorted())
        XCTAssertTrue(report.compileOptions.contains { $0.uppercased().contains("TEMP_STORE=2") })
        XCTAssertEqual(report.finalImageOwner, "SQLCipher.swift/SQLCipher")
        XCTAssertTrue(report.targetTriple.contains("-apple-ios17.0"))
        XCTAssertEqual(
            report.artifactDigestSHA256,
            "dd5a650346c1ba9933d6ba179f8844e03e4a075b3dd3a892796149864cd9ae57"
        )
    }

    func testCipherVersionAllowListRejectsModifiedPrefixMatch() {
        XCTAssertTrue(Profile.isAllowedCipherVersion("4.17.0"))
        XCTAssertTrue(Profile.isAllowedCipherVersion("4.17.0 community"))
        XCTAssertFalse(Profile.isAllowedCipherVersion("4.17.0-modified"))
        XCTAssertFalse(Profile.isAllowedCipherVersion("4.17.0 community-extra"))
        XCTAssertFalse(Profile.isAllowedCipherVersion("4.17"))
        XCTAssertFalse(Profile.isAllowedCipherVersion(""))
    }

    func testFrozenProfileCreateReopenTempAndNoPlaintext() throws {
        let directory = try makeDirectory("complete")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("endpoint.db").path
        let key = try fixtureKey()
        var opened: Profile.Opened? = try Profile.create(firstInstall: .acquire(path: path), key: key)
        try opened?.executeLab("CREATE TABLE raven_records(id INTEGER PRIMARY KEY, body BLOB NOT NULL);")
        try opened?.insertBlobLab(sql: "INSERT INTO raven_records(body) VALUES(?1);", blob: Self.sentinel)
        XCTAssertEqual(try opened?.blobLab("SELECT body FROM raven_records WHERE id=1"), Self.sentinel)

        let temp = directory.appendingPathComponent("temp", isDirectory: true)
        try Profile.runTempWorkloadAndScan(opened: try XCTUnwrap(opened), directory: temp, sentinel: Self.sentinel)
        try opened?.checkpointTruncate()
        opened?.close()
        opened = nil

        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(String(data: bytes.prefix(16), encoding: .utf8), "SQLite format 3\0")
        XCTAssertEqual(bytes[16], 0x10)
        XCTAssertEqual(bytes[17], 0x00)
        XCTAssertEqual(bytes[20], 80)
        XCTAssertNil(bytes.range(of: Self.sentinel))

        opened = try Profile.openExisting(path: path, key: try fixtureKey())
        XCTAssertEqual(try opened?.blobLab("SELECT body FROM raven_records WHERE id=1"), Self.sentinel)
        try Profile.scanForPlaintextSentinel(path: path, extraDirectories: [temp], sentinel: Self.sentinel)
        try opened?.executeLab("PRAGMA temp_store=FILE;")
        XCTAssertThrowsError(try opened?.reverifyProfileForLab())
    }

    func testFirstInstallProofCannotBecomeCREATEFallback() throws {
        let directory = try makeDirectory("install-proof")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("endpoint.db").path
        let proof = try Profile.FirstInstallProof.acquire(path: path)
        FileManager.default.createFile(atPath: path, contents: Data("occupied".utf8))
        XCTAssertThrowsError(try Profile.create(firstInstall: proof, key: fixtureKey())) {
            XCTAssertEqual($0 as? Profile.OpenError, .firstInstallProofStale)
        }

        let absent = directory.appendingPathComponent("absent.db").path
        XCTAssertThrowsError(try Profile.openExisting(path: absent, key: fixtureKey()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent))
    }

    func testWrongKeySaltPlaintextAndPublicProfileFailClosed() throws {
        let directory = try makeDirectory("wrong-profile")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("endpoint.db").path
        var opened: Profile.Opened? = try Profile.create(firstInstall: .acquire(path: path), key: fixtureKey())
        try opened?.executeLab("CREATE TABLE durable(v INTEGER NOT NULL); INSERT INTO durable VALUES(7);")
        try opened?.checkpointTruncate()
        opened?.close()
        opened = nil
        let original = try Data(contentsOf: URL(fileURLWithPath: path))

        XCTAssertThrowsError(try Profile.openExisting(
            path: path,
            key: Profile.RawKey(key: Data(repeating: 0x44, count: 32), salt: Data(repeating: 0x33, count: 16))
        ))
        XCTAssertThrowsError(try Profile.openExisting(
            path: path,
            key: Profile.RawKey(key: Data(repeating: 0x11, count: 32), salt: Data(repeating: 0x34, count: 16))
        ))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)

        let plaintext = directory.appendingPathComponent("plaintext.db").path
        try Data("SQLite format 3\0plaintext-not-a-profile".utf8).write(to: URL(fileURLWithPath: plaintext))
        XCTAssertThrowsError(try Profile.openExisting(path: plaintext, key: fixtureKey()))

        var badHeader = original
        badHeader[20] = 0
        let badHeaderPath = directory.appendingPathComponent("bad-header.db").path
        try badHeader.write(to: URL(fileURLWithPath: badHeaderPath))
        XCTAssertThrowsError(try Profile.openExisting(path: badHeaderPath, key: fixtureKey())) {
            XCTAssertEqual($0 as? Profile.OpenError, .profileMismatch("public_header"))
        }
    }

    func testTruncatedCorruptAndUnsafePathsFailBeforeAcceptance() throws {
        let directory = try makeDirectory("corrupt")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("endpoint.db").path
        var opened: Profile.Opened? = try Profile.create(firstInstall: .acquire(path: path), key: fixtureKey())
        try opened?.executeLab("CREATE TABLE durable(v BLOB); INSERT INTO durable VALUES(randomblob(12000));")
        try opened?.checkpointTruncate()
        opened?.close()
        opened = nil
        let original = try Data(contentsOf: URL(fileURLWithPath: path))

        let truncatedPath = directory.appendingPathComponent("truncated.db").path
        try original.prefix(31).write(to: URL(fileURLWithPath: truncatedPath))
        XCTAssertThrowsError(try Profile.openExisting(path: truncatedPath, key: fixtureKey()))

        var corrupt = original
        corrupt[4096 + 91] ^= 0x80
        let corruptPath = directory.appendingPathComponent("corrupt.db").path
        try corrupt.write(to: URL(fileURLWithPath: corruptPath))
        XCTAssertThrowsError(try Profile.openExisting(path: corruptPath, key: fixtureKey()))

        let symlink = directory.appendingPathComponent("link.db").path
        try FileManager.default.createSymbolicLink(atPath: symlink, withDestinationPath: path)
        XCTAssertThrowsError(try Profile.openExisting(path: symlink, key: fixtureKey()))
        XCTAssertThrowsError(try Profile.openExisting(path: "file:\(path)", key: fixtureKey()))
        XCTAssertThrowsError(try Profile.openExisting(path: "relative.db", key: fixtureKey()))
    }

    func testIndependentlySwappedWALAndSHMAreRejectedWithoutMutation() throws {
        let directory = try makeDirectory("sidecar-swap")
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = directory.appendingPathComponent("a.db").path
        let b = directory.appendingPathComponent("b.db").path
        var openedA: Profile.Opened? = try Profile.create(
            firstInstall: .acquire(path: a),
            key: Profile.RawKey(key: Data(repeating: 0x71, count: 32), salt: Data(repeating: 0x72, count: 16))
        )
        try openedA?.preserveWALOnCloseForLab()
        try openedA?.executeLab("CREATE TABLE payload(v BLOB); INSERT INTO payload VALUES(randomblob(24000));")
        var openedB: Profile.Opened? = try Profile.create(
            firstInstall: .acquire(path: b),
            key: Profile.RawKey(key: Data(repeating: 0x81, count: 32), salt: Data(repeating: 0x82, count: 16))
        )
        try openedB?.preserveWALOnCloseForLab()
        try openedB?.executeLab("CREATE TABLE payload(v BLOB); INSERT INTO payload VALUES(randomblob(26000));")

        func sidecar(_ path: String, _ suffix: String) -> String { path + suffix }
        func copyTriplet(_ source: String, _ destination: String) throws {
            try FileManager.default.copyItem(atPath: source, toPath: destination)
            for suffix in ["-wal", "-shm"] {
                try FileManager.default.copyItem(
                    atPath: sidecar(source, suffix),
                    toPath: sidecar(destination, suffix)
                )
            }
        }
        let good = directory.appendingPathComponent("good.db").path
        let walSwap = directory.appendingPathComponent("wal-swap.db").path
        let shmSwap = directory.appendingPathComponent("shm-swap.db").path
        try copyTriplet(a, good)
        try copyTriplet(a, walSwap)
        try copyTriplet(a, shmSwap)
        try FileManager.default.removeItem(atPath: sidecar(walSwap, "-wal"))
        try FileManager.default.copyItem(atPath: sidecar(b, "-wal"), toPath: sidecar(walSwap, "-wal"))
        try FileManager.default.removeItem(atPath: sidecar(shmSwap, "-shm"))
        try FileManager.default.copyItem(atPath: sidecar(b, "-shm"), toPath: sidecar(shmSwap, "-shm"))
        openedA?.close()
        openedA = nil
        openedB?.close()
        openedB = nil

        let keyA = try Profile.RawKey(
            key: Data(repeating: 0x71, count: 32),
            salt: Data(repeating: 0x72, count: 16)
        )
        let goodOpened = try Profile.openExisting(path: good, key: keyA)
        XCTAssertEqual(try goodOpened.scalarIntLab("SELECT count(*) FROM payload"), 1)

        for candidate in [walSwap, shmSwap] {
            let before = try [candidate, sidecar(candidate, "-wal"), sidecar(candidate, "-shm")]
                .map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
            XCTAssertThrowsError(try Profile.openExisting(
                path: candidate,
                key: Profile.RawKey(
                    key: Data(repeating: 0x71, count: 32),
                    salt: Data(repeating: 0x72, count: 16)
                )
            ))
            let after = try [candidate, sidecar(candidate, "-wal"), sidecar(candidate, "-shm")]
                .map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
            XCTAssertEqual(after, before)
        }
    }

    func testCrashPhaseInitializeCommonCryptoFixture() throws {
        try requireCrashGate()
        let path = try crashFixturePath(reset: true)
        let opened = try Profile.create(firstInstall: .acquire(path: path), key: fixtureKey())
        try opened.executeLab("CREATE TABLE crash_state(v INTEGER NOT NULL); INSERT INTO crash_state VALUES(0);")
        try opened.checkpointTruncate()
        XCTAssertEqual(try opened.scalarIntLab("SELECT v FROM crash_state"), 0)
    }

    func testCrashPhaseExitWithUncommittedTransaction() throws {
        try requireCrashGate()
        let opened = try Profile.openExisting(path: crashFixturePath(reset: false), key: fixtureKey())
        try opened.preserveWALOnCloseForLab()
        try opened.executeLab("BEGIN IMMEDIATE; UPDATE crash_state SET v=1;")
        crashTestRunner(marker: "RAVEN_0A4_COMMONCRYPTO_CRASH_UNCOMMITTED", code: 86)
    }

    func testCrashPhaseVerifyUncommittedWasRolledBack() throws {
        try requireCrashGate()
        let opened = try Profile.openExisting(path: crashFixturePath(reset: false), key: fixtureKey())
        XCTAssertEqual(try opened.scalarIntLab("SELECT v FROM crash_state"), 0)
    }

    func testCrashPhaseExitAfterCommit() throws {
        try requireCrashGate()
        let opened = try Profile.openExisting(path: crashFixturePath(reset: false), key: fixtureKey())
        try opened.preserveWALOnCloseForLab()
        try opened.executeLab("BEGIN IMMEDIATE; UPDATE crash_state SET v=2; COMMIT;")
        crashTestRunner(marker: "RAVEN_0A4_COMMONCRYPTO_CRASH_COMMITTED", code: 87)
    }

    func testCrashPhaseVerifyCommittedTransaction() throws {
        try requireCrashGate()
        let opened = try Profile.openExisting(path: crashFixturePath(reset: false), key: fixtureKey())
        XCTAssertEqual(try opened.scalarIntLab("SELECT v FROM crash_state"), 2)
    }

    func testCrashPhaseExitAfterCheckpoint() throws {
        try requireCrashGate()
        let opened = try Profile.openExisting(path: crashFixturePath(reset: false), key: fixtureKey())
        try opened.executeLab("BEGIN IMMEDIATE; UPDATE crash_state SET v=3; COMMIT;")
        try opened.checkpointTruncate()
        crashTestRunner(marker: "RAVEN_0A4_COMMONCRYPTO_CRASH_CHECKPOINTED", code: 88)
    }

    func testCrashPhaseVerifyCheckpointedTransaction() throws {
        try requireCrashGate()
        let opened = try Profile.openExisting(path: crashFixturePath(reset: false), key: fixtureKey())
        XCTAssertEqual(try opened.scalarIntLab("SELECT v FROM crash_state"), 3)
        try FileManager.default.removeItem(at: crashGateTokenURL())
    }

    /// Phase one of the Task 0A.4 CommonCrypto↔OpenSSL gate.
    func testInteropPhase1SwiftCreatesCommonCryptoFixture() throws {
        let directory = try interopDirectory(reset: true)
        let path = directory.appendingPathComponent("swift-commoncrypto.db").path
        let opened = try Profile.create(firstInstall: .acquire(path: path), key: interopKey())
        try opened.executeLab("CREATE TABLE interop(provider TEXT NOT NULL, step INTEGER NOT NULL, marker BLOB NOT NULL);")
        try opened.insertBlobLab(
            sql: "INSERT INTO interop(provider,step,marker) VALUES('commoncrypto',1,?1);",
            blob: Self.sentinel
        )
        try opened.checkpointTruncate()
        try Profile.scanForPlaintextSentinel(path: path, sentinel: Self.sentinel)
    }

    /// Phase three: Swift verifies Rust's mutation, opens Rust's file, mutates both.
    func testInteropPhase3SwiftOpensAndMutatesBothProviders() throws {
        let directory = try interopDirectory(reset: false)
        let swiftPath = directory.appendingPathComponent("swift-commoncrypto.db").path
        let rustPath = directory.appendingPathComponent("rust-openssl.db").path
        guard FileManager.default.fileExists(atPath: rustPath) else {
            throw XCTSkip("run the Rust middle phase before the Swift reciprocal phase")
        }
        let swiftDB = try Profile.openExisting(path: swiftPath, key: interopKey())
        XCTAssertEqual(try swiftDB.scalarStringLab("SELECT provider FROM interop"), "commoncrypto")
        XCTAssertEqual(try swiftDB.scalarIntLab("SELECT step FROM interop"), 2)
        try swiftDB.executeLab("UPDATE interop SET step=3;")
        try swiftDB.checkpointTruncate()

        let rustDB = try Profile.openExisting(path: rustPath, key: interopKey())
        XCTAssertEqual(try rustDB.scalarStringLab("SELECT provider FROM interop"), "openssl")
        XCTAssertEqual(try rustDB.scalarIntLab("SELECT step FROM interop"), 1)
        XCTAssertEqual(try rustDB.blobLab("SELECT marker FROM interop"), Self.sentinel)
        try rustDB.executeLab("UPDATE interop SET step=2;")
        try rustDB.checkpointTruncate()
        try Profile.scanForPlaintextSentinel(path: swiftPath, sentinel: Self.sentinel)
        try Profile.scanForPlaintextSentinel(path: rustPath, sentinel: Self.sentinel)
    }

    private func fixtureKey() throws -> Profile.RawKey {
        try Profile.RawKey(key: Data(repeating: 0x11, count: 32), salt: Data(repeating: 0x33, count: 16))
    }

    private func interopKey() throws -> Profile.RawKey {
        try Profile.RawKey(key: Self.interopKey, salt: Self.interopSalt)
    }

    private func makeDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("raven-0a4-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func interopDirectory(reset: Bool) throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Profile.dedicatedAppGroup
        ) else {
            throw XCTSkip("signed App Group container unavailable")
        }
        let directory = container.appendingPathComponent("Task0A4Interop", isDirectory: true)
        if reset { try? FileManager.default.removeItem(at: directory) }
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        return directory
    }

    private func requireCrashGate() throws {
        let expected = Data("RAVEN_0A4_CRASH_GATE_V1\n".utf8)
        guard (try? Data(contentsOf: crashGateTokenURL())) == expected else {
            throw XCTSkip("Task 0A.4 crash phases are orchestrated by the signed gate")
        }
    }

    private func crashFixturePath(reset: Bool) throws -> String {
        let directory = try crashGateTokenURL().deletingLastPathComponent()
        let path = directory.appendingPathComponent("commoncrypto-crash.db").path
        if reset {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }
        return path
    }

    private func crashGateTokenURL() throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Profile.dedicatedAppGroup
        ) else {
            throw XCTSkip("signed App Group container unavailable")
        }
        return container
            .appendingPathComponent("Task0A4Crash", isDirectory: true)
            .appendingPathComponent("orchestrator.token")
    }

    private func crashTestRunner(marker: String, code: Int32) -> Never {
        if let markerURL = try? crashGateTokenURL()
            .deletingLastPathComponent()
            .appendingPathComponent("last-crash.marker") {
            FileManager.default.createFile(atPath: markerURL.path, contents: Data())
            if let handle = try? FileHandle(forWritingTo: markerURL) {
                try? handle.truncate(atOffset: 0)
                try? handle.write(contentsOf: Data(marker.utf8))
                try? handle.synchronize()
                try? handle.close()
            }
        }
        FileHandle.standardError.write(Data("\(marker)\n".utf8))
        fsync(STDERR_FILENO)
        _exit(code)
    }
}

#endif
