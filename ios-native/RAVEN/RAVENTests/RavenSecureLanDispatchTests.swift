//
//  RavenSecureLanDispatchTests.swift
//  RAVENTests
//

import CryptoKit
import Foundation
import XCTest
@testable import RAVEN

final class RavenSecureLanDispatchTests: XCTestCase {

    private let initMagic = Data([0x52, 0x56, 0x50, 0x49, 0x31, 0, 0, 0])

    private func peerBundle(seed: UInt8) throws -> RavenSecureLanRlb1V1.LanBundle {
        try RavenSecureLanRlb1V1.fixtureOfferBundle(
            deviceSeed: Data(repeating: seed, count: 32),
            deviceID: "dispatch-peer"
        )
    }

    private func packedEnvelope(envType: RavenEnvelopeV1.EnvType, ciphertext: Data = Data(repeating: 0xAB, count: 32)) -> Data {
        var env = RavenEnvelopeV1(
            envType: envType.rawValue,
            flags: 0,
            messageId: Data(repeating: 0x11, count: 16),
            routingTag: Data(repeating: 0x22, count: 16),
            destDeviceHint: 0,
            createdAtMs: 1_700_000_000_000,
            expiresAtMs: 1_700_086_400_000,
            hopLimit: 8,
            replicationBudget: 2,
            antiReplayNonce: Data(repeating: 0x33, count: 12),
            ratchetHeaderCiphertext: Data(),
            messageCiphertext: ciphertext
        )
        let key = Curve25519.Signing.PrivateKey()
        env.sign(with: key)
        return env.pack()
    }

    private func pairInitPackedEnvelope() -> Data {
        var wire = initMagic
        wire.append(Data(repeating: 0, count: ATSAMPairInitV1.initWireLength - wire.count))
        return packedEnvelope(envType: .message, ciphertext: wire)
    }

    private func dispatchContext(
        peer: RavenSecureLanRlb1V1.LanBundle,
        contacts: RavenSecureLanMutableContactBook
    ) -> (
        ephemeral: RavenSecureLanEphemeralPeerCache,
        spy: RavenSecureLanTrustedPeerPersistenceSpy
    ) {
        (RavenSecureLanEphemeralPeerCache(), RavenSecureLanTrustedPeerPersistenceSpy())
    }

    func testMissingContactRefusesPairInitMessageAndAck() throws {
        let peer = try peerBundle(seed: 0xA1)
        let contacts = RavenSecureLanMutableContactBook()
        let ctx = dispatchContext(peer: peer, contacts: contacts)
        let noise = peer.cert.deviceEdPub

        let cases: [(String, Data, RavenSecureLanDispatchV1.Handlers)] = [
            ("pair init", pairInitPackedEnvelope(), .init(onPairInit: { _ in })),
            ("message", packedEnvelope(envType: .message), .init(onMessage: { _ in })),
            ("ack", packedEnvelope(envType: .ack), .init(onAck: { _ in })),
        ]

        for (label, frame, handlers) in cases {
            XCTAssertThrowsError(
                try RavenSecureLanDispatchV1.dispatchDecryptedFrame(
                    frame,
                    peer: peer,
                    noiseEdPub: noise,
                    contactBook: contacts,
                    ephemeralCache: ctx.ephemeral,
                    trustedPersistence: ctx.spy,
                    hasConfirmedSession: true,
                    handlers: handlers
                )
            ) { error in
                let detail = (error as? RavenSecureLanDispatchError)?.errorDescription ?? "\(error)"
                XCTAssertTrue(
                    detail.contains("not a local contact"),
                    "\(label) expected contact refusal, got: \(detail)"
                )
            }
        }
    }

    func testConfirmedSessionAloneIsInsufficient() throws {
        let peer = try peerBundle(seed: 0xA2)
        let contacts = RavenSecureLanMutableContactBook()
        let ctx = dispatchContext(peer: peer, contacts: contacts)

        XCTAssertThrowsError(
            try RavenSecureLanDispatchV1.dispatchDecryptedFrame(
                packedEnvelope(envType: .message),
                peer: peer,
                noiseEdPub: peer.cert.deviceEdPub,
                contactBook: contacts,
                ephemeralCache: ctx.ephemeral,
                trustedPersistence: ctx.spy,
                hasConfirmedSession: true,
                handlers: .init(onMessage: { _ in })
            )
        )
    }

