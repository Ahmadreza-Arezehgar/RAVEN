import Foundation
import Security
import CryptoKit
import UIKit
import os

fileprivate let logger = Logger(subsystem: "app.raven.ios", category: "NetworkService")

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
    /// Microsecond precision with T separator (e.g. "2024-01-15T12:30:00.123456")
    static let microsecond: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
    /// PostgreSQL default format — space separator (e.g. "2024-01-15 12:30:00.123456")
    static let postgresTimestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
    /// PostgreSQL without fractional seconds (e.g. "2024-01-15 12:30:00")
    static let postgresTimestampNoFraction: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
    /// Parse an ISO 8601 string trying fractional seconds first, then standard.
    static func parseISO8601(_ string: String) -> Date? {
        iso8601WithFraction.date(from: string)
            ?? iso8601Standard.date(from: string)
    }
    /// Format a Date as an ISO 8601 string WITH fractional seconds.
    /// 🟡 BUG FIX (2026-05-10): the previous version dropped sub-
    /// second precision; two messages sent within the same wall
    /// second sorted identically by `ORDER BY timestamp` and the
    /// UI message order became non-deterministic across launches.
    /// `parseISO8601` already accepts both forms so existing rows
    /// without fractional digits still decode correctly.
    static func formatISO8601(_ date: Date) -> String {
        iso8601WithFraction.string(from: date)
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
//
// Round 16 (2026-05-16) — hacker-audit finding N6.
//
// The previous version only ran `SecTrustEvaluateWithError`, which
// trusts any cert chained to a system-installed root. That means an
// MDM/enterprise CA pushed to a managed device — or a user-installed
// root profile the user was social-engineered into trusting — could
// silently decrypt every byte RAVEN ships, harvesting bearer tokens
// and chat ciphertext for offline analysis.
//
// We now do **SPKI-hash public-key pinning** on top of the system
// trust evaluation. The chain still has to be valid AND end with a
// public-key whose SHA-256 SPKI hash matches one of the values
// baked into `RavenTLSPinSet.allowed`.
//
// Why public-key pinning (not full-cert pinning):
//   • Cloud Run rotates leaf certs; pinning the leaf would force a
//     client release on every rotation.
//   • Public-key rotation is rarer and survives leaf renewal.
//   • Apple's HPKP-style guidance (`URLSessionDelegate` +
//     `SecCertificateCopyKey` + SHA-256) is the same shape we use
//     here.
//
// Rotation overlay: `RavenTLSPinSet.allowed` contains MULTIPLE
// hashes so the operations team can roll a new key, ship it to
// clients, wait for adoption, then flip the server. The set must
// always contain at least the production leaf's SPKI AND one
// queued-future key so a single rotation never breaks all clients.
//
// Failure mode: a chain that's system-valid but pins-invalid is
// rejected with `cancelAuthenticationChallenge`. The user sees a
// "network error" — same UX as any other TLS failure.
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

        // 1. System trust evaluation — chain must be valid against
        // the OS trust store.
        var error: CFError?
        let isValid = SecTrustEvaluateWithError(serverTrust, &error)
        guard isValid else {
            #if DEBUG
            print("❌ [TLS] System chain validation failed: \(error?.localizedDescription ?? "unknown")")
            #endif
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // 2. SPKI pinning. Walk the chain and verify at least one
        // certificate's SPKI hash matches our allowlist. The default
        // is to check the LEAF only (cert at index 0), but checking
        // every cert in the chain lets us pin an intermediate key
        // for extra rotation flexibility.
        if !RavenTLSPinSet.validate(serverTrust: serverTrust) {
            #if DEBUG
            print("❌ [TLS] SPKI pin mismatch — rejecting connection.")
            #endif
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}

// MARK: - Pin set
//
// Public-key SPKI SHA-256 hashes for production. The hash is
// computed as `SHA256(SubjectPublicKeyInfo DER)` — Apple's HPKP-
// equivalent encoding. To compute one yourself from the running
// server cert chain:
//
//   openssl s_client -connect raven.app:443 -showcerts < /dev/null 2>/dev/null \
//     | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' \
//     | openssl x509 -pubkey -noout \
//     | openssl pkey -pubin -outform der \
//     | openssl dgst -sha256 -binary \
//     | base64
//
// 🔴 hacker-audit 2026-05-19 — populated SPKI pin set + fixed
// key-type detection.
//
// PRE-FIX STATE: `allowed` was empty AND the SPKI computation only
// pre-pended the RSA-2048 ASN.1 header — wrong for ECDSA keys,
// which is exactly what Cloud Run serves on the leaf. So even if
// an operator had pasted the openssl-computed leaf hash into the
// set, the runtime hash would NEVER match: pinning was effectively
// off in two independent ways.
//
// THIS REVISION:
//   1. `validate(...)` now picks the correct ASN.1 SPKI header
//      based on `SecKeyCopyAttributes` (type + size). Supports
//      RSA-2048, RSA-4096, EC-P-256, EC-P-384 — covers every
//      modern Google Trust Services cert we'll ever see.
//   2. `allowed` is populated with the three SPKI hashes pulled
//      from the live production chain on 2026-05-19:
//        • Leaf  *.a.run.app  (ECDSA P-256, expires 2026-07-13)
//        • Inter GTS WR2      (RSA-2048,    expires 2029-02-20)
//        • Root  GTS Root R1  (RSA-4096,    expires 2028-01-28)
//      Any one of the three matching is enough; pinning the
//      intermediate alone defeats a "rogue CA inside the system
//      trust store" MITM (which is the actual threat). The leaf
//      is included for belt-and-suspenders during normal ops.
//   3. `enforceInProduction = true`. The Swift-side SPKI computation
//      was offline-verified to produce byte-identical hashes to the
//      openssl pipeline on all three certs in the chain (Python
//      mirror script, 2026-05-19). The intermediate (WR2) pin alone
//      survives a leaf rotation; the root (GTS R1) pin survives an
//      intermediate rotation. App is only "bricked" if ALL THREE
//      pins rotate at the same time — currently no rotation event
//      before 2028.
//      Operator's per-release checklist:
//        a. On every TestFlight build, smoke-test against prod from
//           a real device. Look at the Console for "SPKI pin
//           mismatch" — must NOT appear.
//        b. Rotate the LEAF entry every ~75 days (15 days before
//           the 90-day Cloud Run cert expiry, ~2026-06-28 for the
//           current pin). The openssl one-liner below regenerates
//           the hash. The intermediate and root pins only need to
//           be touched on multi-year boundaries.
//        c. If you ever ADD a new production region (the file used
//           to ship a Qatar failover before round-X), regenerate
//           pins for THAT host too — different region, sometimes
//           different intermediate.
//
// REGENERATION COMMAND (run from any machine with network +
// openssl; no GCP creds required):
//
//   HOST=raven-server-516053629173.europe-west1.run.app
//   echo | openssl s_client -connect $HOST:443 -servername $HOST \
//       -showcerts 2>/dev/null \
//   | awk '/BEGIN CERT/,/END CERT/' \
//   | csplit -s -f /tmp/cc -b '%02d.pem' -k - '/BEGIN CERT/' '{*}' \
//     >/dev/null 2>&1 || true
//   for f in /tmp/cc*.pem; do
//       [ -s "$f" ] && grep -q BEGIN "$f" || continue
//       openssl x509 -in "$f" -pubkey -noout \
//       | openssl pkey -pubin -outform der \
//       | openssl dgst -sha256 -binary | base64
//   done
enum RavenTLSPinSet {

    /// Production SPKI SHA-256 hashes (base64). Three-deep so that
    /// neither a leaf rotation NOR an intermediate rotation kicks
    /// users off until the next release.
    static let allowed: Set<String> = [
        // Leaf — Cloud Run *.a.run.app, ECDSA P-256
        // Captured 2026-05-19; expires 2026-07-13. Rotate by ~2026-06-28.
        "neQfZ6ISNsaLedSkSAW/nzr0z59zCA8ReK9X5zb2dZM=",

        // Intermediate — Google Trust Services WR2, RSA-2048
        // Captured 2026-05-19; expires 2029-02-20.
        "YPtHaftLw6/0vnc2BnNKGF54xiCA28WFcccjkA4ypCM=",

        // Root — GTS Root R1, RSA-4096
        // Captured 2026-05-19; expires 2028-01-28.
        "hxqRlPTu1bMS/0DITB1SSu0vd4u/8l8TjPgfaAp63Gc=",
    ]

    /// When false, pinning is reported as success even when the
    /// hash doesn't match — useful during early rollout. Set to
    /// `true` on 2026-05-19 after offline verification that the
    /// hashes above match the live production cert chain via the
    /// `swift_style_spki_hash` Python mirror (see commit notes).
    /// Defence vs. an attacker who installs a custom root CA on
    /// device (MDM, jailbreak, parental control profile) and uses
    /// it to MITM RAVEN traffic; without pin enforcement the system
    /// trust store would happily accept the rogue chain.
    static let enforceInProduction: Bool = true

    /// Run the pin check. Returns `true` when the connection is
    /// allowed; `false` when it must be rejected. An empty `allowed`
    /// set OR `enforceInProduction = false` returns `true` so a
    /// mis-configured pin doesn't brick the app — the operator must
    /// explicitly opt in.
    static func validate(serverTrust: SecTrust) -> Bool {
        guard enforceInProduction, !allowed.isEmpty else { return true }

        let count = SecTrustGetCertificateCount(serverTrust)
        for i in 0..<count {
            guard let cert = SecTrustGetCertificateAtIndex(serverTrust, i),
                  let pin = Self.spkiHash(for: cert) else { continue }
            if allowed.contains(pin) {
                return true
            }
        }
        return false
    }

    // MARK: - SPKI helpers

    /// Pre-pended bytes that turn a raw 2048-bit RSA modulus into a
    /// full SubjectPublicKeyInfo DER. Same prefix HPKP / pin-sha256
    /// uses (`openssl x509 -pubkey -noout | openssl pkey -outform der`).
    private static let rsa2048SPKIHeader: [UInt8] = [
        0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
        0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00,
    ]
    private static let rsa4096SPKIHeader: [UInt8] = [
        0x30, 0x82, 0x02, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
        0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x02, 0x0f, 0x00,
    ]
    /// EC P-256 (secp256r1 / prime256v1). The terminating `03 42 00`
    /// is the BIT STRING wrapper for the 65-byte uncompressed point
    /// `SecKeyCopyExternalRepresentation` hands back.
    private static let ecP256SPKIHeader: [UInt8] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02,
        0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
        0x42, 0x00,
    ]
    /// EC P-384 (secp384r1).
    private static let ecP384SPKIHeader: [UInt8] = [
        0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02,
        0x01, 0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00,
    ]

    /// Compute the SPKI SHA-256 base64 for a single certificate.
    /// Mirrors openssl's `x509 -pubkey -noout | pkey -outform der |
    /// dgst -sha256 -binary | base64` for the supported key types.
    /// Returns nil for unsupported types so the caller skips that
    /// chain position rather than computing a wrong hash that would
    /// silently bypass pinning if the wrong type ever sneaks in.
    private static func spkiHash(for certificate: SecCertificate) -> String? {
        guard let pubKey = SecCertificateCopyKey(certificate) else { return nil }
        var error: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(pubKey, &error) as Data? else { return nil }
        guard let attrs = SecKeyCopyAttributes(pubKey) as? [String: Any],
              let type = attrs[kSecAttrKeyType as String] as? String,
              let bits = attrs[kSecAttrKeySizeInBits as String] as? Int
        else { return nil }

        let header: [UInt8]?
        if type == (kSecAttrKeyTypeRSA as String) {
            switch bits {
            case 2048: header = rsa2048SPKIHeader
            case 4096: header = rsa4096SPKIHeader
            default:   header = nil
            }
        } else if type == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            switch bits {
            case 256: header = ecP256SPKIHeader
            case 384: header = ecP384SPKIHeader
            default:  header = nil
            }
        } else {
            header = nil
        }
        guard let hdr = header else { return nil }

        var spki = Data(hdr)
        spki.append(keyData)
        let digest = SHA256.hash(data: spki)
        return Data(digest).base64EncodedString()
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
    
    // ⚡ PERF: ETag cache — stores ETag + response data per path
    // On 304 Not Modified, returns cached data (skips download + decode)
    private var etagCache: [String: (etag: String, data: Data)] = [:]
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8   // ⚡ 8s timeout — fail fast, retry fast
        // timeoutIntervalForResource intentionally omitted — OS default (~7 days)
        // allows RAVEN+ 2 GB uploads to complete without premature cancellation
        config.waitsForConnectivity = true                 // Allow cellular radio wake-up (false causes -999)
        config.httpMaximumConnectionsPerHost = 10          // ⚡ Up from 6 — feed + API won't compete
        config.httpShouldUsePipelining = true              // ⚡ Pipeline requests on same connection
        
        // 🚨 Critical: Explicitly allow cellular/expensive/constrained access
        // Without these, iOS may block requests in Low Data Mode or on NAT64 cellular networks
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        
        // Create pinning delegate
        tlsDelegate = TLSValidationDelegate()
        
        // Use delegate for TLS chain validation
        session = URLSession(
            configuration: RavenRuntimePolicy.protectForXCTest(config),
            delegate: tlsDelegate,
            delegateQueue: nil
        )
        
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
            // PostgreSQL default: "2024-01-15 12:30:00.123456" (space instead of T)
            if let date = SharedDateFormatters.postgresTimestamp.date(from: dateString) {
                return date
            }
            if let date = SharedDateFormatters.postgresTimestampNoFraction.date(from: dateString) {
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
    
    // MARK: - Warmup

    /// Warm the TLS handshake + TCP connection on the shared session so the
    /// first real API call doesn't pay the handshake cost. ~150-300ms saved
    /// on cold start. Best-effort; silently no-ops on failure.
    func warmConnection() async {
        guard RavenRuntimePolicy.allowsExternalSideEffects else { return }
        guard let url = URL(string: "\(baseURL)/health") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            RavenTestExternalSideEffectAudit.recordActual(.http)
            _ = try await session.data(for: request)
            #if DEBUG
            print("⚡ [NetworkService] Warm connection ready (shared session)")
            #endif
        } catch {
            #if DEBUG
            print("⚠️ [NetworkService] Warmup failed: \(error.localizedDescription)")
            #endif
        }
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
            logger.debug("Token attached (scope: \(scope.rawValue, privacy: .public), len: \(token.count, privacy: .public))")
            
            // Check for restricted endpoints
            if scope == .restricted && !isAllowedForRestricted(path: path) {
                throw APIError.restricted
            }
        } else if !isPublicEndpoint(path: path) {
            // Serverless / not-logged-in: there is no bearer token, so an authed
            // endpoint would just 401 against the (now-off) server and spam the
            // logs + waste battery/network. Fail fast instead of firing a doomed
            // request — callers already treat `.unauthorized` as "no server".
            // Public auth endpoints (isPublicEndpoint) still go through.
            throw APIError.unauthorized
        }

        // Encode body
        if let body = body {
            request.httpBody = try encoder.encode(body)
        }
        
        // ⚡ PERF: Add If-None-Match for GET requests (ETag conditional request)
        if method == "GET", let cachedETag = etagCache[path]?.etag {
            request.setValue(cachedETag, forHTTPHeaderField: "If-None-Match")
        }
        
        // Execute with retry
        return try await executeWithRetry(request: request, retries: 2)  // ⚡ 2 retries (was 3) — max 20s total
    }
    
    private func executeWithRetry<T: Decodable>(
        request: URLRequest,
        retries: Int,
        currentDelay: TimeInterval = 0.4
    ) async throws -> T {
        guard RavenRuntimePolicy.allowsExternalSideEffects else {
            throw APIError.networkError(URLError(.dataNotAllowed))
        }
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
            
            RavenTestExternalSideEffectAudit.recordActual(.http)
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
                
                // ⚡ PERF: Store ETag from response for conditional requests
                if let etag = httpResponse.value(forHTTPHeaderField: "ETag"),
                   let path = request.url?.path {
                    etagCache[path] = (etag: etag, data: data)
                }
                
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
                    // ⚡ PERF: Decode on background thread — the custom date decoder tries 5 formatters
                    // per date field, which is measurable on older devices for large feed responses.
                    let localDecoder = self.decoder
                    let result: T = try await Task.detached(priority: .userInitiated) {
                        try localDecoder.decode(T.self, from: dataToDecode)
                    }.value
                    return result
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
                // Preserve the server's detail body so callers can surface
                // user-actionable messages (e.g. message-request limits,
                // privacy gates) instead of a generic "Access denied".
                let forbiddenDetail = (try? decoder.decode(ErrorResponse.self, from: data))?.detail
                if let forbiddenDetail, !forbiddenDetail.isEmpty {
                    throw APIError.httpError(403, forbiddenDetail)
                }
                throw APIError.forbidden
                
            case 404:
                throw APIError.notFound
                
            case 304:
                // ⚡ PERF: Not Modified — use cached response data
                if let path = request.url?.path,
                   let cached = etagCache[path] {
                    #if DEBUG
                    print("⚡ [NetworkService] 304 Not Modified → using cached ETag response for \(path)")
                    #endif
                    return try decoder.decode(T.self, from: cached.data)
                }
                // Shouldn't happen (304 without prior cache), treat as empty
                throw APIError.serverError
                
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
            
            // Exponential backoff for transient network errors.
            // BUG FIX (2026-05-10): only retry methods that are
            // idempotent OR that the caller explicitly tagged with an
            // `Idempotency-Key` header. The previous version blindly
            // retried POST/PUT/PATCH/DELETE on any URLError, which on
            // the unhappy path "server processed the write but the
            // response packet was lost" caused duplicate writes —
            // duplicate reactions, duplicate friend-request
            // accept/decline, duplicate registration calls. Safe set
            // of HTTP methods is GET/HEAD; PUT is idempotent if the
            // server treats it as such (which RAVEN's API does).
            let method = (request.httpMethod ?? "GET").uppercased()
            let hasIdempotencyKey = request.value(forHTTPHeaderField: "Idempotency-Key") != nil
            let safeToRetry = (method == "GET" || method == "HEAD" || method == "PUT") || hasIdempotencyKey
            if retries > 0 && safeToRetry {
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
            } else if retries > 0 && !safeToRetry {
                #if DEBUG
                print("⚠️ [NetworkService] Skipping retry for \(method) without Idempotency-Key — would risk duplicate write")
                #endif
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

    /// Endpoints that legitimately work without a bearer token (token-issuing
    /// auth + recovery). Everything else is short-circuited when no token is
    /// present so the serverless build doesn't fire doomed authed requests.
    private func isPublicEndpoint(path: String) -> Bool {
        let publicPaths = [
            "/api/auth/register",
            "/api/auth/login",
            "/api/auth/send-code",
            "/api/auth/verify-code",
            "/api/auth/resend-code",
            "/api/auth/refresh"
        ]
        return publicPaths.contains { path.hasPrefix($0) }
    }
    
    // MARK: - Token Refresh (Task-based Single-Flight)
    
    /// The in-flight refresh task. Concurrent 401s all await the SAME task,
    /// and Swift automatically handles cancellation — no continuation leak possible.
    private var activeRefreshTask: Task<Void, Error>?
    /// Generation counter — bumped on every fresh refresh start. Lets
    /// `clearActiveRefresh` confirm the slot still belongs to "our"
    /// refresh before nil-ing (cheap value-typed identity since `Task`
    /// is a struct and can't be `===`-compared).
    private var activeRefreshGeneration: UInt64 = 0
    
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

        // BUG FIX (2026-05-10): the previous version nil-ed out
        // `activeRefreshTask` inside the Task body's `defer`. While the
        // Task inherits the actor's isolation (so the assignment IS
        // actor-isolated), the defer fires BEFORE the awaiters'
        // `task.value` resolves — opening a TOCTOU window where a new
        // 401 caller arriving in that micro-window sees nil and kicks
        // a second refresh, even though the just-completed one
        // succeeded. New invariant: only nil the slot if it still
        // points to ourselves (handles cancellation + concurrent
        // restart cleanly), and do it via an explicit
        // actor-isolated helper rather than a free-standing defer.
        activeRefreshGeneration &+= 1
        let myGeneration = activeRefreshGeneration

        let task = Task<Void, Error> { [weak self] in
            do {
                try await self?.performRefresh()
            } catch {
                await self?.clearActiveRefresh(generation: myGeneration)
                throw error
            }
            await self?.clearActiveRefresh(generation: myGeneration)
        }

        activeRefreshTask = task
        do {
            try await task.value
        } catch {
            // If we threw, make sure the slot is cleared even if the
            // catch path inside the Task didn't run yet.
            clearActiveRefresh(generation: myGeneration)
            throw error
        }
        clearActiveRefresh(generation: myGeneration)
    }

    /// Actor-isolated cleanup. Compares the caller's generation against
    /// the current one and only nil-clears if they match — so a stale
    /// finalizer can't blow away the slot a fresh refresh has already
    /// claimed.
    private func clearActiveRefresh(generation: UInt64) {
        guard activeRefreshGeneration == generation else { return }
        activeRefreshTask = nil
    }
    
    /// The actual refresh network call — only ever called by one task at a time.
    ///
    /// FIX: Now throws instead of returning Bool.
    /// Network errors propagate as-is so callers know it's NOT an auth failure.
    private func performRefresh() async throws {
        guard RavenRuntimePolicy.allowsExternalSideEffects else {
            throw APIError.networkError(URLError(.dataNotAllowed))
        }
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
            RavenTestExternalSideEffectAudit.recordActual(.http)
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
        
        // 🔴 ROUND 19 — hacker-audit Server F8 HIGH.
        // Refresh-token rotation MUST be mandatory: if the server
        // omits a new refresh token (or an on-path attacker strips
        // the field) and we keep using the old one, a one-time
        // leaked refresh token grants indefinite access-token
        // reissuance. Treat the missing field as an auth failure
        // and force a sign-out.
        guard let newRefreshToken = refreshResponse.refreshToken else {
            AuthLogger.log(.tokenStoreFailed, detail: "refresh response missing refresh_token — refusing single-use semantics")
            throw APIError.unauthorized
        }
        do {
            try await KeychainService.shared.updateRefreshToken(newRefreshToken)
            AuthLogger.log(.tokenRotated)
        } catch {
            AuthLogger.log(.tokenStoreFailed, detail: "refresh token: \(error.localizedDescription)")
            throw APIError.networkError(error)
        }

        AuthLogger.log(.refreshSucceeded)
    }
}

// MARK: - QR Login (Desktop pairing)
//
// Mobile-side counterpart to the macOS app's QR-login flow. Server
// router lives at `server/routers/qr_login.py`, mobile endpoints:
//
//   • POST /api/auth/qr-login/scan    — pending → scanned (signed)
//   • POST /api/auth/qr-login/approve — scanned → approved (signed)
//   • POST /api/auth/qr-login/deny    — *      → denied
//
// All three are authed (current user). `scan` and `approve` carry an
// Ed25519 signature over a fixed-format payload — the server verifies
// it against `User.public_key` (which iOS uploads via
// `POST /api/users/me/identity-key`). See
// `Features/QRCode/DesktopLoginApprovalView.swift` for the UI.

// 🔴 Bug fix (2026-05-09): the NetworkService default encoder runs
// `convertToSnakeCase` and the default decoder runs `convertFromSnakeCase`.
// The QR-login server (`server/routers/qr_login.py`) uses literal
// camelCase keys (`sessionId`, `deviceFingerprint`, `requesterIp`,
// `expiresAt`, …). Without explicit `CodingKeys`, every request/response
// for these endpoints fails with HTTP 422 ("Field required") because
// the encoder rewrote our keys to `session_id` / `device_fingerprint`.
// The CodingKeys below pin every field to its exact camelCase wire name,
// which the encoder/decoder respect over the snake-case strategy.

struct QRScanRequest: Encodable {
    let sessionId: String
    let nonce: String
    let deviceFingerprint: String
    let timestamp: Int
    let signature: String

    enum CodingKeys: String, CodingKey {
        case sessionId, nonce, deviceFingerprint, timestamp, signature
    }
}

struct QRScanResponse: Decodable {
    let status: String
    let requesterIp: String?
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case status, requesterIp, expiresAt
    }
}

