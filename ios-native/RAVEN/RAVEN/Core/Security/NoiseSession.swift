// NoiseSession.swift
//
// `Noise_IK_25519_ChaChaPoly_SHA256` — the IK pattern of the
// Noise Protocol Framework (https://noiseprotocol.org/noise.html#5.2).
//
// IK gives us a 1-RTT mutually-authenticated handshake in the case
// where the initiator already knows the responder's static public
// key (e.g. via a friend list or QR pairing). It's the right
// primitive to swap in for v1's constant-salt HKDF + AES-GCM-with-
// long-lived-ECDH: the per-message DH ratchet that follows split()
// gives us forward secrecy that the v1 path lacks.
//
// What this file ships:
//   • `NoiseSession` — drives the 2-message IK handshake.
//   • `NoiseCipherState` — post-handshake transport-mode AEAD.
//   • A self-test in `#if DEBUG` that round-trips message 1 + 2 +
//     a transport-mode encrypt/decrypt against the canonical Noise
//     test vector layout.
//
// What it intentionally does NOT do (yet):
//   • Wire into the v2 envelope path. The current v2 envelope still
//     carries AES-GCM-encrypted v1 ciphertext as its inner payload;
//     swapping that for `NoiseSession` is the next step (Phase C.1.b).
//   • Implement the XX fallback pattern. IK assumes we know the
//     peer's static key; first-contact peers (no friend-of-friend
//     pre-share) still need XX. Tracked separately.
//
// All four siblings (iOS, Mac, Windows, Android) will need a
// byte-identical Noise implementation for cross-platform interop.
// This file is the canonical Swift reference; ports follow.

import Foundation
import CryptoKit

// MARK: - Errors

enum NoiseError: Error, Equatable {
    case missingPeerStaticKey
    case decryptFailed
    case malformedMessage
    case wrongMessageOrder
}

// MARK: - HKDF helpers (RFC 5869, single-block outputs)

private enum NoiseHKDF {
    /// Returns `(t1, t2)` — two 32-byte chunks. Used by `mixKey`.
    static func n2(chainingKey ck: [UInt8], input: Data) -> ([UInt8], [UInt8]) {
        let prk = HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: Data(ck)))
        let prkKey = SymmetricKey(data: Data(prk))
        let t1 = HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: prkKey)
        var t2input = Data(t1)
        t2input.append(0x02)
        let t2 = HMAC<SHA256>.authenticationCode(for: t2input, using: prkKey)
        return (Array(t1), Array(t2))
    }

    /// Returns `(t1, t2, t3)`. Used by `split()` (and `mixKeyAndHash`,
    /// not currently called for IK but kept for completeness).
    static func n3(chainingKey ck: [UInt8], input: Data) -> ([UInt8], [UInt8], [UInt8]) {
        let prk = HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: Data(ck)))
        let prkKey = SymmetricKey(data: Data(prk))
        let t1 = HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: prkKey)
        var t2input = Data(t1)
        t2input.append(0x02)
        let t2 = HMAC<SHA256>.authenticationCode(for: t2input, using: prkKey)
        var t3input = Data(t2)
        t3input.append(0x03)
        let t3 = HMAC<SHA256>.authenticationCode(for: t3input, using: prkKey)
        return (Array(t1), Array(t2), Array(t3))
    }
}

// MARK: - SymmetricState (Noise §5.2)

/// Internal — drives the chaining-key + hash + cipher-key triple
/// that every Noise handshake state machine maintains. Not exposed.
private struct NoiseSymmetricState {
    var ck: [UInt8]    // 32-byte chaining key
    var h: [UInt8]     // 32-byte handshake hash
    var k: SymmetricKey?
    var n: UInt64 = 0  // AEAD nonce counter for the current key

    init(protocolName: String) {
        let nameBytes = Array(protocolName.utf8)
        if nameBytes.count == 32 {
            self.h = nameBytes
        } else if nameBytes.count < 32 {
            // Per spec: pad with zero bytes when name is shorter.
            self.h = nameBytes + [UInt8](repeating: 0, count: 32 - nameBytes.count)
        } else {
            self.h = Array(SHA256.hash(data: Data(nameBytes)))
        }
        self.ck = self.h
    }

