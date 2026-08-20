//
//  RavenSecureLanNoiseTests.swift
//  RAVENTests
//
//  Cross-language KAT coverage for rvn1 LAN Noise XX primitives.
//

import CryptoKit
import Foundation
import XCTest
@testable import RAVEN

final class RavenSecureLanNoiseTests: XCTestCase {

    private func vectorsRoot() -> URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // RAVENTests
            .deletingLastPathComponent() // RAVEN
            .deletingLastPathComponent() // ios-native
            .deletingLastPathComponent() // repository
            .appendingPathComponent("shared-vectors/rvn1/lan")
        return FileManager.default.fileExists(atPath: root.path) ? root : nil
    }

    private func loadVector(_ name: String) throws -> [String: Any] {
        guard let root = vectorsRoot() else {
            throw XCTSkip("shared-vectors/rvn1/lan not found")
        }
        let data = try Data(contentsOf: root.appendingPathComponent(name))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func hex(_ value: String) -> Data {
        precondition(value.count.isMultiple(of: 2))
        var result = Data(capacity: value.count / 2)
        var cursor = value.startIndex
        while cursor < value.endIndex {
            let next = value.index(cursor, offsetBy: 2)
            result.append(UInt8(value[cursor..<next], radix: 16)!)
            cursor = next
        }
        return result
    }

    private func dictionary(_ value: Any?) throws -> [String: Any] {
        try XCTUnwrap(value as? [String: Any])
    }

    // MARK: - Vector KATs

    func testNoiseStatic001Vector() throws {
        let vector = try loadVector("noise_static_001.json")
        let inputs = try dictionary(vector["inputs"])
        let expected = try dictionary(vector["expected"])
        let seed = hex(try XCTUnwrap(inputs["device_seed_hex"] as? String))
        let staticPriv = try RavenSecureLanNoiseV1.deriveNoiseStatic(deviceSeed: seed)
        let staticPub = try RavenSecureLanNoiseV1.noiseStaticPublic(staticPrivate: staticPriv)
        XCTAssertEqual(staticPub, hex(try XCTUnwrap(expected["noise_static_pub_hex"] as? String)))
    }

    func testNoiseBind001Vector() throws {
        let vector = try loadVector("noise_bind_001.json")
        let inputs = try dictionary(vector["inputs"])
        let expected = try dictionary(vector["expected"])
        let seed = hex(try XCTUnwrap(inputs["device_seed_hex"] as? String))
        let staticPub = hex(try XCTUnwrap(inputs["noise_static_pub_hex"] as? String))
        let bind = try RavenSecureLanNoiseV1.encodeBind(deviceSeed: seed, noiseStaticPub: staticPub)
        XCTAssertEqual(bind.count, expected["bind_len"] as? Int)
        XCTAssertEqual(bind, hex(try XCTUnwrap(expected["bind_hex"] as? String)))
        _ = try RavenSecureLanNoiseV1.verifyBind(
            bind: bind,
            noiseStaticPub: staticPub,
            expectedEd25519: LanDeterministicEd25519.publicKey(seed: seed)
        )
    }

    func testNoiseXXHandshake001Vector() throws {
        let vector = try loadVector("noise_xx_handshake_001.json")
        let inputs = try dictionary(vector["inputs"])
        let expected = try dictionary(vector["expected"])

        let initSeed = hex(try XCTUnwrap(inputs["initiator_device_seed_hex"] as? String))
        let respSeed = hex(try XCTUnwrap(inputs["responder_device_seed_hex"] as? String))
        let initEph = hex(try XCTUnwrap(inputs["initiator_ephemeral_priv_hex"] as? String))
        let respEph = hex(try XCTUnwrap(inputs["responder_ephemeral_priv_hex"] as? String))

        let initStaticPriv = try RavenSecureLanNoiseV1.deriveNoiseStatic(deviceSeed: initSeed)
        let respStaticPriv = try RavenSecureLanNoiseV1.deriveNoiseStatic(deviceSeed: respSeed)
        let initStaticPub = try RavenSecureLanNoiseV1.noiseStaticPublic(staticPrivate: initStaticPriv)
        let respStaticPub = try RavenSecureLanNoiseV1.noiseStaticPublic(staticPrivate: respStaticPriv)

        XCTAssertEqual(initStaticPub, hex(try XCTUnwrap(expected["initiator_static_pub_hex"] as? String)))
        XCTAssertEqual(respStaticPub, hex(try XCTUnwrap(expected["responder_static_pub_hex"] as? String)))

        var initiator = try RavenSecureLanNoiseV1.buildInitiator(
            staticPrivate: initStaticPriv,
            fixedEphemeralPrivate: initEph
        )
        var responder = try RavenSecureLanNoiseV1.buildResponder(
            staticPrivate: respStaticPriv,
            fixedEphemeralPrivate: respEph
        )

        let m1 = try initiator.writeMessage(payload: Data())
        XCTAssertEqual(m1, hex(try XCTUnwrap(expected["m1_hex"] as? String)))
        _ = try responder.readMessage(m1)

        let m2 = try responder.writeMessage(payload: Data())
        XCTAssertEqual(m2, hex(try XCTUnwrap(expected["m2_hex"] as? String)))
        _ = try initiator.readMessage(m2)

        let m3 = try initiator.writeMessage(payload: Data())
        XCTAssertEqual(m3, hex(try XCTUnwrap(expected["m3_hex"] as? String)))
        _ = try responder.readMessage(m3)

        XCTAssertEqual(initiator.handshakeHash, hex(try XCTUnwrap(expected["handshake_hash_hex"] as? String)))
        XCTAssertEqual(responder.handshakeHash, initiator.handshakeHash)
        XCTAssertEqual(initiator.remoteStatic, hex(try XCTUnwrap(expected["initiator_remote_static_hex"] as? String)))
        XCTAssertEqual(responder.remoteStatic, hex(try XCTUnwrap(expected["responder_remote_static_hex"] as? String)))

        var initTransport = try initiator.intoTransport()
        var respTransport = try responder.intoTransport()

        let initBind = try RavenSecureLanNoiseV1.encodeBind(deviceSeed: initSeed, noiseStaticPub: initStaticPub)
        let initBindCT = try initTransport.encrypt(plaintext: initBind)
        XCTAssertEqual(initBindCT, hex(try XCTUnwrap(expected["initiator_bind_transport_hex"] as? String)))
        let initBindPT = try respTransport.decrypt(ciphertext: initBindCT)
        _ = try RavenSecureLanNoiseV1.verifyBind(
            bind: initBindPT,
            noiseStaticPub: initStaticPub,
            expectedEd25519: LanDeterministicEd25519.publicKey(seed: initSeed)
        )

        let respBind = try RavenSecureLanNoiseV1.encodeBind(deviceSeed: respSeed, noiseStaticPub: respStaticPub)
        let respBindCT = try respTransport.encrypt(plaintext: respBind)
        XCTAssertEqual(respBindCT, hex(try XCTUnwrap(expected["responder_bind_transport_hex"] as? String)))
        let respBindPT = try initTransport.decrypt(ciphertext: respBindCT)
        _ = try RavenSecureLanNoiseV1.verifyBind(
            bind: respBindPT,
            noiseStaticPub: respStaticPub,
            expectedEd25519: LanDeterministicEd25519.publicKey(seed: respSeed)
        )

        let appPlain = Data("rvn1/lan-vector/app-001".utf8)
        let appCT = try initTransport.encrypt(plaintext: appPlain)
        XCTAssertEqual(appCT, hex(try XCTUnwrap(expected["first_application_ciphertext_hex"] as? String)))
        XCTAssertEqual(appPlain, hex(try XCTUnwrap(expected["first_application_plaintext_hex"] as? String)))
    }

    // MARK: - Limits and smoke

    func testBlake2sProtocolNameHashMatchesReference() {
        let digest = LanBlake2s.hash(Data("Noise_XX_25519_ChaChaPoly_BLAKE2s".utf8))
        XCTAssertEqual(
            digest.map { String(format: "%02x", $0) }.joined(),
            "1ceedd81c5f458b225923dc2507787bf156f9251fc17c45af63263a929fc1ed2"
        )
    }

    func testRejectsOversizedPlaintext() throws {
        let alice = Data(repeating: 0x11, count: 32)
        let bob = Data(repeating: 0x22, count: 32)
        var (initTransport, _) = try handshakePair(initSeed: alice, respSeed: bob)
        let tooBig = Data(repeating: 0, count: RavenSecureLanNoiseV1.maxTransportPlaintext + 1)
        XCTAssertThrowsError(try initTransport.encrypt(plaintext: tooBig)) { error in
            XCTAssertEqual(error as? RavenSecureLanNoiseError, .plaintextTooLarge)
        }
    }

    func testRoundTripWithoutFixedEphemerals() throws {
        let alice = Data(repeating: 0x41, count: 32)
        let bob = Data(repeating: 0x42, count: 32)
        var (initTransport, respTransport) = try handshakePair(initSeed: alice, respSeed: bob)
        let plaintext = Data("hello-lan".utf8)
        let ct = try initTransport.encrypt(plaintext: plaintext)
        let pt = try respTransport.decrypt(ciphertext: ct)
        XCTAssertEqual(pt, plaintext)
    }

    // MARK: - Helpers

    private func handshakePair(
        initSeed: Data,
        respSeed: Data
    ) throws -> (RavenSecureLanNoiseTransport, RavenSecureLanNoiseTransport) {
        let initStaticPriv = try RavenSecureLanNoiseV1.deriveNoiseStatic(deviceSeed: initSeed)
        let respStaticPriv = try RavenSecureLanNoiseV1.deriveNoiseStatic(deviceSeed: respSeed)
        var initiator = try RavenSecureLanNoiseV1.buildInitiator(staticPrivate: initStaticPriv)
        var responder = try RavenSecureLanNoiseV1.buildResponder(staticPrivate: respStaticPriv)
        let m1 = try initiator.writeMessage()
        _ = try responder.readMessage(m1)
        let m2 = try responder.writeMessage()
        _ = try initiator.readMessage(m2)
        let m3 = try initiator.writeMessage()
        _ = try responder.readMessage(m3)
        return (try initiator.intoTransport(), try responder.intoTransport())
    }
}