struct QRApproveRequest: Encodable {
    let sessionId: String
    let timestamp: Int
    let signature: String
    let desktopDeviceName: String
    let desktopDeviceModel: String?
    let desktopDeviceOs: String?

    enum CodingKeys: String, CodingKey {
        case sessionId, timestamp, signature
        case desktopDeviceName, desktopDeviceModel, desktopDeviceOs
    }
}

struct QRApproveResponse: Decodable {
    let status: String
}

struct QRDenyRequest: Encodable {
    let sessionId: String

    enum CodingKeys: String, CodingKey {
        case sessionId
    }
}

struct IdentityKeyRequest: Encodable {
    let publicKey: String

    enum CodingKeys: String, CodingKey {
        case publicKey
    }
}

struct IdentityKeyResponse: Decodable {
    let status: String
}

/// Server `GET /api/auth/qr-login/poll/{sid}` response shape. Used
/// by the phone in **Phase 2** to fetch the JWT it will then forward
/// to the desktop over BLE (`MeshLoginTokenEnvelope`). The fields
/// match the macOS `QrPollResponse` so the desktop's existing
/// `completeQrLogin` path consumes them unchanged.
struct QRPollResponse: Decodable {
    let status: String
    let token: String?
    let refreshToken: String?
    let userId: String?
    let username: String?

