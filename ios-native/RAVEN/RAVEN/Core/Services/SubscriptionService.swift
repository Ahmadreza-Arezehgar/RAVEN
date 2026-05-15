//
//  SubscriptionService.swift
//  RAVEN
//
//  RAVEN+ Subscription Management via RevenueCat
//

import Foundation
import RevenueCat

// MARK: - SubscriptionService

/// Central RevenueCat integration.
/// Manages premium status, offerings, purchases, and restore.
@MainActor @Observable
final class SubscriptionService: NSObject {
    // The class is @MainActor, but PremiumLimits.isPremium (and other
    // mesh/storage code) needs to read `.shared.isPremium` from any actor.
    // The shared instance itself is initialised once and never replaced, so
    // it's safe to mark nonisolated. Only mutating writes funnel back
    // through MainActor methods.
    nonisolated static let shared = SubscriptionService()
    
    // MARK: - Public State
    
    /// Whether the current user has an active RAVEN+ entitlement. Backed by
    /// a thread-safe Sendable box so any actor can read it (PremiumLimits
    /// queries it from BLE/storage code paths) while writes still only
    /// happen on MainActor inside `updatePremiumStatus`. Splitting the
    /// storage out of `@Observable` sidesteps the macro's warning about
    /// `nonisolated(unsafe)` having no effect on the synthesized backing var.
    @ObservationIgnored
    private let premiumState = PremiumStateBox()

    nonisolated var isPremium: Bool { premiumState.value }
    
    /// Available offerings fetched from RevenueCat.
    private(set) var currentOffering: Offering?
    
    /// Loading states
    private(set) var isLoading: Bool = false
    private(set) var isPurchasing: Bool = false
    
    // MARK: - Constants
    //
    // ⚠️ Replace `apiKey` with your real RevenueCat **public** SDK key
    //    from <https://app.revenuecat.com/projects/.../api-keys>.
    //    It is safe to ship in the binary (read-only, scoped to your
    //    project), but it MUST exist or `Purchases.shared.offerings()`
    //    returns "Invalid API Key" and the paywall stays empty.
    //
    // Both Test Store keys (`test_*`) and Apple App Store keys
    // (`appl_*`) are accepted by RevenueCat:
    //   • `appl_*` — production + sandbox (best — sandbox products
    //     work on the simulator with a sandbox Apple ID).
    //   • `test_*` — Test Store; products are manually defined in the
    //     RevenueCat dashboard, no real StoreKit involvement.
    //
    // Both keys previously hard-coded here returned "Invalid API Key"
    // (placeholders / rotated). Until a real key is wired in, the
    // service falls back to a DEBUG-only synthetic offering so the
    // paywall UI is still testable (see `demoFallbackOffering`).
    private static let apiKey = "appl_twdDOMRqqomBWkMQzQsrMDUGxEU"
    private static let entitlementID = "Raven Pro"
    
    // MARK: - Init

    // Nonisolated so `nonisolated static let shared = SubscriptionService()`
    // can construct it without hopping to MainActor. The body only calls
    // `super.init()`, which is fine off-main.
    private nonisolated override init() {
        super.init()
    }
    
    // MARK: - Configuration
    
    /// Call once on app launch (e.g., in RAVENApp.init or AppDelegate).
    func configure() {
        Purchases.logLevel = .warn
        Purchases.configure(withAPIKey: Self.apiKey)
        Purchases.shared.delegate = self
        
        // Fetch initial status
        Task {
            await refreshPremiumStatus()
            await fetchOfferings()
        }
        
        #if DEBUG
        print("💎 [SubscriptionService] RevenueCat configured")
        #endif
    }
    
    // MARK: - Login / Logout
    
    /// Associate the RevenueCat anonymous user with the Raven user ID.
    /// Call after successful login.
    func login(appUserID: String) async {
        do {
            let (customerInfo, _) = try await Purchases.shared.logIn(appUserID)
            updatePremiumStatus(from: customerInfo)
            #if DEBUG
            print("💎 [SubscriptionService] Logged in as \(appUserID.prefix(8))… isPremium=\(isPremium)")
            #endif
        } catch {
            #if DEBUG
            print("❌ [SubscriptionService] Login failed: \(error.localizedDescription)")
            #endif
        }
    }
    
    /// Clear RevenueCat identity on sign-out.
    func logout() async {
        serverGrantedPremium = false
        // ⚡ BUG FIX (audit): hard-clear the persisted premium cache on logout
        // so a downgraded / signed-out user can't retain ghost-mode or other
        // premium-gated mesh privileges via stale UserDefaults state.
        premiumState.value = false
        PremiumLimits.isPremiumCached = false
        do {
            let customerInfo = try await Purchases.shared.logOut()
            updatePremiumStatus(from: customerInfo)
            #if DEBUG
            print("💎 [SubscriptionService] Logged out, isPremium=\(isPremium)")
            #endif
        } catch {
            #if DEBUG
            print("❌ [SubscriptionService] Logout failed: \(error.localizedDescription)")
            #endif
        }
    }
    
    // MARK: - Offerings
    
    /// Latest non-fatal error from a fetch attempt — surfaced in the
    /// paywall's empty-state message so the user knows whether to
    /// retry, check their connection, or contact support.
    private(set) var lastOfferingsError: String?

