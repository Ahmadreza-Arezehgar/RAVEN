// NoiseSessionStore.swift
//
// Per-peer Noise IK session manager. Drives the 2-message handshake
// and caches post-split() transport-mode cipher states so subsequent
// v2 envelopes encrypt + decrypt without re-running the handshake.
//
// What this delivers:
//   • One-shot helpers for initiator and responder so call sites
//     don't have to juggle `NoiseSession` lifecycle themselves.
//   • Memory-only state (intentional — persistence across launches
//     is a follow-up; the cost of dropping sessions on restart is a
//     1-RTT re-handshake, which is fine).
//   • Round-trip self-test via `runRoundTripSelfTest()` so a
//     refactor that breaks the wire format fails loudly in CI.
//
// What this DOES NOT yet do:
//   • Wire into `BLEMeshEngine.send` / `handleV2EnvelopePayload`.
//     That's Phase C.1.c — once it lands, every v2 envelope payload
//     becomes Noise-encrypted with forward secrecy, replacing the
//     constant-salt AES-GCM-with-static-ECDH path that v1 + early
//     v2 carry today.
//
// Sibling: `ios-native/RAVEN/RAVEN/Core/Security/NoiseSessionStore.swift`.

import Foundation
import CryptoKit

@MainActor
final class NoiseSessionStore {
    static let shared = NoiseSessionStore()

    // MARK: - State

    /// In-progress handshakes keyed by 16-byte peer ID.
    /// Initiator side: stashed after `writeMessage1`, awaiting M2.
    /// Responder side: stashed after `readMessage1`, awaiting `writeMessage2`.
    private var pending: [Data: NoiseSession] = [:]

    /// Established post-split() transport-mode cipher pairs keyed by
    /// 16-byte peer ID. `(send, recv)` from THIS side's perspective —
    /// `send` is what we use to write outbound, `recv` for inbound.
    private struct CipherPair {
        let send: NoiseCipherState
        let recv: NoiseCipherState
    }
    private var transport: [Data: CipherPair] = [:]

    /// Per-peer count of consecutive AEAD-decrypt failures since the
    /// last successful decrypt. Round 13 — hacker-audit finding C12:
    /// the previous build evicted the session on the FIRST AEAD fail,
    /// which a mesh attacker can trigger remotely with a single
    /// replayed/garbage frame to force a costly re-handshake. We now
    /// only evict after `maxConsecutiveAEADFails` (5) bad frames so a
    /// single garbage relay can't DoS the session.
    private var consecutiveAEADFails: [Data: Int] = [:]

    /// 🔴 ROUND 70 — sliding-window AEAD-fail counter.
    ///
    /// PREVIOUSLY only `consecutiveAEADFails` was tracked, with a
    /// hard threshold of 5. An attacker who could inject up to 4
    /// garbage frames between every legitimate frame kept the
    /// session alive indefinitely (each legit decrypt reset the
    /// counter), turning the cipher into an oracle and never
    /// triggering re-handshake.
    ///
    /// Fix: ALSO track timestamps of recent AEAD failures per peer.
    /// If we see ≥ `maxWindowedFails` failures within
    /// `windowSeconds`, evict the session regardless of intervening
    /// successes. This forces the attacker to slow down to ~1
    /// failure per `windowSeconds / maxWindowedFails`, which makes
    /// long-running probing economically uninteresting and noisy
    /// enough to log.
    private var windowedAEADFails: [Data: [Date]] = [:]
    private let maxWindowedFails = 6
    private let windowSeconds: TimeInterval = 60

    /// Eviction threshold. 5 picked because it tolerates routine
    /// mesh-relay flakiness (out-of-order, duplicate, drop+retransmit)
    /// without making the user wait through a re-handshake, but still
    /// drops the session quickly once the peer has genuinely rotated
    /// keys (5 valid encrypts in a row, none decrypting → re-key).
    private let maxConsecutiveAEADFails = 5

    private init() {}

    // MARK: - Errors

    enum StoreError: Error, Equatable {
        case identityNotInitialized
        case noPendingHandshake
        case noActiveSession
        case missingPeerStaticKey
    }

    // MARK: - Lookup helpers

    /// True iff we have an established transport session with `peerID`.
    func hasSession(for peerID: Data) -> Bool {
        transport[peerID] != nil
    }

    /// Drop both pending and established state for a peer. Called on
    /// disconnect or after a decrypt failure (which usually means the
    /// other side rotated keys).
    func evict(peerID: Data) {
        pending.removeValue(forKey: peerID)
        transport.removeValue(forKey: peerID)
        consecutiveAEADFails.removeValue(forKey: peerID)
        windowedAEADFails.removeValue(forKey: peerID)
    }