    enum CodingKeys: String, CodingKey {
        case status, token, refreshToken, userId, username
    }
}

extension NetworkService {
    /// Poll the QR-login session for its server-issued tokens. Used
    /// by the phone in Phase-2 bridging (it normally is the desktop
    /// who polls). Anonymous endpoint — no auth header required, the
    /// nonce in the query string is what authenticates the request.
    func qrLoginPoll(sessionId: String, nonce: String) async throws -> QRPollResponse {
        try await get(
            path: "/api/auth/qr-login/poll/\(sessionId)",
            queryItems: [URLQueryItem(name: "nonce", value: nonce)]
        )
    }
}

extension NetworkService {

    /// Mobile flips a desktop-initiated QR-login session from `pending`
    /// to `scanned`. Server checks: nonce match, signature over
    /// `v1|sid|nonce|deviceFp|ts` validates against `User.public_key`,
    /// timestamp within window. Returns the desktop's IP + the
    /// session's expiry so the UI can show context before approve/deny.
    func qrLoginScan(_ body: QRScanRequest) async throws -> QRScanResponse {
        // Round 16 (audit N5): signed body — don't auto-replay on 401.
        try await postCamelCase(path: "/api/auth/qr-login/scan", body: body, signedBody: true)
    }

    /// Approve the previously-scanned desktop. Server upserts a
    /// `LinkedDevice` row + flips status to `approved`; the desktop's
    /// next poll receives the access + refresh tokens.
    func qrLoginApprove(_ body: QRApproveRequest) async throws -> QRApproveResponse {
        try await postCamelCase(path: "/api/auth/qr-login/approve", body: body, signedBody: true)
    }

