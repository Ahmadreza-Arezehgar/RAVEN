//
//  PVErrors.swift
//  RAVEN — PROXIMA-VAULT
//
//  Typed errors for the PV encrypt / decrypt pipeline. Distinct
//  cases so UI / telemetry can render specific copy ("pad
//  exhausted — re-provision" vs "envelope tampered — drop") instead
//  of a generic "decrypt failed".
//

import Foundation

enum PVError: Error, Equatable {
    // MARK: - Pad-lifecycle errors

    /// Pad has consumed its budget for this direction. UI should
    /// surface "re-provision this pad with the peer" and refuse
    /// any further sends in this direction until that happens.
    /// Counter is at or past `PVConstants.counterEndOfLife`
    /// (Patch 4).
    case padExhausted(direction: PVDirection)

    /// Pad was not found by the supplied `padId`. Receiver fails
    /// closed — does not attempt to decrypt with any other pad
    /// (that would be a stealth-lookup, which is v3.2 PV-Stealth
    /// territory).
    case padNotFound(padId: Data)

    /// Caller asked to encrypt before the pad was fully imported,
    /// or the pad blob on disk is shorter than `padCipherBytes`
    /// (storage corruption or interrupted import).
    case padIncomplete

    // MARK: - Envelope-format errors

    /// Bytes don't begin with the PV magic (`PVConstants.envelopeMagic`).
    /// Not a PV envelope at all — caller should fall through to
    /// non-PV processing.
    case notAPVEnvelope

    /// Magic matched but the version byte is unrecognised. Refuses
    /// to guess — receiver could be running an older build.
    case unsupportedFormatVersion(found: UInt8)

    /// Envelope shorter than the minimum legal header + tag length.
    /// Truncation attack or transport corruption.
    case envelopeTruncated

    /// Envelope has a recognised mode byte but the rest of the
    /// header doesn't match that mode's expected layout. (e.g.
    /// `.aesGcmSIV` envelope missing its AEAD nonce slot.)
    case envelopeMalformed

    // MARK: - Counter / replay errors

    /// Received counter is below the replay window — duplicate or
    /// long-delayed re-emission. Receiver MUST drop.
    case replayBelowWindow(received: UInt32, windowFloor: UInt32)

    /// Received counter is already marked in the bitmap as seen.
    /// Same as `replayBelowWindow` but within the active window.
    case replayDuplicate(received: UInt32)

    /// Received counter is more than `acceptableJumpAhead` slots
    /// ahead of `lastSeen`. Possible attacker buffering hugely many
    /// envelopes to retransmit later. Receiver drops.
    case replayJumpTooLarge(received: UInt32, lastSeen: UInt32)

    // MARK: - Auth / decrypt errors

    /// Wegman-Carter tag mismatch. Either tampered ciphertext or
    /// wrong pad-direction. NEVER surfaces ciphertext to the UI.
    case authFailed

    /// AES-GCM-SIV chunk decrypt failed (only in `.aesGcmSIV` mode).
    case aeadDecryptFailed

    /// Mode bit in header doesn't match the AAD-bound mode used
    /// to compute the tag. Patch 1 downgrade-attack defence kicked in.
    case modeMismatch

    /// The requested wire-format mode is reserved but not yet
    /// implemented in this build (e.g. `.aesGcmSIV` in v1.0 —
    /// we ship the info-theoretic mode first and add AES-CTR
    /// support once iOS exposes the lower-level API needed to
    /// split ciphertext from AES's built-in tag).
    case modeNotAvailable(mode: PVConstants.Mode)
}

// MARK: - Direction enum

/// Which end of the pad-pair is sending. Drawn once at pad-provision
/// time by comparing the two device pseudonyms (lexicographic order).
/// Encoded in the wire envelope's `direction` byte. Decoupling from
/// real-pubkey ordering keeps it metadata-neutral (Patch 8).
enum PVDirection: UInt8, Codable, Hashable, Sendable {
    /// "Forward" — the device that owns the lexicographically smaller
    /// pad-local pseudonym is the sender.
    case forward = 0x01
    /// "Reverse" — the other direction.
    case reverse = 0x02

    /// Flip the direction. Receiver of an inbound `.forward` envelope
    /// uses the opposite ranges when it later replies.
    var inverse: PVDirection {
        switch self {
        case .forward: return .reverse
        case .reverse: return .forward
        }
    }
}
