//
//  PVPad.swift
//  RAVEN — PROXIMA-VAULT
//
//  In-memory representation of a single one-time-pad shared between
//  exactly TWO physical devices. Created by `PVProvisioner` (an
//  out-of-band exchange — QR + NFC + audio + in-person Bluetooth)
//  and persisted via `PVPadStore` (Keychain-wrapped, Secure-Enclave
//  gated, biometric-protected).
//
//  Per Patch 5 (direction separation) the pad blob holds TWO
//  symmetric sets of byte ranges, one per direction. The layout is
//  fully deterministic from `PVConstants` so two devices loading
//  the same pad-bytes interpret every offset identically.
//
//  Pad LAYOUT (offsets in bytes, relative to pad start):
//
//    ┌──────────────────────────────────────────────────────────────┐
//    │ HEADER (64 B)                                                │
//    │   0–15   pad_id (random)                                     │
//    │  16–31   pseudo_A (forward sender pad-local id)              │
//    │  32–47   pseudo_B (reverse sender pad-local id)              │
//    │  48–55   provisioned_at (unix64, big-endian)                 │
//    │  56–63   version + reserved                                  │
//    │──────────────────────────────────────────────────────────────│
//    │ FORWARD RANGES (A → B)                                       │
//    │      cipherPad        — `padCipherBytesPerDirection`         │
//    │      macKeys          — `padMacKeysBytesPerDirection`        │
//    │      tagMask          — `padTagMaskBytesPerDirection`        │
//    │      aeadNonce        — `padAeadNonceBytesPerDirection`      │
//    │      lookupKeys       — 32 (reserved for v3.2 PV-Stealth)    │
//    │──────────────────────────────────────────────────────────────│
//    │ REVERSE RANGES (B → A)                                       │
//    │      cipherPad        — `padCipherBytesPerDirection`         │
//    │      macKeys          — `padMacKeysBytesPerDirection`        │
//    │      tagMask          — `padTagMaskBytesPerDirection`        │
//    │      aeadNonce        — `padAeadNonceBytesPerDirection`      │
//    │      lookupKeys       — 32                                   │
//    └──────────────────────────────────────────────────────────────┘
//
//  Counter state (the "where am I in the pad" cursor for each
//  direction) lives OUTSIDE this struct — see `PVPadCursor`. We
//  keep the bytes immutable here and let the cursor own all
//  mutation so a corrupt cursor cannot silently overwrite pad
//  material in memory.
//

import Foundation

/// One-time-pad shared between two devices. Loaded from
/// Keychain at session start, held in memory only while the
/// vault is "open" (biometric session), zeroized on lock or
/// app suspend.
///
/// NOT `Codable` on purpose — serialisation goes through
/// `PVPadStore` which controls encryption-at-rest separately.
struct PVPad: Sendable {

    /// Public identifier (16 B, random at provision time).
    /// Surfaced in every envelope header for receiver-side
    /// lookup. NOT a secret.
    let padId: Data

    /// Pad-local pseudonym for the forward direction's sender.
    /// 16 B drawn from pad-material at provision time.
    /// Acts as the "device identifier" in the envelope so we
    /// don't have to put the real public key on the wire
    /// (Patch 8).
    let pseudonymForward: Data

    /// Pad-local pseudonym for the reverse direction's sender.
    let pseudonymReverse: Data

    /// When the pad was provisioned. Used by UI to surface
    /// "pad is old, consider re-provisioning" warnings; NOT
    /// fed into any KDF.
    let provisionedAt: Date

    /// Raw pad bytes — the whole blob. Held in a `Data` so the
    /// OS can release the page promptly on `zeroize()`. Treated
    /// as a flat array indexed by `PVPadRange` start offsets.
    private(set) var rawBytes: Data

    /// Returns the absolute byte range within `rawBytes` for
    /// a particular purpose+direction. Single point of truth
    /// so encryptor and decryptor agree on every offset.
    func range(for purpose: PVPadRange.Purpose,
               direction: PVDirection) -> PVPadRange {
        PVPadRange.compute(purpose: purpose,
                           direction: direction)
    }