    /// Deny the desktop login. Idempotent — re-denying a denied
    /// session is a no-op on the server.
    func qrLoginDeny(_ body: QRDenyRequest) async throws -> Empty {
        try await postCamelCase(path: "/api/auth/qr-login/deny", body: body)
    }

    /// Upload this device's Ed25519 raw public key so the server can
    /// verify signatures from us (qr-login scan/approve, mesh bridge
    /// attestations, etc.). Idempotent — server returns
    /// `{"status":"unchanged"}` if the key matches what's already
    /// registered. iOS calls this once per session after login.
    func uploadIdentityKey(publicKeyBase64: String) async throws -> IdentityKeyResponse {
        try await postCamelCase(
            path: "/api/users/me/identity-key",
            body: IdentityKeyRequest(publicKey: publicKeyBase64)
        )
    }

    /// 🔴 Bug fix (2026-05-10): the default `post(...)` runs a
    /// JSONEncoder with `keyEncodingStrategy = .convertToSnakeCase`.
    /// **`convertToSnakeCase` is applied AFTER `CodingKeys` lookup**
    /// — meaning even the explicit `case sessionId` we set was
    /// transformed into `session_id` on the wire, which the server's
    /// strict-camelCase Pydantic models rejected with HTTP 422.
    ///
    /// `postCamelCase` builds the request manually with a vanilla
    /// `JSONEncoder` (no key strategy, ISO-8601 dates) so the JSON
    /// keys exactly match the struct's `CodingKeys` raw values. We
    /// keep the rest of the network plumbing — auth, idempotency,
    /// status handling, decoder — identical to the standard `post`
    /// path by reusing the public `get`-style decode at the end.
    /// `signedBody: true` flags this call as carrying a payload that
    /// the caller signed at a specific point in time (QR-login
    /// approve / scan, identity-key upload, etc.). When set, the
    /// 401-retry path is SUPPRESSED — re-sending the same signed
    /// bytes with a stale timestamp lets a MITM replay the signed
    /// request after token refresh. The caller is expected to catch
    /// `.unauthorized`, re-sign with a fresh timestamp, and call
    /// again. Round 16 — hacker-audit finding N5.
    func postCamelCase<T: Decodable, B: Encodable>(
        path: String,
        body: B,
        signedBody: Bool = false
    ) async throws -> T {
        guard RavenRuntimePolicy.allowsExternalSideEffects else {
            throw APIError.networkError(URLError(.dataNotAllowed))
        }
        guard let url = URL(string: baseURL + path) else {
            throw APIError.invalidURL
        }

        // Vanilla encoder: NO key strategy. CodingKeys raw values are
        // emitted verbatim — `sessionId` stays `sessionId`.
        let camelEncoder = JSONEncoder()
        camelEncoder.dateEncodingStrategy = .iso8601
        let httpBody = try camelEncoder.encode(body)

        // Build a request, attach the freshest auth token. Factored as a
        // closure so we can re-build with a refreshed token after a 401.
        let buildRequest: () async -> URLRequest = {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let (token, _) = await KeychainService.shared.getToken() {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            req.httpBody = httpBody
            return req
        }

        // Inner sender — attempts the call once and returns the response
        // pair. Pulled out so the 401 retry below doesn't duplicate the
        // request-construction code.
        func sendOnce() async throws -> (Data, HTTPURLResponse) {
            let req = await buildRequest()
            RavenTestExternalSideEffectAudit.recordActual(.http)
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.serverError
            }
            return (data, http)
        }

        var (data, http) = try await sendOnce()

        // Bug fix (2026-05-10): postCamelCase used to silently fail on a
        // mid-call token expiry — every QR-login + identity-key endpoint
        // routes through here, so a stale access token meant the user
        // saw `httpError(401, …)` with no recovery path. Mirror the
        // 401-refresh-once pattern that `executeWithRetry` uses for
        // every other endpoint: refresh the access token via the
        // refresh token, rebuild the request with the new bearer, and
        // try exactly once more. If the refresh itself fails (offline
        // or refresh-token rejected), `attemptTokenRefresh` throws the
        // appropriate error and we surface that instead of `unauthorized`.
        if http.statusCode == 401 {
            if signedBody {
                // Round 16 (audit N5): don't auto-retry a signed
                // body — the embedded timestamp is now stale and
                // replaying the same signature lets an attacker who
                // captured the first leg send a second authenticated
                // copy. Surface the 401; the caller re-signs.
                throw APIError.unauthorized
            }
            try await attemptTokenRefresh()
            (data, http) = try await sendOnce()
        }

        guard (200..<300).contains(http.statusCode) else {
            // Surface server detail when present so the UI can show
            // the actual reason instead of a generic "request failed".
            let detail: String
            if let err = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                detail = err.detail
            } else {
                detail = "HTTP \(http.statusCode)"
            }
            throw APIError.httpError(http.statusCode, detail)
        }

