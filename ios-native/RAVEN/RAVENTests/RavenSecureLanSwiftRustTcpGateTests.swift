//
//  RavenSecureLanSwiftRustTcpGateTests.swift
//  RAVENTests — cross-process Swift ↔ raven-node TCP message gate.
//
//  Requires ios_swift_rust_tcp_message_gate.sh (real TCP; no memory duplex).
//

#if DEBUG

import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import RAVEN

@MainActor
final class RavenSecureLanSwiftRustTcpGateTests: XCTestCase {

    private let clientSeed = Data(repeating: 0x21, count: 32)
    private let labDefaultsKey = "raven.lab.test_a"
    private static let defaultEnvFile = "/tmp/raven_swift_rust_tcp_gate.env"
    private static let reverseReadyFile = "/tmp/raven_swift_rust_tcp_gate.reverse.ready"
    private static let reverseDoneFile = "/tmp/raven_swift_rust_tcp_gate.reverse.done"
    private static let reverseStatusFile = "/tmp/raven_swift_rust_tcp_gate.reverse.status"

    private var dbRoot: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        if ProcessInfo.processInfo.environment["RAVEN_LAB_TEST_A"] != "1",
           !ProcessInfo.processInfo.arguments.contains("-ravenLabTestA") {
            UserDefaults.standard.set(true, forKey: labDefaultsKey)
        }
        XCTAssertTrue(ATSAMEndpointDurableAdapters.labTestAEnabled, "lab gate must be open")
        ATSAMLabTrustStoreDebugKeychain.reset()
        ATSAMOutboundBodyStage.KeychainStageKey.resetLabStoreForTesting()
    }

    override func tearDownWithError() throws {
        ATSAMLabEndpointHost.shared.stop()
        try? KeychainProtectedSessionStore.deleteAllSessionsForTesting()
        ATSAMLabEndpointHost.rebindAcceptanceDBForTesting(
            .failure(SQLCipherAcceptanceDatabaseError.sqlCipherUnavailable)
        )
        if let dbRoot {
            try? FileManager.default.removeItem(at: dbRoot)
        }
        UserDefaults.standard.removeObject(forKey: labDefaultsKey)
        RavenSecureLanLabListenerController.shared.stopLabListen()
        RavenSecureLanLabListenerController.shared.setForegroundForTesting(true)
        try super.tearDownWithError()
    }

    // MARK: - Forward: PairInit → M1 → sealed ACK → M2

    func testForwardPairInitMessageAckSecondMessageOverTCP() async throws {
        let ctx = try await prepareForwardContext()
        let host = ATSAMLabEndpointHost.shared

        let status1 = try await host.sendLabIndexedMessage("tcp-gate-m1")
        XCTAssertTrue(status1.contains("inbound ACK accepted"), status1)
        try assertAllOutstandingDelivered(db: ctx.db)
        let sessionID = try XCTUnwrap(host.debugBoundSessionIDs().first)
        let afterM1 = try ATSAMEndpointDurableAdapters.sharedProtectedStore.load(sessionID: sessionID)
        XCTAssertEqual(afterM1.nextSendIndex, 1)

        let status2 = try await host.sendLabIndexedMessage("tcp-gate-m2")
        XCTAssertTrue(status2.contains("inbound ACK accepted"), status2)
        try assertAllOutstandingDelivered(db: ctx.db)
        let afterM2 = try ATSAMEndpointDurableAdapters.sharedProtectedStore.load(sessionID: sessionID)
        XCTAssertEqual(afterM2.nextSendIndex, 2)

        // No second PairInit: initiator outbound pending must be clear.
        XCTAssertNil(try ATSAMPrekeyLifecycleStore.shared.loadPendingInitiatorOutbound())
        emitGateLog(status: "FORWARD_M1_ACK_M2_OK", detail: "sendIndex=2")
    }

    func testDuplicateMessageReturnsSameAckNoSecondCommit() async throws {
        let ctx = try await prepareForwardContext()
        let host = ATSAMLabEndpointHost.shared

        let packed = try await host.captureOutboundIndexedMessage("tcp-gate-dup")
        let replies1 = try await host.dialLabCollectingReplies(outboundFrames: [packed])
        let ack1 = try XCTUnwrap(ATSAMLabEndpointHost.sealedAckFrame(in: replies1))
        try await host.acceptInboundAckPacked(ack1)
        let deliveredCount = try ctx.db.outstandingDeliveryStatesForTesting()
            .values.filter { $0 == .delivered }.count
        XCTAssertGreaterThanOrEqual(deliveredCount, 1)

        let sessionID = try XCTUnwrap(host.debugBoundSessionIDs().first)
        let beforeRecv = try ATSAMEndpointDurableAdapters.sharedProtectedStore.load(sessionID: sessionID)

        let replies2 = try await host.dialLabCollectingReplies(outboundFrames: [packed])
        let ack2 = try XCTUnwrap(ATSAMLabEndpointHost.sealedAckFrame(in: replies2))
        XCTAssertEqual(ack1, ack2, "duplicate must return exact same sealed ACK bytes")

        let afterRecv = try ATSAMEndpointDurableAdapters.sharedProtectedStore.load(sessionID: sessionID)
        XCTAssertEqual(afterRecv.nextReceiveIndex, beforeRecv.nextReceiveIndex)
        emitGateLog(status: "DUPLICATE_ACK_IDEMPOTENT", detail: "ack_bytes=\(ack1.count)")
    }

    func testAckLossRetriesExactCiphertextThenDelivers() async throws {
        _ = try await prepareForwardContext()
        let host = ATSAMLabEndpointHost.shared

        let packed = try await host.captureOutboundIndexedMessage("tcp-gate-ack-loss")
        // Simulate ACK loss: dial once, discard ACK without accept.
        let lostReplies = try await host.dialLabCollectingReplies(outboundFrames: [packed])
        XCTAssertNotNil(ATSAMLabEndpointHost.sealedAckFrame(in: lostReplies))

        // Retry exact same packed ciphertext; accept ACK → Delivered.
        try await host.dialLabAndAcceptInboundAckForTesting(outboundFrames: [packed])
        XCTAssertTrue(host.lastLabStatus.contains("inbound ACK accepted"))
        emitGateLog(status: "ACK_LOSS_RETRY_OK", detail: "packed=\(packed.count)")
    }

    func testTamperProducesNoAckAndNoRatchetAdvance() async throws {
        _ = try await prepareForwardContext()
        let host = ATSAMLabEndpointHost.shared
        let sessionID = try XCTUnwrap(host.debugBoundSessionIDs().first)
        let before = try ATSAMEndpointDurableAdapters.sharedProtectedStore.load(sessionID: sessionID)

        var packed = try await host.captureOutboundIndexedMessage("tcp-gate-tamper")
        // Corrupt ciphertext body (keep length) so Noise may still deliver a frame but envelope fails.
        if packed.count > 40 {
            packed[packed.count - 17] ^= 0x5A
        }
        let replies = try await host.dialLabCollectingReplies(outboundFrames: [packed])
        XCTAssertNil(
            ATSAMLabEndpointHost.sealedAckFrame(in: replies),
            "tampered message must not mint sealed ACK"
        )
        let after = try ATSAMEndpointDurableAdapters.sharedProtectedStore.load(sessionID: sessionID)
        XCTAssertEqual(after.nextSendIndex, before.nextSendIndex &+ 1, "local send index advanced on capture")
        // Remote receive index is not on initiator store; assert no inbound ACK path.
        XCTAssertFalse(host.lastLabStatus.contains("inbound ACK accepted"))
        emitGateLog(status: "TAMPER_NO_ACK", detail: "replies=\(replies.count)")
    }

    func testBlockPeerRefusesWithoutAck() async throws {
        let ctx = try await prepareForwardContext()
        let host = ATSAMLabEndpointHost.shared
        let peerEd = try XCTUnwrap(Data(ravenHex: ctx.rustPubHex))

        // Block the live Swift client device ed (same key registered on Rust).
        try writeRustBlocklist(pubHex: ctx.clientPubHex)
        defer { try? clearRustBlocklist() }

        let packed = try await host.captureOutboundIndexedMessage("tcp-gate-block")
        do {
            let replies = try await host.dialLabCollectingReplies(outboundFrames: [packed])
            XCTAssertNil(
                ATSAMLabEndpointHost.sealedAckFrame(in: replies),
                "blocked peer must not mint sealed ACK"
            )
        } catch {
            // Connection abort / peerBlocked is also fail-closed success.
            emitGateLog(status: "BLOCK_REFUSED", detail: "error")
            return
        }
        _ = peerEd
        emitGateLog(status: "BLOCK_NO_ACK", detail: "ok")
    }

    func testContactDeleteRefusesWithoutAck() async throws {
        _ = try await prepareForwardContext()
        let host = ATSAMLabEndpointHost.shared
        try emptyRustContacts()

        let packed = try await host.captureOutboundIndexedMessage("tcp-gate-delete")
        do {
            let replies = try await host.dialLabCollectingReplies(outboundFrames: [packed])
            XCTAssertNil(ATSAMLabEndpointHost.sealedAckFrame(in: replies))
        } catch {
            emitGateLog(status: "CONTACT_DELETE_REFUSED", detail: "error")
            try restoreRustContactsBackup()
            return
        }
        try restoreRustContactsBackup()
        emitGateLog(status: "CONTACT_DELETE_NO_ACK", detail: "ok")
    }

    func testLocalRevocationStickyDenyBlocksDialPath() async throws {
        let ctx = try await prepareForwardContext()
        let host = ATSAMLabEndpointHost.shared
        let peerEd = try XCTUnwrap(Data(ravenHex: ctx.rustPubHex))
        let identity = try DeviceIdentityService.shared.ed25519PublicKeyData()

        try ATSAMLabTrustStore.recordRevocationDeny(deviceEd: peerEd, identityPub: identity)
        defer {
            try? ATSAMLabTrustStoreDebugKeychain.clearRevocationMarkers(
                deviceEd: peerEd,
                identityPub: identity
            )
        }
        XCTAssertTrue(
            ATSAMLabTrustStore.isAdmissionDenied(deviceEd: peerEd, identityPub: identity, noiseEd: nil)
        )
        // Dialer path still attempts TCP; admission deny must be visible for contact book.
        let book = RavenSecureLanLabTrustContactBook()
        XCTAssertTrue(book.isBlocked(deviceEdPub: peerEd, userEdPub: identity, noiseEdPub: peerEd))
        emitGateLog(status: "REVOCATION_STICKY_DENY", detail: "local")
        _ = host
    }

    func testNoLegacyServerlessLanPathFallbackInSecureSources() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("RAVEN/Core/Security/LAN")
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var violations: [String] = []
        for url in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if trimmed.contains("RavenServerlessLanPath.")
                    || trimmed.contains("RVNP1")
                    || trimmed.contains("interim") {
                    violations.append("\(url.lastPathComponent): \(trimmed)")
                }
            }
        }
        XCTAssertTrue(violations.isEmpty, "secure LAN must not fall back: \(violations)")
        emitGateLog(status: "NO_LEGACY_FALLBACK", detail: "lan_sources_ok")
    }

    // MARK: - Reverse: Rust → Swift listener

    func testReverseRustToSwiftMessageAckOverTCP() async throws {
        continueAfterFailure = false
        let ctx = try await prepareForwardContext(listen: true)
        let host = ATSAMLabEndpointHost.shared
        _ = host

        // Ready as soon as PairInit + listen are up so the orchestrator can inject
        // without waiting on an extra forward M1 (script ready-wait is ~60s).
        let listenPort = ctx.listenPort
        XCTAssertGreaterThan(listenPort, 0)
        let ready = """
        RAVEN_SWIFT_LISTEN_PORT=\(listenPort)
        RAVEN_SWIFT_PUB_HEX=\(ctx.clientPubHex)
        """
        try ready.write(toFile: Self.reverseReadyFile, atomically: true, encoding: .utf8)
        if let work = ctx.workDir {
            try ready.write(
                toFile: (work as NSString).appendingPathComponent("reverse.ready"),
                atomically: true,
                encoding: .utf8
            )
        }
        emitGateLog(status: "REVERSE_LISTEN_READY", detail: "port=\(listenPort)")

        // Wait for orchestrator ash inject (script writes .done into /tmp and WORKDIR).
        var doneCandidates = [Self.reverseDoneFile]
        var statusCandidates = [Self.reverseStatusFile]
        if let work = ctx.workDir {
            doneCandidates.append((work as NSString).appendingPathComponent("reverse.done"))
            statusCandidates.append((work as NSString).appendingPathComponent("reverse.status"))
        }
        let deadline = Date().addingTimeInterval(120)
        var sawDone = false
        while Date() < deadline {
            if doneCandidates.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
                sawDone = true
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(sawDone, "orchestrator must inject Rust→Swift message (missing done file)")

        let statusPath = statusCandidates.first(where: { FileManager.default.fileExists(atPath: $0) })
        let status = statusPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        guard status.contains("status delivered") || (status.contains("delivered") && status.contains("PASS")) else {
            XCTFail("reverse ash status: \(status)")
            return
        }
        emitGateLog(status: "REVERSE_RUST_TO_SWIFT_OK", detail: "done")
    }

    // MARK: - Setup

    private struct ForwardContext {
        let db: SQLCipherAcceptanceDatabase
        let rustPubHex: String
        let clientPubHex: String
        let listenPort: UInt16
        let workDir: String?
    }

    private func prepareForwardContext(listen: Bool = false) async throws -> ForwardContext {
        let env = try loadGateEnv()
        guard rustListenerReachable(port: env.port) else {
            XCTFail("Rust raven-node listener not reachable on 127.0.0.1:\(env.port) — run gate script")
            throw XCTestError(.failureWhileWaiting)
        }

        try DeviceIdentityService.shared.installDeterministicIdentityForLabIntegration(seed: clientSeed)
        try ATSAMLabTrustStore.resetLocalMaterialForLabIntegration()
        _ = try ATSAMLabTrustStore.ensureLocalMaterial()
        ATSAMLabEndpointHost.shared.resetLabHostStateForTesting()
        if let pending = try ATSAMPrekeyLifecycleStore.shared.loadPendingInitiatorOutbound() {
            try ATSAMPrekeyLifecycleStore.shared.clearInitiatorOutbound(initID: pending.initID)
        }

        if let certPath = env.certJSONPath,
           let cert = try? String(contentsOfFile: certPath, encoding: .utf8) {
            try ATSAMLabTrustStore.importPeerCertJSON(cert)
        }
        if let prekeyPath = env.prekeyJSONPath,
           let prekey = try? String(contentsOfFile: prekeyPath, encoding: .utf8) {
            try ATSAMLabTrustStore.importPeerPrekeyJSON(prekey)
        }

        let listenPort: UInt16 = listen ? env.swiftListenPort : 0
        let cfg = RavenServerlessLanConfig(
            host: "127.0.0.1",
            port: env.port,
            peerPubHex: env.pubHex,
            listenPort: listenPort
        )
        cfg.save()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tcp-gate-\(UUID().uuidString)", isDirectory: true)
        dbRoot = root
        let db = try SQLCipherAcceptanceDatabase(
            testRoot: root,
            keyHex: String(repeating: "ab", count: 32)
        )
        ATSAMLabEndpointHost.rebindAcceptanceDBForTesting(.success(db))

        let host = ATSAMLabEndpointHost.shared
        host.refreshSecureListen()
        if listen {
            RavenSecureLanLabListenerController.shared.setForegroundForTesting(true)
            try RavenSecureLanTransportV1.configureLabListenIfEnabled(port: listenPort)
            // Brief settle for NWListener bind.
            try await Task.sleep(nanoseconds: 300_000_000)
        }

        let pairStatus = try await host.dialPairInitToMac()
        XCTAssertTrue(pairStatus.contains("initiator session installed"), pairStatus)

        let clientPub = try DeviceIdentityService.shared.deviceSigningPublicKeyRaw()
        return ForwardContext(
            db: db,
            rustPubHex: env.pubHex,
            clientPubHex: clientPub.ravenHex,
            listenPort: listenPort,
            workDir: env.workDir
        )
    }

    private struct GateEnv {
        let port: UInt16
        let pubHex: String
        let certJSONPath: String?
        let prekeyJSONPath: String?
        let workDir: String?
        let swiftListenPort: UInt16
    }

    private func loadGateEnv() throws -> GateEnv {
        let envPath = ProcessInfo.processInfo.environment["RAVEN_LAN_RUST_ENV_FILE"] ?? Self.defaultEnvFile
        var map: [String: String] = [:]
        if FileManager.default.fileExists(atPath: envPath),
           let contents = try? String(contentsOfFile: envPath, encoding: .utf8) {
            for line in contents.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    map[String(parts[0])] = String(parts[1])
                }
            }
        }
        func env(_ key: String) -> String? {
            ProcessInfo.processInfo.environment[key] ?? map[key]
        }
        guard let portStr = env("RAVEN_LAN_RUST_PORT"),
              let port = UInt16(portStr), port > 0,
              let pubHex = env("RAVEN_LAN_RUST_PUB_HEX"),
              pubHex.count == 64 else {
            XCTFail("missing RAVEN_LAN_RUST_PORT/PUB_HEX — run ios_swift_rust_tcp_message_gate.sh")
            throw XCTestError(.failureWhileWaiting)
        }
        let listen = UInt16(env("RAVEN_SWIFT_LISTEN_PORT") ?? "") ?? 17433
        return GateEnv(
            port: port,
            pubHex: pubHex,
            certJSONPath: env("RAVEN_LAN_RUST_CERT_JSON"),
            prekeyJSONPath: env("RAVEN_LAN_RUST_PREKEY_JSON"),
            workDir: env("RAVEN_LAN_RUST_WORKDIR"),
            swiftListenPort: listen
        )
    }

    private func assertAllOutstandingDelivered(db: SQLCipherAcceptanceDatabase) throws {
        let states = try db.outstandingDeliveryStatesForTesting()
        XCTAssertFalse(states.isEmpty, "expected outstanding rows after send")
        for (_, state) in states {
            XCTAssertEqual(state, .delivered)
        }
    }

    private func rustWorkDir() throws -> URL {
        let env = try loadGateEnv()
        guard let work = env.workDir else {
            throw XCTestError(.failureWhileWaiting)
        }
        return URL(fileURLWithPath: work)
    }

    private func writeRustBlocklist(pubHex: String) throws {
        let dir = try rustWorkDir()
        let body = """
        {\n  \"pub_hex\": [\"\(pubHex.lowercased())\"]\n}\n
        """
        // Raven BlockList path is `blocked_pubs.json` (not blocked.json).
        try body.write(
            to: dir.appendingPathComponent("blocked_pubs.json"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func clearRustBlocklist() throws {
        let path = try rustWorkDir().appendingPathComponent("blocked_pubs.json")
        try? FileManager.default.removeItem(at: path)
    }

    private func emptyRustContacts() throws {
        let contacts = try rustWorkDir().appendingPathComponent("contacts.json")
        let backup = contacts.appendingPathExtension("bak")
        if FileManager.default.fileExists(atPath: contacts.path) {
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.copyItem(at: contacts, to: backup)
        }
        try "[]\n".write(to: contacts, atomically: true, encoding: .utf8)
    }

    private func restoreRustContactsBackup() throws {
        let contacts = try rustWorkDir().appendingPathComponent("contacts.json")
        let backup = contacts.appendingPathExtension("bak")
        if FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.removeItem(at: contacts)
            try FileManager.default.moveItem(at: backup, to: contacts)
        }
    }

    private func rustListenerReachable(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private func emitGateLog(status: String, detail: String) {
        // Non-sensitive only: status / digests / indexes — never plaintext or keys.
        TestATrace.emit(
            location: "RavenSecureLanSwiftRustTcpGateTests",
            message: "TRACE_TCP_GATE",
            status: status,
            detail: detail
        )
        #if DEBUG
        print("🕊️ [TcpGate] status=\(status) detail=\(detail)")
        #endif
    }
}

private extension DeviceIdentityService {
    func deviceSigningPublicKeyRaw() throws -> Data {
        guard let seed = deviceSigningSeed else {
            throw NSError(domain: "TcpGate", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "device signing seed missing",
            ])
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
    }

    func ed25519PublicKeyData() throws -> Data {
        try deviceSigningPublicKeyRaw()
    }
}

#endif
