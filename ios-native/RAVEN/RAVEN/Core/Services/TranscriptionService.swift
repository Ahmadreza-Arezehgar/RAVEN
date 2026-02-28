import Foundation

// MARK: - Transcript Response

/// Response from POST /api/posts/{id}/transcribe or GET /api/posts/{id}/transcript
struct TranscriptResponse: Codable {
    let status: String          // "none", "pending", "processing", "ready", "failed"
    let language: String?
    let text: String?
}

// MARK: - Local Cache Entry

private struct CachedTranscript: Codable {
    let text: String
    let language: String?
    let cachedAt: Date
}

// MARK: - TranscriptionService

/// Handles transcription requests, polling, and local caching for voice posts/comments.
/// Communicates with:
///   - POST /api/posts/{id}/transcribe
///   - GET  /api/posts/{id}/transcript
///   - POST /api/comments/{id}/transcribe
///   - GET  /api/comments/{id}/transcript
@MainActor
final class TranscriptionService {
    static let shared = TranscriptionService()
    
    private let cacheKey = "com.raven.transcriptCache"
    private let maxPollAttempts = 15
    private let pollInterval: TimeInterval = 2.0
    
    private init() {}
    
    // MARK: - Public API
    
    /// Request transcription for a voice post. Returns the transcript when ready.
    /// If cached locally, returns immediately without a network call.
    func transcribe(postId: String) async throws -> TranscriptResponse {
        // Check local cache first
        if let cached = getCachedTranscript(id: postId) {
            #if DEBUG
            print("🎙️ [Transcript] Cache hit for post \(postId.prefix(8))…")
            #endif
            return TranscriptResponse(status: "ready", language: cached.language, text: cached.text)
        }
        
        // RAVEN+ rate limit: Free 3/day, RAVEN+ unlimited
        guard PremiumLimits.canUseTranscription() else {
            throw PremiumLimitError.dailyTranscriptionLimitReached(remaining: PremiumLimits.remainingTranscriptions)
        }
        
        // Trigger transcription (POST with empty body)
        #if DEBUG
        print("🎙️ [Transcript] POST /api/posts/\(postId.prefix(8))…/transcribe")
        #endif
        do {
            let initial: TranscriptResponse = try await NetworkService.shared.post(
                path: "/api/posts/\(postId)/transcribe",
                body: Empty()
            )
            #if DEBUG
            print("🎙️ [Transcript] Initial response: status=\(initial.status)")
            #endif
            
            // Already ready (server had it cached)
            if initial.status == "ready", let text = initial.text {
                cacheTranscript(id: postId, text: text, language: initial.language)
                return initial
            }
            
            // Poll until ready
            return try await poll(path: "/api/posts/\(postId)/transcript", cacheId: postId)
        } catch {
            PremiumLimits.refundTranscription()
            throw error
        }
    }
    
    /// Request transcription for a voice comment.
    func transcribe(commentId: String) async throws -> TranscriptResponse {
        if let cached = getCachedTranscript(id: commentId) {
            #if DEBUG
            print("🎙️ [Transcript] Cache hit for comment \(commentId.prefix(8))…")
            #endif
            return TranscriptResponse(status: "ready", language: cached.language, text: cached.text)
        }
        
        // RAVEN+ rate limit: Free 3/day, RAVEN+ unlimited
        guard PremiumLimits.canUseTranscription() else {
            throw PremiumLimitError.dailyTranscriptionLimitReached(remaining: PremiumLimits.remainingTranscriptions)
        }
        
        #if DEBUG
        print("🎙️ [Transcript] POST /api/comments/\(commentId.prefix(8))…/transcribe")
        #endif
        do {
            let initial: TranscriptResponse = try await NetworkService.shared.post(
                path: "/api/comments/\(commentId)/transcribe",
                body: Empty()
            )
            #if DEBUG
            print("🎙️ [Transcript] Initial response: status=\(initial.status)")
            #endif
            
            if initial.status == "ready", let text = initial.text {
                cacheTranscript(id: commentId, text: text, language: initial.language)
                return initial
            }
            
            return try await poll(path: "/api/comments/\(commentId)/transcript", cacheId: commentId)
        } catch {
            PremiumLimits.refundTranscription()
            throw error
        }
    }
    