        // For empty 2xx responses (e.g. /qr-login/deny), return Empty
        // if the caller asked for it. Use safe `as?` instead of force
        // cast so a future caller passing a different `T` for an empty
        // body throws a decoder error instead of crashing.
        if data.isEmpty, let empty = Empty() as? T {
            return empty
        }
        return try decoder.decode(T.self, from: data)
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


// MARK: - Chat Endpoints (reactions / typing / in-thread search)

extension NetworkService {

    struct MessageReactionDTO: Codable, Equatable {
        let id: String
        let userId: String
        let emoji: String
        let createdAt: Date
        // Note: NO explicit CodingKeys — the NetworkService decoder uses
        // `.convertFromSnakeCase`, which already maps server-side
        // `user_id` → `userId` and `created_at` → `createdAt`. Adding
        // explicit `case userId = "user_id"` makes the decoder look for
        // a literal `user_id` key AFTER the strategy has already
        // transformed it to `userId`, producing a "key not found" crash.
    }

    struct ToggleReactionResponse: Decodable {
        let action: String                 // "added" | "removed"
        let reactions: [MessageReactionDTO]
    }

    /// Toggle the (user, emoji) pair on a message. The server adds the
    /// reaction if it didn't exist and removes it otherwise — no separate
    /// DELETE endpoint needed. `isGroup` switches which message table the
    /// server looks in.
    @discardableResult
    func toggleMessageReaction(
        messageId: String,
        emoji: String,
        isGroup: Bool
    ) async throws -> ToggleReactionResponse {
        struct Body: Encodable { let emoji: String; let isGroup: Bool }
        return try await post(
            path: "/api/messages/\(messageId)/reactions",
            body: Body(emoji: emoji, isGroup: isGroup)
        )
    }