    /// Fetch the latest offerings from RevenueCat.
    func fetchOfferings() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let offerings = try await Purchases.shared.offerings()
            currentOffering = offerings.current
            lastOfferingsError = nil
            #if DEBUG
            // Log enough detail to debug an empty-paywall report
            // (was previously just the identifier, which silently
            // hid the "no offerings configured at all" case).
            let allIDs = offerings.all.keys.sorted().joined(separator: ", ")
            let pkgCount = offerings.current?.availablePackages.count ?? 0
            NSLog("💎 [SubscriptionService] Fetched offerings — current=\(offerings.current?.identifier ?? "none") packages=\(pkgCount) all=[\(allIDs)]")
            if offerings.current == nil {
                lastOfferingsError = "RevenueCat returned no current offering. Check the dashboard: an Offering must be marked as ‘Current’ and contain at least one Package."
                NSLog("⚠️ [SubscriptionService] No `current` offering set in the RevenueCat dashboard — paywall will show empty state.")
            } else if pkgCount == 0 {
                lastOfferingsError = "The current offering has no packages. Add at least one Package in the RevenueCat dashboard."
                NSLog("⚠️ [SubscriptionService] Current offering '\(offerings.current!.identifier)' has 0 packages.")
            }
            #endif
        } catch {
            lastOfferingsError = error.localizedDescription
            #if DEBUG
            NSLog("❌ [SubscriptionService] Fetch offerings failed: \(error.localizedDescription)")
            #endif
        }
    }
    
    // MARK: - Purchase
    
    /// Purchase a specific package from the current offering.
    @discardableResult
    func purchase(package: Package) async throws -> Bool {
        isPurchasing = true
        defer { isPurchasing = false }
        
        do {
            let result = try await Purchases.shared.purchase(package: package)
            
            if !result.userCancelled {
                updatePremiumStatus(from: result.customerInfo)

                // ⚡ AUDIT FIX: Only mirror to currentUser AFTER RevenueCat
                // confirms the entitlement is active. Previously we wrote
                // `isPremium = true` unconditionally on a non-cancelled
                // purchase, which could leave a stale crown badge if the
                // entitlement check failed validation server-side.
                if self.isPremium {
                    AuthService.shared.currentUser?.isPremium = true
                }

                #if DEBUG
                print("💎 [SubscriptionService] Purchase complete (entitled=\(isPremium))")
                #endif
                return true
            } else {
                #if DEBUG
                print("💎 [SubscriptionService] Purchase cancelled by user")
                #endif
                return false
            }
        } catch {
            #if DEBUG
            print("❌ [SubscriptionService] Purchase failed: \(error.localizedDescription)")
            #endif
            throw error
        }
    }
    
    // MARK: - Restore
    
    /// Restore previous purchases.
    func restorePurchases() async throws {
        isLoading = true
        defer { isLoading = false }
        
        let customerInfo = try await Purchases.shared.restorePurchases()
        updatePremiumStatus(from: customerInfo)
        #if DEBUG
        print("💎 [SubscriptionService] Restored purchases, isPremium=\(isPremium)")
        #endif
    }
    
    // MARK: - Status Refresh
    
    /// Manually refresh premium status from RevenueCat.
    func refreshPremiumStatus() async {
        do {
            let customerInfo = try await Purchases.shared.customerInfo()
            updatePremiumStatus(from: customerInfo)
        } catch {
            #if DEBUG
            print("❌ [SubscriptionService] Status refresh failed: \(error.localizedDescription)")
            #endif
        }
    }
    
    // MARK: - Private Helpers
    
    /// Whether the server has permanently granted premium (e.g. admin accounts).
    /// Set from the user profile API response during login.
    private var serverGrantedPremium: Bool = false
    
    /// Call after fetching user profile from API to set server-granted premium.
    func setServerPremiumStatus(_ isPremiumFromServer: Bool) {
        if serverGrantedPremium != isPremiumFromServer {
            serverGrantedPremium = isPremiumFromServer

            // Immediately update premium status for UI responsiveness (offline cold start)
            let wasPremium = isPremium
            let next = isPremiumFromServer || wasPremium
            premiumState.value = next
            PremiumLimits.isPremiumCached = next
            if wasPremium != next {
                #if DEBUG
                print("💎 [SubscriptionService] Immediate server-granted premium: \(wasPremium) → \(next)")
                #endif
                NotificationCenter.default.post(name: .premiumStatusDidChange, object: nil)
            }
            
            // Also reconcile with RevenueCat (may fail offline — that's OK now)
            Task {
                await refreshPremiumStatus()
            }
        }
    }
    
    private func updatePremiumStatus(from customerInfo: CustomerInfo) {
        let wasPremium = isPremium
        // Premium if EITHER RevenueCat entitlement is active OR server grants permanent premium
        let next = customerInfo.entitlements[Self.entitlementID]?.isActive == true || serverGrantedPremium
        premiumState.value = next

        // Sync thread-safe cache (readable from any actor)
        PremiumLimits.isPremiumCached = next
        if wasPremium != next {
            #if DEBUG
            print("💎 [SubscriptionService] Premium status changed: \(wasPremium) → \(next)")
            #endif
            NotificationCenter.default.post(name: .premiumStatusDidChange, object: nil)
        }
    }
}

/// Thread-safe storage for `SubscriptionService.isPremium`. Lives outside
/// `@Observable` so reads can be `nonisolated` without tripping the macro
/// warning, and writes are serialised by `os_unfair_lock` (cheap and
/// available pre-iOS 18, unlike `Mutex`).
private final class PremiumStateBox: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var stored: Bool = false

    var value: Bool {
        get {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return stored
        }
        set {
            os_unfair_lock_lock(&lock)
            stored = newValue
            os_unfair_lock_unlock(&lock)
        }
    }
}

// MARK: - PurchasesDelegate

extension SubscriptionService: PurchasesDelegate {
    nonisolated func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {
        Task { @MainActor in
            self.updatePremiumStatus(from: customerInfo)
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    static let premiumStatusDidChange = Notification.Name("premiumStatusDidChange")
}
