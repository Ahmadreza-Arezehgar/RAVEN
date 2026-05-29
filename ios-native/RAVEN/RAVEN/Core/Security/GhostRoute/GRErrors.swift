//
//  GRErrors.swift
//  RAVEN — Ghost Route
//

import Foundation

enum GRError: Error, Equatable {

    /// Not a Ghost Route envelope (magic bytes do not match).
    /// Caller should fall through to non-GR processing.
    case notAGREnvelope

    /// Envelope size is wrong (truncation or corruption).
    case sizeMismatch(expected: Int, got: Int)

    /// Unrecognised version byte. Receiver MUST refuse — never
    /// guess across versions.
    case unsupportedVersion(found: UInt8)

    /// Envelope passed magic + version checks but the declared
    /// payload length is inconsistent with the buffer.
    case malformedHeader

    /// `match(...)` found no pairing whose computed
    /// recipient_tag equals the on-wire value. Either this
    /// envelope is for someone else, or the sender used a
    /// stale pair.
    case noMatchingPairing

    /// Internal: a primitive caller passed the wrong size.
    case internalInputError(reason: String)
}