    /// Fetch the current reaction list for a single message.
    func messageReactions(messageId: String, isGroup: Bool) async throws -> [MessageReactionDTO] {
        struct Wrapper: Decodable { let reactions: [MessageReactionDTO] }
        let queryItems = [URLQueryItem(name: "is_group", value: isGroup ? "true" : "false")]
        let resp: Wrapper = try await get(
            path: "/api/messages/\(messageId)/reactions",
            queryItems: queryItems
        )
        return resp.reactions
    }

    struct MessageSearchHit: Decodable, Identifiable {
        let id: String
        let senderId: String
        let content: String
        let timestamp: Date
        let editedAt: Date?
    }

    /// In-thread substring search across DM history with a peer.
    func searchThread(peerId: String, query: String, limit: Int = 50) async throws -> [MessageSearchHit] {
        struct Wrapper: Decodable { let matches: [MessageSearchHit] }
        let resp: Wrapper = try await get(
            path: "/api/messages/search",
            queryItems: [
                URLQueryItem(name: "peer_id", value: peerId),
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "limit", value: String(limit)),
            ]
        )
        return resp.matches
    }

    /// Push a typing indicator to the peer / group. Fire-and-forget — we
    /// don't surface failures because typing is purely cosmetic.
    func postTyping(peerId: String, isTyping: Bool, isGroup: Bool) async {
        struct Body: Encodable { let peerId: String; let isTyping: Bool; let isGroup: Bool }
        struct Empty: Decodable {}
        _ = try? await (post(
            path: "/api/messages/typing",
            body: Body(peerId: peerId, isTyping: isTyping, isGroup: isGroup)
        ) as Empty)
    }

