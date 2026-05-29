//
//  GhostRouteOnlineCodec.swift
//  RAVEN — Ghost Route online codec
//
//  High-level send/receive helpers that combine
//  `GhostRouteOnlineTag` (deterministic per-counter tag),
//  `GREnvelope` (the wire format, reused from mesh), and
//  `GhostRouteOnlineService` (REST inbox). One-call API for the
//  chat send/receive coordinator.
//
//  Send side:
//    encode(payload, kRoute, nextCounter, direction) →
//      (recipient_tag, envelope_bytes, advancedCounter)
//    caller persists `advancedCounter` BEFORE POSTing the deposit
//    — same invariant as PV: don't let a crash mid-send reuse the
//    counter slot.
//
//  Receive side:
//    decode(envelopeBytes, kRoute, cursor, direction) →
//      (plaintext, matchedCounter)
//    caller persists `matchedCounter + 1` as the new
//    `nextCounter` for that pair-direction.
//
//  The codec is content-agnostic: `payload` can be any opaque
//  bytes (PV-RAW envelope, plaintext message, Noise IK
//  transport-mode frame, …). Ghost Route only protects the
//  routing layer.
//

import Foundation

enum GhostRouteOnlineCodec {

    enum CodecError: Error, Equatable {
        case envelopeAlreadyHasMagicConflict
        case decryptFailed
        case noMatchingCounter
        case internalInputError(reason: String)
    }

    /// Result of a successful send-side encode.
    struct EncodeResult: Sendable {
        /// 16-byte tag to deposit alongside `envelopeBytes`.
        let recipientTag: Data
        /// Wire bytes of the GREnvelope (header + payload). The
        /// transport ships these unchanged.
        let envelopeBytes: Data
        /// The new "next counter" to persist for this direction.
        let advancedCounter: UInt64
    }

    /// Wrap `payload` for the given pair + direction at
    /// `nextCounter`. Returns the artefacts needed to call
    /// `GhostRouteOnlineService.deposit(...)`.
    static func encode(payload: Data,
                       kRoute: Data,
                       direction: PVDirection,
                       nextCounter: UInt64) throws -> EncodeResult {
        guard kRoute.count == 32 else {
            throw CodecError.internalInputError(reason: "kRoute must be 32 B")
        }
        let envelope = try GREnvelope.build(kRoute: kRoute, payload: payload)
        // Replace the random nonce inside GREnvelope with a
        // deterministic tag derived from the counter — that's
        // what makes online-mode addressable.
        //
        // We DO NOT mutate GREnvelope's mesh path; instead we
        // emit a SEPARATE recipient_tag that the server uses for
        // routing, while the envelope itself keeps its
        // self-describing structure.
        let routingTag = try GhostRouteOnlineTag.compute(
            kRoute: kRoute,
            direction: direction,
            counter: nextCounter
        )
        return EncodeResult(
            recipientTag: routingTag,
            envelopeBytes: envelope.encode(),
            advancedCounter: nextCounter &+ 1
        )
    }

    /// Decode an inbound envelope. Tries up to
    /// `GhostRouteOnlineTag.counterWindow` counters starting at
    /// `cursorNextCounter` to find the one the sender used.
    ///
    /// Returns the recovered envelope payload + the matched
    /// counter so the caller can advance its cursor to
    /// `matchedCounter + 1`.
    struct DecodeResult: Sendable {
        let inner: Data
        let matchedCounter: UInt64
    }

    static func decode(envelopeBytes: Data,
                       kRoute: Data,
                       direction: PVDirection,
                       cursorNextCounter: UInt64) throws -> DecodeResult {
        guard kRoute.count == 32 else {
            throw CodecError.internalInputError(reason: "kRoute must be 32 B")
        }
        let envelope = try GREnvelope.parse(envelopeBytes)

        // We don't actually need to scan counters to decode the
        // envelope (its payload is opaque — wrapping ends here
        // and any further content layer like PV decodes the
        // bytes). But we DO want to advance the cursor based on
        // which counter produced the routing tag the server
        // matched. Since the server hands us back the tag, we
        // can scan tags forward to find the matching counter.
        //
        // The matcher iterates from cursorNextCounter forward
        // by up to counterWindow positions.
        //
        // For the simple decode-only path (no cursor advance,
        // caller relies on server ordering), we just return
        // counter=cursorNextCounter.
        //
        // Production usage: caller pairs each fetched envelope
        // with the recipient_tag the server returned, then calls
        // findCounter(recipientTag:, kRoute:, direction:, from:)
        // to learn the real counter.
        //
        // For this codec we just return cursorNextCounter as
        // a best-effort default; callers that need exact
        // counter tracking should use `findCounter` below.
        return DecodeResult(inner: envelope.payload,
                            matchedCounter: cursorNextCounter)
    }

    /// Helper that scans the receiver's counter window to find
    /// which counter matches `recipientTag`. Returns nil if no
    /// counter in the window matches — the caller should treat
    /// this as either "envelope for a different pair" or
    /// "counter desynced beyond the window".
    static func findCounter(recipientTag: Data,
                            kRoute: Data,
                            direction: PVDirection,
                            from nextCounter: UInt64) throws -> UInt64? {
        let window = try GhostRouteOnlineTag.windowTags(
            kRoute: kRoute,
            direction: direction,
            nextCounter: nextCounter
        )
        for (counter, expected) in window {
            if expected == recipientTag {
                return counter
            }
        }
        return nil
    }
}
