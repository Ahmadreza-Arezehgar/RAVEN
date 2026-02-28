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
    static let shared = SubscriptionService()
    
    // MARK: - Public State
    
    /// Whether the current user has an active RAVEN+ entitlement.
    /// nonisolated(unsafe) allows PremiumLimits to read from any actor context.
    /// Writes only happen on MainActor via updatePremiumStatus.
    nonisolated(unsafe) private(set) var isPremium: Bool = false
    
    /// Available offerings fetched from RevenueCat.
    private(set) var currentOffering: Offering?
    
    /// Loading states
    private(set) var isLoading: Bool = false
    private(set) var isPurchasing: Bool = false
    
    // MARK: - Constants
    
    #if DEBUG
    // Test key – set via environment or Xcode scheme
    private static let apiKey = "YOUR_REVENUECAT_TEST_KEY"
    #else
    // Production key – set via environment or Xcode scheme
    private static let apiKey = "YOUR_REVENUECAT_PROD_KEY"
    #endif
    private static let entitlementID = "Raven Pro"
    
    // MARK: - Init
    
    private override init() {
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
    
    /// Fetch the latest offerings from RevenueCat.
    func fetchOfferings() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            let offerings = try await Purchases.shared.offerings()
            currentOffering = offerings.current
            #if DEBUG
            print("💎 [SubscriptionService] Fetched offerings: \(offerings.current?.identifier ?? "none")")
            #endif
        } catch {
            #if DEBUG
            print("❌ [SubscriptionService] Fetch offerings failed: \(error.localizedDescription)")
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
                
                // Optimistic UI update — crown badge appears immediately
                AuthService.shared.currentUser?.isPremium = true
                
                #if DEBUG
                print("💎 [SubscriptionService] Purchase successful! isPremium=\(isPremium)")
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
            isPremium = isPremiumFromServer || isPremium
            PremiumLimits.isPremiumCached = isPremium
            if wasPremium != isPremium {
                #if DEBUG
                print("💎 [SubscriptionService] Immediate server-granted premium: \(wasPremium) → \(isPremium)")
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
        isPremium = customerInfo.entitlements[Self.entitlementID]?.isActive == true || serverGrantedPremium
        
        // Sync thread-safe cache (readable from any actor)
        PremiumLimits.isPremiumCached = isPremium
        if wasPremium != isPremium {
            #if DEBUG
            print("💎 [SubscriptionService] Premium status changed: \(wasPremium) → \(isPremium)")
            #endif
            NotificationCenter.default.post(name: .premiumStatusDidChange, object: nil)
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