    // MARK: - Pinned messages

    /// One pinned message — the shape matches the server's
    /// `PinnedMessageResponse` (snake_case via the encoder strategy).
    struct PinnedMessageDTO: Decodable, Identifiable, Equatable {
        let id: String
        let senderId: String
        let senderUsername: String?
        let senderName: String?
        let content: String?
        let messageType: String
        let audioUrl: String?
        let audioDurationSeconds: Int?
        let timestamp: Date
        let pinnedAt: Date
        let pinnedByUserId: String
    }

    struct TogglePinResponse: Decodable {
        let action: String          // "pinned" | "unpinned" | "noop"
        let pinned: Bool
        let pinnedAt: Date?
        let pinnedByUserId: String?
    }

    /// Pin or unpin a message. `pinned: true` pins, `false` unpins.
    /// Idempotent — re-pinning an already-pinned message returns
    /// `action: "noop"` but still pushes a WS event so peers re-sync.
    @discardableResult
    func toggleMessagePin(
        messageId: String,
        isGroup: Bool,
        pinned: Bool
    ) async throws -> TogglePinResponse {
        struct Body: Encodable { let isGroup: Bool; let pinned: Bool }
        return try await post(
            path: "/api/messages/\(messageId)/pin",
            body: Body(isGroup: isGroup, pinned: pinned)
        )
    }

    /// All currently pinned messages in the 1:1 thread with `peerId`,
    /// most-recently-pinned first.
    func pinnedMessagesDM(peerId: String) async throws -> [PinnedMessageDTO] {
        try await get(path: "/api/messages/conversation/\(peerId)/pinned")
    }

    /// All currently pinned messages in a group.
    func pinnedMessagesGroup(groupId: String) async throws -> [PinnedMessageDTO] {
        try await get(path: "/api/messages/group/\(groupId)/pinned")
    }

    // MARK: - Disappearing messages (per-conversation timer · v1.8)

    /// The shared disappearing-messages timer of a 1:1 conversation.
    /// `disappearingSeconds == 0` means off; otherwise every new
    /// message is auto-deleted that many seconds after it is sent.
    struct DisappearingSettingDTO: Decodable {
        let peerId: String
        let disappearingSeconds: Int
    }

