import Foundation
import UIKit

// MARK: - CrashGuard
// Lightweight crash debugging service: breadcrumb logging, crash detection, and server reporting.
// No external dependencies required.

final class CrashGuard {
    static let shared = CrashGuard()
    
    // MARK: - Breadcrumb Types
    
    enum BreadcrumbCategory: String, Codable {
        case navigation     // Screen/view transitions
        case action         // User taps, gestures
        case network        // WebSocket, API calls
        case audio          // Audio session, recording, rooms
        case media          // Photo picker, camera, editor
        case lifecycle      // App foreground/background/terminate
        case error          // Caught errors that didn't crash
        case system         // Memory warnings, interruptions
    }
    
    struct Breadcrumb: Codable {
        let timestamp: Date
        let category: BreadcrumbCategory
        let message: String
        let metadata: [String: String]?
    }
    
    struct CrashReport: Codable {
        let deviceModel: String
        let osVersion: String
        let appVersion: String
        let buildNumber: String
        let memoryUsageMB: Double
        let crashTimestamp: Date?    // When we think the crash happened
        let launchTimestamp: Date    // When the app relaunched
        let lastException: String?  // From NSSetUncaughtExceptionHandler
        let lastSignal: String?     // From signal handler
        let breadcrumbs: [Breadcrumb]
        let sessionId: String
        let previousSessionId: String?
    }
    
    // MARK: - Constants
    
    private let maxBreadcrumbs = 30
    private let breadcrumbsKey = "CrashGuard_Breadcrumbs"
    private let cleanExitKey = "CrashGuard_CleanExit"
    private let sessionIdKey = "CrashGuard_SessionId"
    private let previousSessionIdKey = "CrashGuard_PreviousSessionId"
    private let lastExceptionKey = "CrashGuard_LastException"
    private let lastActiveTimestampKey = "CrashGuard_LastActiveTimestamp"
    

    
    private var breadcrumbs: [Breadcrumb] = []
    private let queue = DispatchQueue(label: "com.raven.crashguard", qos: .utility)
    private let sessionId = UUID().uuidString
    private var memoryWarningObserver: NSObjectProtocol?
    
    private init() {}
    
    // MARK: - Start / Stop
    
    /// Call as the FIRST line in didFinishLaunchingWithOptions
    func start() {
        #if DEBUG
        print("🛡️ [CrashGuard] Starting — session \(sessionId)")
        #endif
        
        // Save current session ID and keep previous
        let previousSession = UserDefaults.standard.string(forKey: sessionIdKey)
        UserDefaults.standard.set(previousSession, forKey: previousSessionIdKey)
        UserDefaults.standard.set(sessionId, forKey: sessionIdKey)
        
        // Check if previous session exited cleanly
        let wasCleanExit = UserDefaults.standard.bool(forKey: cleanExitKey)
        
        if !wasCleanExit {
            // Previous session did NOT exit cleanly → likely a crash
            handleDetectedCrash(previousSession: previousSession)
        } else {
            #if DEBUG
            print("🛡️ [CrashGuard] Previous session exited cleanly ✅")
            #endif
        }
        
        // Reset clean exit flag (will be set to true on normal termination)
        UserDefaults.standard.set(false, forKey: cleanExitKey)
        
        // Clear stored breadcrumbs from previous session
        breadcrumbs = []
        saveBreadcrumbs()
        
        // Install exception and signal handlers
        installCrashHandlers()
        
        // Monitor memory warnings
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.log(.system, "⚠️ MEMORY WARNING received", metadata: [
                "memoryMB": String(format: "%.1f", self?.currentMemoryMB() ?? 0)
            ])
        }
        