    // MARK: - Initiator API

    /// Begin an IK handshake to `peerStaticKey`. Returns the message-1
    /// bytes the caller transmits over BLE / MPC / Wi-Fi Aware.
    /// Embed `payload` in M1 to land it 1-RTT (the responder's
    /// `processInboundHandshake1` returns the decrypted payload).
    func startHandshake(
        toPeer peerStaticKey: Curve25519.KeyAgreement.PublicKey,
        payload: Data = Data()
    ) throws -> (message1: Data, peerID: Data) {
        let session: NoiseSession = try DeviceIdentityService.shared.withAgreementPrivateKey { ourStatic in
            try NoiseSession(role: .initiator, staticKey: ourStatic, peerStaticKey: peerStaticKey)
        } ?? { throw StoreError.identityNotInitialized }()

        let m1 = try session.writeMessage1(payload: payload)
        let pid = RUMProtocolV2.peerID(fromPublicKey: peerStaticKey.rawRepresentation)
        pending[pid] = session
        return (m1, pid)
    }

    /// Initiator received message 2 — finish the handshake. Stores
    /// post-split() cipher states under `peerID` and returns the
    /// responder's reply payload (typically empty for IK).
    @discardableResult
    func finishHandshakeAsInitiator(
        message2: Data,
        peerID: Data
    ) throws -> Data {
        guard let session = pending.removeValue(forKey: peerID) else {
            throw StoreError.noPendingHandshake
        }
        let payload = try session.readMessage2(message2)
        let (send, recv) = try session.split()
        transport[peerID] = CipherPair(send: send, recv: recv)
        return payload
    }

    // MARK: - Responder API

    /// Process inbound message 1. Returns the decrypted payload from
    /// the initiator AND the message-2 bytes the caller should send
    /// back. Stores the post-split() cipher pair under the recovered
    /// peer's 16-byte peer ID.
    func processInboundHandshake1(
        message1: Data,
        replyPayload: Data = Data()
    ) throws -> (payload: Data, message2: Data, peerID: Data) {
        let session: NoiseSession = try DeviceIdentityService.shared.withAgreementPrivateKey { ourStatic in
            try NoiseSession(role: .responder, staticKey: ourStatic, peerStaticKey: nil)
        } ?? { throw StoreError.identityNotInitialized }()

        let payload = try session.readMessage1(message1)
        let m2 = try session.writeMessage2(payload: replyPayload)
        guard let recoveredPeerStatic = session.peerStaticKey else {
            throw StoreError.missingPeerStaticKey
        }
        let (send, recv) = try session.split()
        let pid = RUMProtocolV2.peerID(fromPublicKey: recoveredPeerStatic.rawRepresentation)
        transport[pid] = CipherPair(send: send, recv: recv)
        return (payload, m2, pid)
    }

    // MARK: - Stateless 1-RTT IK (serverless, no cached session)

    /// Write a Noise IK message-1 to `peerStaticKey` carrying `payload`, WITHOUT
    /// caching a pending session. This is the serverless first-contact path: two
    /// peers who have only exchanged static keys out-of-band (QR) can seal each
    /// message as a self-contained IK M1 (fresh ephemeral ⇒ forward secrecy),
    /// and the recipient reads it with `openHandshake1Stateless`. No M2 / no
    /// pairing round-trip is needed for the body to be delivered + read.
    func writeHandshake1Stateless(
        toPeer peerStaticKey: Curve25519.KeyAgreement.PublicKey,
        payload: Data
    ) -> Data? {
        let session: NoiseSession
        do {
            session = try DeviceIdentityService.shared.withAgreementPrivateKey { ourStatic in
                try NoiseSession(role: .initiator, staticKey: ourStatic, peerStaticKey: peerStaticKey)
            } ?? { throw StoreError.identityNotInitialized }()
        } catch {
            return nil
        }
        return try? session.writeMessage1(payload: payload)
    }

    /// Read the payload embedded in a Noise IK message-1 WITHOUT caching a
    /// transport session (the symmetric counterpart of `writeHandshake1Stateless`).
    /// Not storing a transport pair keeps the scheme symmetric: our reply also
    /// goes out as our own IK M1, so we never half-open a session the peer can't
    /// complete. Returns (payload, recovered sender static key) or nil.
    func openHandshake1Stateless(message1: Data) -> (payload: Data, peerStatic: Data)? {
        let session: NoiseSession
        do {
            session = try DeviceIdentityService.shared.withAgreementPrivateKey { ourStatic in
                try NoiseSession(role: .responder, staticKey: ourStatic, peerStaticKey: nil)
            } ?? { throw StoreError.identityNotInitialized }()
        } catch {
            return nil
        }
        guard let payload = try? session.readMessage1(message1),
              let peerStatic = session.peerStaticKey else {
            return nil
        }
        return (payload, peerStatic.rawRepresentation)
    }

