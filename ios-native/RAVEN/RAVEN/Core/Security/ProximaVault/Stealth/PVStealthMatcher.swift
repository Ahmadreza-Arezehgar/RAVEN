//
//  PVStealthMatcher.swift
//  RAVEN — PROXIMA-VAULT Stealth
//
//  Receiver-side: given an inbound stealth envelope plus the set
//  of locally-active pads, decide which (if any) pad the envelope
//  was addressed to.
//
//  For each active pad's directional sub-key K_lookup^{dir}, scan
//  the counter window
//
//      [cursor.lastSeenCounter + 1 ... + counterWindowSize]
//
//  computing `expected_tag = HMAC(K_lookup^{dir}, label || nonce
//  || counter)` and comparing against the envelope's `lookup_tag`
//  in constant time. First match wins.
//
//  Cost: O(active_pads × counterWindowSize) HMACs per inbound
//  envelope. At 20 pads × 32 window × ~3 µs HMAC ≈ 1.92 ms on A17.
//  See PDF §22 cost table.
//
//  Performance note: in production, callers SHOULD cache
//  `directionalKey(parent, .forward)` and
//  `directionalKey(parent, .reverse)` per pair to avoid the HKDF
//  call inside the inner loop. The reference matcher here does
//  not cache so the API stays self-contained.
//

import Foundation

/// One "active pad" entry as the matcher sees it. Caller is
/// expected to load this from the pad store.
struct PVStealthActivePad: Sendable {

    /// Local identifier for the pad — typically the pad's `pad_id`
    /// (the same 16-byte value the legacy PV-Standard envelope
    /// would have carried in plaintext). NOT placed on the wire
    /// here; only used for the matcher to surface "this is the
    /// match" to the caller.
    let padId: Data

    /// Parent K_lookup sub-key from `ATSAMKeyTree.pvStealthLookupKey`.
    /// 32 bytes.
    let kLookupParent: Data

    /// Receiver-side cursor for this pad in BOTH directions. The
    /// matcher uses `forward.lastSeenCounter` if the envelope
    /// claims direction = .forward, and `reverse.lastSeenCounter`
    /// otherwise.
    let forwardCursor: PVPadCursor
    let reverseCursor: PVPadCursor
}

/// Outcome of a matcher scan.
struct PVStealthMatch: Sendable, Equatable {
    /// The pad that produced the matching tag.
    let padId: Data
    /// The counter value that produced the match. The caller will
    /// use this to consume the right per-message K_wc / mask / cipher
    /// strips when decrypting.
    let matchedCounter: UInt32
    /// Direction the envelope was sent in (mirrors envelope.direction).
    let direction: PVDirection
    /// Echo of the envelope for downstream decryption.
    let envelope: PVStealthEnvelope
}

enum PVStealthMatcher {

    /// Try to find a matching pad + counter for `envelope`.
    /// Returns the first match in the configured counter window.
    /// `nil` means "addressed elsewhere" — the COMMON case for
    /// most envelopes a relay or local listener sees.
    ///
    /// Bounded cost. Constant-time tag compare.
    static func match(envelope: PVStealthEnvelope,
                      activePads: [PVStealthActivePad]) throws -> PVStealthMatch? {
        for pad in activePads {
            // Pick the cursor that matches the envelope's claimed
            // direction. Both ends of a pair share the SAME K_lookup
            // parent, so the directional key derivation is
            // symmetric — we just point at the right cursor for
            // counter-window scanning.
            let cursor: PVPadCursor
            switch envelope.direction {
            case .forward: cursor = pad.forwardCursor
            case .reverse: cursor = pad.reverseCursor
            }

            // Derive K_lookup^{dir} once per pad (cache opportunity
            // for callers that hold this struct across calls).
            let kDir = try PVStealthLookupTag.directionalKey(
                parentKey: pad.kLookupParent,
                direction: envelope.direction
            )

            // Scan counter window forward from lastSeenCounter + 1
            // (or 0 if the cursor is fresh). We also try
            // `lastSeenCounter` itself as a 33rd test slot in case
            // the same envelope is being re-presented for replay
            // detection on the layer above us.
            let start = cursor.lastSeenCounter
            let end = start &+ UInt32(PVStealthConstants.counterWindowSize)
            for c in start...end {
                let expected = try PVStealthLookupTag.compute(
                    directionalKey: kDir,
                    lookupNonce: envelope.lookupNonce,
                    counter: c
                )
                if PVStealthLookupTag.tagsEqual(expected, envelope.lookupTag) {
                    return PVStealthMatch(
                        padId: pad.padId,
                        matchedCounter: c,
                        direction: envelope.direction,
                        envelope: envelope
                    )
                }
            }
        }
        return nil
    }
}