    /// Read N bytes from the pad starting at `offset`. Bounds
    /// checked; throws `padIncomplete` if the read would walk
    /// past the pad's end.
    func read(offset: Int, length: Int) throws -> Data {
        guard offset >= 0,
              length > 0,
              offset + length <= rawBytes.count else {
            throw PVError.padIncomplete
        }
        return rawBytes.subdata(in: offset ..< (offset + length))
    }

    /// Best-effort zeroization of the pad-bytes buffer. Swift
    /// `Data`'s storage is COW and may have multiple references;
    /// callers MUST be the sole owner before calling this. The
    /// dispose pattern is: load → use → `consumingZeroize()` on
    /// the same scope so no other reference can keep the
    /// pre-zero copy alive.
    ///
    /// Note: Swift cannot guarantee a single physical page —
    /// the runtime may relocate Data backing storage. For true
    /// guarantees pad material should sit in `SecureBytes` (a
    /// future helper that wraps `mlock`'d allocation); for v1
    /// reference, this best-effort is documented as such.
    mutating func consumingZeroize() {
        rawBytes.withUnsafeMutableBytes { buf in
            // 0xFF first then 0x00 — two-pass overwrite so any
            // memory-scanning tool reading mid-clear sees noise,
            // not the pad pattern.
            for i in 0..<buf.count { buf[i] = 0xFF }
            for i in 0..<buf.count { buf[i] = 0x00 }
        }
        rawBytes = Data()
    }

    // MARK: - Hash-equality helpers

    /// Constant-time equality on pad IDs. NEVER use `==` on the
    /// raw `Data` for security-sensitive comparisons — the
    /// stdlib `==` short-circuits on first mismatch.
    static func padIdsMatch(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }
}

// MARK: - Byte-range descriptor

/// Describes one slice of the pad for one purpose, one direction.
/// Computed deterministically from `PVConstants` so both ends agree.
struct PVPadRange: Sendable {

    enum Purpose: Sendable {
        case cipher
        case macKeys
        case tagMask
        case aeadNonce
        case lookupKeys
    }

    /// Absolute byte offset within the pad blob.
    let offset: Int

    /// Length of this range in bytes.
    let length: Int

    /// Compute the (offset, length) for a given (purpose, direction)
    /// pair. The layout matches the diagram at the top of `PVPad`.
    /// Any drift here vs. the encrypt/decrypt expectation will silently
    /// corrupt — keep this function as the only source of truth.
    static func compute(purpose: Purpose,
                        direction: PVDirection) -> PVPadRange {
        // Header is 64 bytes.
        let headerSize = 64

        // Size of one direction's bundle:
        let oneDirection =
            PVConstants.padCipherBytesPerDirection +
            PVConstants.padMacKeysBytesPerDirection +
            PVConstants.padTagMaskBytesPerDirection +
            PVConstants.padAeadNonceBytesPerDirection +
            PVConstants.padLookupKeysBytesPerDirection

        // Forward block starts after header; reverse block starts
        // after forward.
        let dirStart: Int
        switch direction {
        case .forward: dirStart = headerSize
        case .reverse: dirStart = headerSize + oneDirection
        }

        // Within a direction block, ranges are laid out in this
        // strict order (DO NOT REORDER — pad-bytes provisioned by
        // older builds rely on this exact sequence):
        //   cipher | macKeys | tagMask | aeadNonce | lookupKeys
        switch purpose {
        case .cipher:
            return PVPadRange(
                offset: dirStart,
                length: PVConstants.padCipherBytesPerDirection
            )
        case .macKeys:
            return PVPadRange(
                offset: dirStart + PVConstants.padCipherBytesPerDirection,
                length: PVConstants.padMacKeysBytesPerDirection
            )
        case .tagMask:
            return PVPadRange(
                offset: dirStart +
                        PVConstants.padCipherBytesPerDirection +
                        PVConstants.padMacKeysBytesPerDirection,
                length: PVConstants.padTagMaskBytesPerDirection
            )
        case .aeadNonce:
            return PVPadRange(
                offset: dirStart +
                        PVConstants.padCipherBytesPerDirection +
                        PVConstants.padMacKeysBytesPerDirection +
                        PVConstants.padTagMaskBytesPerDirection,
                length: PVConstants.padAeadNonceBytesPerDirection
            )
        case .lookupKeys:
            return PVPadRange(
                offset: dirStart +
                        PVConstants.padCipherBytesPerDirection +
                        PVConstants.padMacKeysBytesPerDirection +
                        PVConstants.padTagMaskBytesPerDirection +
                        PVConstants.padAeadNonceBytesPerDirection,
                length: PVConstants.padLookupKeysBytesPerDirection
            )
        }
    }