        log(.lifecycle, "App launched", metadata: [
            "device": deviceModel(),
            "os": UIDevice.current.systemVersion,
            "memory_mb": String(format: "%.1f", currentMemoryMB())
        ])
    }
    
    /// Call in applicationWillTerminate or when the user explicitly quits
    func markCleanExit() {
        log(.lifecycle, "Clean exit")
        UserDefaults.standard.set(true, forKey: cleanExitKey)
        UserDefaults.standard.synchronize()
        #if DEBUG
        print("🛡️ [CrashGuard] Clean exit marked ✅")
        #endif
    }
    
    // MARK: - Breadcrumb Logging
    
    /// Log a breadcrumb. Thread-safe, non-blocking.
    func log(_ category: BreadcrumbCategory, _ message: String, metadata: [String: String]? = nil) {
        let crumb = Breadcrumb(
            timestamp: Date(),
            category: category,
            message: message,
            metadata: metadata
        )
        
        queue.async { [weak self] in
            guard let self = self else { return }
            self.breadcrumbs.append(crumb)
            
            // Ring buffer — keep only the last N
            if self.breadcrumbs.count > self.maxBreadcrumbs {
                self.breadcrumbs.removeFirst(self.breadcrumbs.count - self.maxBreadcrumbs)
            }
            
            // Persist to UserDefaults so they survive a crash
            self.saveBreadcrumbs()
            
            #if DEBUG
            let emoji: String
            switch category {
            case .navigation: emoji = "🧭"
            case .action: emoji = "👆"
            case .network: emoji = "🌐"
            case .audio: emoji = "🎵"
            case .media: emoji = "📷"
            case .lifecycle: emoji = "📱"
            case .error: emoji = "⚠️"
            case .system: emoji = "💻"
            }
            print("🛡️ [CrashGuard] \(emoji) [\(category.rawValue)] \(message)")
            #endif
        }
        
        // Also update the "last active" timestamp
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastActiveTimestampKey)
    }
    
    // MARK: - Crash Detection
    
    private func handleDetectedCrash(previousSession: String?) {
        #if DEBUG
        print("🛡️ [CrashGuard] ❌ CRASH DETECTED — previous session did not exit cleanly!")
        #endif
        
        // Load breadcrumbs from the crashed session
        let crashBreadcrumbs = loadPersistedBreadcrumbs()
        let lastException = UserDefaults.standard.string(forKey: lastExceptionKey)
        let lastActive = UserDefaults.standard.double(forKey: lastActiveTimestampKey)
        
        // POSIX signal handlers removed — Apple's crash reporter handles
        // signals in TestFlight. Custom handlers with Swift were causing
        // infinite recursion on corrupted heaps.
        let lastSignal: String? = nil
        
        let crashTimestamp: Date? = lastActive > 0 ? Date(timeIntervalSince1970: lastActive) : nil
        
        // Build crash report
        let report = CrashReport(
            deviceModel: deviceModel(),
            osVersion: UIDevice.current.systemVersion,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            memoryUsageMB: currentMemoryMB(),
            crashTimestamp: crashTimestamp,
            launchTimestamp: Date(),
            lastException: lastException,
            lastSignal: lastSignal,
            breadcrumbs: crashBreadcrumbs,
            sessionId: sessionId,
            previousSessionId: previousSession
        )
        
        // Log the crash trail to console
        #if DEBUG
        print("🛡️ [CrashGuard] ═══════════════════════════════════════")
        print("🛡️ [CrashGuard] CRASH REPORT — Previous Session")
        print("🛡️ [CrashGuard] Device: \(report.deviceModel) / iOS \(report.osVersion)")
        print("🛡️ [CrashGuard] App: \(report.appVersion) (\(report.buildNumber))")
        #endif
        if let ex = lastException {
            #if DEBUG
            print("🛡️ [CrashGuard] Last Exception: \(ex)")
            #endif
        }
        if let sig = lastSignal {
            #if DEBUG
            print("🛡️ [CrashGuard] Last Signal: \(sig)")
            #endif
        }
        if let ts = crashTimestamp {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            #if DEBUG
            print("🛡️ [CrashGuard] Crashed around: \(formatter.string(from: ts))")
            #endif
        }
        #if DEBUG
        print("🛡️ [CrashGuard] Breadcrumb trail (\(crashBreadcrumbs.count) items):")
        #endif
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        for crumb in crashBreadcrumbs {
            let meta = crumb.metadata?.map { "\($0.key)=\($0.value)" }.joined(separator: ", ") ?? ""
            #if DEBUG
            print("🛡️   [\(formatter.string(from: crumb.timestamp))] [\(crumb.category.rawValue)] \(crumb.message) \(meta)")
            #endif
        }
        #if DEBUG
        print("🛡️ [CrashGuard] ═══════════════════════════════════════")
        #endif
        
        // Clear stored exception for next session
        UserDefaults.standard.removeObject(forKey: lastExceptionKey)
        
        // Upload to server (fire and forget)
        uploadCrashReport(report)
    }
    
    // MARK: - Crash Handlers
    
    private func installCrashHandlers() {
        // Uncaught NSException handler
        // NOTE: NSSetUncaughtExceptionHandler runs on the crashing thread before
        // the process terminates. UserDefaults.set is risky but generally works
        // for ObjC exceptions (unlike POSIX signals).
        NSSetUncaughtExceptionHandler { exception in
            let info = "\(exception.name.rawValue): \(exception.reason ?? "no reason") | callstack: \(exception.callStackSymbols.prefix(10).joined(separator: " ← "))"
            UserDefaults.standard.set(info, forKey: "CrashGuard_LastException")
            UserDefaults.standard.synchronize()
        }
        
        // POSIX signal handlers INTENTIONALLY NOT INSTALLED.
        // Calling any Swift runtime code (even StaticString.withUTF8Buffer) inside
        // a signal handler on a corrupted heap causes infinite recursion and locks
        // the CPU before iOS can terminate the process.
        // Apple's own crash reporter in TestFlight/App Store handles SIGABRT,
        // SIGSEGV, etc. reliably — custom handlers are unnecessary and dangerous.
        
        #if DEBUG
        print("🛡️ [CrashGuard] Exception handler installed (POSIX signals handled by system)")
        #endif
    }
    
    // MARK: - Persistence
    
    private func saveBreadcrumbs() {
        guard let data = try? JSONEncoder().encode(breadcrumbs) else { return }
        UserDefaults.standard.set(data, forKey: breadcrumbsKey)
    }
    
    private func loadPersistedBreadcrumbs() -> [Breadcrumb] {
        guard let data = UserDefaults.standard.data(forKey: breadcrumbsKey),
              let crumbs = try? JSONDecoder().decode([Breadcrumb].self, from: data) else {
            return []
        }
        return crumbs
    }
    
    // MARK: - Server Upload
    
    private func uploadCrashReport(_ report: CrashReport) {
        guard let url = AppConfig.apiURL(path: "/api/crash-reports") else {
            #if DEBUG
            print("🛡️ [CrashGuard] No API URL configured — skipping upload")
            #endif
            return
        }
        
        Task.detached(priority: .utility) {
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                
                // Add auth token if available
                if let (token, _) = await KeychainService.shared.getToken() {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                request.httpBody = try encoder.encode(report)
                
                let (_, response) = try await URLSession.shared.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                #if DEBUG
                print("🛡️ [CrashGuard] Crash report uploaded — status \(statusCode)")
                #endif
            } catch {
                #if DEBUG
                print("🛡️ [CrashGuard] Failed to upload crash report: \(error.localizedDescription)")
                #endif
            }
        }
    }
    
    // MARK: - System Info
    
    private func currentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576.0 : 0
    }
    
    private func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        var machine = systemInfo.machine
        let machineSize = MemoryLayout.size(ofValue: machine)
        let model = withUnsafePointer(to: &machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: machineSize) { ptr in
                String(validatingUTF8: ptr)
            }
        }
        return model ?? UIDevice.current.model
    }
}
