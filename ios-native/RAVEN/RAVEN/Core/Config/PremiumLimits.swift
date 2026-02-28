//
//  PremiumLimits.swift
//  RAVEN
//
//  Centralized feature gate thresholds for free vs RAVEN+ tiers.
//

import Foundation

// MARK: - PremiumLimits

/// Centralized configuration for all RAVEN+ feature gates.
/// All threshold checks reference `SubscriptionService.shared.isPremium`.
struct PremiumLimits {
    
    /// Persistent cache of premium status, backed by UserDefaults.
    /// Survives cold starts so Ghost Mode is protected during the seconds
    /// before RevenueCat re-validates with Apple's servers.
    nonisolated(unsafe) static var isPremiumCached: Bool {
        get { UserDefaults.standard.bool(forKey: "raven_premium_cache") }
        set { UserDefaults.standard.set(newValue, forKey: "raven_premium_cache") }
    }
    
    /// Convenience accessor for current premium status.
    /// Returns true if EITHER the live RevenueCat status or the persisted
    /// cache says premium — prevents Ghost Mode leaks on cold start.
    nonisolated(unsafe) static var isPremium: Bool {
        SubscriptionService.shared.isPremium || isPremiumCached
    }
    
    // ═══════════════════════════════════════════════════════════════════
    // MARK: - Media & Storage
    // ═══════════════════════════════════════════════════════════════════
    
    /// Maximum file upload size in bytes.
    /// Free: 25 MB, RAVEN+: 2 GB
    static var maxFileUploadBytes: Int {
        isPremium ? 2_147_483_648 : 26_214_400
    }
    
    /// Image compression quality for posts.
    /// Free: 0.75, RAVEN+: 1.0 (lossless)
    static var imageCompressionQuality: CGFloat {
        isPremium ? 1.0 : 0.75
    }
    
    /// Max image dimension for posts/attachments.
    /// Free: 2048px, RAVEN+: 8192px (near-lossless)
    static var maxImageDimension: CGFloat {
        isPremium ? 8192 : 2048
    }
    
    /// Maximum voice message duration in seconds.
    /// Free: 120s (2 min), RAVEN+: 600s (10 min)
    static var voiceMessageMaxDuration: TimeInterval {
        isPremium ? 600.0 : 120.0
    }
    
    /// Maximum number of media items (photos/videos) per post.
    /// Free: 4, RAVEN+: 10
    static var maxMediaPerPost: Int {
        isPremium ? 10 : 4
    }
    
    // ═══════════════════════════════════════════════════════════════════
    // MARK: - AI Features (Daily Rate Limits)
    // ═══════════════════════════════════════════════════════════════════
    
    /// Daily transcription limit. Free: 3, RAVEN+: unlimited.
    static var dailyTranscriptionLimit: Int {
        isPremium ? Int.max : 3
    }
    
    /// Daily Gemini AI question limit. Free: 5, RAVEN+: unlimited.
    static var dailyGeminiLimit: Int {
        isPremium ? Int.max : 5
    }
    
    // ═══════════════════════════════════════════════════════════════════
    // MARK: - Privacy & Stealth
    // ═══════════════════════════════════════════════════════════════════
    
    /// Ghost Mode: suppress outgoing read receipts.
    /// Only available to RAVEN+ users.
    static var ghostModeEnabled: Bool {
        // Ghost Mode activates when a premium user has turned off Read Receipts.
        // Free users cannot disable read receipts (paywall gated in PrivacySettingsView).
        let readReceiptsEnabled = UserDefaults.standard.object(forKey: "readReceipts") as? Bool ?? true
        return isPremium && !readReceiptsEnabled
    }
    
    // ═══════════════════════════════════════════════════════════════════
    // MARK: - Mesh Superpowers
    // ═══════════════════════════════════════════════════════════════════
    
    /// Mesh message TTL in seconds.
    /// Free: 86400 (24h), RAVEN+: 259200 (72h)
    static var meshTTLSeconds: Int {
        isPremium ? 259_200 : 86_400
    }
    
    /// Mesh message hop limit.
    /// Free: 10, RAVEN+: 50
    static var meshHopLimit: Int {
        isPremium ? 50 : 10
    }
    
    /// Binary Spray & Wait budget for mesh relay.
    /// Free: 5 (conservative), RAVEN+: 50 (full city coverage)
    static var meshSprayBudget: Int {
        isPremium ? 50 : 5
    }
    