    func testAfterDeleteContactRefusesAgain() throws {
        let peer = try peerBundle(seed: 0xA3)
        let contacts = RavenSecureLanMutableContactBook()
        contacts.addContact(peer.cert.deviceEdPub)
        let ctx = dispatchContext(peer: peer, contacts: contacts)
        var handled = false

        try RavenSecureLanDispatchV1.dispatchDecryptedFrame(
            packedEnvelope(envType: .message),
            peer: peer,
            noiseEdPub: peer.cert.deviceEdPub,
            contactBook: contacts,
            ephemeralCache: ctx.ephemeral,
            trustedPersistence: ctx.spy,
            hasConfirmedSession: true,
            handlers: .init(onMessage: { _ in handled = true })
        )
        XCTAssertTrue(handled)

        contacts.removeContact(peer.cert.deviceEdPub)
        handled = false
        XCTAssertThrowsError(
            try RavenSecureLanDispatchV1.dispatchDecryptedFrame(
                packedEnvelope(envType: .message),
                peer: peer,
                noiseEdPub: peer.cert.deviceEdPub,
                contactBook: contacts,
                ephemeralCache: ctx.ephemeral,
                trustedPersistence: ctx.spy,
                hasConfirmedSession: true,
                handlers: .init(onMessage: { _ in handled = true })
            )
        )
        XCTAssertFalse(handled)
    }

    func testContactPresentAllowsStubHandlers() throws {
        let peer = try peerBundle(seed: 0xA4)
        let contacts = RavenSecureLanMutableContactBook()
        contacts.addContact(peer.cert.userEdPub)
        let ctx = dispatchContext(peer: peer, contacts: contacts)

        var pairInitCalled = false
        var messageCalled = false
        var ackCalled = false

        try RavenSecureLanDispatchV1.dispatchDecryptedFrame(
            pairInitPackedEnvelope(),
            peer: peer,
            noiseEdPub: peer.cert.deviceEdPub,
            contactBook: contacts,
            ephemeralCache: ctx.ephemeral,
            trustedPersistence: ctx.spy,
            hasConfirmedSession: false,
            handlers: .init(onPairInit: { _ in pairInitCalled = true })
        )
        XCTAssertTrue(pairInitCalled)

        try RavenSecureLanDispatchV1.dispatchDecryptedFrame(
            packedEnvelope(envType: .message),
            peer: peer,
            noiseEdPub: peer.cert.deviceEdPub,
            contactBook: contacts,
            ephemeralCache: ctx.ephemeral,
            trustedPersistence: ctx.spy,
            hasConfirmedSession: false,
            handlers: .init(onMessage: { _ in messageCalled = true })
        )
        XCTAssertTrue(messageCalled)

        try RavenSecureLanDispatchV1.dispatchDecryptedFrame(
            packedEnvelope(envType: .ack),
            peer: peer,
            noiseEdPub: peer.cert.deviceEdPub,
            contactBook: contacts,
            ephemeralCache: ctx.ephemeral,
            trustedPersistence: ctx.spy,
            hasConfirmedSession: false,
            handlers: .init(onAck: { _ in ackCalled = true })
        )
        XCTAssertTrue(ackCalled)
    }

    func testRlb1OfferRemembersEphemeralWithoutContact() throws {
        let peer = try peerBundle(seed: 0xB1)
        let offerPeer = try peerBundle(seed: 0xB2)
        let wire = try RavenSecureLanRlb1V1.encodeOffer(offerPeer)
        let contacts = RavenSecureLanMutableContactBook()
        let cache = RavenSecureLanEphemeralPeerCache()
        let spy = RavenSecureLanTrustedPeerPersistenceSpy()

        try RavenSecureLanDispatchV1.dispatchDecryptedFrame(
            wire,
            peer: offerPeer,
            noiseEdPub: offerPeer.cert.deviceEdPub,
            contactBook: contacts,
            ephemeralCache: cache,
            trustedPersistence: spy,
            hasConfirmedSession: false,
            handlers: .init()
        )

        XCTAssertNotNil(cache.load(deviceEdPub: offerPeer.cert.deviceEdPub))
        XCTAssertEqual(spy.persistCalls.count, 0)
        XCTAssertEqual(RavenSecureLanDispatchV1.classifyFrame(wire), .rlb1Offer)
        _ = peer
    }

    func testBlockedPeerRefusedEvenWithContact() throws {
        let peer = try peerBundle(seed: 0xC1)
        let contacts = RavenSecureLanMutableContactBook()
        contacts.addContact(peer.cert.deviceEdPub)
        contacts.block(peer.cert.deviceEdPub)
        let cache = RavenSecureLanEphemeralPeerCache()

        XCTAssertThrowsError(
            try RavenSecureLanDispatchV1.dispatchDecryptedFrame(
                packedEnvelope(envType: .message),
                peer: peer,
                noiseEdPub: peer.cert.deviceEdPub,
                contactBook: contacts,
                ephemeralCache: cache,
                trustedPersistence: nil,
                hasConfirmedSession: true,
                handlers: .init(onMessage: { _ in })
            )
        ) { error in
            XCTAssertEqual(error as? RavenSecureLanDispatchError, .peerBlocked)
        }
    }

    func testSecureDispatchNeverUsesLegacyPath() {
        XCTAssertThrowsError(
            try RavenSecureLanSecurePathGuard.refuseLegacyDelegation(useLegacyPath: true)
        ) { error in
            XCTAssertEqual(error as? RavenSecureLanError, .legacyLanPathForbidden)
        }
    }
}
