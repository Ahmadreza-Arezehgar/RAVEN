import Foundation

/// Central configuration for API endpoints and environment settings
enum AppConfig {
    
    // MARK: - Environment Detection
    
    static var isDebug: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
    
    // MARK: - API Configuration
    
    /// Set this to true to use local development server
    /// Change to false to use production server in DEBUG mode
    static let useLocalServer = false
    
    /// Local development server URL (your Mac's IP on local network)
    /// Use "localhost" if running on simulator, or your Mac's IP for physical device
    private static let localServerURL = "http://localhost:8000"
    
    /// Production server URLs — ordered by priority.
    /// If the primary server fails, the app automatically switches to the next one.
    static let serverList: [String] = [
        "https://raven-server-5iwa2y5n3a-ew.a.run.app",   // 🇧🇪 Belgium (primary — closest to EU)
        "https://raven-server-5iwa2y5n3a-ww.a.run.app",   // 🇶🇦 Doha (backup)
    ]
    
    /// The API base URL to use based on environment
    static var apiBaseURL: String {
        #if DEBUG
        if useLocalServer { return localServerURL }
        #endif
        return ServerFailover.shared.activeServerURL
    }
    
    // MARK: - Convenience
    
    /// Build full API URL from path
    static func apiURL(path: String) -> URL? {
        let cleanPath = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: "\(apiBaseURL)\(cleanPath)")
    }
    
    /// Print current configuration (for debugging)
    static func printConfig() {
        #if DEBUG
        print("📱 App Configuration:")
        print("   • Debug Mode: \(isDebug)")
        print("   • Use Local Server: \(useLocalServer)")
        print("   • API Base URL: \(apiBaseURL)")
        print("   • Server List: \(serverList)")
        #endif
    }
    
    // MARK: - Media URL Helper
    
    /// Convert a path (relative or absolute) to a full media URL
    /// Handles cases where server returns "/uploads/..." without base URL
    static func mediaURL(from path: String?) -> URL? {
        guard let path = path, !path.isEmpty else { return nil }
        
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        
        // Already a full URL or local file
        if encodedPath.hasPrefix("http://") || encodedPath.hasPrefix("https://") || encodedPath.hasPrefix("file://") {
            return URL(string: encodedPath)
        }
        
        // Relative path - prepend base URL
        let cleanPath = encodedPath.hasPrefix("/") ? encodedPath : "/\(encodedPath)"
        return URL(string: "\(apiBaseURL)\(cleanPath)")
    }
}

// MARK: - Server Failover Manager

/// Manages automatic server failover when the primary server becomes unreachable.
/// Tracks consecutive failures and switches to the next server in the list.
final class ServerFailover {
    static let shared = ServerFailover()
    
    /// Current server index in the server list
    private var currentIndex: Int = 0
    
    /// Consecutive failure count for the current server
    private var consecutiveFailures: Int = 0
    
    /// Number of failures before switching to the next server
    private let failoverThreshold: Int = 1
    
    /// Timestamp of last failover to prevent rapid switching
    private var lastFailoverTime: Date = .distantPast
    
    /// Minimum seconds between failover switches
    private let failoverCooldown: TimeInterval = 30
    
    /// Lock for thread safety
    private let lock = NSLock()
    
    /// The currently active server URL
    var activeServerURL: String {
        lock.lock()
        defer { lock.unlock() }
        let servers = AppConfig.serverList
        guard !servers.isEmpty else { return "" }
        return servers[currentIndex % servers.count]
    }
    
    /// Report a successful request — resets failure counter
    func reportSuccess() {
        lock.lock()
        defer { lock.unlock() }
        consecutiveFailures = 0
    }
    
    /// Report a failed request (timeout, connection error).
    /// After `failoverThreshold` consecutive failures, switches to the next server.
    /// Returns `true` if a failover occurred.
    @discardableResult
    func reportFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        let servers = AppConfig.serverList
        guard servers.count > 1 else { return false }
        
        consecutiveFailures += 1
        
        guard consecutiveFailures >= failoverThreshold else { return false }
        
        // Cooldown: don't switch too rapidly
        let now = Date()
        guard now.timeIntervalSince(lastFailoverTime) >= failoverCooldown else { return false }
        
        // Switch to next server
        let oldIndex = currentIndex
        currentIndex = (currentIndex + 1) % servers.count
        consecutiveFailures = 0
        lastFailoverTime = now
        
        #if DEBUG
        print("🔄 [ServerFailover] Switching server: \(servers[oldIndex]) → \(servers[currentIndex])")
        #endif
        return true
    }
    
    /// Force switch to a specific server index
    func switchTo(index: Int) {
        lock.lock()
        defer { lock.unlock() }
        let servers = AppConfig.serverList
        guard index >= 0 && index < servers.count else { return }
        currentIndex = index
        consecutiveFailures = 0
        #if DEBUG
        print("🔄 [ServerFailover] Force-switched to server: \(servers[index])")
        #endif
    }
    
    /// Reset to primary server
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        currentIndex = 0
        consecutiveFailures = 0
        #if DEBUG
        print("🔄 [ServerFailover] Reset to primary server")
        #endif
    }
}
