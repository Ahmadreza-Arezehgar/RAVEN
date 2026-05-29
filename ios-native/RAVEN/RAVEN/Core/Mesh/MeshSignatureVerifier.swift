//
//  MeshSignatureVerifier.swift
//  RAVEN
//
//  Shared Ed25519 signature verification for incoming mesh messages.
//  All feature handlers (Club, Echo, Vault) should call verify()
//  before processing any payload.
//

import Foundation

// MARK: - Mesh Signature Verifier

enum MeshSignatureVerifier {
    
    /// Verify that a MeshMessageFrame has a valid Ed25519 signature.
    ///
    /// The signature covers a canonical form of the frame: same JSON object
    /// with the `s` and `spk` keys removed, re-serialized with sorted keys.
    /// Senders use `canonicalSigningData(from:)` to produce the bytes they sign,
    /// and verifiers reproduce those same bytes here before calling Ed25519 verify.
    ///
    /// - Parameters:
    ///   - data: The raw Data that was received (full JSON frame, including s/spk)
    ///   - signature: Base64-encoded Ed25519 signature from the frame
    ///   - signerPublicKey: Base64-encoded public key from the frame
    /// - Returns: `true` if signature is valid, `false` otherwise
    static func verify(data: Data, signature: String?, signerPublicKey: String?) -> Bool {
        // If no signature present, reject (fail-closed)
        guard let sigB64 = signature,
              let pkB64 = signerPublicKey,
              let sigData = Data(base64Encoded: sigB64),
              let pkData = Data(base64Encoded: pkB64) else {
            #if DEBUG
            print("⚠️ [MeshVerify] Missing signature or public key — rejecting")
            #endif
            return false
        }

        guard let canonical = canonicalSigningData(from: data) else {
            #if DEBUG
            print("⚠️ [MeshVerify] Failed to build canonical form — rejecting")
            #endif
            return false
        }

        let valid = DeviceIdentityService.shared.verify(
            signature: sigData,
            data: canonical,
            publicKey: pkData
        )

        #if DEBUG
        if !valid {
            print("⚠️ [MeshVerify] Invalid signature — spoofed message rejected")
        }
        #endif

        return valid
    }

    /// Extract signature fields from raw JSON data without full decode.
    /// Returns (signature, signerPublicKey) or nil if not present.
    static func extractSignatureFields(from data: Data) -> (signature: String?, signerPublicKey: String?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        return (json["s"] as? String, json["spk"] as? String)
    }

    /// Build the canonical bytes that the sender signed and the receiver verifies.
    /// Strips `s` and `spk` from the JSON object and re-serializes with sorted keys
    /// so both ends produce identical bytes regardless of native dict ordering.
    static func canonicalSigningData(from data: Data) -> Data? {
        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        json.removeValue(forKey: "s")
        json.removeValue(forKey: "spk")
        return try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }
}
