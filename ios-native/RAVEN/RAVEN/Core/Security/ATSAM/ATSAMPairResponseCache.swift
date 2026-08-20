//
//  ATSAMPairResponseCache.swift
//  RAVEN — durable PairResponse OOB replay cache (§4.9 responder).
//
//  Path: …/app.raven.ios.atsam.prekey.v1/lan_pair_response/{init_id_hex}
//  Atomic write → file fsync → parent-dir fsync before PairInit confirm.
//

import CryptoKit
import Darwin
import Foundation

enum ATSAMPairResponseCache {

    static let namespace = "app.raven.ios.atsam.prekey.v1"

    enum CacheError: Error, Equatable {
        case empty
        case notPairResponseOob
        case decodeFailed
        case initIDMismatch
        case initHashMismatch
        case responderMismatch
        case badSignature
        case fsyncFailed
        case unavailable
    }

    private static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("raven/atsam/\(namespace)", isDirectory: true)
    }

    /// Test-only override; production uses Application Support.
    private static var _testRoot: URL?

    static func setTestRoot(_ url: URL?) {
        _testRoot = url
    }

    static func rootDirectory() -> URL {
        _testRoot ?? defaultRoot
    }

    static func path(forInitID initID: Data) -> URL {
        rootDirectory()
            .appendingPathComponent("lan_pair_response", isDirectory: true)
            .appendingPathComponent(initID.ravenHexLower)
    }

    /// Persist packed PairResponse OOB bytes durably before session confirm.
    static func store(initID: Data, packed: Data) throws {
        guard initID.count == 16, !packed.isEmpty else { throw CacheError.empty }
        try atomicWritePrivate(path: path(forInitID: initID), contents: packed)
    }

    /// Load and cryptographically verify cached bytes against the accepted PairInit.
    static func loadVerified(
        initValue: ATSAMPairInitV1.PairInit,
        localDeviceEd: Data
    ) throws -> Data {
        let file = path(forInitID: initValue.initID)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw CacheError.unavailable
        }
        let bytes = try Data(contentsOf: file)
        do {
            return try verifyCachedBytes(bytes, initValue: initValue, localDeviceEd: localDeviceEd)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    #if DEBUG
    /// Test hook: remove cached response so fault-injection windows start clean.
    static func removeStored(initID: Data) throws {
        let file = path(forInitID: initID)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }
    #endif

    static func verifyCachedBytes(
        _ packed: Data,
        initValue: ATSAMPairInitV1.PairInit,
        localDeviceEd: Data
    ) throws -> Data {
        guard !packed.isEmpty else { throw CacheError.empty }
        guard case .pairResponse(let wire) = RavenPairInitLanOob.classifyPackedEnvelope(packed) else {
            throw CacheError.notPairResponseOob
        }
        let response = try ATSAMPairInitV1.decodeResponse(wire)
        let digest = try ATSAMPairInitV1.initHash(initValue)
        guard response.initID == initValue.initID else { throw CacheError.initIDMismatch }
        guard response.initHash == digest else { throw CacheError.initHashMismatch }
        guard response.responderDeviceEd25519PublicKey == localDeviceEd else {
            throw CacheError.responderMismatch
        }
        let signing = try ATSAMPairInitV1.responseSigningBytes(response)
        guard verifyEd25519(
            signature: response.signature,
            message: signing,
            publicKey: response.responderDeviceEd25519PublicKey
        ) else {
            throw CacheError.badSignature
        }
        return packed
    }

    // MARK: - Durable file write (matches ATSAMOutboundBodyStage)

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
            throw CacheError.fsyncFailed
        }
    }

    private static func fsyncParentDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else { throw CacheError.fsyncFailed }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw CacheError.fsyncFailed }
    }

    private static func verifyEd25519(signature: Data, message: Data, publicKey: Data) -> Bool {
        guard signature.count == 64,
              publicKey.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            return false
        }
        return key.isValidSignature(signature, for: message)
    }
}

private extension Data {
    var ravenHexLower: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
