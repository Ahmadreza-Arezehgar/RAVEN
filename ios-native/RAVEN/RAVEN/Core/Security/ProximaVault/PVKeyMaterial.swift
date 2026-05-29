//
//  PVKeyMaterial.swift
//  RAVEN — PROXIMA-VAULT
//
//  Slices a `PVPad` into per-message key material. This file is the
//  one place where pad-byte ↔ purpose mapping happens — keep all
//  byte arithmetic here so a future audit can verify "every key
//  comes from a distinct, non-overlapping pad slice" by reading
//  one file.
//
//  Each message consumes a small, fixed-size strip from each of:
//
//    • macKeys  — 16 B   → universal-hash key K_wc for this message
//    • tagMask  — 16 B   → XOR mask applied to GHASH output → tag
//    • aeadNonce — 12 B  → AES-GCM-SIV nonce (only `.aesGcmSIV` mode)
//    • cipherPad — N B   → keystream for the ciphertext body (only
//                          `.infoTheoretic` mode)
//
//  Strips are addressed by `(direction, counter)`. Strips never
//  overlap: strip `i` for direction d sits at
//      `range.offset + i * stripSize`.
//
//  ⚠️  Direction separation (Patch 5/9): A→B strips draw from the
//      `forward` block; B→A strips draw from `reverse`. So the
//      same counter on opposite sides yields different K_wc / mask
//      / nonce — an attacker who learns A→B keys gains nothing
//      about B→A traffic.
//

import Foundation

enum PVKeyMaterial {

    // MARK: - Strip sizes (mirrors PVConstants)

    /// Universal-hash key length per message (one strip). 16 B.
    static let macKeyStrip: Int = PVConstants.universalHashKeyBytes  // 16

    /// Tag-mask XOR strip per message. 16 B (matches `macTagBytes`).
    static let tagMaskStrip: Int = PVConstants.macTagBytes  // 16

    /// AEAD nonce strip per message. 12 B.
    static let aeadNonceStrip: Int = PVConstants.aeadNonceBytes  // 12

    // MARK: - Per-message key extraction

    /// Fetch the Wegman-Carter universal-hash key for the given
    /// (direction, counter) tuple. NEVER reused — the receiver
    /// must consume the same strip exactly once before the bitmap
    /// marks the counter as seen.
    static func universalHashKey(pad: PVPad,
                                 direction: PVDirection,
                                 counter: UInt32) throws -> Data {
        let range = pad.range(for: .macKeys, direction: direction)
        let stripOffset = range.offset + Int(counter) * macKeyStrip
        guard stripOffset + macKeyStrip <= range.offset + range.length else {
            throw PVError.padExhausted(direction: direction)
        }
        return try pad.read(offset: stripOffset, length: macKeyStrip)
    }

    /// Fetch the 16-byte tag mask for the given counter. XORed onto
    /// the raw GHASH output to produce the on-wire tag.
    static func tagMask(pad: PVPad,
                        direction: PVDirection,
                        counter: UInt32) throws -> Data {
        let range = pad.range(for: .tagMask, direction: direction)
        let stripOffset = range.offset + Int(counter) * tagMaskStrip
        guard stripOffset + tagMaskStrip <= range.offset + range.length else {
            throw PVError.padExhausted(direction: direction)
        }
        return try pad.read(offset: stripOffset, length: tagMaskStrip)
    }

    /// Fetch the 12-byte AES-GCM-SIV nonce strip. Only used in
    /// `.aesGcmSIV` mode; `.infoTheoretic` mode skips this call but
    /// the strip space still EXISTS in the pad so future mode
    /// switches don't require re-provision (cursor accounting is
    /// mode-independent).
    static func aeadNonce(pad: PVPad,
                          direction: PVDirection,
                          counter: UInt32) throws -> Data {
        let range = pad.range(for: .aeadNonce, direction: direction)
        let stripOffset = range.offset + Int(counter) * aeadNonceStrip
        guard stripOffset + aeadNonceStrip <= range.offset + range.length else {
            throw PVError.padExhausted(direction: direction)
        }
        return try pad.read(offset: stripOffset, length: aeadNonceStrip)
    }

    /// Fetch a contiguous slice of the cipher keystream starting at
    /// `cipherOffset` for `length` bytes. In `.infoTheoretic` mode
    /// the encryptor allocates this slice as plaintext-XOR keystream.
    /// Layout: messages consume cipherPad sequentially in
    /// COUNTER order — message i starts where message i-1 ended.
    /// That offset is tracked by the cursor (`PVPadCursor.cipherOffsetForCounter`).
    static func cipherKeystream(pad: PVPad,
                                direction: PVDirection,
                                cipherOffset: Int,
                                length: Int) throws -> Data {
        let range = pad.range(for: .cipher, direction: direction)
        guard cipherOffset >= 0,
              length > 0,
              cipherOffset + length <= range.length else {
            throw PVError.padExhausted(direction: direction)
        }
        return try pad.read(offset: range.offset + cipherOffset, length: length)
    }

    // MARK: - Pseudonyms (stable per pad, per direction)

    /// Returns the pad-local pseudonym that should appear in the
    /// envelope header for the given direction. Both ends derive
    /// this from the SAME pad-header bytes so the receiver can
    /// match envelopes to the correct cursor.
    ///
    /// v3.1.2 limitation: stable for the pad's lifetime ⇒ enables
    /// metadata correlation (this is the Issue 10 / Patch 10
    /// finding). v3.2 PV-Stealth replaces this with a rotating
    /// `lookup_tag`.
    static func pseudonym(pad: PVPad,
                          direction: PVDirection) -> Data {
        switch direction {
        case .forward: return pad.pseudonymForward
        case .reverse: return pad.pseudonymReverse
        }
    }
}

// MARK: - Cipher-pad allocation

extension PVKeyMaterial {

    /// Reserve `length` bytes of cipher-pad keystream for an
    /// outbound message, given the current cursor state. Returns
    /// the keystream bytes AND the new cursor.
    ///
    /// Caller must persist the returned cursor BEFORE handing the
    /// envelope to the transport layer; otherwise a crash mid-send
    /// risks the next message reusing the same pad slice on
    /// retry (catastrophic for OTP).
    static func reserveCipherKeystream(pad: PVPad,
                                       cursor: PVPadCursor,
                                       length: Int) throws -> (keystream: Data,
                                                               updatedCursor: PVPadCursor) {
        let range = pad.range(for: .cipher, direction: cursor.direction)
        let startOffset = Int(cursor.cipherBytesConsumed)
        guard startOffset + length <= range.length else {
            var c = cursor
            c.exhausted = true
            throw PVError.padExhausted(direction: cursor.direction)
        }
        let keystream = try pad.read(offset: range.offset + startOffset, length: length)
        var updated = cursor
        // Overflow-safe: bounded by range.length ≤ 2^32 by design
        updated.cipherBytesConsumed = UInt32(startOffset + length)
        return (keystream, updated)
    }
}
