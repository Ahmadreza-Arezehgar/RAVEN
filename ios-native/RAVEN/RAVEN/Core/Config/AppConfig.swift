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
    
    /// Production server URLs.
    ///
    /// Single-region deployment as of this revision: 🇧🇪 Belgium only.
    /// The previous Qatar (me-central1) failover was decommissioned to cut
    /// cost — when Belgium is unreachable, the iOS client falls through
    /// to the BLE mesh + mesh-bridge layer for messages and text-only
    /// posts (see `MessageRouter` and `MeshPostService`). Only operations
    /// that strictly require the server (account create, full-media post
    /// upload, friend list refresh) will fail; everything else continues.
    static let serverList: [String] = [
        "https://raven-server-516053629173.europe-west1.run.app",  // 🇧🇪 Belgium
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
    
    /// Convert a path (relative or absolute) to a full media URL.
    /// Handles cases where server returns "/uploads/..." without base URL.
    ///
    /// Round 14 (2026-05-16) — hacker-audit finding N9.
    /// Two changes vs. the old behaviour:
    ///   1. `http://` is REJECTED — only `https://` and the
    ///      relative-path branch (which prepends our own apiBaseURL)
    ///      are accepted. ATS would block plain HTTP on most
    ///      consumers anyway, but enforcing it here means a server-
    ///      side compromise that injects `http://attacker/x.svg`
    ///      never reaches the ImageIO decoder (SVG + crafted XML
    ///      have been image-decoder RCE in past iOS releases).
    ///   2. Host allow-list — absolute URLs must point to one of
    ///      our known media/CDN hostnames. An attacker-controlled
    ///      domain in an attacker-injected URL is rejected even if
    ///      it's HTTPS.
    private static let allowedMediaHostSuffixes: Set<String> = [
        // Cloud Run + project domains.
        "run.app",
        "raven.app",
        "raven-messager.com",
        // 🔴 ROUND 25 — Cloud Storage host where Cloud Run stores
        // every uploaded attachment (signed URLs land at
        // storage.googleapis.com/<bucket>/<object>). My round-14
        // allowlist forgot this host so every image in the feed
        // rejected with "media URL host ... not in allowlist". The
        // user's log showed 3 stacked rejections per feed render.
        "googleapis.com",
        // Google CDNs for Apple/Google sign-in avatars.
        "googleusercontent.com",
        // Apple-hosted sign-in avatars (when we ever wire them).
        "apple.com",
    ]

    static func mediaURL(from path: String?) -> URL? {
        guard let path = path, !path.isEmpty else { return nil }

        // 🔴 BUG FIX (2026-05-20) — feed media not loading.
        //
        // PREVIOUSLY: `path.addingPercentEncoding(withAllowedCharacters:
        // .urlQueryAllowed)` ran unconditionally, even on already-fully-
        // formed `https://...` GCS signed URLs. The `urlQueryAllowed`
        // character set does NOT include `%`, so every pre-existing
        // percent-escape in the signed URL (e.g. `%40` for `@`, `%2F`
        // for `/`) was double-encoded to `%2540`, `%252F`. Google Cloud
        // Storage then rejected the request with
        //   400 MalformedSecurityHeader — "Credential scope string has
        //    invalid format"
        // and the iOS image loader showed a broken thumbnail.
        //
        // FIX: only percent-encode RELATIVE paths. A full `https://`
        // URL is already correctly encoded by whoever produced it
        // (Cloud Run + the GCS SDK, which handle URL encoding properly
        // by construction). Pass it through to `URL(string:)` untouched.
        if path.hasPrefix("https://") {
            guard let url = URL(string: path),
                  let host = url.host?.lowercased() else {
                #if DEBUG
                print("⚠️ [AppConfig] absolute URL failed to parse: \(path.prefix(96))")
                #endif
                return nil
            }
            let allowed = allowedMediaHostSuffixes.contains { suffix in
                host == suffix || host.hasSuffix("." + suffix)
            }
            if !allowed {
                #if DEBUG
                print("⚠️ [AppConfig] media URL host '\(host)' not in allowlist — rejected.")
                #endif
                return nil
            }
            return url
        }

        // Plain HTTP and other schemes are rejected outright.
        if path.hasPrefix("http://") {
            #if DEBUG
            print("⚠️ [AppConfig] plain HTTP media URL rejected: \(path.prefix(64))")
            #endif
            return nil
        }

        // Local file — used by attachment-cache reads.
        if path.hasPrefix("file://") {
            return URL(string: path)
        }

        // Relative path — percent-encode the segments that need it,
        // then prepend our trusted base URL. ONLY relative paths get
        // encoded here; absolute URLs took the early-return branch
        // above.
        let encodedRelative = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        let cleanPath = encodedRelative.hasPrefix("/") ? encodedRelative : "/\(encodedRelative)"
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
