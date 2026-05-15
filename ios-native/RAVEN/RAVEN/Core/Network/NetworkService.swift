import Foundation
import Security
import CryptoKit
import UIKit

// MARK: - Shared Date Formatters (created once per process, reused everywhere)
// ISO8601DateFormatter is expensive to allocate (~1ms per init).
// This enum is internal so all modules can reuse the singletons.
enum SharedDateFormatters {
    /// ISO 8601 with fractional seconds (e.g. "2024-01-15T12:30:00.123Z")
    static let iso8601WithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    /// ISO 8601 standard (e.g. "2024-01-15T12:30:00Z")
    static let iso8601Standard: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    /// Microsecond precision (e.g. "2024-01-15T12:30:00.123456")
    static let microsecond: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
    /// Parse an ISO 8601 string trying fractional seconds first, then standard.
    static func parseISO8601(_ string: String) -> Date? {
        iso8601WithFraction.date(from: string)
            ?? iso8601Standard.date(from: string)
    }
    /// Format a Date as an ISO 8601 string (standard, no fractional seconds).
    static func formatISO8601(_ date: Date) -> String {
        iso8601Standard.string(from: date)
    }
}


// MARK: - API Error
enum APIError: Error, LocalizedError {
    case invalidURL
    case unauthorized
    case forbidden
    case notFound
    case badRequest(String)
    case serverError
    case httpError(Int, String)  // status code + detail from server
    case networkError(Error)
    case decodingError(Error)
    case rateLimited(retryAfter: Int?)
    case restricted  // Token is restricted (email not verified)
    case usernameRequired  // User needs to set username first (409)
    case tlsValidationFailed  // TLS certificate chain validation failed
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .unauthorized: return "Invalid credentials"
        case .forbidden: return "Access denied"
        case .notFound: return "Not found"
        case .badRequest(let message): return message
        case .serverError: return "Server error"
        case .httpError(let code, let detail): return "Error \(code): \(detail)"
        case .networkError(let error): return error.localizedDescription
        case .decodingError: return "Failed to parse response"
        case .rateLimited: return "Too many requests"
        case .restricted: return "Please verify your email first"
        case .usernameRequired: return "Please set a username first"
        case .tlsValidationFailed: return "Certificate validation failed"
        }
    }
    
    /// True for genuine auth failures (401/403/restricted) — NOT network errors
    var isAuthError: Bool {
        switch self {
        case .unauthorized, .forbidden, .restricted:
            return true
        default:
            return false
        }
    }
}

// MARK: - Auth Diagnostic Logger
/// Structured logging for auth decisions — helps debug spurious logouts.
/// Never prints raw tokens; only short hashes for correlation.
enum AuthLogger {
    enum Event: String {
        case refreshStarted      = "REFRESH_STARTED"
        case refreshSucceeded    = "REFRESH_OK"
        case refreshFailed       = "REFRESH_FAIL"
        case refreshExhausted    = "REFRESH_EXHAUSTED"
        case refreshQueued       = "REFRESH_QUEUED"
        case tokenRotated        = "TOKEN_ROTATED"
        case tokenStoreFailed    = "TOKEN_STORE_FAIL"
        case logoutDecision      = "LOGOUT_DECISION"
        case networkErrorIgnored = "NETWORK_ERR_IGNORED"
    }

    static func log(_ event: Event, endpoint: String = "", detail: String = "") {
        let ts = PerformanceConstants.iso8601.string(from: Date())
        let endpointInfo = endpoint.isEmpty ? "" : " endpoint=\(endpoint)"
        let detailInfo = detail.isEmpty ? "" : " | \(detail)"
        #if DEBUG
        print("🔐 [Auth] \(event.rawValue)\(endpointInfo)\(detailInfo) @ \(ts)")
        #endif
    }
}

// MARK: - TLS Validation Delegate
// Standard TLS certificate chain validation using the OS trust store.
// NOT certificate pinning — pinning is intentionally disabled for Google Cloud Run,
// whose certificates rotate automatically and unpredictably.
// Security is maintained via:
// 1. Standard TLS chain validation (below)
// 2. HTTPS enforcement
// 3. Token-based authentication at the API layer
// 4. Google Cloud Run's managed TLS infrastructure
final class TLSValidationDelegate: NSObject, URLSessionDelegate {
    
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        
        // Validate the certificate chain using system trust store
        var error: CFError?
        let isValid = SecTrustEvaluateWithError(serverTrust, &error)
        
