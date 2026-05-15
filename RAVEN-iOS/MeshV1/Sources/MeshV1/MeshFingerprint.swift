// `MESH_PROTOCOL.md` §D — Fingerprint format.
//
//   fingerprint = SHA-256(ed25519_public_key)[0..6] as uppercase hex,
//                 grouped XXXX-XXXX-XXXX.
//
// Used by every layer that needs a stable per-device identifier visible to
// the user (pairing codes, friend-device lookup, advertised BLE name).
import CryptoKit
import Foundation

public enum Fingerprint {
    public static func fromEd25519PublicKey(_ edPublicKey: Data) -> String {
        let digest = SHA256.hash(data: edPublicKey)
        let prefix = digest.prefix(6)
        let hex = prefix.map { String(format: "%02X", $0) }.joined()
        let a = hex.prefix(4)
        let b = hex.dropFirst(4).prefix(4)
        let c = hex.dropFirst(8).prefix(4)
        return "\(a)-\(b)-\(c)"
    }
}
