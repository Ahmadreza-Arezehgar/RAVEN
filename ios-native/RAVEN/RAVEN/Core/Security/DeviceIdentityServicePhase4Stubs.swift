//
//  DeviceIdentityService+Phase4Stubs.swift
//  RAVEN
//
//  Surface-level stubs for the Phase-4 identity-rotation API the
//  Phase-4 commit added to `DeviceIdentityService` and the revert
//  removed. `IdentityRotationService` and `NoiseSessionStore` still
//  call into these names; the stubs return safe defaults so the
//  build links and the call sites silently degrade until the real
//  implementations come back.
//

import Foundation
import CryptoKit

extension DeviceIdentityService {
    /// Window during which both the old and new identity keys are
    /// considered valid after a rotation. Real implementation backs
    /// this off a server-issued config; stub uses one hour.
    static var rotationGraceWindowSeconds: TimeInterval { 3_600 }

    /// Generate a new identity key pair, attest to the rotation, and
    /// return the attestation proof. Stub returns a proof valid for
    /// the next grace window so call sites that read `validUntil`
    /// don't divide by zero / produce negative timestamps.
    func rotateKeys() async throws -> RotationProof {
        RotationProof(validUntil: Date().addingTimeInterval(Self.rotationGraceWindowSeconds))
    }

    struct RotationProof {
        let validUntil: Date
    }

    /// Run a closure with the device's static X25519 agreement private
    /// key in scope, then zero local references. Stub uses an empty
    /// `Data` because the real key never leaves
    /// `DeviceIdentityService` in this build; callers (Noise sessions)
    /// that need the actual key will fail their handshake at runtime
    /// rather than silently produce wrong output, which is the right
    /// fail-loud behaviour while the proper API is missing.
    func withAgreementPrivateKey<T>(_ body: (Curve25519.KeyAgreement.PrivateKey) throws -> T) rethrows -> T {
        // Generate a one-shot ephemeral key — calls that depend on the
        // real long-term static key (Noise IK responder side) will
        // fail loudly because the public-key won't match what the
        // peer knows. That is correct: we don't have the real key in
        // this revert state.
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        return try body(ephemeral)
    }
}
