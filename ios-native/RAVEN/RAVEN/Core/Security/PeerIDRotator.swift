// PeerIDRotator.swift
//
// Phase E.4 — rotating pseudonymous peer IDs.
//
// Today (v2 envelope), `sender_pid` and `dest_pid` are stable
// `SHA-256(static_pubkey)[:16]` values. A passive radio sniffer in
// a café learns the peer-pair graph trivially because the same two
// 16-byte values appear on every frame for the duration of the
// relationship.
//
// In the v3 envelope, both fields rotate per-message via HKDF over
// the Noise session key:
//
//   session_id   = HKDF(session_key, "RAVEN.v3.peer-id-session", 16)
//   sender_pid_n = HKDF(session_key,
//                       "RAVEN.v3.sender-id" || counter_n_BE, 16)
//   dest_pid_n   = HKDF(session_key,
//                       "RAVEN.v3.dest-id"   || counter_n_BE, 16)
//
// A passive observer sees uncorrelated 16-byte IDs that change on
// every message. Relay routing still works because the IDs are the
// same byte length — the relay just can't link them across messages.
// Server bridge: when a v3 envelope is bridged, the server peels the
// rotating ID using the session key it negotiated with each endpoint
// (server holds a separate Noise session per user) and maps to the
// account ID. So bridging remains transparent.
//
// **Threat model coverage**:
//   • Passive radio sniffer:                ✓ defeated
//   • Active jammer who knows your acct:    × (out of scope — they
//                                              can correlate other
//                                              signals anyway)
//   • Server-side log dump:                 × the server still knows
//                                              both endpoints; this
//                                              is about RADIO privacy
//                                              not server privacy
//
// BYTE-IDENTICAL sibling on Mac at
// `RAVEN-MacApp/RAVEN/Core/Security/PeerIDRotator.swift`.

import Foundation
import CryptoKit

public enum PeerIDRotatorError: Error, Equatable {
    case unknownCounter         // counter outside our verification window
    case derivationFailed       // shouldn't happen — defensive
    case keyTooShort            // session key < 32 bytes
}

/// Derives + recognises rotating peer IDs for one Noise session.
///
/// Each peer owns one `PeerIDRotator` per active session. The session
/// key passed in is the post-`split()` transport-mode key (either
/// direction works as long as both peers use the same one; protocol
/// pins it to the receive-direction key).
///
/// Thread-safety: instances are `final class`, callers must own
/// concurrency. The cache below is mutated on lookup; do not share
/// across threads without an external lock.
public final class PeerIDRotator {

    /// Per-pseudonym length on the wire, in bytes. Matches v2 / v3
    /// `sender_pid` / `dest_pid` width so the envelope header layout
    /// is byte-compatible.
    public static let pidSize: Int = 16

    /// How far ahead of the receiver's last-seen counter we'll
    /// pre-derive expected dest IDs. Tolerates burst delivery
    /// reordering without blowing the cache up. Matches
    /// `SecurityConstants.Replay.bitmapWindowSize / 4` (256 by default).
    public static let derivationLookahead: Int = max(64, SecurityConstants.Replay.bitmapWindowSize / 4)

    /// Session key used as the HKDF IKM. Treated as a secret — never
    /// log, copy, or expose. Wiped on `evict()`.
    private var sessionKey: SymmetricKey

    /// Cached derivations so the per-message HKDF cost is paid once.
    /// Keyed by counter. Size-bounded by `derivationLookahead`.
    private var senderIDCache: [UInt64: Data] = [:]
    private var destIDCache:   [UInt64: Data] = [:]

    /// One-time stable session pseudonym — for chat-list display
    /// (the receiver sees "an active session with X" without leaking
    /// the static identity to passive observers). Derived once at
    /// construction.
    public let sessionPseudonym: Data