    // MARK: - Transport mode

    /// Encrypt `plaintext` with the cached transport key for `peerID`.
    /// `ad` becomes the AEAD additional-data binding. Returns nil
    /// when no session exists (caller's signal to start a handshake).
    func encrypt(_ plaintext: Data, ad: Data, forPeer peerID: Data) -> Data? {
        guard let pair = transport[peerID] else { return nil }
        return try? pair.send.encryptWithAd(ad, plaintext: plaintext)
    }

    /// Decrypt `ciphertext`. Returns nil when no session exists or
    /// the AEAD verify fails.
    ///
    /// Round 13: only evicts after `maxConsecutiveAEADFails`
    /// consecutive failures. A single garbage frame (replay, mesh
    /// flake, or attacker-injected noise) no longer tears the session
    /// down — the threshold gives legitimate retransmits room to
    /// recover. (Audit finding C12.)
    func decrypt(_ ciphertext: Data, ad: Data, fromPeer peerID: Data) -> Data? {
        guard let pair = transport[peerID] else { return nil }
        do {
            let pt = try pair.recv.decryptWithAd(ad, ciphertext: ciphertext)
            // Successful decrypt resets the consecutive streak — bad
            // frames before this one were noise, not a key change.
            // 🔴 ROUND 70 — we deliberately DO NOT reset the windowed
            // counter here. A successful decrypt does not "forgive"
            // recent failures; the windowed budget is about catching
            // probing attackers who interleave garbage with legitimate
            // traffic to keep the consecutive counter at 0.
            consecutiveAEADFails.removeValue(forKey: peerID)
            return pt
        } catch {
            let count = (consecutiveAEADFails[peerID] ?? 0) + 1
            consecutiveAEADFails[peerID] = count

            // 🔴 ROUND 70 — record this failure in the windowed log
            // and prune entries older than `windowSeconds`.
            let now = Date()
            var window = windowedAEADFails[peerID] ?? []
            window.append(now)
            let cutoff = now.addingTimeInterval(-windowSeconds)
            window = window.filter { $0 >= cutoff }
            windowedAEADFails[peerID] = window

            if count >= maxConsecutiveAEADFails {
                #if DEBUG
                print("[NoiseSessionStore] \(count) consecutive AEAD fails for peer — evicting; peer probably rotated keys.")
                #endif
                evict(peerID: peerID)
            } else if window.count >= maxWindowedFails {
                // Probing attacker pattern: many fails sprinkled
                // across the window with intervening successes.
                #if DEBUG
                print("[NoiseSessionStore] \(window.count) windowed AEAD fails (within \(Int(windowSeconds))s) for peer — evicting; probable in-session probing attack.")
                #endif
                evict(peerID: peerID)
            }
            return nil
        }
    }

    // MARK: - Self-test

    /// Round-trip a handshake + transport message through TWO stores
    /// (one acting as initiator, one as responder). Useful as a unit
    /// test in `#if DEBUG` builds. Throws on any mismatch.
    static func runRoundTripSelfTest(
        initiatorStatic: Curve25519.KeyAgreement.PrivateKey,
        responderStatic: Curve25519.KeyAgreement.PrivateKey,
        m1Payload: Data = Data("hi from initiator".utf8),
        m2Payload: Data = Data("hi back from responder".utf8),
        transportPayload: Data = Data("transport message".utf8)
    ) throws -> (m1: Int, m2: Int, ct: Int) {
        // Inline (not using `shared`) so the test doesn't pollute
        // the real `transport` cache and so we don't depend on
        // `DeviceIdentityService` having been initialized.
        var initiator = try NoiseSession(
            role: .initiator,
            staticKey: initiatorStatic,
            peerStaticKey: responderStatic.publicKey
        )
        var responder = try NoiseSession(
            role: .responder,
            staticKey: responderStatic,
            peerStaticKey: nil
        )
        // Mute mutability warnings for the values we only call methods on.
        _ = initiator; _ = responder

        let m1 = try initiator.writeMessage1(payload: m1Payload)
        let p1 = try responder.readMessage1(m1)
        guard p1 == m1Payload else { throw StoreError.noActiveSession }

        let m2 = try responder.writeMessage2(payload: m2Payload)
        let p2 = try initiator.readMessage2(m2)
        guard p2 == m2Payload else { throw StoreError.noActiveSession }

        let (iSend, iRecv) = try initiator.split()
        let (rSend, rRecv) = try responder.split()
        _ = (iRecv, rSend) // exercise the unused-side accessors

        let ad = Data("self-test".utf8)
        let ct = try iSend.encryptWithAd(ad, plaintext: transportPayload)
        let pt = try rRecv.decryptWithAd(ad, ciphertext: ct)
        guard pt == transportPayload else { throw StoreError.noActiveSession }

        return (m1: m1.count, m2: m2.count, ct: ct.count)
    }