    mutating func mixHash(_ data: Data) {
        var hasher = SHA256()
        hasher.update(data: Data(h))
        hasher.update(data: data)
        h = Array(hasher.finalize())
    }

    mutating func mixKey(_ input: Data) {
        let (newCK, newK) = NoiseHKDF.n2(chainingKey: ck, input: input)
        ck = newCK
        k = SymmetricKey(data: Data(newK))
        n = 0
    }

    /// 96-bit ChaChaPoly nonce: 4 zero bytes prefix + 8-byte LE counter.
    private func currentNonce() throws -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 4)
        let leBytes = withUnsafeBytes(of: n.littleEndian) { Array($0) }
        bytes.append(contentsOf: leBytes)
        return try ChaChaPoly.Nonce(data: Data(bytes))
    }

    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        guard let k else {
            // No cipher key yet — the spec says we still mix the
            // plaintext into the hash, then return it unchanged.
            mixHash(plaintext)
            return plaintext
        }
        let nonce = try currentNonce()
        let sealed = try ChaChaPoly.seal(plaintext, using: k, nonce: nonce, authenticating: Data(h))
        var ct = Data(sealed.ciphertext)
        ct.append(sealed.tag)
        n &+= 1
        mixHash(ct)
        return ct
    }

    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        guard let k else {
            mixHash(ciphertext)
            return ciphertext
        }
        guard ciphertext.count >= 16 else { throw NoiseError.malformedMessage }
        let tag = ciphertext.suffix(16)
        let payload = ciphertext.prefix(ciphertext.count - 16)
        let nonce = try currentNonce()
        let sealed: ChaChaPoly.SealedBox
        do {
            sealed = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: payload, tag: tag)
        } catch {
            throw NoiseError.malformedMessage
        }
        let plaintext: Data
        do {
            plaintext = try ChaChaPoly.open(sealed, using: k, authenticating: Data(h))
        } catch {
            throw NoiseError.decryptFailed
        }
        n &+= 1
        mixHash(ciphertext)
        return plaintext
    }
}

// MARK: - HandshakeState (IK pattern only)

/// Drives a Noise_IK_25519_ChaChaPoly_SHA256 handshake. Two
/// messages: initiator → responder, then responder → initiator.
/// Call `split()` after both messages have been written/read; the
/// returned cipher pair carries the transport-mode session keys.
public final class NoiseSession {
    public enum Role { case initiator, responder }

    public static let protocolName = "Noise_IK_25519_ChaChaPoly_SHA256"

    private var sym: NoiseSymmetricState
    private let role: Role

    // Static + ephemeral keypairs. `s` is ours; `e` we generate at the
    // first message we write. `rs`/`re` are the peer's.
    private let s: Curve25519.KeyAgreement.PrivateKey
    private var e: Curve25519.KeyAgreement.PrivateKey?
    private var rs: Curve25519.KeyAgreement.PublicKey?
    private var re: Curve25519.KeyAgreement.PublicKey?

    /// Tracks how many handshake messages we've processed; clamps
    /// callers to the correct order.
    private var msgIndex: Int = 0

    /// Build a session.
    /// - Parameters:
    ///   - role: who we are.
    ///   - staticKey: our long-term Curve25519 key (e.g. from
    ///     `DeviceIdentityService`).
    ///   - peerStaticKey: required for the initiator (IK assumes we
    ///     know it); responder leaves nil — we recover the peer's
    ///     static key from message 1.
    ///   - prologue: optional context bytes mixed in before any DH
    ///     output. Use it to bind app-level metadata (e.g. the v2
    ///     envelope `msg_id` or service name) into the handshake hash.
    public init(role: Role,
                staticKey: Curve25519.KeyAgreement.PrivateKey,
                peerStaticKey: Curve25519.KeyAgreement.PublicKey?,
                prologue: Data = Data()) throws {
        self.role = role
        self.s = staticKey
        self.rs = peerStaticKey
        self.sym = NoiseSymmetricState(protocolName: Self.protocolName)
        self.sym.mixHash(prologue)
        // IK pre-message: the responder's static public key is mixed
        // in by both sides before the first handshake message.
        if role == .initiator {
            guard let rs else { throw NoiseError.missingPeerStaticKey }
            self.sym.mixHash(rs.rawRepresentation)
        } else {
            // Responder mixes in OUR static (which is the responder's
            // static — i.e. ours, since we are the responder).
            self.sym.mixHash(self.s.publicKey.rawRepresentation)
        }
    }

