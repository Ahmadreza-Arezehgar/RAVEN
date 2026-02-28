import Foundation

/// Tracks consumed content (seen/skipped) for single-use feed items.
/// Like Snapchat/BeReal - once consumed, content never appears again.
@MainActor
class ContentConsumptionTracker: ObservableObject {
    static let shared = ContentConsumptionTracker()
    
    /// Set of content IDs already sent to server (prevents duplicate calls)
    private var sentToServer: Set<String> = []
    
    /// Offline queue for when network unavailable
    private var pendingQueue: [(contentId: String, contentType: String, status: String)] = []
    
    /// Visibility timers for tracking view duration
    private var visibilityTimers: [String: Timer] = [:]
    
    
    private init() {
        // Load pending queue from UserDefaults
        loadPendingQueue()
        
        // FIX: Listen to the correct notification (.networkStatusChanged)
        // "NetworkBecameAvailable" does not exist in the project, so offline views never synced
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(flushPendingQueue),
            name: .networkStatusChanged,
            object: nil
        )
    }
    
    // MARK: - Public API
    
    /// Mark content as consumed (seen or skipped).
    /// Idempotent - safe to call multiple times.
    func markConsumed(contentId: String, contentType: ContentType, status: ConsumptionStatus) {
        guard !sentToServer.contains(contentId) else { return }
        sentToServer.insert(contentId)
        
        #if DEBUG
        print("📍 [Consume] \(status.rawValue) \(contentType.rawValue):\(contentId.prefix(8))")
        #endif
        
        sendToServer(contentId: contentId, contentType: contentType, status: status)
    }
    
    /// Start visibility timer for content (call when ≥80% visible).
    /// Automatically marks as "seen" after threshold duration.
    func startVisibilityTimer(contentId: String, contentType: ContentType) {
        guard visibilityTimers[contentId] == nil else { return }
        guard !sentToServer.contains(contentId) else { return }
        
        let duration: TimeInterval = contentType == .story ? 0.7 : 1.2
        
        let timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.markConsumed(contentId: contentId, contentType: contentType, status: .seen)
            self?.visibilityTimers.removeValue(forKey: contentId)
        }
        
        visibilityTimers[contentId] = timer
    }
    
    /// Cancel visibility timer (call when content leaves viewport).
    func cancelVisibilityTimer(contentId: String) {
        visibilityTimers[contentId]?.invalidate()
        visibilityTimers.removeValue(forKey: contentId)
    }
    
    /// Mark as skipped (user explicitly swiped/skipped before seeing fully).
    func markSkipped(contentId: String, contentType: ContentType) {
        cancelVisibilityTimer(contentId: contentId)
        markConsumed(contentId: contentId, contentType: contentType, status: .skipped)
    }
    
    // MARK: - Private
    
    private func sendToServer(contentId: String, contentType: ContentType, status: ConsumptionStatus) {
        Task { @MainActor in
            guard let tokenResult = await KeychainService.shared.getToken() else {
                queueForLater(contentId: contentId, contentType: contentType, status: status)
                return
            }
            
            performNetworkRequest(contentId: contentId, contentType: contentType, status: status, token: tokenResult.token)
        }
    }

    
    private func performNetworkRequest(contentId: String, contentType: ContentType, status: ConsumptionStatus, token: String) {
        
        let clientEventId = UUID().uuidString
        
        let body: [String: Any] = [
            "content_id": contentId,
            "content_type": contentType.rawValue,
            "status": status.rawValue,
            "client_event_id": clientEventId
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }
        
        // Use AppConfig for consistent URL
        guard let url = AppConfig.apiURL(path: "/api/posts/content/consume") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        // Use async/await instead of Combine to avoid leaking subscriptions in the singleton's cancellables set
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let status = json["status"] as? String,
                   status == "consumed" || status == "already_consumed" {
                    #if DEBUG
                    print("✅ [Consume] Synced \(contentId.prefix(8))")
                    #endif
                }
            } catch {
                // Queue for retry
                self.queueForLater(contentId: contentId, contentType: contentType, status: status)
            }
        }
    }
    
    private func queueForLater(contentId: String, contentType: ContentType, status: ConsumptionStatus) {
        pendingQueue.append((contentId, contentType.rawValue, status.rawValue))
        savePendingQueue()
    }
    
    @objc private func flushPendingQueue() {
        // FIX: Only flush when actually online (notification fires for all status changes)
        guard NetworkMonitor.shared.isOnline else { return }
        
        let queue = pendingQueue
        pendingQueue.removeAll()
        savePendingQueue()
        
        for item in queue {
            guard let contentType = ContentType(rawValue: item.contentType),
                  let status = ConsumptionStatus(rawValue: item.status) else { continue }
            
            // Remove from sentToServer to allow re-send
            sentToServer.remove(item.contentId)
            markConsumed(contentId: item.contentId, contentType: contentType, status: status)
        }
    }
    
    private func savePendingQueue() {
        let data = pendingQueue.map { ["id": $0.contentId, "type": $0.contentType, "status": $0.status] }
        UserDefaults.standard.set(data, forKey: "consumption_pending_queue")
    }
    
    private func loadPendingQueue() {
        guard let data = UserDefaults.standard.array(forKey: "consumption_pending_queue") as? [[String: String]] else { return }
        pendingQueue = data.compactMap { dict in
            guard let id = dict["id"], let type = dict["type"], let status = dict["status"] else { return nil }
            return (id, type, status)
        }
    }
    
    // MARK: - Types
    
    enum ContentType: String {
        case post = "post"
        case story = "story"
    }
    
    enum ConsumptionStatus: String {
        case seen = "seen"
        case skipped = "skipped"
    }
}