        if isValid {
            // Certificate chain is valid - accept the connection
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            // Certificate chain validation failed - reject
            #if DEBUG
            print("❌ [TLS] Certificate chain validation failed: \(error?.localizedDescription ?? "unknown")")
            #endif
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

// MARK: - Network Service
actor NetworkService {
    static let shared = NetworkService()
    
    private var baseURL: String { AppConfig.apiBaseURL }
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let tlsDelegate: TLSValidationDelegate
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        // timeoutIntervalForResource intentionally omitted — OS default (~7 days)
        // allows RAVEN+ 2 GB uploads to complete without premature cancellation
        config.waitsForConnectivity = true               // FIX: Allow cellular radio to wake up
        // Multipath handover removed — requires com.apple.developer.networking.multipath entitlement
        // which needs a special request from Apple. Re-enable if/when entitlement is granted.
        
        // 🚨 Critical: Explicitly allow cellular/expensive/constrained access
        // Without these, iOS may block requests in Low Data Mode or on NAT64 cellular networks
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        
        // Create pinning delegate
        tlsDelegate = TLSValidationDelegate()
        
        // Use delegate for TLS chain validation
        session = URLSession(configuration: config, delegate: tlsDelegate, delegateQueue: nil)
        
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            
            // Use shared static formatters — creating DateFormatters is expensive
            // and the old code created 3 new ones per date field per decode call
            if let date = SharedDateFormatters.iso8601WithFraction.date(from: dateString) {
                return date
            }
            if let date = SharedDateFormatters.iso8601Standard.date(from: dateString) {
                return date
            }
            if let date = SharedDateFormatters.microsecond.date(from: dateString) {
                return date
            }
            
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode date: \(dateString)"
            )
        }
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }
    
    // MARK: - Request Methods
    
    func get<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> T {
        try await request(method: "GET", path: path, queryItems: queryItems, body: nil as Empty?)
    }
    
    func post<T: Decodable, B: Encodable>(
        path: String,
        body: B,
        idempotencyKey: String? = nil,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> T {
        try await request(method: "POST", path: path, queryItems: queryItems, body: body, idempotencyKey: idempotencyKey)
    }
    
    func put<T: Decodable, B: Encodable>(
        path: String,
        body: B
    ) async throws -> T {
        try await request(method: "PUT", path: path, queryItems: nil, body: body, idempotencyKey: nil)
    }
    
    func patch<T: Decodable, B: Encodable>(
        path: String,
        body: B
    ) async throws -> T {
        try await request(method: "PATCH", path: path, queryItems: nil, body: body, idempotencyKey: nil)
    }
    
    func delete(path: String) async throws {
        let _: Empty = try await request(method: "DELETE", path: path, queryItems: nil, body: nil as Empty?, idempotencyKey: nil)
    }
    
    func delete<T: Decodable>(path: String) async throws -> T {
        try await request(method: "DELETE", path: path, queryItems: nil, body: nil as Empty?, idempotencyKey: nil)
    }
    
    // MARK: - Multipart Upload
    
    /// Upload a file via multipart/form-data. Returns the decoded response.
    func uploadMultipart<T: Decodable>(
        path: String,
        fileData: Data,
        fileName: String,
        mimeType: String,
        fieldName: String = "file"
    ) async throws -> T {
        guard let url = URL(string: baseURL + path) else {
            throw APIError.invalidURL
        }
        
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        // Auth
        if let (token, scope) = await KeychainService.shared.getToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if scope == .restricted {
                throw APIError.restricted
            }
        }
        
        // Build multipart body
        var body = Data()
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\n")
        body.appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        body.appendString("\r\n--\(boundary)--\r\n")
        
        request.httpBody = body
        
        // Increase timeout for large uploads
        request.timeoutInterval = 3600
        
        #if DEBUG
        print("📤 [NetworkService] UPLOAD \(path) (\(fileData.count) bytes, \(mimeType))")
        #endif
        
        return try await executeWithRetry(request: request, retries: 2)
    }
    
    // MARK: - Private
    
    private func request<T: Decodable, B: Encodable>(
        method: String,
        path: String,
        queryItems: [URLQueryItem]?,
        body: B?,
        idempotencyKey: String? = nil
    ) async throws -> T {
        // Build URL
        guard var components = URLComponents(string: baseURL + path) else {
            throw APIError.invalidURL
        }
        // Only override query items if explicitly provided (preserve query params embedded in path)
        if let queryItems = queryItems {
            components.queryItems = queryItems
        }
        
        guard let url = components.url else {
            throw APIError.invalidURL
        }
        
        // Build request
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Add idempotency key for POST requests
        if let key = idempotencyKey {
            request.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        }
        
        // Add auth token
        if let (token, scope) = await KeychainService.shared.getToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            #if DEBUG
            print("🔑 [NetworkService] Token attached (scope: \(scope), len: \(token.count))")
            #endif
            
            // Check for restricted endpoints
            if scope == .restricted && !isAllowedForRestricted(path: path) {
                throw APIError.restricted
            }
        } else {
            #if DEBUG
            print("⚠️ [NetworkService] NO TOKEN for request: \(path)")
            #endif
        }
        
        // Encode body
        if let body = body {
            request.httpBody = try encoder.encode(body)
        }
        
        // Execute with retry
        return try await executeWithRetry(request: request, retries: 3)
    }
    
    private func executeWithRetry<T: Decodable>(
        request: URLRequest,
        retries: Int,
        currentDelay: TimeInterval = 1.0
    ) async throws -> T {
        // Stop zombie retries if the Task was cancelled (e.g. user left screen)
        try Task.checkCancellation()
        
        // Fast-fail if completely offline to maintain offline-first responsiveness
        if !NetworkMonitor.shared.isOnline {
            throw APIError.networkError(URLError(.notConnectedToInternet))
        }
        
        // 📡 Always-on request logging (critical for diagnosing cellular/NAT64 issues)
        #if DEBUG
        print("📡 [NetworkService] REQ: \(request.httpMethod ?? "GET") \(request.url?.path ?? "")")
        #endif
        
        do {
            // Log request details (debug only)
            #if DEBUG
            let method = request.httpMethod ?? "GET"
            let url = request.url?.absoluteString ?? "unknown"
            let bodyPreview = request.httpBody.flatMap { String(data: $0, encoding: .utf8)?.prefix(200) } ?? ""
            print("📤 [NetworkService] \(method) \(url)")
            if !bodyPreview.isEmpty {
                print("📤 [NetworkService] BODY: \(bodyPreview)...")
            }
            #endif
            
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.networkError(URLError(.badServerResponse))
            }
            
            // 📡 Always-on response logging
            #if DEBUG
            print("✅ [NetworkService] RES: \(request.url?.path ?? "") -> HTTP \(httpResponse.statusCode)")
            #endif
            
            // Detailed response logging (debug only)
            #if DEBUG
            let rawResponse = String(data: data, encoding: .utf8) ?? "nil"
            print("📥 [NetworkService] RESPONSE: \(rawResponse.prefix(500))")
            #endif
            
            switch httpResponse.statusCode {
            case 200...299:
                ServerFailover.shared.reportSuccess()
                if let empty = Empty() as? T {
                    return empty
                }
                
                // BUG FIX [P2]: Safely handle 204 No Content or empty bodies
                let dataToDecode: Data
                if data.isEmpty || httpResponse.statusCode == 204 {
                    // Try primitive fallbacks first (optional/empty init support)
                    if let res = try? decoder.decode(T.self, from: Data("{}".utf8)) { return res }
                    if let res = try? decoder.decode(T.self, from: Data("[]".utf8)) { return res }
                    if let res = try? decoder.decode(T.self, from: Data("null".utf8)) { return res }
                    
                    // Throw a specific error instead of a cryptic DecodingError
                    throw APIError.decodingError(NSError(domain: "NetworkService", code: 204, userInfo: [NSLocalizedDescriptionKey: "Server returned 204 No Content, but expected a strict model with required fields."]))
                } else {
                    dataToDecode = data
                }
                
                do {
                    return try decoder.decode(T.self, from: dataToDecode)
                } catch let decodingError as DecodingError {
                    #if DEBUG
                    print("❌ [NetworkService] DECODE ERROR for \(T.self):")
                    switch decodingError {
                    case .typeMismatch(let type, let context):
                        print("   Type mismatch: expected \(type) at \(context.codingPath.map(\.stringValue).joined(separator: ".")) — \(context.debugDescription)")
                    case .valueNotFound(let type, let context):
                        print("   Value not found: \(type) at \(context.codingPath.map(\.stringValue).joined(separator: ".")) — \(context.debugDescription)")
                    case .keyNotFound(let key, let context):
                        print("   Key not found: '\(key.stringValue)' at \(context.codingPath.map(\.stringValue).joined(separator: ".")) — \(context.debugDescription)")
                    case .dataCorrupted(let context):
                        print("   Data corrupted at \(context.codingPath.map(\.stringValue).joined(separator: ".")) — \(context.debugDescription)")
                    @unknown default:
                        print("   Unknown: \(decodingError)")
                    }
                    let rawJSON = String(data: data, encoding: .utf8) ?? "nil"
                    print("   📦 RAW JSON: \(rawJSON.prefix(1000))")
                    #endif
                    throw decodingError
                }
                
            case 400:
                #if DEBUG
                let rawError = String(data: data, encoding: .utf8) ?? "nil"
                print("❌ [NetworkService] 400 ERROR: \(rawError)")
                #endif
                let errorResponse = try? decoder.decode(ErrorResponse.self, from: data)
                throw APIError.badRequest(errorResponse?.detail ?? "Bad request")
                
            case 401:
                let endpoint = request.url?.path ?? "unknown"
                guard retries > 0 else {
                    AuthLogger.log(.refreshExhausted, endpoint: endpoint, detail: "retries=0, giving up")
                    throw APIError.unauthorized
                }
                
                // FIX: If offline, this throws networkError (NOT unauthorized)
                // so the caller sees a network error instead of triggering logout.
                try await attemptTokenRefresh()
                
                var retryRequest = request
                if let (freshToken, _) = await KeychainService.shared.getToken() {
                    retryRequest.setValue("Bearer \(freshToken)", forHTTPHeaderField: "Authorization")
                }
                // After refresh, retry immediately with zero delay
                return try await executeWithRetry(request: retryRequest, retries: 0)
                
            case 403:
                throw APIError.forbidden
                
            case 404:
                throw APIError.notFound
                
            case 422:
                #if DEBUG
                let rawError = String(data: data, encoding: .utf8) ?? "nil"
                print("❌ [NetworkService] 422 VALIDATION ERROR: \(rawError)")
                #endif
                let errorResponse = try? decoder.decode(ErrorResponse.self, from: data)
                throw APIError.badRequest(errorResponse?.detail ?? "Validation error")
                
            case 409:
                let errorResponse = try? decoder.decode(ErrorResponse.self, from: data)
                if errorResponse?.detail.contains("username") == true || errorResponse?.detail.contains("USERNAME") == true {
                    throw APIError.usernameRequired
                }
                throw APIError.badRequest(errorResponse?.detail ?? "Conflict")
                
            case 429:
                let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }
                throw APIError.rateLimited(retryAfter: retryAfter)
                
            case 500...599:
                #if DEBUG
                let rawError = String(data: data, encoding: .utf8) ?? "nil"
                print("❌ [NetworkService] SERVER ERROR \(httpResponse.statusCode): \(rawError)")
                #endif
                // Try to parse server error detail for actionable messages
                if let errorResponse = try? decoder.decode(ErrorResponse.self, from: data),
                   !errorResponse.detail.isEmpty {
                    throw APIError.httpError(httpResponse.statusCode, errorResponse.detail)
                }
                throw APIError.serverError
                
            default:
                throw APIError.serverError
            }
            
        } catch let error as APIError { throw error
        } catch let error as DecodingError {
            throw APIError.decodingError(error)
        } catch {
            // 📡 Always-on error logging (critical for diagnosing DNS/NAT64 failures)
            let nsError = error as NSError
            #if DEBUG
            print("❌ [NetworkService] FAIL: \(request.url?.path ?? "") -> \(error.localizedDescription) (Domain: \(nsError.domain), Code: \(nsError.code))")
            #endif
            
            // Don't retry if task was cancelled (user navigated away)
            let isCancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            if isCancelled {
                throw APIError.networkError(error)
            }
            
            // Don't retry timeouts when app is backgrounded — iOS throttles networking
            let isTimeout = (error as? URLError)?.code == .timedOut
            let isBackgrounded = await MainActor.run { UIApplication.shared.applicationState != .active }
            if isTimeout && isBackgrounded {
                throw APIError.networkError(error)
            }
            
            // Exponential backoff for transient network errors
            if retries > 0 {
                #if DEBUG
                if isTimeout {
                    print("⚠️ [NetworkService] Request timed out, retrying in \(currentDelay)s... (\(retries) left)")
                } else {
                    print("⚠️ [NetworkService] Network error, retrying in \(currentDelay)s... (\(retries) left)")
                }
                #endif
                try await Task.sleep(nanoseconds: UInt64(currentDelay * 1_000_000_000))
                return try await executeWithRetry(
                    request: request,
                    retries: retries - 1,
                    currentDelay: min(currentDelay * 2.0, 10.0)
                )
            }
            
            // ═══════════════════════════════════════════════════════════════
            // SEAMLESS FAILOVER: All retries on current server exhausted.
            // Before throwing an error to the UI, try the backup server.
            // ═══════════════════════════════════════════════════════════════
            let isConnectionError = (error as? URLError)?.code == .timedOut ||
                (error as? URLError)?.code == .cannotConnectToHost ||
                (error as? URLError)?.code == .networkConnectionLost ||
                (error as? URLError)?.code == .notConnectedToInternet ||
                (error as? URLError)?.code == .cannotFindHost
            
            if isConnectionError {
                let didSwitch = ServerFailover.shared.reportFailure()
                if didSwitch, let originalURL = request.url {
                    // Rebuild URL with the new server
                    let path = originalURL.path
                    let query = originalURL.query.map { "?\($0)" } ?? ""
                    let newBase = ServerFailover.shared.activeServerURL
                    if let newURL = URL(string: "\(newBase)\(path)\(query)") {
                        var newRequest = request
                        newRequest.url = newURL
                        #if DEBUG
                        print("🔄 [NetworkService] Failover → retrying on \(newBase)")
                        #endif
                        return try await executeWithRetry(
                            request: newRequest,
                            retries: 2,
                            currentDelay: 0.5
                        )
                    }
                }
            }
            
            throw APIError.networkError(error)
        }
    }
    
    private func isAllowedForRestricted(path: String) -> Bool {
        let allowedPaths = [
            "/api/auth/send-code",
            "/api/auth/verify-code",
            "/api/auth/resend-code",
            "/api/users/me",
            "/api/auth/refresh"
        ]
        return allowedPaths.contains(path)
    }
    
    // MARK: - Token Refresh (Task-based Single-Flight)
    
    /// The in-flight refresh task. Concurrent 401s all await the SAME task,
    /// and Swift automatically handles cancellation — no continuation leak possible.
    private var activeRefreshTask: Task<Void, Error>?
    
    /// Attempt to refresh the access token using stored refresh token.
    /// Uses Task-based single-flight: if a refresh is already running, all callers
    /// await the same Task. When a Task is cancelled, Swift cleans it up natively —
    /// no dangling continuations, no memory leaks.
    ///
    /// FIX: Now throws instead of returning Bool.
    /// - Network errors → throws APIError.networkError (no logout)
    /// - Auth failures → throws APIError.unauthorized (triggers logout)
    private func attemptTokenRefresh() async throws {
        // If a refresh is already in-flight, just await the existing task
        if let existingTask = activeRefreshTask {
            AuthLogger.log(.refreshQueued, detail: "waiting for in-flight refresh task")
            try await existingTask.value
            return
        }
        
        // Create a new refresh task — defer is INSIDE the Task body so that
        // cancellation of the calling task doesn't prematurely nil the reference
        // while the refresh network request is still in-flight.
        let task = Task<Void, Error> {
            defer {
                self.activeRefreshTask = nil
            }
            try await performRefresh()
        }
        
        // Store for concurrent callers to share
        activeRefreshTask = task
        try await task.value
    }
    
    /// The actual refresh network call — only ever called by one task at a time.
    ///
    /// FIX: Now throws instead of returning Bool.
    /// Network errors propagate as-is so callers know it's NOT an auth failure.
    private func performRefresh() async throws {
        guard let refreshToken = await KeychainService.shared.getRefreshToken() else {
            AuthLogger.log(.refreshFailed, detail: "no refresh token in Keychain")
            throw APIError.unauthorized
        }
        
        AuthLogger.log(.refreshStarted)
        
        guard let url = URL(string: "\(baseURL)/api/auth/refresh") else {
            AuthLogger.log(.refreshFailed, detail: "invalid refresh URL")
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15.0  // Prevent hang on edge/mesh networks
        
        let body = ["refresh_token": refreshToken]
        request.httpBody = try? JSONEncoder().encode(body)
        
        let data: Data
        let response: URLResponse
        do {
            let result = try await session.data(for: request)
            data = result.0
            response = result.1
        } catch {
            // FIX: Throw network error instead of returning false.
            // This prevents offline timeouts from being misinterpreted as 401.
            let isCancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            if isCancelled {
                AuthLogger.log(.networkErrorIgnored, detail: "refresh task cancelled gracefully")
            } else {
                AuthLogger.log(.networkErrorIgnored, detail: "refresh network error: \(error.localizedDescription)")
            }
            throw APIError.networkError(error)
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            AuthLogger.log(.refreshFailed, detail: "no HTTP response")
            throw APIError.networkError(URLError(.badServerResponse))
        }
        
        // ⚠️ CRITICAL: Distinguish auth failure from network/server errors
        switch httpResponse.statusCode {
        case 200:
            break // Success — continue below
        case 401, 403:
            // ⚡️ FIX: Guard against captive portals returning 401/403 HTML pages.
            // Only treat as auth failure if our server actually returned JSON.
            if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
               contentType.lowercased().contains("application/json") {
                AuthLogger.log(.refreshFailed, detail: "server returned \(httpResponse.statusCode) JSON — token invalid")
                throw APIError.unauthorized  // Genuine auth failure → triggers logout
            } else {
                AuthLogger.log(.networkErrorIgnored, detail: "got \(httpResponse.statusCode) but not JSON (likely captive portal) — skipping logout")
                throw APIError.networkError(URLError(.cannotDecodeContentData))
            }
        default:
            AuthLogger.log(.networkErrorIgnored, detail: "refresh got \(httpResponse.statusCode) — NOT an auth error, skipping logout")
            throw APIError.serverError  // Server issue, NOT auth → no logout
        }
        
        let refreshResponse = try decoder.decode(RefreshResponse.self, from: data)
        
        do {
            try await KeychainService.shared.updateAccessToken(refreshResponse.token)
        } catch {
            AuthLogger.log(.tokenStoreFailed, detail: "access token: \(error.localizedDescription)")
            throw APIError.networkError(error)
        }
        
        if let newRefreshToken = refreshResponse.refreshToken {
            do {
                try await KeychainService.shared.updateRefreshToken(newRefreshToken)
                AuthLogger.log(.tokenRotated)
            } catch {
                AuthLogger.log(.tokenStoreFailed, detail: "refresh token: \(error.localizedDescription)")
            }
        }
        
        AuthLogger.log(.refreshSucceeded)
    }
}

// MARK: - Helper Types

struct Empty: Codable {}

struct ErrorResponse: Codable {
    let detail: String
}

struct RefreshResponse: Codable {
    let token: String
    let tokenType: String
    let refreshToken: String?  // New refresh token (token rotation)
    
    enum CodingKeys: String, CodingKey {
        case token
        case tokenType = "token_type"
        case refreshToken = "refresh_token"
    }
}

// MARK: - Notification Names
// Note: .forceReAuth removed — was dead code (posted but never observed).
// Auth failures now propagate via APIError.unauthorized; AuthService handles gracefully.
