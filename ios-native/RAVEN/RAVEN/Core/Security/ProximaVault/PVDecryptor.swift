//
//  PVDecryptor.swift
//  RAVEN — PROXIMA-VAULT
//
//  Decrypt entry point. Inverse of `PVEncryptor.encrypt`.
//
//  Caller responsibilities:
//    1. Detect that a payload is a PV envelope via
//       `PVEnvelope.hasPVMagic(_:)` BEFORE allocating any decrypt
//       state. If it's not PV, fall through to normal processing.
//    2. Load the matching pad (by `padId`) + receive-side cursor.
//    3. Call `decrypt(...)`.
//    4. Persist the updated cursor (bitmap advance + lastSeen
//       counter) so replays of the same counter are rejected on
//       the next call.
//    5. Hand `plaintext` to the chat UI / handler.
//

import Foundation
// CryptoKit not imported in v1.0 — info-theoretic path uses pure
// XOR + GHASH, no AEAD primitives. Reintroduce when `.aesGcmSIV`
// mode lands.

enum PVDecryptor {

    /// Decrypt a parsed `envelope`. Receiver's `cursor` MUST be for
    /// the direction the envelope claims (e.g. an envelope marked
    /// `.forward` is decoded with a `.forward` cursor at the
    /// receiver side because that's the direction the SENDER used
    /// to fill the pad).
    ///
    /// Returns the recovered plaintext on success. Throws on:
    ///   • Pad mismatch (wrong padId).
    ///   • Replay (counter already seen, below window, etc.)
    ///   • Auth failure (tag mismatch — tampered ciphertext or
    ///     wrong pad direction).
    ///   • Pad exhaustion (counter past EOL or runs off the strip).
    static func decrypt(envelope: PVEnvelope,
                        pad: PVPad,
                        cursor: PVPadCursor) throws -> (plaintext: Data,
                                                        updatedCursor: PVPadCursor) {

        // 1. Pad-id match check (constant time).
        guard PVPad.padIdsMatch(envelope.padId, pad.padId) else {
            throw PVError.padNotFound(padId: envelope.padId)
        }

        // 2. Replay check. We DON'T mark the counter as seen yet —
        //    we wait until after MAC verification so an unauthenticated
        //    attacker can't poison the bitmap.
        var working = cursor
        // Read-only check pass first.
        try working.acceptCounter(envelope.counter)
        // (`acceptCounter` mutates `working`; if MAC verification
        // fails below we'll discard `working` and return the
        // original. The caller therefore won't persist the poisoned
        // cursor.)

        // 3. Pull per-message key material from the pad.
        let kWc  = try PVKeyMaterial.universalHashKey(pad: pad,
                                                     direction: envelope.direction,
                                                     counter: envelope.counter)
        let mask = try PVKeyMaterial.tagMask(pad: pad,
                                            direction: envelope.direction,
                                            counter: envelope.counter)

        // 4. Reconstruct the AAD blob exactly as the sender did
        //    (envelope minus its 16-byte tag).
        let aad = envelope.aadBytes()

        // 5. Verify the Wegman-Carter tag in constant time.
        guard PVWegmanCarter.verify(message: aad,
                                    key: kWc,
                                    mask: mask,
                                    receivedTag: envelope.tag) else {
            // CRITICAL: do NOT persist `working`. Discard the
            // tentative cursor advance so a replay-after-MAC-failure
            // doesn't trick us into thinking the counter has been
            // consumed.
            throw PVError.authFailed
        }

        // 6. MAC succeeded — recover plaintext.
        let plaintext: Data
        switch envelope.mode {
        case .infoTheoretic:
            // Pull cipher-pad keystream from the offset the sender
            // declared. Verify it's within bounds.
            let keystream = try PVKeyMaterial.cipherKeystream(
                pad: pad,
                direction: envelope.direction,
                cipherOffset: Int(envelope.cipherOffset),
                length: envelope.ciphertext.count
            )
            plaintext = PVWegmanCarter.xor(envelope.ciphertext, keystream)

        case .aesGcmSIV:
            // v1.0 doesn't decode AES-GCM-SIV mode envelopes (see
            // `PVEncryptor` for the matching reason). The MAC check
            // would have passed for a v2 sender, but we lack the
            // primitives to undo the cipher. Surface the limitation
            // rather than silently dropping.
            throw PVError.modeNotAvailable(mode: .aesGcmSIV)
        }

        // 7. Replay-bitmap and counter advance are kept from `working`.
        return (plaintext, working)
    }
}
