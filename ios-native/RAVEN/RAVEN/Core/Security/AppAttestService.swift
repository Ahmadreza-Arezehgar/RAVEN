//
//  AppAttestService.swift
//  RAVEN
//
//  🔴 v1.8 (2026-05-21) — feature #3: App Attest device enrolment.
//
//  Wraps Apple's DeviceCheck `DCAppAttestService`. Once per install,
//  after the user is signed in, this:
//    1. generates a hardware-backed key in the Secure Enclave,
//    2. fetches a one-time challenge from the server,
//    3. attests the key over SHA-256(challenge),
//    4. ships the attestation to POST /api/attest/enroll.
//
//  The server verifies the attestation chains to Apple's App Attest
//  Root CA — proving the request came from a genuine, unmodified
//  RAVEN build on real Apple hardware (the private key never leaves
//  the Secure Enclave). The enrolled key later lets requests be
//  proven genuine via App Attest assertions (a follow-up).
//
//  This is a SILENT, best-effort background hardening. It:
//    • no-ops on the Simulator / unsupported hardware (`isSupported`),
//    • no-ops once enrolled,
//    • never blocks the UI and never surfaces an error to the user,
//    • is purely additive — the mesh relay, the bridge and non-iOS
//      clients are untouched, and a device that never enrols keeps
//      working exactly as before.

import Foundation
import DeviceCheck
import CryptoKit

@MainActor
final class AppAttestService {

    static let shared = AppAttestService()
    private init() {}

    private let service = DCAppAttestService.shared
    private let keyIdKey = "raven.appattest.keyId"
    private let enrolledKey = "raven.appattest.enrolled"
    private var isRunning = false

    /// True on a real device that supports App Attest (false on the
    /// Simulator and on pre-A-series hardware).
    var isSupported: Bool { service.isSupported }

    /// True once this device has successfully enrolled its key.
    var isEnrolled: Bool { UserDefaults.standard.bool(forKey: enrolledKey) }

    // MARK: - Enrolment

    /// Run App Attest enrolment once, in the background, if this device
    /// supports it and hasn't enrolled yet. Idempotent and safe to call
    /// on every launch and on every login — it no-ops when already
    /// done, unsupported, or already in flight.
    func enrolIfNeeded() {
        guard service.isSupported else { return }   // Simulator / unsupported
        guard !isEnrolled else { return }
        guard !isRunning else { return }
        isRunning = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isRunning = false }
            // Only attempt while authenticated — the attest endpoints
            // require a session. Otherwise just retry next launch.
            guard await KeychainService.shared.getToken() != nil else { return }
            do {
                try await self.performEnrolment()
                UserDefaults.standard.set(true, forKey: self.enrolledKey)
                #if DEBUG
                print("✅ [AppAttest] device enrolled")
                #endif
            } catch {
                #if DEBUG
                print("⚠️ [AppAttest] enrolment failed (will retry): \(error)")
                #endif
            }
        }
    }

    private func performEnrolment() async throws {
        // 1. Reuse a stored key id, or mint a fresh hardware key.
        let keyId = try await currentOrNewKeyId()

        // 2. One-time server challenge.
        let challenge = try await NetworkService.shared.attestChallenge()
        guard let challengeData = Data(base64Encoded: challenge.challenge) else {
            throw AppAttestError.malformedChallenge
        }

        // 3. Attest the key over SHA-256(challenge).
        let clientDataHash = Data(SHA256.hash(data: challengeData))
        let attestation: Data
        do {
            attestation = try await attestKey(keyId, clientDataHash: clientDataHash)
        } catch {
            // The stored key may be stale (e.g. after a device restore).
            // Drop it so the next attempt mints a fresh one.
            UserDefaults.standard.removeObject(forKey: keyIdKey)
            throw error
        }

        // 4. Ship the attestation to the server for verification.
        let result = try await NetworkService.shared.attestEnroll(
            keyId: keyId,
            attestation: attestation.base64EncodedString(),
            challenge: challenge.challenge)
        guard result.enrolled else { throw AppAttestError.serverRejected }
    }

    // MARK: - Key management

    private func currentOrNewKeyId() async throws -> String {
        if let stored = UserDefaults.standard.string(forKey: keyIdKey),
           !stored.isEmpty {
            return stored
        }
        let keyId = try await generateKey()
        UserDefaults.standard.set(keyId, forKey: keyIdKey)
        return keyId
    }

    // MARK: - DCAppAttestService bridging (callback → async)

    private func generateKey() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            service.generateKey { keyId, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let keyId {
                    cont.resume(returning: keyId)
                } else {
                    cont.resume(throwing: AppAttestError.noKeyId)
                }
            }
        }
    }

    private func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            service.attestKey(keyId, clientDataHash: clientDataHash) { attestation, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let attestation {
                    cont.resume(returning: attestation)
                } else {
                    cont.resume(throwing: AppAttestError.noAttestation)
                }
            }
        }
    }
}

enum AppAttestError: Error {
    case malformedChallenge
    case noKeyId
    case noAttestation
    case serverRejected
}
