//
//  GhostRouteOnlineTag.swift
//  RAVEN — Ghost Route online tag derivation
//
//  Online Ghost Route uses a slightly different tag construction
//  from the mesh path. In the mesh case, the recipient_tag is
//  derived from the per-message random nonce that travels with
//  the envelope — relays just forward and ignore. The receiver
//  recomputes the tag when it inspects the envelope.
//
//  Online traffic cannot work that way. The server stores
//  envelopes keyed by tag, and the receiver must compute its
//  expected tags WITHOUT first downloading every envelope. The
//  per-message random nonce is unknown to the receiver until
//  fetch time, so it cannot serve as the lookup key.
//
//  Solution: tags are deterministic in the per-pair counter.
//
//      recipient_tag_i = Trunc_128(HMAC(
//          K_route_pair,
//          "ATSAM/v1/GhostRoute/online" || direction || uint64_be(counter_i)
//      ))
//
//  Both ends derive `K_route_pair` from the same ATSAM key tree.
//  The sender increments its monotonic counter per message; the
//  receiver tries the next N counters per pair when polling. With
//  N = 32, a one-hour outage tolerates 32 messages without re-sync.
//
//  Privacy property
//  ────────────────
//  Without K_route_pair, the server sees a set of 128-bit random
//  strings. It cannot link two tags to the same pair, cannot
//  identify the sender, and cannot identify the receiver beyond
//  "this client polled these tags".
//

import Foundation
import CryptoKit

enum GhostRouteOnlineTag {

    /// Domain string fed into HMAC. Defeats cross-protocol
    /// confusion between online and mesh Ghost Route paths.
    static let domain: Data = Data("ATSAM/v1/GhostRoute/online".utf8)

    /// Counter window the receiver will try when polling. Tradeoff
    /// between fetch cost (O(active_pairs × window)) and offline
    /// tolerance. 32 is generous; production may tune down.
    static let counterWindow: Int = 32

    /// Compute the deterministic tag for (kRoute, direction,
    /// counter).
    static func compute(kRoute: Data,
                        direction: PVDirection,
                        counter: UInt64) throws -> Data {
        guard kRoute.count == 32 else {
            throw GRError.internalInputError(reason: "kRoute must be 32 B")
        }
        var input = Data(capacity: domain.count + 1 + 8)
        input.append(domain)
        input.append(direction.rawValue)
        // Big-endian uint64.
        for i in 0..<8 {
            input.append(UInt8((counter >> ((7 - i) * 8)) & 0xFF))
        }
        let mac = HMAC<SHA256>.authenticationCode(
            for: input,
            using: SymmetricKey(data: kRoute)
        )
        return Data(mac).prefix(GRConstants.recipientTagBytes)
    }

    /// Build the window of tags a receiver should poll for a
    /// single pair-direction. Returns `counterWindow` tags
    /// starting at `nextCounter`.
    static func windowTags(kRoute: Data,
                           direction: PVDirection,
                           nextCounter: UInt64) throws -> [(counter: UInt64, tag: Data)] {
        var out: [(UInt64, Data)] = []
        out.reserveCapacity(counterWindow)
        for offset in 0..<UInt64(counterWindow) {
            let c = nextCounter &+ offset
            out.append((c, try compute(kRoute: kRoute,
                                       direction: direction,
                                       counter: c)))
        }
        return out
    }
}
