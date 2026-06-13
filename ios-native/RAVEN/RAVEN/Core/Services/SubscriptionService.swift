//
//  SubscriptionService.swift
//  RAVEN
//
//  MESSENGER PIVOT (2026-06): RAVEN+ subscription removed.
//  Every feature is free for everyone, so this is now a no-op stub:
//  `isPremium` is hardcoded `true` and all former RevenueCat calls do nothing.
//  The RevenueCat SDK dependency has been removed from the Xcode project.
//
//  The public API surface (shared, isPremium, configure, login, logout,
//  setServerPremiumStatus, refreshPremiumStatus) is intentionally preserved so
//  existing callers (AuthService, RAVENApp) compile unchanged.
//

import Foundation

// MARK: - SubscriptionService (no-op stub)

@MainActor @Observable
final class SubscriptionService: NSObject {
    nonisolated static let shared = SubscriptionService()

    /// Subscription removed — everyone is premium, for free, forever.
    nonisolated var isPremium: Bool { true }

    private nonisolated override init() {
        super.init()
    }

    // MARK: - Lifecycle / identity (no-ops kept for call-site compatibility)

    /// Was: RevenueCat configuration. Now a no-op.
    func configure() {
        #if DEBUG
        print("💎 [SubscriptionService] Subscriptions removed — all features are free.")
        #endif
    }

    /// Was: associate RevenueCat identity on login. Now a no-op.
    func login(appUserID: String) async {}

    /// Was: clear RevenueCat identity on logout. Now a no-op.
    func logout() async {}

    /// Was: mirror server-granted premium. Now a no-op (everyone is premium).
    func setServerPremiumStatus(_ isPremiumFromServer: Bool) {}

    /// Was: re-validate entitlement with RevenueCat. Now a no-op.
    func refreshPremiumStatus() async {}
}

// MARK: - Notification

extension Notification.Name {
    /// Kept for any observers; never posted now that premium status is constant.
    static let premiumStatusDidChange = Notification.Name("premiumStatusDidChange")
}