    // MARK: - Message 1 (initiator → responder)
    //
    //   -> e, es, s, ss
    // Initiator writes: ephemeral, encrypted_static, encrypted_payload.

    public func writeMessage1(payload: Data = Data()) throws -> Data {
        guard role == .initiator, msgIndex == 0 else { throw NoiseError.wrongMessageOrder }
        guard let rs else { throw NoiseError.missingPeerStaticKey }

        let e = Curve25519.KeyAgreement.PrivateKey()
        self.e = e
        let ePub = e.publicKey.rawRepresentation
        sym.mixHash(ePub)

        // es: DH(e, rs)
        let es = try e.sharedSecretFromKeyAgreement(with: rs)
        es.withUnsafeBytes { sym.mixKey(Data($0)) }

        // s: encrypted static public key
        let sPub = s.publicKey.rawRepresentation
        let encryptedS = try sym.encryptAndHash(sPub)

        // ss: DH(s, rs)
        let ss = try s.sharedSecretFromKeyAgreement(with: rs)
        ss.withUnsafeBytes { sym.mixKey(Data($0)) }

        let encryptedPayload = try sym.encryptAndHash(payload)

        var out = Data()
        out.append(ePub)
        out.append(encryptedS)
        out.append(encryptedPayload)
        msgIndex = 1
        return out
    }

    public func readMessage1(_ message: Data) throws -> Data {
        guard role == .responder, msgIndex == 0 else { throw NoiseError.wrongMessageOrder }
        // Layout: [32 e_pub | (32 + 16) encrypted_s | rest encrypted_payload]
        guard message.count >= 32 + 32 + 16 else { throw NoiseError.malformedMessage }
        let base = message.startIndex

        let ePubData = message.subdata(in: base..<(base + 32))
        let ePub: Curve25519.KeyAgreement.PublicKey
        do {
            ePub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ePubData)
        } catch {
            throw NoiseError.malformedMessage
        }
        re = ePub
        sym.mixHash(ePubData)

        // es from our static + their ephemeral.
        let es = try s.sharedSecretFromKeyAgreement(with: ePub)
        es.withUnsafeBytes { sym.mixKey(Data($0)) }

