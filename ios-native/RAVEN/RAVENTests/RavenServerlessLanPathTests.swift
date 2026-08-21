//
//  RavenServerlessLanPathTests.swift
//  RAVENTests — interim seal parity + framing + flag gating.
//

import XCTest
import CryptoKit
@testable import RAVEN

final class RavenServerlessLanPathTests: XCTestCase {

    override func tearDown() {
        FeatureFlag.ravenEnvelopeV1.setEnabled(false)
        RavenServerlessLanConfig.clear()
        super.tearDown()
    }

    func testPairwiseKeyMatchesRustKAT() {
        let a = Data(repeating: 1, count: 32)
        let b = Data(repeating: 2, count: 32)
        let key = RavenInterimSeal.derivePairwiseKey(localPub: a, peerPub: b)
        let hex = key.withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex, "23b797ecf9085621051a0ac973c8906ec4d5b32de76d02ec10e659ebff66e9d3")
    }

    func testInterimSealRoundtrip() throws {
        let a = Data(repeating: 3, count: 32)
        let b = Data(repeating: 4, count: 32)
        let key = RavenInterimSeal.derivePairwiseKey(localPub: a, peerPub: b)
        let mid = Data(repeating: 9, count: 16)
        let wire = try RavenInterimSeal.seal(
            key: key,
            plaintext: Data("hello-lan".utf8),
            senderAddr: "rvn1aaa",
            recipientAddr: "rvn1bbb",
            messageId: mid
        )
        XCTAssertEqual(RavenInterimSeal.classify(wire), .interimStub)
        let pt = try RavenInterimSeal.unseal(
            key: key,
            wire: wire,
            senderAddr: "rvn1aaa",
            recipientAddr: "rvn1bbb",
            messageId: mid
        )
        XCTAssertEqual(String(data: pt, encoding: .utf8), "hello-lan")
    }

    func testClassifyOpaqueAtsam() {
        var body = RavenInterimSeal.magic
        body.append(RavenInterimSeal.atsamProtoV2)
        body.append(RavenInterimSeal.suite)
        body.append(Data(repeating: 0, count: 40))
        XCTAssertEqual(RavenInterimSeal.classify(body), .opaqueAtsam(proto: 0x02))
    }

    func testOutboundCarrierRejectsPlaintextInterimAndMalformedBodies() {
        var plaintext = MessageContentSealer.plainMagic
        plaintext.append(Data("relay-readable".utf8))
        XCTAssertFalse(RavenServerlessLanPath.isEligibleOutboundSealedBody(plaintext))

        var interim = RavenInterimSeal.magic
        interim.append(RavenInterimSeal.stubProto)
        interim.append(RavenInterimSeal.suite)
        interim.append(Data(repeating: 0, count: 64))
        XCTAssertFalse(RavenServerlessLanPath.isEligibleOutboundSealedBody(interim))

        var truncatedV2 = RavenInterimSeal.magic
        truncatedV2.append(RavenInterimSeal.atsamProtoV2)
        truncatedV2.append(RavenInterimSeal.suite)
        XCTAssertFalse(RavenServerlessLanPath.isEligibleOutboundSealedBody(truncatedV2))
        XCTAssertFalse(RavenServerlessLanPath.isEligibleOutboundSealedBody(Data(repeating: 0, count: 64)))
        XCTAssertFalse(RavenServerlessLanPath.isEligibleOutboundSealedBody(Data(repeating: 0, count: 256 * 1024 + 1)))
    }

    func testOutboundCarrierAcceptsOnlyBoundedAuthenticatedCiphertextShapes() {
        var v2 = RavenInterimSeal.magic
        v2.append(RavenInterimSeal.atsamProtoV2)
        v2.append(RavenInterimSeal.suite)
        v2.append(Data(repeating: 0, count: 4 + 12 + 1 + 16))
        XCTAssertTrue(RavenServerlessLanPath.isEligibleOutboundSealedBody(v2))

        var noise = MessageContentSealer.sealedMagic
        noise.append(Data(repeating: 0, count: 17))
        XCTAssertTrue(RavenServerlessLanPath.isEligibleOutboundSealedBody(noise))

        var handshake = MessageContentSealer.handshakeMagic
        handshake.append(Data(repeating: 0, count: 96))
        XCTAssertTrue(RavenServerlessLanPath.isEligibleOutboundSealedBody(handshake))
    }

    func testFrameDeframeRoundtrip() {
        let payload = Data("RVN1-fake".utf8)
        let framed = RavenServerlessLanPath.frame(payload)
        let parsed = RavenServerlessLanPath.deframe(framed)
        XCTAssertEqual(parsed?.0, payload)
        XCTAssertEqual(parsed?.1.isEmpty, true)
    }

    func testPackSealedIntoEnvelope() {
        var body = RavenInterimSeal.magic
        body.append(RavenInterimSeal.atsamProtoV2)
        body.append(contentsOf: [0x01])
        body.append(Data(repeating: 7, count: 40))
        let sk = Curve25519.Signing.PrivateKey()
        let mid = Data(repeating: 1, count: 16)
        let tag = Data(repeating: 2, count: 16)
        let env = RavenServerlessLanPath.packSealedMessage(
            sealedBody: body,
            messageId: mid,
            routingTag: tag,
            signingKey: sk,
            hybridPQHint: true,
            nowMs: 1_700_000_000_000
        )
        XCTAssertEqual(env.envType, RavenEnvelopeV1.EnvType.message.rawValue)
        XCTAssertEqual(env.flags & 1, 1)
        XCTAssertEqual(env.messageCiphertext, body)
        XCTAssertEqual(env.senderAuthentication.count, 64)
        XCTAssertTrue(env.verify(publicKey: sk.publicKey))
        let packed = env.pack()
        XCTAssertEqual(RavenEnvelopeV1.unpack(packed), env)
    }

    func testLanGatedWhenFlagOff() {
        FeatureFlag.ravenEnvelopeV1.setEnabled(false)
        XCTAssertFalse(RavenServerlessLanPath.isActive)
        XCTAssertFalse(
            RavenServerlessLanPath.shouldAttemptLan(wifiUp: true, peerOnLan: true, blePeersNearby: true)
        )
    }

    func testLanPreferredWhenFlagOn() {
        FeatureFlag.ravenEnvelopeV1.setEnabled(true)
        XCTAssertTrue(RavenServerlessLanPath.isActive)
        XCTAssertTrue(
            RavenServerlessLanPath.shouldAttemptLan(wifiUp: true, peerOnLan: true, blePeersNearby: true)
        )
        // BLE-only situation: prefer BLE at transport layer; shouldAttemptLan requires peerOnLan.
        XCTAssertFalse(
            RavenServerlessLanPath.shouldAttemptLan(wifiUp: false, peerOnLan: false, blePeersNearby: true)
        )
        XCTAssertEqual(
            RavenHybridTransport.prefer(wifiUp: false, peerOnLan: false, blePeersNearby: true),
            .bleMesh
        )
        XCTAssertEqual(
            RavenHybridTransport.prefer(wifiUp: false, peerOnLan: false, blePeersNearby: false),
            .unavailable
        )
    }

    func testSendThrowsWhenFlagOff() async {
        FeatureFlag.ravenEnvelopeV1.setEnabled(false)
        let sk = Curve25519.Signing.PrivateKey()
        let env = RavenServerlessLanPath.packSealedMessage(
            sealedBody: Data(repeating: 0, count: 20),
            messageId: Data(repeating: 1, count: 16),
            routingTag: Data(repeating: 2, count: 16),
            signingKey: sk
        )
        do {
            _ = try await RavenServerlessLanPath.sendEnvelope(env, host: "127.0.0.1", port: 9)
            XCTFail("expected flagDisabled")
        } catch let err as RavenServerlessLanPath.LanError {
            XCTAssertEqual(err, .flagDisabled)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testOpaqueSendRejectsPlaintextBeforeOpeningNetworkConnection() async {
        FeatureFlag.ravenEnvelopeV1.setEnabled(true)
        var plaintext = MessageContentSealer.plainMagic
        plaintext.append(Data("must-never-reach-relay".utf8))
        do {
            _ = try await RavenServerlessLanPath.sendOpaqueSealed(
                sealedBody: plaintext,
                signingKey: Curve25519.Signing.PrivateKey(),
                host: "127.0.0.1",
                port: 9
            )
            XCTFail("expected unsupportedSealedBody")
        } catch let err as RavenServerlessLanPath.LanError {
            XCTAssertEqual(err, .unsupportedSealedBody)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testFireAndForgetRejectsMalformedEnvelopeBeforeOpeningNetworkConnection() async {
        FeatureFlag.ravenEnvelopeV1.setEnabled(true)
        var prefixOnly = RavenEnvelopeV1.magic
        prefixOnly.append(RavenEnvelopeV1.version)
        prefixOnly.append(Data(repeating: 0, count: RavenEnvelopeV1.prefixLength))
        do {
            try await RavenServerlessLanPath.sendPackedFireAndForget(
                prefixOnly,
                host: "127.0.0.1",
                port: 9
            )
            XCTFail("expected invalidEnvelope")
        } catch let err as RavenServerlessLanPath.LanError {
            XCTAssertEqual(err, .invalidEnvelope)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testStructuralAckResponseRemainsUnverified() {
        let signer = Curve25519.Signing.PrivateKey()
        var ack = RavenEnvelopeV1(
            envType: RavenEnvelopeV1.EnvType.ack.rawValue,
            messageId: Data(repeating: 0x11, count: 16),
            routingTag: Data(repeating: 0x22, count: 16),
            createdAtMs: 1,
            expiresAtMs: .max,
            hopLimit: 2,
            replicationBudget: 1,
            antiReplayNonce: Data(repeating: 0x33, count: 12),
            messageCiphertext: Data(repeating: 0x44, count: 101)
        )
        ack.sign(with: signer)

        XCTAssertEqual(
            RavenServerlessLanPath.unverifiedResponseError(ack.pack()),
            .unverifiedAck
        )
        XCTAssertEqual(
            RavenServerlessLanPath.unverifiedResponseError(Data("not-an-envelope".utf8)),
            .badAck
        )
    }
}