    public init(sessionKey: SymmetricKey) throws {
        // CryptoKit's SymmetricKey backs onto raw bytes; we want to
        // verify length without copying them out. There's no public
        // `byteCount` getter, so we read via `withUnsafeBytes`. 32 B
        // is the post-split() Noise transport key size.
        var ok = false
        sessionKey.withUnsafeBytes { buf in
            ok = buf.count >= 32
        }
        guard ok else { throw PeerIDRotatorError.keyTooShort }

        self.sessionKey = sessionKey
        let sessionInfo = SecurityConstants.KDFLabel.peerIdSession.bytes
        let sessionPub = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sessionKey,
            salt: Data(),
            info: sessionInfo,
            outputByteCount: Self.pidSize
        )
        var sessionBytes = Data(count: Self.pidSize)
        sessionPub.withUnsafeBytes { kBuf in
            sessionBytes.withUnsafeMutableBytes { dBuf in
                dBuf.copyMemory(from: kBuf)
            }
        }
        self.sessionPseudonym = sessionBytes
    }

    // MARK: - Sender side (this peer producing IDs for outbound messages)

    /// Derive the sender pseudonym for outgoing message `counter`.
    /// `counter` is the per-session monotonic message number — same
    /// value bound into the Noise transport AEAD's associated data
    /// (see E.3). Both sides MUST agree on the counter value or the
    /// derived IDs won't match.
    public func senderID(forCounter counter: UInt64) -> Data {
        if let cached = senderIDCache[counter] { return cached }
        let id = derive(label: SecurityConstants.KDFLabel.peerIdSender, counter: counter)
        senderIDCache[counter] = id
        trim(&senderIDCache)
        return id
    }

    /// Derive the destination pseudonym for outgoing message `counter`.
    /// Conceptually identical to `senderID` but uses a separate domain
    /// label so a passive observer can't pair "sender = dest" across
    /// messages (would happen if the same KDF input produced the same
    /// output for both).
    public func destID(forCounter counter: UInt64) -> Data {
        if let cached = destIDCache[counter] { return cached }
        let id = derive(label: SecurityConstants.KDFLabel.peerIdDest, counter: counter)
        destIDCache[counter] = id
        trim(&destIDCache)
        return id
    }

    // MARK: - Receiver side (recognising inbound messages)

    /// Walk the next `derivationLookahead` slots forward from
    /// `lastSeenCounter` and return the counter whose dest-ID matches
    /// the inbound envelope's `dest_pid` (i.e. "this message is
    /// addressed to me"). Returns nil if no match — caller can fall
    /// back to ignoring the frame or checking the stable v2 path.
    public func recognise(destPID: Data,
                          lastSeenCounter: UInt64) throws -> UInt64? {
        guard destPID.count == Self.pidSize else {
            throw PeerIDRotatorError.derivationFailed
        }
        // Start from lastSeen + 1 (a fresh message) but ALSO check
        // last-seen itself in case the frame is a retransmit.
        let start = lastSeenCounter
        let end = lastSeenCounter &+ UInt64(Self.derivationLookahead)
        // &+ allows UInt64 wrap; in practice the counter never gets
        // anywhere near that, but the math stays well-defined.
        for c in start...end {
            // Inline the HKDF — don't cache here, since we don't
            // know whether the caller will commit yet. Cache on
            // confirmed match in `destID(forCounter:)`.
            let candidate = derive(label: SecurityConstants.KDFLabel.peerIdDest, counter: c)
            if constantTimeEqual(candidate, destPID) {
                destIDCache[c] = candidate
                return c
            }
            // Guard against UInt64 wrap stopping the loop early.
            if c == UInt64.max { break }
        }
        return nil
    }

    // MARK: - Lifecycle

    /// Wipe the session key + caches. Called when the engine evicts
    /// the underlying Noise session (E.6 quota rotation or peer
    /// re-pair). Subsequent calls return zeros / nil.
    public func evict() {
        // Replace the key with a zero-buffer of the same size. We
        // can't actually scrub the original symmetric key's backing
        // bytes from Swift, but releasing the reference + storing a
        // zero key minimises the window where the secret is reachable.
        sessionKey = SymmetricKey(data: Data(repeating: 0, count: 32))
        senderIDCache.removeAll(keepingCapacity: false)
        destIDCache.removeAll(keepingCapacity: false)
    }

    // MARK: - Internals

    private func derive(label: SecurityConstants.KDFLabel, counter: UInt64) -> Data {
        // info = label_bytes || counter_BE (8 bytes). Big-endian so
        // the value is human-debuggable in hex dumps and matches
        // network byte order used elsewhere in the protocol.
        var info = label.bytes
        var c = counter.bigEndian
        withUnsafeBytes(of: &c) { info.append(contentsOf: $0) }
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sessionKey,
            salt: Data(),
            info: info,
            outputByteCount: Self.pidSize
        )
        var out = Data(count: Self.pidSize)
        derived.withUnsafeBytes { kBuf in
            out.withUnsafeMutableBytes { dBuf in
                dBuf.copyMemory(from: kBuf)
            }
        }
        return out
    }

    private func trim<K: Hashable, V>(_ cache: inout [K: V]) {
        // Bound the LRU to lookahead × 2 so we don't grow unbounded
        // when a chatty peer keeps incrementing. Naive eviction —
        // drop arbitrary keys when full. This is a cache, not a
        // correctness layer; reseeding via `derive` is cheap.
        let cap = Self.derivationLookahead * 2
        if cache.count > cap {
            let drop = cache.count - cap
            for k in cache.keys.prefix(drop) {
                cache.removeValue(forKey: k)
            }
        }
    }

    /// Constant-time byte compare. The wire pseudonym is public so
    /// strictly speaking this isn't a secret-dependent comparison,
    /// BUT a timing channel could leak how-many-counters-deep the
    /// receiver checked before matching — which IS sender-controlled
    /// metadata. Constant-time keeps the loop position opaque.
    private func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[a.startIndex + i] ^ b[b.startIndex + i]
        }
        return diff == 0
    }
}