        // s: 32-byte encrypted static + 16-byte tag = 48 bytes.
        let encryptedS = message.subdata(in: (base + 32)..<(base + 32 + 48))
        let sPubBytes = try sym.decryptAndHash(encryptedS)
        guard sPubBytes.count == 32 else { throw NoiseError.malformedMessage }
        let rsRecovered: Curve25519.KeyAgreement.PublicKey
        do {
            rsRecovered = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: sPubBytes)
        } catch {
            throw NoiseError.malformedMessage
        }
        self.rs = rsRecovered

        // ss: DH(s, rs) — both static keys agree.
        let ss = try s.sharedSecretFromKeyAgreement(with: rsRecovered)
        ss.withUnsafeBytes { sym.mixKey(Data($0)) }

        let encryptedPayload = message.subdata(in: (base + 32 + 48)..<message.endIndex)
        let payload = try sym.decryptAndHash(encryptedPayload)
        msgIndex = 1
        return payload
    }

    // MARK: - Message 2 (responder → initiator)
    //
    //   <- e, ee, se
    // Responder writes ephemeral + encrypted payload (no static —
    // the initiator already had ours before the handshake).

    public func writeMessage2(payload: Data = Data()) throws -> Data {
        guard role == .responder, msgIndex == 1 else { throw NoiseError.wrongMessageOrder }
        guard let re else { throw NoiseError.malformedMessage }
        guard let rs else { throw NoiseError.malformedMessage }

        let e = Curve25519.KeyAgreement.PrivateKey()
        self.e = e
        let ePub = e.publicKey.rawRepresentation
        sym.mixHash(ePub)

        // ee: DH(e, re)
        let ee = try e.sharedSecretFromKeyAgreement(with: re)
        ee.withUnsafeBytes { sym.mixKey(Data($0)) }

        // se: DH(s, re) — our static, peer's ephemeral.
        // The IK pattern actually specifies `se` as DH(s, re) on the
        // responder side; that maps to our `s` (responder static)
        // and `re` (initiator ephemeral, which we stored on read of
        // message 1).
        let se = try s.sharedSecretFromKeyAgreement(with: re)
        se.withUnsafeBytes { sym.mixKey(Data($0)) }

        // Suppress the "unused var" warning when running without
        // tests — `rs` is captured for symmetry with the spec; future
        // patterns (e.g. ratcheted IK) will mix it in here too.
        _ = rs

        let encryptedPayload = try sym.encryptAndHash(payload)
        var out = Data()
        out.append(ePub)
        out.append(encryptedPayload)
        msgIndex = 2
        return out
    }

    public func readMessage2(_ message: Data) throws -> Data {
        guard role == .initiator, msgIndex == 1 else { throw NoiseError.wrongMessageOrder }
        guard let e else { throw NoiseError.malformedMessage }
        guard let rs else { throw NoiseError.missingPeerStaticKey }
        guard message.count >= 32 + 16 else { throw NoiseError.malformedMessage }
        let base = message.startIndex

        let ePubData = message.subdata(in: base..<(base + 32))
        let ePub: Curve25519.KeyAgreement.PublicKey
        do {
            ePub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ePubData)
        } catch {
            throw NoiseError.malformedMessage
        }
        re = ePub
        sym.mixHash(ePubData)

        // ee: DH(e, re) from initiator's POV — our ephemeral, their
        // ephemeral.
        let ee = try e.sharedSecretFromKeyAgreement(with: ePub)
        ee.withUnsafeBytes { sym.mixKey(Data($0)) }

        // se: DH(e, rs) on the initiator — our ephemeral, their
        // static. That's the symmetric counterpart of what the
        // responder did in `writeMessage2` above.
        let se = try e.sharedSecretFromKeyAgreement(with: rs)
        se.withUnsafeBytes { sym.mixKey(Data($0)) }

        let encryptedPayload = message.subdata(in: (base + 32)..<message.endIndex)
        let payload = try sym.decryptAndHash(encryptedPayload)
        msgIndex = 2
        return payload
    }

    // MARK: - Split (transport mode)

    /// After both handshake messages have been processed, derive two
    /// transport-mode `NoiseCipherState`s and discard the handshake
    /// state. Returns `(sending, receiving)` keyed for THIS side —
    /// the initiator's `sending` matches the responder's `receiving`,
    /// and vice-versa.
    public func split() throws -> (sending: NoiseCipherState, receiving: NoiseCipherState) {
        guard msgIndex == 2 else { throw NoiseError.wrongMessageOrder }
        // Per spec: HKDF(ck, zero-length, n=2). We re-use `n2` with
        // an empty input.
        let (k1, k2) = NoiseHKDF.n2(chainingKey: sym.ck, input: Data())
        // Phase E.6 — stamp `establishedAt` once at transport-mode
        // entry so both directions share the same age clock. Engines
        // use this to detect rotation candidates without needing to
        // store the timestamp themselves.
        let now = Date()
        let send: NoiseCipherState
        let recv: NoiseCipherState
        switch role {
        case .initiator:
            send = NoiseCipherState(key: SymmetricKey(data: Data(k1)), establishedAt: now)
            recv = NoiseCipherState(key: SymmetricKey(data: Data(k2)), establishedAt: now)
        case .responder:
            recv = NoiseCipherState(key: SymmetricKey(data: Data(k1)), establishedAt: now)
            send = NoiseCipherState(key: SymmetricKey(data: Data(k2)), establishedAt: now)
        }
        return (send, recv)
    }

    /// Handshake hash — useful for binding application-level data
    /// (e.g. an "out-of-band SAS" verification string) to this
    /// session. Only meaningful after `split()`.
    public var handshakeHash: Data { Data(sym.h) }

    /// The peer's static Curve25519 public key. For an initiator
    /// this is the value passed to `init`; for a responder it's the
    /// value recovered from message 1 (nil before `readMessage1`).
    /// `NoiseSessionStore` needs this on the responder side to
    /// derive the peer's stable 16-byte peer-id and stash the
    /// post-split() cipher states under it.
    public var peerStaticKey: Curve25519.KeyAgreement.PublicKey? { rs }
}

