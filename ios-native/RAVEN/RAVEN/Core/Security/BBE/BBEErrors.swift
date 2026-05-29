//
//  BBEErrors.swift
//  RAVEN — BBE
//
//  Typed errors for the BBE pipeline. Each case is distinct so
//  UI / telemetry can act on specific failure modes rather than a
//  generic "beacon broken".
//

import Foundation

enum BBEError: Error, Equatable {

    // MARK: - Wire-format

    /// Not a BBE beacon (magic bytes don't match). Caller should
    /// fall through to non-BBE processing.
    case notABeacon

    /// Beacon size mismatch. Either truncation or corruption.
    case sizeMismatch(expected: Int, got: Int)

    /// Beacon version is unrecognised. Receiver MUST refuse —
    /// never guess.
    case unsupportedVersion(found: UInt8)

    // MARK: - Epoch / clock

    /// Beacon epoch is outside the acceptable skew window
    /// `[t_now - clockSkewWindowPast, t_now + clockSkewWindowFuture]`.
    /// Surfaces clock-skew or replay attempts more than 10 min old.
    case epochOutOfWindow(beacon: UInt32, local: UInt32)

    /// Local clock is not NTP-synced AND no recent peer
    /// transcript-bound timestamp is available. Per ATSAM §3,
    /// BBE MUST be disabled in this state.
    case clockNotSynchronised

    // MARK: - Ratchet / catch-up

    /// The catch-up cache for this pairing doesn't contain any
    /// state old enough to match the observed epoch. The pair
    /// either fell out of touch for > `catchUpMax` epochs or
    /// re-paired with different keys; surface a re-pair prompt.
    case catchUpExceeded(observedEpoch: UInt32, oldestCached: UInt32)

    // MARK: - Detect

    /// Detect was called but no active pairings are loaded; the
    /// caller should refresh the pairing set before retrying.
    case noActivePairings

    // MARK: - Internal

    /// Length precondition violated by a primitive caller. Indicates
    /// a programmer bug — fail-fast.
    case internalInputError(reason: String)
}
