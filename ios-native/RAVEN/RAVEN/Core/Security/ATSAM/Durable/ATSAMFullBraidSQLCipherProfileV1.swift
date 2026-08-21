//
//  ATSAMFullBraidSQLCipherProfileV1.swift
//  RAVEN
//
//  Slice 3 Task 0A.4 — lab-only, frozen SQLCipher open profile.
//  No production store, live carrier, or A–F coordinator wiring lives here.
//

#if targetEnvironment(macCatalyst)
#error("FULL_BRAID_SQLCIPHER_CATALYST_HOLD")
#else

import Darwin
import Foundation
import SQLCipher

enum ATSAMFullBraidSQLCipherProfileV1 {
    static let productionEnabled = false
    static let allowedCipherVersions: Set<String> = ["4.17.0", "4.17.0 community"]
    static let expectedSQLiteVersion = "3.53.3"
    static let expectedProvider = "commoncrypto"
    static let dedicatedAppGroup = "group.app.raven.fullbraid"
    static let pageSize = 4096
    static let kdfIter = 256_000
    static let plaintextHeaderSize = 32
    static let reservedBytes: UInt8 = 80
    static let busyTimeoutMS = 5_000
    static let hmacAlgorithm = "HMAC_SHA512"
    static let kdfAlgorithm = "PBKDF2_HMAC_SHA512"
    static let artifactDigestSHA256 = "dd5a650346c1ba9933d6ba179f8844e03e4a075b3dd3a892796149864cd9ae57"

    private static let sqliteHeader = Data("SQLite format 3\0".utf8)
    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    enum OpenError: Error, Equatable, CustomStringConvertible {
        case productionDisabled
        case missingConsumerCodecMacro
        case missingCodecSymbol
        case pathRejected(String)
        case firstInstallProofStale
        case sqlite(stage: String, code: Int32)
        case profileMismatch(String)
        case integrityFailed(String)
        case tempDirectoryRejected
        case tempFileCreated
        case plaintextSentinelFound

        var description: String {
            switch self {
            case .productionDisabled: return "FULL_BRAID_SQLCIPHER_APPLE_LAB_ONLY"
            case .missingConsumerCodecMacro: return "FULL_BRAID_SQLCIPHER_MISSING_SQLITE_HAS_CODEC"
            case .missingCodecSymbol: return "FULL_BRAID_SQLCIPHER_CODEC_SYMBOL_MISSING"
            case .pathRejected(let reason): return "SQLCIPHER_PATH_REJECTED:\(reason)"
            case .firstInstallProofStale: return "SQLCIPHER_FIRST_INSTALL_PROOF_STALE"
            case .sqlite(let stage, let code): return "SQLCIPHER_SQLITE_ERROR:\(stage):\(code)"
            case .profileMismatch(let field): return "SQLCIPHER_PROFILE_MISMATCH:\(field)"
            case .integrityFailed(let field): return "SQLCIPHER_INTEGRITY_FAILED:\(field)"
            case .tempDirectoryRejected: return "SQLCIPHER_TEMP_DIRECTORY_REJECTED"
            case .tempFileCreated: return "SQLCIPHER_TEMP_FILE_CREATED"
            case .plaintextSentinelFound: return "SQLCIPHER_PLAINTEXT_SENTINEL_FOUND"
            }
        }
    }

    struct Report: Equatable {
        let cipherVersion: String
        let sqliteVersion: String
        let sqliteSourceID: String
        let provider: String
        let providerVersion: String
        let compileOptions: [String]
        let cipherPageSize: Int
        let cipherHMACAlgorithm: String
        let cipherKDFAlgorithm: String
        let cipherUseHMAC: Bool
        let cipherPlaintextHeaderSize: Int
        let cipherMemorySecurity: Bool
        let journalMode: String
        let synchronous: Int
        let foreignKeys: Bool
        let tempStore: Int
        let mmapSize: Int
        let lockingMode: String
        let busyTimeoutMS: Int
        let targetTriple: String
        let buildMode: String
        let artifactDigestSHA256: String
        let consumerSqliteHasCodec: Bool
        let finalImageOwner: String
    }

    final class RawKey {
        private var key: Data
        private var salt: Data

