//
//  RavenSecureLanEphemeralPeersTests.swift
//  RAVENTests
//

import Foundation
import XCTest
@testable import RAVEN

final class RavenSecureLanTrustedPeerPersistenceSpy: RavenSecureLanTrustedPeerPersistence {
    private(set) var persistCalls: [RavenSecureLanRlb1V1.LanBundle] = []

    func persistTrustedPeerBundle(_ bundle: RavenSecureLanRlb1V1.LanBundle) throws {
        persistCalls.append(bundle)
    }
}

final class RavenSecureLanEphemeralPeersTests: XCTestCase {

    private func bundle(seed: UInt8, deviceID: String) throws -> RavenSecureLanRlb1V1.LanBundle {
        try RavenSecureLanRlb1V1.fixtureOfferBundle(
            deviceSeed: Data(repeating: seed, count: 32),
            deviceID: deviceID
        )
    }

    func testMaxSixteenPeersEnforced() throws {
        var clock = Date(timeIntervalSince1970: 1_000)
        let cache = RavenSecureLanEphemeralPeerCache(now: { clock })

        for i in 0..<16 {
            let b = try bundle(seed: UInt8(i + 1), deviceID: "peer-\(i)")
            cache.remember(b)
        }
        XCTAssertEqual(cache.count, 16)

        let extra = try bundle(seed: 0xEE, deviceID: "peer-extra")
        cache.remember(extra)
        XCTAssertEqual(cache.count, 16)
        XCTAssertNotNil(cache.load(deviceEdPub: extra.cert.deviceEdPub))
    }

    func testTTLFifteenMinutesFromLastRemember() throws {
        var clock = Date(timeIntervalSince1970: 10_000)
        let cache = RavenSecureLanEphemeralPeerCache(now: { clock })
        let peer = try bundle(seed: 0xAB, deviceID: "ttl-peer")
        cache.remember(peer)
        XCTAssertNotNil(cache.load(deviceEdPub: peer.cert.deviceEdPub))

        clock = clock.addingTimeInterval(15 * 60 - 1)
        XCTAssertNotNil(cache.load(deviceEdPub: peer.cert.deviceEdPub))

        clock = clock.addingTimeInterval(2)
        XCTAssertNil(cache.load(deviceEdPub: peer.cert.deviceEdPub))
    }

    func testEvictsEarliestExpiryWhenAtCap() throws {
        var clock = Date(timeIntervalSince1970: 5_000)
        let cache = RavenSecureLanEphemeralPeerCache(now: { clock })

        var firstDevice: Data?
        for i in 0..<16 {
            clock = Date(timeIntervalSince1970: 5_000 + Double(i))
            let b = try bundle(seed: UInt8(i + 1), deviceID: "evict-\(i)")
            if i == 0 { firstDevice = b.cert.deviceEdPub }
            cache.remember(b)
        }

        clock = Date(timeIntervalSince1970: 5_020)
        let newcomer = try bundle(seed: 0xCC, deviceID: "evict-new")
        cache.remember(newcomer)

        XCTAssertEqual(cache.count, 16)
        XCTAssertNil(cache.load(deviceEdPub: try XCTUnwrap(firstDevice)))
        XCTAssertNotNil(cache.load(deviceEdPub: newcomer.cert.deviceEdPub))
    }

    func testStrangerRememberDoesNotCallDurablePersistence() throws {
        let cache = RavenSecureLanEphemeralPeerCache()
        let contacts = RavenSecureLanMutableContactBook()
        let spy = RavenSecureLanTrustedPeerPersistenceSpy()
        let peer = try bundle(seed: 0x01, deviceID: "stranger")

        try cache.cachePeerBundle(peer, contactBook: contacts, durable: spy)

        XCTAssertEqual(spy.persistCalls.count, 0)
        XCTAssertNotNil(cache.load(deviceEdPub: peer.cert.deviceEdPub))
    }

    func testContactTrustedPeerMayPersistDurable() throws {
        let cache = RavenSecureLanEphemeralPeerCache()
        let contacts = RavenSecureLanMutableContactBook()
        let spy = RavenSecureLanTrustedPeerPersistenceSpy()
        let peer = try bundle(seed: 0x02, deviceID: "friend")
        contacts.addContact(peer.cert.deviceEdPub)

        try cache.cachePeerBundle(peer, contactBook: contacts, durable: spy)

        XCTAssertEqual(spy.persistCalls.count, 1)
        XCTAssertEqual(spy.persistCalls[0].cert.deviceEdPub, peer.cert.deviceEdPub)
    }

    func testEphemeralCacheDoesNotPromoteToContactTrust() throws {
        let cache = RavenSecureLanEphemeralPeerCache()
        let contacts = RavenSecureLanMutableContactBook()
        let peer = try bundle(seed: 0x03, deviceID: "ephemeral-only")

        cache.remember(peer)
        XCTAssertNotNil(cache.load(deviceEdPub: peer.cert.deviceEdPub))
        XCTAssertFalse(RavenSecureLanDispatchV1.peerIsTrusted(peer, contactBook: contacts))
    }
}
