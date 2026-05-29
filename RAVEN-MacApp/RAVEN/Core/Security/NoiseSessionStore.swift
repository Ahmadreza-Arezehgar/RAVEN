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

    // MARK: - Transport mode

    /// Encrypt `plaintext` with the cached transport key for `peerID`.
    /// `ad` becomes the AEAD additional-data binding. Returns nil
    /// when no session exists (caller's signal to start a handshake).
    func encrypt(_ plaintext: Data, ad: Data, forPeer peerID: Data) -> Data? {
        guard let pair = transport[peerID] else { return nil }
        return try? pair.send.encryptWithAd(ad, plaintext: plaintext)
    }

    /// Decrypt `ciphertext`. Returns nil when no session exists or
    /// the AEAD verify fails (in which case the caller should evict
    /// the session — the peer probably rotated keys).
    func decrypt(_ ciphertext: Data, ad: Data, fromPeer peerID: Data) -> Data? {
        guard let pair = transport[peerID] else { return nil }
        do {
            return try pair.recv.decryptWithAd(ad, ciphertext: ciphertext)
        } catch {
            // AEAD failure → evict so the next send forces a fresh
            // handshake instead of looping on a dead session.
            evict(peerID: peerID)
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
        // NoiseSession is a `public final class` — the binding never
        // changes, only the object's internal state via method calls,
        // so `let` is correct here. Was `var` historically when this
        // type was a struct.
        let initiator = try NoiseSession(
            role: .initiator,
            staticKey: initiatorStatic,
            peerStaticKey: responderStatic.publicKey
        )
        let responder = try NoiseSession(
            role: .responder,
            staticKey: responderStatic,
            peerStaticKey: nil
        )

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
}