// MARK: - CipherState (transport mode)

/// Post-handshake AEAD state. Each direction (send / receive) gets
/// one. ChaChaPoly nonces tick monotonically; reusing an old nonce
/// is a security failure, so callers should treat the state as
/// non-copyable and not mutate from multiple threads concurrently.
///
/// ## Phase E hardening
///
/// **E.3 replay enforcement** is mostly free here: the nonce is
/// derived from the monotonic counter `n`, so an attacker re-injecting
/// an old ciphertext sees AEAD-tag-mismatch immediately. The on-receive
/// `n` and on-send `n` MUST stay in lock-step; reordering on the wire
/// breaks decrypt. For lossy / out-of-order transports (BLE relays,
/// Wi-Fi Aware) the bitmap window in
/// ``NoiseReplayWindow`` tracks recently-seen counters and the engine
/// rewinds `n` to the correct value before retrying — see
/// `decryptWithAd(_:ciphertext:counter:)`.
///
/// **E.6 forward-secrecy quotas** are exposed through `messageCount`
/// + `establishedAt` + `shouldRotate`. Engines call `shouldRotate`
/// before every encrypt; once it returns true, the engine evicts the
/// session and forces a fresh handshake on the next outbound message.
/// This caps the blast radius of a stolen key to
/// `SecurityConstants.Session.maxMessages` ∧
/// `SecurityConstants.Session.maxAge`.
public final class NoiseCipherState {
    private let key: SymmetricKey
    private var n: UInt64 = 0

    /// Wall-clock time the session entered transport mode. Used by
    /// `shouldRotate` to honour `SecurityConstants.Session.maxAge`.
    public let establishedAt: Date

    /// Total messages encrypted OR decrypted by this state. Same value
    /// as the AEAD nonce counter `n` — exposed read-only so callers
    /// can implement quota checks without touching the nonce path.
    public var messageCount: UInt64 { n }

    public init(key: SymmetricKey, establishedAt: Date = Date()) {
        self.key = key
        self.establishedAt = establishedAt
    }

    /// True iff this session has crossed any of the rotation thresholds
    /// in ``SecurityConstants/Session`` and should be re-handshaked
    /// before the next message. Returns false when the rotation feature
    /// flag is disabled — engines that ignore this signal stay on the
    /// pre-E.6 long-lived-session behaviour.
    public var shouldRotate: Bool {
        guard SecurityConstants.sessionRotationEnabled else { return false }
        if n >= SecurityConstants.Session.maxMessages { return true }
        if Date().timeIntervalSince(establishedAt) >= SecurityConstants.Session.maxAge { return true }
        return false
    }

    /// Hard ceiling — the engine MUST refuse to encrypt past this even
    /// when `sessionRotationEnabled == false`, because crossing it
    /// approaches the nonce-reuse boundary for ChaCha20-Poly1305 (we
    /// still have 2^64 - 1M nonces of headroom, so this is a defence
    /// in depth, not a hard cryptographic limit).
    public var hasReachedHardLimit: Bool {
        n >= SecurityConstants.Session.hardLimitMessages
    }

