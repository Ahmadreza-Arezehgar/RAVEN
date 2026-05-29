//
//  EchoStore.swift
//  RAVEN
//
//  Observable view model for Echo feature.
//  Manages active echoes, response counts, and auto-cleanup.
//

import Foundation
import Combine

// MARK: - Echo Store

@MainActor @Observable
final class EchoStore {
    static let shared = EchoStore()
    
    /// All active (non-expired) echoes, sorted by recency.
    var receivedEchoes: [Echo] = []
    
    /// Echoes authored by this user.
    var myEchoes: [Echo] = []
    
    /// Response summaries keyed by echo ID.
    var responseSummaries: [String: EchoResponseSummary] = [:]
    
    /// Loading state.
    var isLoading: Bool = false
    
    /// Error message for UI.
    var errorMessage: String?
    
    private var cleanupTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        setupNotificationObservers()
        startCleanupTimer()
    }
    
    // MARK: - Public API
    
    /// Load all active echoes from database.
    func loadEchoes() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            receivedEchoes = try await EchoRepository.shared.getActiveEchoes()
            myEchoes = try await EchoRepository.shared.getMyEchoes()
            
            // Batch-load response summaries
            let allIds = (receivedEchoes + myEchoes).map(\.id)
            let uniqueIds = Array(Set(allIds))
            responseSummaries = try await EchoRepository.shared.getResponseSummaries(echoIds: uniqueIds)
            
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load echoes"
            #if DEBUG
            print("📣 [EchoStore] Load error: \(error)")
            #endif
        }
    }
    
    /// Create a new echo.
    func createEcho(content: String, ttlMinutes: Int = 360, shareLocation: Bool = false) async -> Bool {
        guard let echo = await EchoService.shared.createEcho(
            content: content,
            ttlMinutes: ttlMinutes,
            shareLocation: shareLocation
        ) else {
            errorMessage = "Rate limited: max 3 echoes per hour"
            return false
        }
        
        // Update local lists
        myEchoes.insert(echo, at: 0)
        receivedEchoes.insert(echo, at: 0)
        responseSummaries[echo.id] = .empty(for: echo.id)
        
        return true
    }
    
    /// Respond to an echo with an emoji.
    func respond(to echoId: String, with emoji: EchoEmoji) async -> Bool {
        let success = await EchoService.shared.respond(to: echoId, with: emoji)
        if success {
            // Optimistic update
            var summary = responseSummaries[echoId] ?? .empty(for: echoId)
            summary.counts[emoji, default: 0] += 1
            responseSummaries[echoId] = summary
        }
        return success
    }
    
    /// Check if we've already responded to an echo.
    func hasResponded(to echoId: String) -> Bool {
        EchoService.shared.respondedEchoIds.contains(echoId)
    }
    
    /// Get response summary for an echo.
    func summary(for echoId: String) -> EchoResponseSummary {
        responseSummaries[echoId] ?? .empty(for: echoId)
    }
    
    // MARK: - Private
    
    private func setupNotificationObservers() {
        NotificationCenter.default.publisher(for: .echoReceived)
            .sink { [weak self] _ in
                Task { await self?.loadEchoes() }
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: .echoResponseReceived)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] notification in
                guard let echoId = notification.userInfo?["echoId"] as? String else { return }
                Task { await self?.refreshSummary(for: echoId) }
            }
            .store(in: &cancellables)
    }
    
    private func refreshSummary(for echoId: String) async {
        do {
            let summary = try await EchoRepository.shared.getResponseSummary(echoId: echoId)
            responseSummaries[echoId] = summary
        } catch {
            #if DEBUG
            print("📣 [EchoStore] Failed to refresh summary for \(echoId.prefix(8)): \(error)")
            #endif
        }
    }

    private func startCleanupTimer() {
        // 🟡 BUG FIX (2026-05-10): both the outer Timer closure AND
        // the inner Task captured `self` strongly. EchoStore is a
        // singleton so the strong-self isn't a leak per se, but the
        // pattern is copy-pasted around the codebase and the
        // singleton's arrays + DB fetches keep churning forever.
        // `[weak self]` makes the cleanup loop honestly cancellable
        // (and matches the pattern we want elsewhere).
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Remove expired from local arrays
                self.receivedEchoes.removeAll { $0.isExpired }
                self.myEchoes.removeAll { $0.isExpired }

                // Cleanup database
                do {
                    try await EchoRepository.shared.cleanupExpired()
                } catch {
                    #if DEBUG
                    print("📣 [EchoStore] cleanupExpired failed: \(error)")
                    #endif
                }
            }
        }
    }
}
