//
//  GatewayBeaconPinStore.swift
//  RAVEN
//
//  🔴 ROUND 26 (2026-05-16) — hacker-audit MESH-MED-7.
//
//  TOFU pin-set for gateway beacon signer keys. On the first signed
//  beacon we ever see from a given `gatewayDeviceId`, we record
//  (deviceId → signerPubKey). Every subsequent beacon claiming the
//  same deviceId must use the same signer key, or it's rejected as
//  an impersonation attempt.
//
//  The reason TOFU here (rather than a server-attested directory):
//  gateways are mesh-only; the offline neighbour who's reading the
//  beacon may have no internet at all, so we can't go ask a server
//  "is this the real signer key for that deviceId?". TOFU is the
//  best we can do until the gateway tier has its own server-side
//  attestation flow (tracked separately).
//
//  Persistence: in-memory only. A process restart drops the pin set
//  and the next beacon re-pins from scratch. That window is short
//  (gateway beacons are 30s-cadence) and an attacker would need to
//  win every race for the first signed beacon since process start
//  to plant a forged pin. The risk-tier is the same as our existing
//  TOFU paths in `FriendDeviceRepository`.

import Foundation

actor GatewayBeaconPinStore {
    static let shared = GatewayBeaconPinStore()

    /// gatewayDeviceId → Ed25519 signer public key bytes.
    private var pins: [String: Data] = [:]

    private init() {}

    /// Either accept this signer key (matches the existing pin or
    /// establishes a new one) or reject (signer changed).
    /// - Returns: true on accept, false on reject.
    nonisolated func acceptOrPin(gatewayDeviceId: String, signerPublicKey: Data) -> Bool {
        // Hop to actor isolation via an unstructured task — callers
        // are already in BLE callback context, this stays fast.
        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        Task {
            ok = await self._acceptOrPin(
                gatewayDeviceId: gatewayDeviceId,
                signerPublicKey: signerPublicKey
            )
            semaphore.signal()
        }
        // Small bounded wait — actor calls are microseconds in practice.
        // Worst case the BLE callback yields for a few µs.
        _ = semaphore.wait(timeout: .now() + .milliseconds(50))
        return ok
    }

    /// Check whether we have ANY pin for this gatewayDeviceId.
    /// Used to refuse downgrade to an unsigned beacon after we've
    /// seen a signed one.
    nonisolated func hasPinned(gatewayDeviceId: String) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var hit = false
        Task {
            hit = await self._hasPinned(gatewayDeviceId: gatewayDeviceId)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + .milliseconds(50))
        return hit
    }

    /// Drop the pin set — used on sign-out and on debug self-test.
    func reset() { pins.removeAll() }

    // MARK: - Actor-isolated implementations

    private func _acceptOrPin(gatewayDeviceId: String, signerPublicKey: Data) -> Bool {
        if let existing = pins[gatewayDeviceId] {
            return existing == signerPublicKey
        }
        pins[gatewayDeviceId] = signerPublicKey
        return true
    }

    private func _hasPinned(gatewayDeviceId: String) -> Bool {
        return pins[gatewayDeviceId] != nil
    }
}