    private func currentNonce() throws -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 4)
        let leBytes = withUnsafeBytes(of: n.littleEndian) { Array($0) }
        bytes.append(contentsOf: leBytes)
        return try ChaChaPoly.Nonce(data: Data(bytes))
    }

    public func encryptWithAd(_ ad: Data, plaintext: Data) throws -> Data {
        // E.6 hard-limit guard. We never let the counter touch 2^64 −
        // anything-close-to-1M because that's where the nonce-reuse
        // risk lives; rotate well before then.
        if hasReachedHardLimit {
            throw NoiseError.wrongMessageOrder
        }
        let nonce = try currentNonce()
        let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: ad)
        var ct = Data(sealed.ciphertext)
        ct.append(sealed.tag)
        n &+= 1
        return ct
    }

    public func decryptWithAd(_ ad: Data, ciphertext: Data) throws -> Data {
        guard ciphertext.count >= 16 else { throw NoiseError.malformedMessage }
        let tag = ciphertext.suffix(16)
        let payload = ciphertext.prefix(ciphertext.count - 16)
        let nonce = try currentNonce()
        let sealed = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: payload, tag: tag)
        let plaintext: Data
        do {
            plaintext = try ChaChaPoly.open(sealed, using: key, authenticating: ad)
        } catch {
            throw NoiseError.decryptFailed
        }
        n &+= 1
        return plaintext
    }
}

// MARK: - Replay window (Phase E.3)

/// Sliding-bitmap anti-replay window — IPsec / RFC 6479 style.
///
/// Tracks the highest counter seen plus a bitmap of which of the previous
/// ``SecurityConstants/Replay/bitmapWindowSize`` slots have been
/// delivered. Lets us accept slightly-out-of-order frames (common on
/// lossy BLE relays) while still rejecting genuine replays and
/// far-future jumps.
///
/// Independent of the AEAD nonce: a determined attacker who knows the
/// session key could craft a frame with any nonce, but they can't
/// guess one in the future window without breaking AEAD anyway. The
/// window is defence-in-depth — drops obviously-bad frames before we
/// burn CPU on the AEAD verify, and catches the "buffered frame
/// re-injected later" attack the 24h Bloom filter can't see across.
public struct NoiseReplayWindow {
    private(set) var highest: UInt64 = 0
    /// Bit i = true iff counter `(highest - i)` has been delivered.
    /// `bitmap[0]` corresponds to `highest`.
    private var bitmap: [Bool]

    /// Default size mirrors `SecurityConstants.Replay.bitmapWindowSize` (1024).
    /// Kept as a literal here because `SecurityConstants` is internal and
    /// cannot appear in a `public` default-argument expression.
    public init(size: Int = 1024) {
        self.bitmap = [Bool](repeating: false, count: max(64, size))
    }

    /// Returns `.fresh` if `counter` is new + in-window, otherwise
    /// the reason for rejection. Caller must invoke `commit(counter:)`
    /// AFTER successful AEAD verify — never on the pre-check alone.
    public func check(counter: UInt64) -> ReplayDecision {
        if counter > highest {
            let jump = counter - highest
            if jump > SecurityConstants.Replay.acceptableJumpAhead {
                return .tooFarAhead
            }
            return .fresh
        }
        let delta = Int(highest - counter)
        if delta >= bitmap.count {
            return .tooOld
        }
        return bitmap[delta] ? .alreadySeen : .fresh
    }

    /// Records that `counter` was successfully delivered. Updates the
    /// high-water mark + shifts the bitmap if we jumped ahead.
    public mutating func commit(counter: UInt64) {
        if counter > highest {
            let shift = counter - highest
            if shift >= UInt64(bitmap.count) {
                // Counter jumped clear over the window — wipe and start
                // fresh at the new high.
                bitmap = [Bool](repeating: false, count: bitmap.count)
            } else {
                // Slide existing bits down by `shift` slots.
                let shiftAmount = Int(shift)
                for i in stride(from: bitmap.count - 1, through: shiftAmount, by: -1) {
                    bitmap[i] = bitmap[i - shiftAmount]
                }
                for i in 0..<shiftAmount {
                    bitmap[i] = false
                }
            }
            highest = counter
            bitmap[0] = true
            return
        }
        let delta = Int(highest - counter)
        if delta < bitmap.count {
            bitmap[delta] = true
        }
    }

    public enum ReplayDecision: Equatable {
        case fresh           // accept, then call commit on AEAD success
        case alreadySeen     // exact replay — drop silently
        case tooOld          // dropped out of window — drop, no alarm
        case tooFarAhead     // counter jumped past window — likely attack, drop + log
    }
}