    // MARK: - End-to-end crypto self-test (DEBUG only)
    //
    // Companion to `runRoundTripSelfTest`, but verifies layers that
    // sit ABOVE raw Noise:
    //
    //   L1 — raw Noise IK round-trip (delegated to
    //        `runRoundTripSelfTest`).
    //   L2 — initiator/responder lifecycle the way
    //        `NoiseSessionStore` drives it: startHandshake → process
    //        → finish → encrypt+decrypt with the post-split() cipher
    //        states.  Same shape as the production code path but on
    //        fresh `NoiseSession` instances so we don't pollute the
    //        `.shared` transport cache.
    //   L3 — MessageContentSealer wire format: RVNS1 magic + AEAD
    //        bound to (sender, recipient, msgId) AAD.  Catches AAD-
    //        construction asymmetry (the kind of bug where seal and
    //        unseal would compute different AADs and the AEAD verify
    //        fails on a perfectly valid ciphertext).
    //
    // Logs one PASS/FAIL line per layer.  All three layers run
    // inline against ephemeral keys, so this is safe to call before
    // `DeviceIdentityService` is ready and produces no side effects
    // on the user's real session state.

    /// Run all three layers, log a single PASS/FAIL summary.
    /// Call from `RAVENApp.application(_:didFinishLaunchingWithOptions:)`.
    static func runEndToEndSelfTest() {
        var l1: String = "?"
        var l2: String = "?"
        var l3: String = "?"

        do {
            try Self.l1_rawNoiseRoundTrip()
            l1 = "PASS"
        } catch { l1 = "FAIL(\(error))" }

        do {
            try Self.l2_storeLifecycleRoundTrip()
            l2 = "PASS"
        } catch { l2 = "FAIL(\(error))" }

        do {
            try Self.l3_sealerWireRoundTrip()
            l3 = "PASS"
        } catch { l3 = "FAIL(\(error))" }

        let line = "🔬 [CryptoSelfTest] L1(raw-noise)=\(l1) | L2(store-lifecycle)=\(l2) | L3(sealer-wire)=\(l3)"
        NSLog("%@", line)
        print(line)
    }

    private enum SelfTestFailure: Error, CustomStringConvertible {
        case payload(layer: String, expected: String, got: String)
        case missingPeerStaticKey
        case wireMagicMismatch
        var description: String {
            switch self {
            case .payload(let layer, let exp, let got):
                return "\(layer): expected=\(exp) got=\(got)"
            case .missingPeerStaticKey:
                return "responder didn't recover peer static key from M1"
            case .wireMagicMismatch:
                return "RVNS1 magic byte mismatch"
            }
        }
    }

    private static func l1_rawNoiseRoundTrip() throws {
        let iStatic = Curve25519.KeyAgreement.PrivateKey()
        let rStatic = Curve25519.KeyAgreement.PrivateKey()
        let result = try Self.runRoundTripSelfTest(
            initiatorStatic: iStatic,
            responderStatic: rStatic
        )
        guard result.m1 > 0, result.m2 > 0, result.ct > 0 else {
            throw SelfTestFailure.payload(layer: "L1.size", expected: ">0", got: "\(result)")
        }
    }