    /// VIP routing priority boost for mesh messages.
    /// RAVEN+ messages get +50 priority in the mesh queue.
    static var meshPriorityBoost: Int {
        isPremium ? 50 : 0
    }
    
    // ═══════════════════════════════════════════════════════════════════
    // MARK: - Daily Usage Tracking (UserDefaults-backed)
    // ═══════════════════════════════════════════════════════════════════
    
    private static let transcriptionCountKey = "raven.daily.transcription_count"
    private static let transcriptionDateKey  = "raven.daily.transcription_date"
    private static let geminiCountKey        = "raven.daily.gemini_count"
    private static let geminiDateKey         = "raven.daily.gemini_date"
    
    /// Check if a transcription request is allowed. Increments counter if yes.
    static func canUseTranscription() -> Bool {
        if isPremium { return true }
        return incrementDailyCounter(
            countKey: transcriptionCountKey,
            dateKey: transcriptionDateKey,
            limit: 3
        )
    }
    
    /// Check if a Gemini AI request is allowed. Increments counter if yes.
    static func canUseGemini() -> Bool {
        if isPremium { return true }
        return incrementDailyCounter(
            countKey: geminiCountKey,
            dateKey: geminiDateKey,
            limit: 5
        )
    }
    
    /// Remaining transcription uses today.
    static var remainingTranscriptions: Int {
        if isPremium { return Int.max }
        return remainingUses(countKey: transcriptionCountKey, dateKey: transcriptionDateKey, limit: 3)
    }
    
    /// Remaining Gemini AI uses today.
    static var remainingGeminiUses: Int {
        if isPremium { return Int.max }
        return remainingUses(countKey: geminiCountKey, dateKey: geminiDateKey, limit: 5)
    }
    
    // MARK: - Private Counter Logic
    
    private static func incrementDailyCounter(countKey: String, dateKey: String, limit: Int) -> Bool {
        let defaults = UserDefaults.standard
        let today = Calendar.current.startOfDay(for: Date())
        let storedDate = defaults.object(forKey: dateKey) as? Date ?? .distantPast
        
        // Reset counter if it's a new day
        if Calendar.current.startOfDay(for: storedDate) != today {
            defaults.set(1, forKey: countKey)
            defaults.set(today, forKey: dateKey)
            return true // First use of the day
        }
        
        let currentCount = defaults.integer(forKey: countKey)
        if currentCount < limit {
            defaults.set(currentCount + 1, forKey: countKey)
            return true
        }
        
        return false // Limit reached
    }
    
    private static func remainingUses(countKey: String, dateKey: String, limit: Int) -> Int {
        let defaults = UserDefaults.standard
        let today = Calendar.current.startOfDay(for: Date())
        let storedDate = defaults.object(forKey: dateKey) as? Date ?? .distantPast
        
        if Calendar.current.startOfDay(for: storedDate) != today {
            return limit
        }
        
        return max(0, limit - defaults.integer(forKey: countKey))
    }
    
    // MARK: - Refunds (Network Failure Recovery)
    
    /// Refund a Gemini AI use if the network call failed
    static func refundGemini() {
        if isPremium { return }
        let currentCount = UserDefaults.standard.integer(forKey: geminiCountKey)
        if currentCount > 0 { UserDefaults.standard.set(currentCount - 1, forKey: geminiCountKey) }
    }
    
    /// Refund a transcription use if the network call failed
    static func refundTranscription() {
        if isPremium { return }
        let currentCount = UserDefaults.standard.integer(forKey: transcriptionCountKey)
        if currentCount > 0 { UserDefaults.standard.set(currentCount - 1, forKey: transcriptionCountKey) }
    }
}

// MARK: - Errors

enum PremiumLimitError: LocalizedError {
    case fileTooLarge(maxMB: Int)
    case dailyTranscriptionLimitReached(remaining: Int)
    case dailyGeminiLimitReached(remaining: Int)
    case premiumRequired(feature: String)
    
    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let maxMB):
            return PremiumLimits.isPremium
                ? "File exceeds the \(maxMB) MB upload limit."
                : "File exceeds the \(maxMB) MB upload limit. Upgrade to RAVEN+ for up to 2 GB uploads."
        case .dailyTranscriptionLimitReached:
            return "You've used all 3 free transcriptions today. Upgrade to RAVEN+ for unlimited."
        case .dailyGeminiLimitReached:
            return "You've used all 5 free AI questions today. Upgrade to RAVEN+ for unlimited."
        case .premiumRequired(let feature):
            return "\(feature) is a RAVEN+ exclusive feature. Upgrade to unlock."
        }
    }
}
