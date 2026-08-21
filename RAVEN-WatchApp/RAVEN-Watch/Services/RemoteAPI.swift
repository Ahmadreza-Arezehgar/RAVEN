// RemoteAPI.swift
//
// Standalone-LTE fallback for cellular Apple Watch (Series 4+) when the
// paired iPhone is unreachable. Hits the same FastAPI server every
// other RAVEN client uses; reuses the auth token stored in the shared
// App Group keychain (the iPhone writes it there at sign-in time).
//
// What this gives up vs. going through the phone:
//
//   • No mesh path — the Watch can't BLE-broadcast or relay. If the
//     server is also unreachable the send fails. The phone-routed path
//     would have queued onto BLE/MPC/bridge automatically.
//   • No E2E mesh encryption layer — sends here go server-only TLS,
//     which is still encrypted in transit but doesn't carry the mesh
//     envelope's Ed25519 signature chain. The server tags messages from
//     this path so receivers can show a "sent via watch (online)"
//     subtle badge if desired.
//
// What it preserves:
//
//   • Authoritative reach — if the network is up, the message lands.
//   • Same server contract as every other client, so cross-platform
//     compatibility (Mac/Windows/Android receivers) is automatic.

import Foundation

actor RemoteAPI {
    static let shared = RemoteAPI()

    /// Override at build time for staging.
    private let baseURL = URL(string: "https://api.raven-messager.com")!
    private let groupId = "group.app.raven.shared"
    /// Pulled from the App Group container that the iPhone writes after
    /// sign-in. The Watch never owns credentials — only borrows them.
    ///
    /// 🔴 ROUND 26 — hacker-audit MESH-HIGH-3.
    ///   Only the encrypted variant (`raven.auth.token.enc`) is accepted.
    ///   Before the iPhone ships the wrap key via WCSession, standalone LTE
    ///   sends fail closed to the phone-mediated queue.
    private var token: String? {
        get async {
            guard let base = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: groupId)
            else { return nil }
            let url = base.appendingPathComponent("auth.json")
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            // Encrypted path (round 26+).
            if let enc = obj["raven.auth.token.enc"] as? String,
               let decrypted = await WatchAuthKeyStore.shared.decryptToken(base64Blob: enc) {
                return decrypted
            }
            // 🔴 hacker-audit 2026-05-19 — legacy plaintext path REMOVED.
            //
            // PREVIOUSLY this fell back to `obj["raven.auth.token"]`
            // (plaintext bearer token in app-group JSON) when the
            // encrypted variant wasn't present. The fallback was
            // documented as a "kept until the fleet upgrades" shim, but
            // it left every fresh install vulnerable until the first
            // WCSession sync delivered the wrap key. A jailbroken watch
            // or a malicious app sharing the app-group could read the
            // plaintext token off disk in seconds.
            //
            // Now we refuse standalone sends until the encrypted token
            // is available. The watch falls through to phone-mediated
            // sends (PhoneBridge) instead, which is the safer default
            // — the phone is the credential authority by design.
            return nil
        }
    }

    enum APIError: Error, LocalizedError {
        case noAuth, transport(Error), status(Int)
        var errorDescription: String? {
            switch self {
            case .noAuth: return "Watch is not signed in (pair with iPhone first)."
            case .transport(let e): return e.localizedDescription
            case .status(let code): return "Server returned \(code)."
            }
        }
    }

    /// Online-only DM send. Used by `ComposeReplyView` when
    /// `PhoneBridge.isReachable == false` AND the Watch has its own
    /// network path (cellular or saved Wi-Fi). Falls back to a queued
    /// userInfo on the bridge if both paths fail.
    func sendDM(recipientId: String, text: String, clientMessageId: String) async throws {
        guard let token = await token else { throw APIError.noAuth }

        var req = URLRequest(url: baseURL.appendingPathComponent("/api/messages/send"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("watchos", forHTTPHeaderField: "X-Raven-Client")

        let body: [String: Any] = [
            "recipient_id": recipientId,
            "text": text,
            "client_message_id": clientMessageId,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw APIError.transport(URLError(.badServerResponse)) }
            guard (200..<300).contains(http.statusCode) else { throw APIError.status(http.statusCode) }
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.transport(error)
        }
    }

}