    /// Read the disappearing-messages timer for the 1:1 thread with `peerId`.
    func conversationDisappearing(peerId: String) async throws -> DisappearingSettingDTO {
        try await get(path: "/api/messages/conversation/\(peerId)/disappearing")
    }

    /// Set the disappearing-messages timer for the 1:1 thread with
    /// `peerId`. `seconds` must be a server-allowed value
    /// (0, 30, 300, 3600, 28800, 86400, 604800, 2592000).
    @discardableResult
    func setConversationDisappearing(peerId: String, seconds: Int) async throws -> DisappearingSettingDTO {
        struct Body: Encodable { let seconds: Int }
        return try await put(
            path: "/api/messages/conversation/\(peerId)/disappearing",
            body: Body(seconds: seconds)
        )
    }

    // MARK: - App Attest device enrolment (v1.8)

    /// A one-time challenge nonce for an App Attest enrolment.
    struct AttestChallengeDTO: Decodable {
        let challenge: String   // base64
    }

    /// The outcome of an App Attest enrolment.
    struct AttestEnrollDTO: Decodable {
        let enrolled: Bool
        let environment: String
    }

    /// Request a fresh single-use App Attest challenge.
    func attestChallenge() async throws -> AttestChallengeDTO {
        struct Empty: Encodable {}
        return try await post(path: "/api/attest/challenge", body: Empty())
    }

    /// Submit an App Attest attestation to enrol this device's key.
    @discardableResult
    func attestEnroll(keyId: String, attestation: String,
                      challenge: String) async throws -> AttestEnrollDTO {
        struct Body: Encodable {
            let keyId: String
            let attestation: String
            let challenge: String
        }
        return try await post(
            path: "/api/attest/enroll",
            body: Body(keyId: keyId, attestation: attestation, challenge: challenge))
    }

    // MARK: - Saved messages (per-user bookmarks)

    struct SavedMessageDTO: Decodable, Identifiable, Equatable {
        /// The bookmark row id — what you DELETE against if you want to
        /// remove a single bookmark.
        let id: String
        let messageId: String
        let isGroup: Bool
        let savedAt: Date
        let senderUsername: String?
        let senderName: String?
        let content: String?
        let messageType: String
        let audioUrl: String?
        let audioDurationSeconds: Int?
        let timestamp: Date
        let peerUserId: String?
        let groupId: String?
    }

    struct SaveActionResponse: Decodable {
        let action: String  // "saved" | "removed" | "noop"
        let id: String?     // bookmark row id (only on "saved")
    }

    @discardableResult
    func saveMessage(messageId: String, isGroup: Bool) async throws -> SaveActionResponse {
        struct Body: Encodable { let isGroup: Bool }
        return try await post(
            path: "/api/messages/\(messageId)/save",
            body: Body(isGroup: isGroup)
        )
    }

    @discardableResult
    func unsaveMessage(messageId: String, isGroup: Bool) async throws -> SaveActionResponse {
        try await delete(
            path: "/api/messages/\(messageId)/save?is_group=\(isGroup ? "true" : "false")"
        )
    }

    /// Every message the current user has bookmarked. Newest-bookmark-first.
    func listSavedMessages() async throws -> [SavedMessageDTO] {
        try await get(path: "/api/messages/saved")
    }

    // MARK: - Group polls

    struct PollOptionDTO: Decodable, Identifiable, Equatable {
        let id: String
        let text: String
        let voteCount: Int
        let voters: [String]   // empty list when poll is anonymous
    }

    struct PollDTO: Decodable, Identifiable, Equatable {
        let id: String
        let groupId: String
        let creatorId: String
        let creatorName: String
        let question: String
        let options: [PollOptionDTO]
        let allowMultiple: Bool
        let isAnonymous: Bool
        let isClosed: Bool
        let totalVotes: Int
        let myVotes: [String]  // option IDs the current user has selected
        let createdAt: Date
        let expiresAt: Date?
    }

    @discardableResult
    func createPoll(
        groupId: String,
        question: String,
        options: [String],
        allowMultiple: Bool,
        isAnonymous: Bool,
        expiresInMinutes: Int?
    ) async throws -> PollDTO {
        struct Body: Encodable {
            let question: String
            let options: [String]
            let allowMultiple: Bool
            let isAnonymous: Bool
            let expiresInMinutes: Int?
        }
        return try await post(
            path: "/api/groups/\(groupId)/polls",
            body: Body(
                question: question,
                options: options,
                allowMultiple: allowMultiple,
                isAnonymous: isAnonymous,
                expiresInMinutes: expiresInMinutes
            )
        )
    }

    func listPolls(groupId: String) async throws -> [PollDTO] {
        try await get(path: "/api/groups/\(groupId)/polls")
    }

    func getPoll(groupId: String, pollId: String) async throws -> PollDTO {
        try await get(path: "/api/groups/\(groupId)/polls/\(pollId)")
    }

    @discardableResult
    func votePoll(groupId: String, pollId: String, optionId: String) async throws -> PollDTO {
        struct Body: Encodable { let optionId: String }
        return try await post(
            path: "/api/groups/\(groupId)/polls/\(pollId)/vote",
            body: Body(optionId: optionId)
        )
    }

    @discardableResult
    func closePoll(groupId: String, pollId: String) async throws -> PollDTO {
        struct Empty: Encodable {}
        return try await post(
            path: "/api/groups/\(groupId)/polls/\(pollId)/close",
            body: Empty()
        )
    }
}