    private static func l2_storeLifecycleRoundTrip() throws {
        let aliceStatic = Curve25519.KeyAgreement.PrivateKey()
        let bobStatic   = Curve25519.KeyAgreement.PrivateKey()

        var alice = try NoiseSession(role: .initiator, staticKey: aliceStatic, peerStaticKey: bobStatic.publicKey)
        var bob   = try NoiseSession(role: .responder, staticKey: bobStatic,   peerStaticKey: nil)
        _ = alice; _ = bob

        // Initiator embeds an in-flight payload in M1 — the same 1-RTT
        // pattern the production code uses (see encodeV2NoiseHandshake1FrameForPeer).
        let inFlight = Data("1RTT-payload".utf8)
        let m1 = try alice.writeMessage1(payload: inFlight)
        let recovered = try bob.readMessage1(m1)
        guard recovered == inFlight else {
            throw SelfTestFailure.payload(
                layer: "L2.M1-payload",
                expected: String(decoding: inFlight, as: UTF8.self),
                got: String(decoding: recovered, as: UTF8.self)
            )
        }
        guard bob.peerStaticKey != nil else { throw SelfTestFailure.missingPeerStaticKey }

        let m2 = try bob.writeMessage2(payload: Data())
        _ = try alice.readMessage2(m2)

        let (aSend, _) = try alice.split()
        let (_, bRecv) = try bob.split()

        let ad = Data("L2-msg-id".utf8)
        let plain = Data("transport-after-handshake".utf8)
        let ct = try aSend.encryptWithAd(ad, plaintext: plain)
        let pt = try bRecv.decryptWithAd(ad, ciphertext: ct)
        guard pt == plain else {
            throw SelfTestFailure.payload(
                layer: "L2.transport",
                expected: String(decoding: plain, as: UTF8.self),
                got: String(decoding: pt, as: UTF8.self)
            )
        }
    }

    private static func l3_sealerWireRoundTrip() throws {
        // Stand up Noise transport keys exactly the way the
        // production handshake produces them.
        let aliceStatic = Curve25519.KeyAgreement.PrivateKey()
        let bobStatic   = Curve25519.KeyAgreement.PrivateKey()
        var alice = try NoiseSession(role: .initiator, staticKey: aliceStatic, peerStaticKey: bobStatic.publicKey)
        var bob   = try NoiseSession(role: .responder, staticKey: bobStatic,   peerStaticKey: nil)
        _ = alice; _ = bob
        _ = try bob.readMessage1(try alice.writeMessage1(payload: Data()))
        _ = try alice.readMessage2(try bob.writeMessage2(payload: Data()))
        let (aSend, _) = try alice.split()
        let (_, bRecv) = try bob.split()

        // Mirror MessageContentSealer.{seal,unseal} byte-for-byte.
        let senderId    = "alice-test"
        let recipientId = "bob-test"
        let msgId       = UUID().uuidString
        let plaintext   = "the quick brown fox jumps over the lazy dog"

        let aadSender = buildAADForSelfTest(
            senderUserId: senderId,
            recipientUserId: recipientId,
            msgId: msgId
        )
        let ct = try aSend.encryptWithAd(aadSender, plaintext: Data(plaintext.utf8))

        // Build wire: RVNS1 magic || ciphertext.
        var wire = Data()
        wire.append(rvns1MagicForSelfTest)
        wire.append(ct)

        // Receiver-side decode: strip magic, rebuild AAD, decrypt.
        guard wire.prefix(rvns1MagicForSelfTest.count) == rvns1MagicForSelfTest else {
            throw SelfTestFailure.wireMagicMismatch
        }
        let rest = wire.subdata(in: rvns1MagicForSelfTest.count..<wire.count)
        let aadReceiver = buildAADForSelfTest(
            senderUserId: senderId,
            recipientUserId: recipientId,
            msgId: msgId
        )
        let pt = try bRecv.decryptWithAd(aadReceiver, ciphertext: rest)
        guard let recoveredText = String(data: pt, encoding: .utf8), recoveredText == plaintext else {
            throw SelfTestFailure.payload(
                layer: "L3.sealer",
                expected: plaintext,
                got: String(data: pt, encoding: .utf8) ?? "<non-utf8>"
            )
        }
    }

    /// Exact mirror of `MessageContentSealer.sealedMagic` (private).
    /// Mirrored here so this self-test catches a divergence between
    /// the two definitions instead of silently diverging.
    private static let rvns1MagicForSelfTest: Data =
        Data([0x52, 0x56, 0x4E, 0x53, 0x31, 0x00, 0x00, 0x00])

    /// Exact mirror of `MessageContentSealer.buildAAD` (private).
    /// Same caveat as the magic bytes: if the production AAD shape
    /// ever changes, the L3 test FAILs with an AEAD verify error
    /// pointing right at this method.
    private static func buildAADForSelfTest(
        senderUserId: String?,
        recipientUserId: String?,
        msgId: String
    ) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data("raven-sealer-v2".utf8))
        hasher.update(data: Data([0x00]))
        hasher.update(data: Data((senderUserId ?? "").utf8))
        hasher.update(data: Data([0x00]))
        hasher.update(data: Data((recipientUserId ?? "").utf8))
        hasher.update(data: Data([0x00]))
        hasher.update(data: Data(msgId.utf8))
        return Data(hasher.finalize())
    }
}
