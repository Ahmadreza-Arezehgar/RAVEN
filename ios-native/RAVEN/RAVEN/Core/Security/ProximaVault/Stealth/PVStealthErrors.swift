//
//  PVStealthErrors.swift
//  RAVEN — PROXIMA-VAULT Stealth
//

import Foundation

enum PVStealthError: Error, Equatable {

    /// Not a PV-Stealth envelope (magic bytes do not match).
    /// Caller should fall through to non-stealth processing.
    case notAStealthEnvelope

    /// Envelope size mismatch (truncation or corruption).
    case sizeMismatch(expected: Int, got: Int)

    /// Unrecognised version byte.
    case unsupportedVersion(found: UInt8)

    /// Header passed magic + version but the declared ciphertext
    /// length is inconsistent with the buffer.
    case malformedHeader

    /// Receiver-side: no matching pad found within the counter
    /// window. Either the envelope is addressed to another pad,
    /// or the sender ran more than `counterWindowSize` messages
    /// ahead of the receiver's last-seen counter.
    case noMatchingPad

    /// MAC verification failed after a matching pad was found.
    /// Tampered ciphertext or wrong direction.
    case authFailed

    /// Internal: a primitive caller passed the wrong size.
    case internalInputError(reason: String)
}
