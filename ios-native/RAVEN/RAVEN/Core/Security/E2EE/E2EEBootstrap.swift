//
//  E2EEBootstrap.swift
//  RAVEN
//
//  One-shot setup that runs early in the app lifecycle. Responsible for:
//   1. Wiring the network-backed bundle provider into E2EEService.
//   2. Publishing our public bundle on first launch (or rotation).
//   3. Topping up the server-side one-time pre-key pool.
//
//  Idempotent — safe to call on every cold start. The expensive paths
//  (key generation + REST) gate themselves on UserDefaults markers
//  and remote pool counts.
//
//  Call site (in RAVENApp.swift on .task or after auth lands):
//      Task.detached { await E2EEBootstrap.shared.runIfNeeded() }
//

import Foundation
import os

fileprivate let logger = Logger(subsystem: "app.raven.ios", category: "Security.E2EEBootstrap")

actor E2EEBootstrap {
    static let shared = E2EEBootstrap()

    // MARK: - Persistence keys

    private enum Defaults {
        static let didPublishInitialBundle = "raven.e2ee.boot.publishedInitialBundle"
        static let lastTopUpEpoch          = "raven.e2ee.boot.lastTopUpEpoch"
    }

    /// Don't hit the OPK top-up endpoint more than once per hour.
    private let topUpInterval: TimeInterval = 60 * 60

    // MARK: - Public entry point

    /// Run the bootstrap — safe to call repeatedly. Logs but doesn't
    /// throw, because failing E2EE setup must not crash the app.
    /// Other code checks `E2EEMessageGateway.isEnabled` before
    /// relying on E2EE being available.
    func runIfNeeded() async {
        // 1. Always wire the provider — cheap, no network.
        await E2EEService.shared.configure(bundleProvider: E2EENetworkProvider.shared)

        // 1b. Wire the auto-revoke side-effect: any time a peer's
        //     identity key changes, drop their "Verified" flag so
        //     the user is forced to re-verify out-of-band.
        PeerVerificationStore.startAutoRevokeOnIdentityChange()

        // 2. The remaining steps need an authenticated user + device id.
        guard
            let userId = await KeychainService.shared.getUserId(),
            let deviceId = DeviceIdentityService.shared.fingerprint
        else {
            logger.debug("No user/device yet — deferring publish")
            return
        }

        await publishInitialBundleIfNeeded(userId: userId, deviceId: deviceId)
        await topUpOneTimePreKeysIfStale(userId: userId, deviceId: deviceId)
    }

    /// Drop the local "we've published" flag — used when the user
    /// rotates their identity, switches accounts, or we explicitly
    /// want to force a fresh publish on next bootstrap.
    func resetForNextLaunch() {
        UserDefaults.standard.removeObject(forKey: Defaults.didPublishInitialBundle)
        UserDefaults.standard.removeObject(forKey: Defaults.lastTopUpEpoch)
    }

    // MARK: - Internal steps

    private func publishInitialBundleIfNeeded(userId: String, deviceId: String) async {
        let alreadyPublished = UserDefaults.standard.bool(forKey: Defaults.didPublishInitialBundle)
        guard !alreadyPublished else { return }

        do {
            try await E2EENetworkProvider.shared.uploadOurBundle(
                userId: userId,
                deviceId: deviceId
            )
            UserDefaults.standard.set(true, forKey: Defaults.didPublishInitialBundle)
            logger.debug("Initial bundle published for \(userId, privacy: .private)")
        } catch {
            logger.debug("Bundle publish failed: \(error.localizedDescription, privacy: .public)")
            // Leave the flag unset so we retry on next launch.
        }
    }

    private func topUpOneTimePreKeysIfStale(userId: String, deviceId: String) async {
        let lastTopUp = UserDefaults.standard.double(forKey: Defaults.lastTopUpEpoch)
        let now = Date().timeIntervalSince1970
        guard now - lastTopUp > topUpInterval else { return }

        do {
            try await E2EENetworkProvider.shared.topUpOneTimePreKeys(
                userId: userId,
                deviceId: deviceId,
                target: 50
            )
            UserDefaults.standard.set(now, forKey: Defaults.lastTopUpEpoch)
            logger.debug("One-time pre-keys topped up")
        } catch {
            logger.debug("OPK top-up failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