    /// Total size of one fully-provisioned pad on disk, in bytes.
    /// = 64 B header + 2 × per-direction bundle.
    static var totalPadSize: Int {
        let oneDirection =
            PVConstants.padCipherBytesPerDirection +
            PVConstants.padMacKeysBytesPerDirection +
            PVConstants.padTagMaskBytesPerDirection +
            PVConstants.padAeadNonceBytesPerDirection +
            PVConstants.padLookupKeysBytesPerDirection
        return 64 + 2 * oneDirection
    }
}

// MARK: - Cursor (mutable per-direction state)

/// Tracks where the encryptor has spent pad bytes for a given pad
/// AND direction. Held SEPARATELY from `PVPad` so:
///   • The pad-bytes can be marked immutable / locked into Secure
///     Enclave-wrapped storage and never need to be re-saved when
///     the cursor advances.
///   • Cursor corruption (e.g. a crash mid-encrypt) can't damage
///     the underlying pad material.
///
/// Persisted by `PVPadStore` separately, with a per-direction
/// counter + replay bitmap (for receive side).
struct PVPadCursor: Codable, Sendable {

    /// Pad this cursor belongs to. Mismatched pad_id ⇒ refuse to load.
    let padId: Data

    /// Which direction this cursor tracks.
    let direction: PVDirection

    /// Next message counter to allocate. Incremented after each
    /// successful encrypt; persisted before the envelope is handed
    /// to the transport layer so a crash mid-send doesn't reuse a
    /// pad strip.
    var nextCounter: UInt32

    /// Highest counter seen so far in this direction (receive
    /// side). Pairs with `replayBitmap` to enforce out-of-order
    /// acceptance within `PVConstants.replayWindowSize`.
    var lastSeenCounter: UInt32

    /// Sliding bitmap of recently-seen counters in this direction
    /// (receive side). One bit per slot, 16 k slots = 2 KiB
    /// (matches `PVConstants.replayWindowSize`).
    var replayBitmap: Data

    /// Has the pad been declared exhausted for this direction?
    /// Set once `nextCounter` reaches `counterEndOfLife` or the
    /// pad runs out of bytes for any required range. Encrypt
    /// fast-fails with `.padExhausted` thereafter.
    var exhausted: Bool

    /// Bytes consumed from this direction's cipher-pad range so
    /// far. Tracked separately from `nextCounter` because
    /// per-message content length varies. Persisted with the
    /// rest of the cursor in `PVPadStore`.
    ///
    /// Stored as `UInt32` since one direction's cipher range is
    /// bounded by `padCipherBytesPerDirection` ≪ 2³².
    var cipherBytesConsumed: UInt32

    /// Initialise a fresh cursor for a newly-provisioned pad.
    static func freshCursor(padId: Data,
                            direction: PVDirection) -> PVPadCursor {
        let bitmapBytes = PVConstants.replayWindowSize / 8
        return PVPadCursor(
            padId: padId,
            direction: direction,
            nextCounter: 0,
            lastSeenCounter: 0,
            replayBitmap: Data(repeating: 0x00, count: bitmapBytes),
            exhausted: false,
            cipherBytesConsumed: 0
        )
    }

    // MARK: - Encryption-side helpers