    /// Check if a transcript is locally cached.
    func hasCachedTranscript(id: String) -> Bool {
        getCachedTranscript(id: id) != nil
    }
    
    /// Get cached transcript text (if available).
    func cachedText(for id: String) -> String? {
        getCachedTranscript(id: id)?.text
    }
    
    /// Get cached transcript language (if available).
    func cachedLanguage(for id: String) -> String? {
        getCachedTranscript(id: id)?.language
    }
    
    // MARK: - Polling
    
    private func poll(path: String, cacheId: String) async throws -> TranscriptResponse {
        for _ in 0..<maxPollAttempts {
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            
            let response: TranscriptResponse = try await NetworkService.shared.get(path: path)
            
            if response.status == "ready", let text = response.text {
                cacheTranscript(id: cacheId, text: text, language: response.language)
                return response
            }
            
            if response.status == "failed" {
                return response
            }
            
            // Continue polling for "pending" / "processing"
        }
        
        // Timeout
        return TranscriptResponse(status: "failed", language: nil, text: nil)
    }
    
    // MARK: - Local Cache (UserDefaults)
    
    private func getCachedTranscript(id: String) -> CachedTranscript? {
        guard let data = UserDefaults.standard.data(forKey: "\(cacheKey)_\(id)") else { return nil }
        return try? JSONDecoder().decode(CachedTranscript.self, from: data)
    }
    
    private func cacheTranscript(id: String, text: String, language: String?) {
        let entry = CachedTranscript(text: text, language: language, cachedAt: Date())
        if let data = try? JSONEncoder().encode(entry) {
            UserDefaults.standard.set(data, forKey: "\(cacheKey)_\(id)")
        }
    }
    
    // MARK: - Message Transcription (1:1 & Group)
    
    /// Request transcription for a voice message (chat).
    /// - Parameters:
    ///   - messageId: Server-assigned message ID
    ///   - isGroup: Whether this is a group message
    ///   - groupId: Group ID (required when isGroup is true)
    func transcribe(messageId: String, isGroup: Bool = false, groupId: String? = nil) async throws -> TranscriptResponse {
        if let cached = getCachedTranscript(id: messageId) {
            #if DEBUG
            print("🎙️ [Transcript] Cache hit for message \(messageId.prefix(8))…")
            #endif
            return TranscriptResponse(status: "ready", language: cached.language, text: cached.text)
        }
        
        // RAVEN+ rate limit: Free 3/day, RAVEN+ unlimited
        guard PremiumLimits.canUseTranscription() else {
            throw PremiumLimitError.dailyTranscriptionLimitReached(remaining: PremiumLimits.remainingTranscriptions)
        }
        
        // Build path based on 1:1 vs group
        let basePath: String
        if isGroup, let gid = groupId {
            basePath = "/api/groups/\(gid)/messages/\(messageId)"
        } else {
            basePath = "/api/messages/\(messageId)"
        }
        
        #if DEBUG
        print("🎙️ [Transcript] POST \(basePath)/transcribe")
        #endif
        do {
            let initial: TranscriptResponse = try await NetworkService.shared.post(
                path: "\(basePath)/transcribe",
                body: Empty()
            )
            #if DEBUG
            print("🎙️ [Transcript] Initial response: status=\(initial.status)")
            #endif
            
            if initial.status == "ready", let text = initial.text {
                cacheTranscript(id: messageId, text: text, language: initial.language)
                return initial
            }
            
            return try await poll(path: "\(basePath)/transcript", cacheId: messageId)
        } catch {
            PremiumLimits.refundTranscription()
            throw error
        }
    }
}
