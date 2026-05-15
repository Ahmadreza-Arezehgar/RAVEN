// `MESH_PROTOCOL.md` §F — 6-digit out-of-band pairing code.
//
//   code = SHA-256( min(pub1,pub2) || max(pub1,pub2) || nonce ).first(4 bytes BE) mod 1_000_000
//
// Pubkeys sorted lexicographically by their base64 representation, so both
// sides arrive at the same code deterministically.
import CryptoKit
import Foundation

public enum PairingCode {

    /// Pubkeys are base64 strings; sort order is lexicographic on the string
    /// itself. Implementations MUST NOT decode to bytes for the sort.
    public static func derive(pub1B64: String, pub2B64: String, nonce: Data) -> Int {
        let sorted = [pub1B64, pub2B64].sorted()
        var input = Data()
        input.append(Data(sorted[0].utf8))
        input.append(Data(sorted[1].utf8))
        input.append(nonce)
        let hash = SHA256.hash(data: input)
        // First 4 bytes BIG-endian → UInt32 → mod 1_000_000.
        let first4 = hash.prefix(4)
        var bytes = [UInt8](repeating: 0, count: 4)
        for (i, b) in first4.enumerated() { bytes[i] = b }
        let n = (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
        return Int(n % 1_000_000)
    }

    public static func format(_ code: Int) -> String { String(format: "%06d", code) }
}
