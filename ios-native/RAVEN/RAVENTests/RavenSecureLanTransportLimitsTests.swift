//
//  RavenSecureLanTransportLimitsTests.swift
//  RAVENTests
//

import Foundation
import Network
import XCTest
@testable import RAVEN

final class RavenSecureLanTransportLimitsTests: XCTestCase {

    func testProductionLimitConstantsMatchSpec() {
        let limits = RavenSecureLanTransportLimits.production
        XCTAssertEqual(limits.ioTimeoutSeconds, 30)
        XCTAssertEqual(limits.replyIdleSeconds, 2)
        XCTAssertEqual(limits.maxConcurrentInboundConnections, 32)
        XCTAssertEqual(limits.maxConnectionsPerIP, 4)
        XCTAssertEqual(limits.maxFramesPerConnection, 64)
        XCTAssertEqual(limits.connectionLifetimeSeconds, 120)
        XCTAssertGreaterThanOrEqual(limits.maxConcurrentInboundConnections, limits.maxConnectionsPerIP)
        XCTAssertGreaterThan(limits.maxFramesPerConnection, 0)
        XCTAssertGreaterThanOrEqual(limits.connectionLifetimeSeconds, 30)
    }

    func testCanonicalIPv4Key() {
        let key = RavenSecureLanIPKeyCodec.ipv4(192, 168, 1, 10)
        XCTAssertEqual(key.family, .ipv4)
        XCTAssertEqual(key.octets, Data([192, 168, 1, 10]))
        XCTAssertEqual(key.byteCount, 4)
    }

    func testCanonicalIPv6LoopbackKey() {
        let fromParts = RavenSecureLanIPKeyCodec.ipv6Loopback()
        let expanded = RavenSecureLanIPKeyCodec.ipv6Octets(
            Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
        )!
        XCTAssertEqual(fromParts, expanded)
        XCTAssertEqual(fromParts.family, .ipv6)
        XCTAssertEqual(fromParts.byteCount, 16)
    }

    func testDifferentIPsDifferentKeys() {
        let a = RavenSecureLanIPKeyCodec.ipv4(10, 0, 0, 1)
        let b = RavenSecureLanIPKeyCodec.ipv4(10, 0, 0, 2)
        let c = RavenSecureLanIPKeyCodec.ipv6Loopback()
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testIPv4MappedIPv6StaysIPv6WhenPresentedAsIPv6() {
        var mapped = Data(repeating: 0, count: 10)
        mapped.append(contentsOf: [0xFF, 0xFF])
        mapped.append(contentsOf: [192, 168, 0, 1])
        let key = RavenSecureLanIPKeyCodec.ipv6Octets(mapped)!
        XCTAssertEqual(key.family, .ipv6)
        XCTAssertEqual(key.byteCount, 16)
        XCTAssertNotEqual(key, RavenSecureLanIPKeyCodec.ipv4(192, 168, 0, 1))
    }

    func testNetworkHostKeyUsesRawOctets() throws {
        let v4 = try XCTUnwrap(IPv4Address("10.1.2.3"))
        let key4 = try XCTUnwrap(RavenSecureLanIPKeyCodec.key(from: .ipv4(v4)))
        XCTAssertEqual(key4.octets, Data([10, 1, 2, 3]))

        let v6 = try XCTUnwrap(IPv6Address("::1"))
        let key6 = try XCTUnwrap(RavenSecureLanIPKeyCodec.key(from: .ipv6(v6)))
        XCTAssertEqual(key6.octets, RavenSecureLanIPKeyCodec.ipv6Loopback().octets)
    }

    func testAdmissionEnforcesGlobalAndPerIPCaps() {
        let limits = RavenSecureLanTransportLimits(
            ioTimeoutSeconds: 30,
            replyIdleSeconds: 2,
            maxConcurrentInboundConnections: 2,
            maxConnectionsPerIP: 1,
            maxFramesPerConnection: 64,
            connectionLifetimeSeconds: 120
        )
        let admission = RavenSecureLanAdmissionController(limits: limits)
        let ipA = RavenSecureLanIPKeyCodec.ipv4(127, 0, 0, 1)
        let ipB = RavenSecureLanIPKeyCodec.ipv4(127, 0, 0, 2)

        XCTAssertTrue(admission.tryAdmit(ip: ipA))
        XCTAssertFalse(admission.tryAdmit(ip: ipA))
        XCTAssertTrue(admission.tryAdmit(ip: ipB))
        XCTAssertFalse(admission.tryAdmit(ip: ipB))

        admission.release(ip: ipA)
        XCTAssertTrue(admission.tryAdmit(ip: ipA))
    }

    func testAdmissionGlobalCap32PerIPCap4() {
        let admission = RavenSecureLanAdmissionController()
        let baseIP = RavenSecureLanIPKeyCodec.ipv4(10, 0, 0, 1)

        for i in 0..<4 {
            XCTAssertTrue(admission.tryAdmit(ip: baseIP), "per-ip slot \(i)")
        }
        XCTAssertFalse(admission.tryAdmit(ip: baseIP), "5th on same IP denied")

        for last in 2...29 {
            let key = RavenSecureLanIPKeyCodec.ipv4(10, 0, 0, UInt8(last))
            XCTAssertTrue(admission.tryAdmit(ip: key), "global slot for 10.0.0.\(last)")
        }
        XCTAssertEqual(admission.globalActive, 32)
        XCTAssertFalse(admission.tryAdmit(ip: RavenSecureLanIPKeyCodec.ipv4(10, 0, 0, 99)))

        admission.release(ip: baseIP)
        XCTAssertTrue(admission.tryAdmit(ip: RavenSecureLanIPKeyCodec.ipv4(10, 0, 0, 99)))
    }

    func testFrameBudgetRejectsAfterMax() {
        var budget = RavenSecureLanFrameBudget()
        for _ in 0..<64 {
            XCTAssertTrue(budget.consumeFrame(maxFrames: 64))
        }
        XCTAssertFalse(budget.consumeFrame(maxFrames: 64))
        XCTAssertEqual(budget.framesSeen, 65)
    }

    func testConnectionLifetimeConstant() {
        let opened = Date(timeIntervalSince1970: 1_000)
        let tracker = RavenSecureLanConnectionLifetime(openedAt: opened)
        XCTAssertFalse(tracker.isExpired(at: opened.addingTimeInterval(119)))
        XCTAssertTrue(tracker.isExpired(at: opened.addingTimeInterval(120)))
    }

    func testSecurePathRejectsLegacyLanPath() {
        XCTAssertThrowsError(
            try RavenSecureLanSecurePathGuard.refuseLegacyDelegation(useLegacyPath: true)
        ) { error in
            XCTAssertEqual(error as? RavenSecureLanError, .legacyLanPathForbidden)
        }
        XCTAssertNoThrow(try RavenSecureLanTransportV1.preflightSecureEntry())
        XCTAssertNoThrow(try RavenSecureLanDispatchV1.preflightSecureEntry())
    }

    @MainActor
    func testListenRefusesWhenLabGateClosed() {
        UserDefaults.standard.set(false, forKey: "raven.lab.test_a")
        defer { UserDefaults.standard.set(true, forKey: "raven.lab.test_a") }
        XCTAssertThrowsError(
            try RavenSecureLanTransportV1.configureLabListenIfEnabled(port: 17420)
        ) { error in
            XCTAssertEqual(error as? RavenSecureLanListenError, .labGateClosed)
        }
    }
}