    /// Reserve the next counter for an encrypt, returning the
    /// counter to use. Advances `nextCounter` atomically (from the
    /// caller's PoV — the actor that owns the cursor serialises
    /// access). If the pad is exhausted, throws.
    mutating func allocateNextCounter() throws -> UInt32 {
        guard !exhausted else {
            throw PVError.padExhausted(direction: direction)
        }
        guard nextCounter < PVConstants.perDirectionMessageBudget,
              nextCounter < PVConstants.counterEndOfLife else {
            exhausted = true
            throw PVError.padExhausted(direction: direction)
        }
        let allocated = nextCounter
        nextCounter &+= 1
        return allocated
    }

    // MARK: - Receive-side helpers

    /// Check a received counter against the sliding window and
    /// either accept (mark seen + advance) or reject.
    /// Pure function on the bitmap; no I/O.
    mutating func acceptCounter(_ received: UInt32) throws {
        // Hard ceiling — EOL was reached by the peer.
        guard received < PVConstants.counterEndOfLife else {
            throw PVError.replayJumpTooLarge(received: received, lastSeen: lastSeenCounter)
        }

        // Within-window or new-high?
        if received > lastSeenCounter {
            let jump = UInt64(received) - UInt64(lastSeenCounter)
            // Reject impossibly-large jumps (Patch 6 — bounded skip).
            guard jump <= UInt64(SecurityConstants.Replay.acceptableJumpAhead) else {
                throw PVError.replayJumpTooLarge(received: received, lastSeen: lastSeenCounter)
            }
            // Shift bitmap left by `jump` bits.
            shiftBitmapLeft(by: Int(jump))
            // Mark the new tail bit (position 0).
            setBitmapBit(0)
            lastSeenCounter = received
        } else {
            // received <= lastSeenCounter — in-window?
            let delta = Int(lastSeenCounter - received)
            guard delta < PVConstants.replayWindowSize else {
                throw PVError.replayBelowWindow(
                    received: received,
                    windowFloor: UInt32(max(0, Int64(lastSeenCounter) - Int64(PVConstants.replayWindowSize - 1)))
                )
            }
            if getBitmapBit(delta) {
                throw PVError.replayDuplicate(received: received)
            }
            setBitmapBit(delta)
        }
    }

    // MARK: - Private bitmap ops

    /// Shift the bitmap left by `n` bits. Higher-position bits (older
    /// messages) fall off the top; position 0 (newest) opens up for the
    /// caller to set.
    private mutating func shiftBitmapLeft(by n: Int) {
        let totalBits = replayBitmap.count * 8
        guard n > 0 else { return }
        if n >= totalBits {
            // Whole window scrolled past — zero everything.
            for i in 0..<replayBitmap.count { replayBitmap[i] = 0 }
            return
        }
        let byteShift = n / 8
        let bitShift  = n % 8
        var working = [UInt8](repeating: 0, count: replayBitmap.count)
        // We treat bitmap[0] as the LSB end (newest = position 0).
        for i in 0..<replayBitmap.count {
            let src = i + byteShift
            if src < replayBitmap.count {
                working[i] = replayBitmap[src] >> bitShift
                if bitShift != 0, src + 1 < replayBitmap.count {
                    working[i] |= replayBitmap[src + 1] << (8 - bitShift)
                }
            }
        }
        replayBitmap = Data(working)
    }

    /// Read the bit at `position` (0 = newest / last-seen).
    private func getBitmapBit(_ position: Int) -> Bool {
        let byteIdx = position / 8
        let bitIdx = position % 8
        guard byteIdx < replayBitmap.count else { return false }
        return (replayBitmap[byteIdx] & (1 << bitIdx)) != 0
    }

    /// Set the bit at `position`.
    private mutating func setBitmapBit(_ position: Int) {
        let byteIdx = position / 8
        let bitIdx = position % 8
        guard byteIdx < replayBitmap.count else { return }
        replayBitmap[byteIdx] |= UInt8(1 << bitIdx)
    }
}
