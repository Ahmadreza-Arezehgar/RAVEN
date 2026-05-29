//
//  MeshGhostRouteAdapter.swift
//  RAVEN — Ghost Route × existing mesh transport
//
//  Thin adapter that wraps an existing transport payload in a
//  Ghost Route envelope when ATSAM's routing layer is enabled,
//  and unwraps it on the receive side. The adapter is the *only*
//  place where Ghost Route touches transport-adjacent data flow.
//  It is gated behind a runtime feature flag and is purely
//  callable — no existing transport code path is changed by the
//  mere existence of this file.
//
//  Integration model (deliberately conservative):
//
//   • Sender side: BEFORE handing an opaque payload `P` to the
//     existing mesh transport, the caller may invoke
//     `MeshGhostRouteAdapter.wrap(payload: P, kRoute: ...)` to
//     get back `GREnvelope.encode()` bytes. The transport then
//     ships those bytes as it would any payload. The transport
//     does NOT know whether the payload is Ghost-Routed.
//
//   • Receiver side: AFTER pulling an inbound payload `P` off the
//     wire, the caller may invoke
//     `MeshGhostRouteAdapter.peekAndUnwrap(payload: P, active:)`
//     to attempt a Ghost Route match. If the payload does not
//     begin with the GR magic bytes, the helper returns
//     `.notGhostRouted` and the caller continues with normal
//     processing. If it does match a known pair, the helper
//     returns the inner payload + the matched pair-id.
//
//  This pattern is the same one we use for PROXIMA-VAULT: a
//  content-layer primitive whose wire blob is opaque to the
//  transport layer. By construction, enabling or disabling the
//  feature flag cannot change the bytes that flow through
//  `BLEMeshEngine` / `MeshGatewayService` for non-GR payloads.
//
//  No file inside `Core/Mesh/` is modified by adding this adapter.
//  Production wiring (i.e. calling `wrap(...)` before mesh emit
//  and `peekAndUnwrap(...)` after mesh receive) is a separate
//  bounded patch in the chat send/receive coordinator, gated on
//  `FeatureFlag.atsam` AND a per-conversation opt-in.
//

import Foundation

/// Runtime feature-flag gate. Centralised so future call sites
/// agree on the policy ("Ghost Route is allowed when ATSAM master
/// flag is on") without scattering the check.
enum MeshGhostRouteAdapter {

    /// Whether the adapter is allowed to perform wrap / unwrap
    /// for new traffic. Reads the existing feature-flag system;
    /// flipping this in Debug settings does NOT retroactively
    /// affect already-shipped envelopes.
    static var isEnabled: Bool {
        FeatureFlag.isATSAMEnabled
    }

    // MARK: - Send side

    /// Wrap an opaque payload in a Ghost Route envelope for the
    /// peer identified by `kRoute` (the per-pair routing key
    /// derived from `ATSAMKeyTree.ghostRouteKey`).
    ///
    /// Returns the wire bytes that should be handed to the
    /// transport layer. The transport sees an opaque blob with a
    /// `GR1!` magic prefix; it does not need to know anything
    /// about Ghost Route to deliver it.
    ///
    /// Throws if `kRoute` is the wrong size or if CSPRNG fails.
    static func wrap(payload: Data, kRoute: Data) throws -> Data {
        let envelope = try GREnvelope.build(kRoute: kRoute, payload: payload)
        return envelope.encode()
    }

    // MARK: - Receive side

    /// Result of a receive-side adapter call.
    enum UnwrapResult {
        /// The bytes do not look like a Ghost Route envelope.
        /// Caller continues with the normal processing path
        /// (this is the COMMON case for any transport that
        /// happens to be carrying non-GR traffic).
        case notGhostRouted

        /// The bytes are a Ghost Route envelope but no active
        /// pair matched the recipient tag. Either the envelope
        /// is for a different recipient, or our active-pair set
        /// is stale.
        case unmatched

        /// Successful match. Caller hands `inner` to the existing
        /// chat layer as if it had been received directly, plus
        /// uses `pairingId` to associate with the right peer.
        case matched(pairingId: Data, inner: Data)

        /// Parser-level failure (truncated bytes, unsupported
        /// version, malformed header). Caller MUST NOT continue
        /// processing this payload.
        case malformed(Error)
    }

    /// Peek at incoming `payload` and attempt to identify it as
    /// Ghost-Routed. Pure, no I/O.
    ///
    /// Performance: O(active_pairs × 1) HMAC operations on a hit
    /// (each pair computes one expected tag and constant-time
    /// compares it). Misses short-circuit on the magic bytes.
    static func peekAndUnwrap(payload: Data,
                              activePairs: [GRMatcher.ActivePair]) -> UnwrapResult {
        // Cheap pre-check: most transport payloads are NOT
        // Ghost-Routed. Don't allocate a parser for them.
        guard GREnvelope.looksLikeEnvelope(payload) else {
            return .notGhostRouted
        }

        let envelope: GREnvelope
        do {
            envelope = try GREnvelope.parse(payload)
        } catch let error as GRError where error == .notAGREnvelope {
            return .notGhostRouted
        } catch {
            return .malformed(error)
        }

        do {
            if let match = try GRMatcher.match(envelope: envelope, activePairs: activePairs) {
                return .matched(pairingId: match.pairingId, inner: envelope.payload)
            } else {
                return .unmatched
            }
        } catch {
            return .malformed(error)
        }
    }
}
