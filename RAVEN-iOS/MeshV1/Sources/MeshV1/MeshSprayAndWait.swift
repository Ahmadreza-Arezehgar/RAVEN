// `MESH_PROTOCOL.md` §E — Binary Spray-and-Wait routing decisions.
//
// Sender starts with `sprayCounter = L` (5 free / 50 RAVEN+). On forward,
// each peer gets `floor(spray / 2)` tokens, sender keeps the rest. When
// counter reaches 1, the message enters the "wait" phase — only direct
// recipient (or trusted friend device) gets it.
import Foundation

public enum SprayAndWait {

    public struct ForwardDecision: Equatable {
        public let tokensToGive: Int
        public let tokensRemaining: Int
        public let inWaitPhase: Bool
    }

    public static func split(currentTokens: Int) -> ForwardDecision {
        let safe = min(max(currentTokens, 0), MeshConstants.sprayProtocolMax)
        if safe <= MeshConstants.sprayWaitThreshold {
            // Wait phase: only direct recipient / trusted friend gets a copy.
            return ForwardDecision(tokensToGive: safe, tokensRemaining: 0, inWaitPhase: true)
        }
        let give = max(1, safe / 2)
        let keep = safe - give
        return ForwardDecision(tokensToGive: give, tokensRemaining: keep, inWaitPhase: false)
    }

    /// Per-peer probabilistic gossip from §E (excludes direct-recipient case).
    public static func gossipProbability(peerCount: Int) -> Double {
        if peerCount <= 0 { return 0.0 }
        if peerCount <= 2 { return 1.0 }
        return min(1.0, max(0.25, 3.0 / Double(peerCount + 1)))
    }

    /// Stable forward-decision per (messageId, deviceFingerprint).
    public static func shouldForwardByGossip(messageId: String,
                                             deviceFingerprint: String,
                                             peerCount: Int) -> Bool {
        let p = gossipProbability(peerCount: peerCount)
        if p >= 1.0 { return true }
        if p <= 0.0 { return false }
        // Mirror Kotlin String.hashCode for parity.
        let bucket = Double(stableHash(messageId + deviceFingerprint) % 1000) / 1000.0
        return bucket < p
    }

    /// Java/Kotlin String.hashCode equivalent. UInt32 wraparound, then keep
    /// non-negative modulus 1000.
    static func stableHash(_ s: String) -> UInt {
        var h: Int32 = 0
        for scalar in s.unicodeScalars {
            h = h &* 31 &+ Int32(scalar.value & 0xFFFF)
        }
        return UInt(UInt32(bitPattern: h))
    }
}
