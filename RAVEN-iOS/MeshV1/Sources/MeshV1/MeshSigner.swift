// One-stop sign + verify for every mesh frame kind. Layers `MeshCanonicalizers`
// over CryptoKit's `Curve25519.Signing`.
//
// Both `sign` and `verify` are deterministic — Ed25519 has no nonce — so they
// exercise the same byte path as `shared-vectors/v1/canonicalization/` and
// `shared-vectors/v1/crypto/ed25519_*.json`.
import CryptoKit
import Foundation

public enum MeshSigner {

    public static func signDm(_ env: SecureMeshEnvelope, privateKey: Data) throws -> Data {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        return try key.signature(for: DmSigningCanonicalizer.bytes(env))
    }

    public static func verifyDm(_ env: SecureMeshEnvelope, signature: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: DmSigningCanonicalizer.bytes(env))
    }

    public static func signPost(_ post: MeshPostEnvelope, privateKey: Data) throws -> Data {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        return try key.signature(for: PostSigningCanonicalizer.bytes(post))
    }

    public static func verifyPost(_ post: MeshPostEnvelope, signature: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: PostSigningCanonicalizer.bytes(post))
    }

    public static func signAck(_ ack: MeshACKEnvelope, privateKey: Data) throws -> Data {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        return try key.signature(for: AckSigningCanonicalizer.bytes(ack))
    }

    public static func verifyAck(_ ack: MeshACKEnvelope, signature: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: AckSigningCanonicalizer.bytes(ack))
    }

    public static func signStop(_ stop: StopCommand, privateKey: Data) throws -> Data {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        return try key.signature(for: StopSigningCanonicalizer.bytes(stop))
    }

    public static func verifyStop(_ stop: StopCommand, signature: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: StopSigningCanonicalizer.bytes(stop))
    }

    public static func signFrame(rawFrame: [String: Any], privateKey: Data) throws -> Data {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        return try key.signature(for: FrameJsonCanonicalizer.bytes(rawFrame: rawFrame))
    }

    public static func verifyFrame(rawFrame: [String: Any], signature: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              let bytes = try? FrameJsonCanonicalizer.bytes(rawFrame: rawFrame) else { return false }
        return key.isValidSignature(signature, for: bytes)
    }
}
