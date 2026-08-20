//
//  RavenSecureLanRustIntegrationTests.swift
//  RAVENTests — Task 18: Swift TCP dialer ↔ Rust lan_direct listener.
//

import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import RAVEN

final class RavenSecureLanRustIntegrationTests: XCTestCase {

    private let clientSeed = Data(repeating: 0x21, count: 32)

    override func setUp() {
        super.setUp()
        #if DEBUG
        UserDefaults.standard.set(true, forKey: "raven.lab.test_a")
        #endif
    }

    override func tearDown() {
        #if DEBUG
        UserDefaults.standard.removeObject(forKey: "raven.lab.test_a")
        #endif
        super.tearDown()
    }

    private static let defaultEnvFile = "/tmp/raven_swift_rust_lan.env"

    private func rustEnv() throws -> (port: UInt16, pubHex: String) {
        let envPath = ProcessInfo.processInfo.environment["RAVEN_LAN_RUST_ENV_FILE"] ?? Self.defaultEnvFile
        if FileManager.default.fileExists(atPath: envPath),
           let contents = try? String(contentsOfFile: envPath, encoding: .utf8) {
            var portStr: String?
            var pubHex: String?
            for line in contents.split(separator: "\n") {
                if line.hasPrefix("RAVEN_LAN_RUST_PORT=") {
                    portStr = String(line.dropFirst("RAVEN_LAN_RUST_PORT=".count))
                } else if line.hasPrefix("RAVEN_LAN_RUST_PUB_HEX=") {
                    pubHex = String(line.dropFirst("RAVEN_LAN_RUST_PUB_HEX=".count))
                }
            }
            if let portStr, let pubHex, let port = UInt16(portStr), port > 0,
               pubHex.count == 64, let pub = Data(ravenHex: pubHex), pub.count == 32 {
                return (port, pubHex)
            }
        }
        let portStr = ProcessInfo.processInfo.environment["RAVEN_LAN_RUST_PORT"]
            ?? ProcessInfo.processInfo.environment["RAVEN_LAN_INTEGRATION_PORT"]
        let pubHex = ProcessInfo.processInfo.environment["RAVEN_LAN_RUST_PUB_HEX"]
            ?? ProcessInfo.processInfo.environment["RAVEN_LAN_INTEGRATION_PUB_HEX"]
        guard let portStr, let pubHex, let port = UInt16(portStr), port > 0,
              pubHex.count == 64, let pub = Data(ravenHex: pubHex), pub.count == 32 else {
            throw XCTSkip("Set RAVEN_LAN_RUST_PORT + RAVEN_LAN_RUST_PUB_HEX (see ios_swift_rust_lan_integration.sh)")
        }
        return (port, pubHex)
    }

    private func localOffer(seed: Data) throws -> Data {
        let bundle = try RavenSecureLanRlb1V1.fixtureOfferBundle(
            deviceSeed: seed,
            deviceID: "swift-rust-client"
        )
        return try RavenSecureLanRlb1V1.encodeOffer(bundle)
    }

    func testSwiftDialerHandshakesWithRustListener() async throws {
        let env = try rustEnv()
        guard rustListenerReachable(port: env.port) else {
            throw XCTSkip("Rust listener unavailable — run ios_swift_rust_lan_integration.sh")
        }
        let expectedPub = try XCTUnwrap(Data(ravenHex: env.pubHex))

        let replies = try await RavenSecureLanDialerV1.dial(
            host: "127.0.0.1",
            port: env.port,
            expectedDeviceEdPub: expectedPub,
            frames: [],
            identity: .init(deviceSeed: clientSeed),
            localOffer: try localOffer(seed: clientSeed),
            limits: RavenSecureLanTransportLimits(
                ioTimeoutSeconds: 10,
                replyIdleSeconds: 1,
                maxConcurrentInboundConnections: 4,
                maxConnectionsPerIP: 2,
                maxFramesPerConnection: 8,
                connectionLifetimeSeconds: 20
            )
        )

        XCTAssertGreaterThanOrEqual(replies.count, 1, "expected peer RLB1 offer as first reply")
        XCTAssertTrue(RavenSecureLanRlb1V1.isRlb1(replies[0]), "first reply must be RLB1 offer wire")
    }

    @MainActor
    func testSwiftPairInitReceivesPairResponseOnSameConnection() async throws {
        let env = try rustEnv()
        guard rustListenerReachable(port: env.port) else {
            throw XCTSkip("Rust listener unavailable — run ios_swift_rust_lan_integration.sh")
        }
        let expectedPub = try XCTUnwrap(Data(ravenHex: env.pubHex))

        try DeviceIdentityService.shared.installDeterministicIdentityForLabIntegration(seed: clientSeed)
        try ATSAMLabTrustStore.resetLocalMaterialForLabIntegration()
        _ = try ATSAMLabTrustStore.ensureLocalMaterial()

        let replies = try await RavenSecureLanDialerV1.dialLabPairInit(
            host: "127.0.0.1",
            port: env.port,
            expectedDeviceEdPub: expectedPub
        )

        XCTAssertGreaterThanOrEqual(replies.count, 2, "expected RLB1 offer + PairResponse")
        let hasPairResponse = replies.contains { frame in
            if case .pairResponse = RavenPairInitLanOob.classifyPackedEnvelope(frame) { return true }
            return false
        }
        XCTAssertTrue(hasPairResponse, "PairInit must receive PairResponse on same TCP session")
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
}