        init(key: Data, salt: Data) throws {
            guard key.count == 32 else { throw OpenError.profileMismatch("raw_key_length") }
            guard salt.count == 16 else { throw OpenError.profileMismatch("raw_salt_length") }
            self.key = key
            self.salt = salt
        }

        deinit { wipe() }

        func wipe() {
            key.resetBytes(in: 0..<key.count)
            salt.resetBytes(in: 0..<salt.count)
        }

        fileprivate func withRawLiteral<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
            var bytes = Data("x'".utf8)
            let hex = Array("0123456789abcdef".utf8)
            for byte in key {
                bytes.append(hex[Int(byte >> 4)])
                bytes.append(hex[Int(byte & 0x0f)])
            }
            for byte in salt {
                bytes.append(hex[Int(byte >> 4)])
                bytes.append(hex[Int(byte & 0x0f)])
            }
            bytes.append(UInt8(ascii: "'"))
            defer { bytes.resetBytes(in: 0..<bytes.count) }
            return try bytes.withUnsafeBytes(body)
        }
    }

    struct FirstInstallProof {
        fileprivate let canonicalPath: String

        static func acquire(path: String) throws -> Self {
            .init(canonicalPath: try validateNewPath(path))
        }
    }

    final class Opened {
        private var db: OpaquePointer?
        let report: Report
        let canonicalPath: String

        fileprivate init(db: OpaquePointer, report: Report, canonicalPath: String) {
            self.db = db
            self.report = report
            self.canonicalPath = canonicalPath
        }

        deinit { close() }

        func close() {
            guard let db else { return }
            sqlite3_close_v2(db)
            self.db = nil
        }

        func executeLab(_ sql: String) throws {
            guard let db else { throw OpenError.sqlite(stage: "closed", code: SQLITE_MISUSE) }
            try exec(db, sql, stage: "lab_execute")
        }

        func scalarStringLab(_ sql: String) throws -> String {
            guard let db else { throw OpenError.sqlite(stage: "closed", code: SQLITE_MISUSE) }
            return try scalarString(db, sql, stage: "lab_scalar")
        }

        func scalarIntLab(_ sql: String) throws -> Int {
            guard let value = Int(try scalarStringLab(sql)) else {
                throw OpenError.profileMismatch("lab_scalar_int")
            }
            return value
        }

        func insertBlobLab(sql: String, blob: Data) throws {
            guard let db else { throw OpenError.sqlite(stage: "closed", code: SQLITE_MISUSE) }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db, stage: "lab_prepare_blob")
            }
            let rc = blob.withUnsafeBytes {
                sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32($0.count), transientDestructor)
            }
            guard rc == SQLITE_OK, sqlite3_step(stmt) == SQLITE_DONE else {
                throw sqliteError(db, stage: "lab_insert_blob")
            }
        }

        func blobLab(_ sql: String) throws -> Data {
            guard let db else { throw OpenError.sqlite(stage: "closed", code: SQLITE_MISUSE) }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else {
                throw sqliteError(db, stage: "lab_read_blob")
            }
            let count = Int(sqlite3_column_bytes(stmt, 0))
            guard count > 0, let base = sqlite3_column_blob(stmt, 0) else { return Data() }
            return Data(bytes: base, count: count)
        }

        func checkpointTruncate() throws {
            guard let db else { throw OpenError.sqlite(stage: "closed", code: SQLITE_MISUSE) }
            try exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", stage: "checkpoint")
        }

        func preserveWALOnCloseForLab() throws {
            guard let db else { throw OpenError.sqlite(stage: "closed", code: SQLITE_MISUSE) }
            try setDBConfig(db, op: 1006, value: 1, field: "no_ckpt_on_close")
        }

        func reverifyProfileForLab() throws -> Report {
            guard let db else { throw OpenError.sqlite(stage: "closed", code: SQLITE_MISUSE) }
            let verified = try verifyCipherProfileAndIntegrity(db)
            return try verifyRuntimeAndBuildReport(db, verified: verified)
        }
    }

    static var consumerSqliteHasCodecDefined: Bool {
        #if SQLITE_HAS_CODEC
        true
        #else
        false
        #endif
    }

    static func isAllowedCipherVersion(_ version: String) -> Bool {
        allowedCipherVersions.contains(version)
    }

    static func create(firstInstall proof: FirstInstallProof, key: RawKey) throws -> Opened {
        guard !FileManager.default.fileExists(atPath: proof.canonicalPath) else {
            throw OpenError.firstInstallProofStale
        }
        return try openProfile(path: proof.canonicalPath, create: true, key: key)
    }

    static func openExisting(path: String, key: RawKey) throws -> Opened {
        let canonical = try validateExistingPath(path)
        try validatePublicHeader(path: canonical)
        return try openProfile(path: canonical, create: false, key: key)
    }

    static func runLabLinkageProbe() throws -> Report {
        guard !productionEnabled else { throw OpenError.productionDisabled }
        guard consumerSqliteHasCodecDefined else { throw OpenError.missingConsumerCodecMacro }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("raven-sqlcipher-linkage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("probe.db").path
        let key = try RawKey(key: Data(repeating: 0x21, count: 32), salt: Data(repeating: 0x42, count: 16))
        let opened = try create(firstInstall: .acquire(path: path), key: key)
        return opened.report
    }

    static func runTempWorkloadAndScan(
        opened: Opened,
        directory: URL,
        sentinel: Data
    ) throws {
        guard directory.isFileURL else { throw OpenError.tempDirectoryRejected }
        let canonical = directory.standardizedFileURL
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: false)
        guard (try FileManager.default.contentsOfDirectory(atPath: canonical.path)).isEmpty else {
            throw OpenError.tempDirectoryRejected
        }
        let escaped = canonical.path.replacingOccurrences(of: "'", with: "''")
        try opened.executeLab("PRAGMA temp_store_directory='\(escaped)';")
        try opened.executeLab("CREATE TEMP TABLE raven_temp(v BLOB); WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<12000) INSERT INTO raven_temp SELECT randomblob(256) FROM n; SELECT length(v) FROM raven_temp ORDER BY v; DROP TABLE raven_temp;")
        let entries = try FileManager.default.contentsOfDirectory(atPath: canonical.path)
        guard entries.isEmpty else { throw OpenError.tempFileCreated }
        try scanForPlaintextSentinel(path: opened.canonicalPath, extraDirectories: [canonical], sentinel: sentinel)
    }

    static func scanForPlaintextSentinel(
        path: String,
        extraDirectories: [URL] = [],
        sentinel: Data
    ) throws {
        guard !sentinel.isEmpty else { throw OpenError.profileMismatch("empty_sentinel") }
        var candidates = [path, path + "-wal", path + "-shm"]
        for directory in extraDirectories {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
                candidates.append(directory.appendingPathComponent(name).path)
            }
        }
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: candidate), options: [.mappedIfSafe])
            if bytes.range(of: sentinel) != nil { throw OpenError.plaintextSentinelFound }
        }
    }

    private static func openProfile(path: String, create: Bool, key: RawKey) throws -> Opened {
        guard consumerSqliteHasCodecDefined else { throw OpenError.missingConsumerCodecMacro }
        var db: OpaquePointer?
        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_EXRESCODE
        if create { flags |= SQLITE_OPEN_CREATE }
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            if let db { sqlite3_close_v2(db) }
            throw OpenError.sqlite(stage: "open", code: rc)
        }
        do {
            try hardenBeforeKey(db)
            try applyRawKeyAndProfile(db, key: key)
            let verified = try verifyCipherProfileAndIntegrity(db)
            try configurePostIntegritySecurity(db)
            try configureRuntime(db)
            let report = try verifyRuntimeAndBuildReport(db, verified: verified)
            return Opened(db: db, report: report, canonicalPath: path)
        } catch {
            sqlite3_close_v2(db)
            // Never unlink here: without the Task 0C mutation lease this open
            // path cannot prove it still owns a concurrently replaced name.
            throw error
        }
    }

    private static func hardenBeforeKey(_ db: OpaquePointer) throws {
        try setDBConfig(db, op: 1005, value: 0, field: "load_extension")
        try setDBConfig(db, op: 1017, value: 0, field: "trusted_schema")
        try setDBConfig(db, op: 1010, value: 1, field: "defensive")
        try setDBConfig(db, op: 1014, value: 0, field: "dqs_ddl")
        try setDBConfig(db, op: 1013, value: 0, field: "dqs_dml")
    }

    private static func setDBConfig(_ db: OpaquePointer, op: Int32, value: Int32, field: String) throws {
        typealias ConfigFn = @convention(c) (OpaquePointer?, Int32, Int32, UnsafeMutablePointer<Int32>?) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "raven_sqlcipher_db_config_int") else {
            throw OpenError.missingCodecSymbol
        }
        let function = unsafeBitCast(symbol, to: ConfigFn.self)
        var readback: Int32 = -1
        guard function(db, op, value, &readback) == SQLITE_OK, readback == value else {
            throw OpenError.profileMismatch(field)
        }
    }

    private static func applyRawKeyAndProfile(_ db: OpaquePointer, key: RawKey) throws {
        typealias KeyFn = @convention(c) (OpaquePointer?, UnsafeRawPointer?, Int32) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sqlite3_key") else {
            throw OpenError.missingCodecSymbol
        }
        let function = unsafeBitCast(symbol, to: KeyFn.self)
        let rc = key.withRawLiteral { raw -> Int32 in
            function(db, raw.baseAddress, Int32(raw.count))
        }
        guard rc == SQLITE_OK else { throw OpenError.sqlite(stage: "key", code: rc) }
        try exec(db, "PRAGMA cipher_page_size=4096; PRAGMA kdf_iter=256000; PRAGMA cipher_hmac_algorithm=HMAC_SHA512; PRAGMA cipher_kdf_algorithm=PBKDF2_HMAC_SHA512; PRAGMA cipher_use_hmac=ON; PRAGMA cipher_plaintext_header_size=32;", stage: "cipher_profile")
    }

    private static func configurePostIntegritySecurity(_ db: OpaquePointer) throws {
        try exec(
            db,
            "PRAGMA cipher_memory_security=ON; PRAGMA cipher_log='off'; PRAGMA cipher_log_level='NONE';",
            stage: "post_integrity_security"
        )
    }

    private static func configureRuntime(_ db: OpaquePointer) throws {
        guard sqlite3_busy_timeout(db, Int32(busyTimeoutMS)) == SQLITE_OK else {
            throw OpenError.sqlite(stage: "busy_timeout", code: sqlite3_errcode(db))
        }
        try exec(db, "PRAGMA temp_store=MEMORY; PRAGMA mmap_size=0; PRAGMA locking_mode=NORMAL; PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL; PRAGMA journal_mode=WAL;", stage: "runtime_profile")
    }

    private struct VerifiedCipherProfile {
        let cipherVersion: String
        let sqliteVersion: String
        let sourceID: String
        let provider: String
        let providerVersion: String
        let compileOptions: [String]
        let hmac: String
        let kdf: String
    }

    private static func verifyCipherProfileAndIntegrity(_ db: OpaquePointer) throws -> VerifiedCipherProfile {
        let cipherVersion = try pragmaString(db, "cipher_version")
        guard isAllowedCipherVersion(cipherVersion) else { throw OpenError.profileMismatch("cipher_version") }
        let sqliteVersion = try scalarString(db, "SELECT sqlite_version()", stage: "sqlite_version")
        guard sqliteVersion == expectedSQLiteVersion else { throw OpenError.profileMismatch("sqlite_version") }
        let sourceID = try scalarString(db, "SELECT sqlite_source_id()", stage: "sqlite_source_id")
        let provider = try pragmaString(db, "cipher_provider").lowercased()
        guard provider == expectedProvider else { throw OpenError.profileMismatch("provider") }
        let providerVersion = try pragmaString(db, "cipher_provider_version")
        guard try pragmaInt(db, "cipher_status") == 1 else { throw OpenError.profileMismatch("cipher_status") }
        guard try pragmaInt(db, "cipher_page_size") == pageSize else { throw OpenError.profileMismatch("cipher_page_size") }
        guard try pragmaInt(db, "kdf_iter") == kdfIter else { throw OpenError.profileMismatch("kdf_iter") }
        let hmac = try pragmaString(db, "cipher_hmac_algorithm")
        guard hmac == hmacAlgorithm else { throw OpenError.profileMismatch("cipher_hmac_algorithm") }
        let kdf = try pragmaString(db, "cipher_kdf_algorithm")
        guard kdf == kdfAlgorithm else { throw OpenError.profileMismatch("cipher_kdf_algorithm") }
        guard try pragmaInt(db, "cipher_use_hmac") == 1 else { throw OpenError.profileMismatch("cipher_use_hmac") }
        guard try pragmaInt(db, "cipher_plaintext_header_size") == plaintextHeaderSize else { throw OpenError.profileMismatch("plaintext_header_size") }
        let compileOptions = try rows(db, "PRAGMA compile_options;").sorted()
        guard compileOptions.contains(where: { $0.uppercased().contains("TEMP_STORE=2") }) else {
            throw OpenError.profileMismatch("compile_options")
        }
        guard try rows(db, "PRAGMA cipher_integrity_check;").isEmpty else {
            throw OpenError.integrityFailed("cipher_integrity_check")
        }
        _ = try scalarString(db, "SELECT count(*) FROM sqlite_master", stage: "sqlite_master")
        guard try rows(db, "PRAGMA integrity_check;") == ["ok"] else {
            throw OpenError.integrityFailed("integrity_check")
        }
        return VerifiedCipherProfile(
            cipherVersion: cipherVersion,
            sqliteVersion: sqliteVersion,
            sourceID: sourceID,
            provider: provider,
            providerVersion: providerVersion,
            compileOptions: compileOptions,
            hmac: hmac,
            kdf: kdf
        )
    }

    private static func verifyRuntimeAndBuildReport(
        _ db: OpaquePointer,
        verified: VerifiedCipherProfile
    ) throws -> Report {
        guard try pragmaInt(db, "cipher_memory_security") == 1 else {
            throw OpenError.profileMismatch("cipher_memory_security")
        }
        let journalMode = try pragmaString(db, "journal_mode").lowercased()
        guard journalMode == "wal" else { throw OpenError.profileMismatch("journal_mode") }
        let synchronous = try pragmaInt(db, "synchronous")
        guard synchronous == 2 else { throw OpenError.profileMismatch("synchronous") }
        let foreignKeys = try pragmaInt(db, "foreign_keys") == 1
        guard foreignKeys else { throw OpenError.profileMismatch("foreign_keys") }
        let tempStore = try pragmaInt(db, "temp_store")
        guard tempStore == 2 else { throw OpenError.profileMismatch("temp_store") }
        let mmapSize = try pragmaInt(db, "mmap_size")
        guard mmapSize == 0 else { throw OpenError.profileMismatch("mmap_size") }
        let lockingMode = try pragmaString(db, "locking_mode").lowercased()
        guard lockingMode == "normal" else { throw OpenError.profileMismatch("locking_mode") }
        let timeout = try pragmaInt(db, "busy_timeout")
        guard timeout == busyTimeoutMS else { throw OpenError.profileMismatch("busy_timeout") }
        return Report(
            cipherVersion: verified.cipherVersion,
            sqliteVersion: verified.sqliteVersion,
            sqliteSourceID: verified.sourceID,
            provider: verified.provider,
            providerVersion: verified.providerVersion,
            compileOptions: verified.compileOptions,
            cipherPageSize: pageSize,
            cipherHMACAlgorithm: verified.hmac,
            cipherKDFAlgorithm: verified.kdf,
            cipherUseHMAC: true,
            cipherPlaintextHeaderSize: plaintextHeaderSize,
            cipherMemorySecurity: true,
            journalMode: journalMode,
            synchronous: synchronous,
            foreignKeys: foreignKeys,
            tempStore: tempStore,
            mmapSize: mmapSize,
            lockingMode: lockingMode,
            busyTimeoutMS: timeout,
            targetTriple: targetTriple,
            buildMode: buildMode,
            artifactDigestSHA256: artifactDigestSHA256,
            consumerSqliteHasCodec: true,
            finalImageOwner: "SQLCipher.swift/SQLCipher"
        )
    }

    private static var targetTriple: String {
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unsupported"
        #endif
        #if targetEnvironment(simulator)
        return "\(architecture)-apple-ios17.0-simulator"
        #else
        return "\(architecture)-apple-ios17.0"
        #endif
    }

    private static var buildMode: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    private static func validateNewPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.hasPrefix("file:") else {
            throw OpenError.pathRejected("syntax")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path == path else { throw OpenError.pathRejected("noncanonical") }
        let parent = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw OpenError.pathRejected("parent")
        }
        guard !FileManager.default.fileExists(atPath: path) else { throw OpenError.firstInstallProofStale }
        guard !FileManager.default.fileExists(atPath: path + "-wal"),
              !FileManager.default.fileExists(atPath: path + "-shm") else {
            throw OpenError.pathRejected("stale_sidecar")
        }
        return path
    }

    private static func validateExistingPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.hasPrefix("file:") else {
            throw OpenError.pathRejected("syntax")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path == path else { throw OpenError.pathRejected("noncanonical") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw OpenError.pathRejected("metadata")
        }
        try validateSidecarBinding(path: path)
        return path
    }

    private static func readRegularSidecar(_ path: String) throws -> Data? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw OpenError.pathRejected("sidecar_metadata")
        }
        return try Data(contentsOf: url)
    }

    private static func validateSidecarBinding(path: String) throws {
        let wal = try readRegularSidecar(path + "-wal")
        let shm = try readRegularSidecar(path + "-shm")
        guard wal != nil || shm == nil else { throw OpenError.profileMismatch("orphan_shm") }
        guard let wal else { return }
        if wal.isEmpty {
            guard let shm, shm.count >= 96 else {
                if shm == nil { return }
                throw OpenError.profileMismatch("shm_header")
            }
            for base in [0, 48] {
                guard le32(shm, base) == 3_007_000,
                      shm[base + 12] == 1,
                      le32(shm, base + 16) == 0 else {
                    throw OpenError.profileMismatch("empty_wal_shm_binding")
                }
            }
            return
        }
        guard wal.count >= 32,
              [0x377f0682, 0x377f0683].contains(be32(wal, 0)),
              be32(wal, 4) == 3_007_000,
              be32(wal, 8) == UInt32(pageSize) else {
            throw OpenError.profileMismatch("wal_header")
        }
        guard let shm else { return }
        guard shm.count >= 96 else { throw OpenError.profileMismatch("shm_header") }
        for base in [0, 48] {
            guard le32(shm, base) == 3_007_000,
                  shm[base + 12] == 1,
                  le16(shm, base + 14) == UInt16(pageSize),
                  shm[base + 32..<base + 40] == wal[16..<24] else {
                throw OpenError.profileMismatch("wal_shm_binding")
            }
        }
    }

    private static func be32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }

    // Every supported Apple ABI in this profile is little-endian; the SHM
    // wal-index header is native-endian, unlike the big-endian WAL header.
    private static func le32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private static func le16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func validatePublicHeader(path: String) throws {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let header = try handle.read(upToCount: plaintextHeaderSize) ?? Data()
        guard header.count == plaintextHeaderSize,
              header.prefix(16) == sqliteHeader,
              header[16] == 0x10, header[17] == 0x00,
              header[20] == reservedBytes,
              header[21] == 64, header[22] == 32, header[23] == 32 else {
            throw OpenError.profileMismatch("public_header")
        }
    }

    private static func exec(_ db: OpaquePointer, _ sql: String, stage: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &error)
        if let error { sqlite3_free(error) }
        guard rc == SQLITE_OK else { throw OpenError.sqlite(stage: stage, code: rc) }
    }

    private static func pragmaString(_ db: OpaquePointer, _ name: String) throws -> String {
        try scalarString(db, "PRAGMA \(name);", stage: name)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func pragmaInt(_ db: OpaquePointer, _ name: String) throws -> Int {
        guard let value = Int(try pragmaString(db, name)) else { throw OpenError.profileMismatch(name) }
        return value
    }

    private static func scalarString(_ db: OpaquePointer, _ sql: String, stage: String) throws -> String {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw sqliteError(db, stage: stage) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let value = sqlite3_column_text(stmt, 0) else {
            throw sqliteError(db, stage: stage)
        }
        return String(cString: value)
    }

    private static func rows(_ db: OpaquePointer, _ sql: String) throws -> [String] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw sqliteError(db, stage: "rows_prepare") }
        var output: [String] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return output }
            guard rc == SQLITE_ROW else { throw sqliteError(db, stage: "rows_step") }
            if let value = sqlite3_column_text(stmt, 0) { output.append(String(cString: value)) }
        }
    }

    private static func sqliteError(_ db: OpaquePointer, stage: String) -> OpenError {
        OpenError.sqlite(stage: stage, code: sqlite3_extended_errcode(db))
    }
}

#endif
