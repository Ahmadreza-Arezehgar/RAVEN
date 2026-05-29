// RealtimeEngine — keeps an inbox WebSocket open to the FastAPI backend
// so iPhones, the Catalyst DMG build, and the Flutter clients can push
// messages to this Mac in real time, instead of forcing the user to
// pull-to-refresh.
//
// Transport stack (mirrors the iOS production app's RealtimeEngine):
//
//   1. Primary: `wss://<host>/ws/inbox?token=<JWT>` — server fans out
//      new DMs, group messages, edits, reactions, typing, room events
//      and bridge envelopes pushed by mesh bridges over a single channel.
//
//   2. Fallback: `GET /api/messages/inbox?since=<iso>` polled every 30s.
//      Engaged when the WS hasn't connected yet, between reconnect
//      attempts, or after the retry budget is exhausted.
//
//   3. Bridge drain: on every successful WS connect (and on cold start),
//      we ask the server for any `/api/mesh/pending-bridges` envelopes
//      stashed by mesh devices while we were offline. The Mac App Store
//      build can't itself participate in BLE mesh, but it CAN be the
//      online recipient that picks up bridged messages — that's the
//      "bridge mode (server-routed)" the README claims and what this
//      module finally implements.
//
// The engine fans incoming events out via NotificationCenter so the
// chat list / thread views can react without owning network state. See
// the `Notification.Name` block at the bottom of this file for the wire.

import Foundation
import AppKit
import Combine

@MainActor
final class RealtimeEngine: ObservableObject {
    static let shared = RealtimeEngine()

    enum ConnectionState: String {
        case disconnected
        case connecting
        case websocket
        case polling
    }

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var lastSyncTime: Date?

    // Polling fallback
    private var pollingTimer: Timer?
    private let pollingInterval: TimeInterval = 30
    private var lastInboxTimestamp: Date?
    private var isPollingInFlight = false

    // WebSocket
    private static let wsSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.allowsExpensiveNetworkAccess = true
        cfg.allowsConstrainedNetworkAccess = true
        return URLSession(configuration: cfg, delegate: nil, delegateQueue: nil)
    }()
    private var webSocketTask: URLSessionWebSocketTask?
    private var wsPingTimer: Timer?
    private var wsReconnectAttempts = 0
    private let maxWsReconnectAttempts = 10
    private var isWebSocketConnected = false

    // Wake / network observers — kept so we can tear them down if the
    // engine is ever stopped permanently (e.g. on sign-out).
    private var didWakeObserver: NSObjectProtocol?
    private var willSleepObserver: NSObjectProtocol?

    private init() {
        setupLifecycleObservers()
        setupMeshObserver()
    }

    /// Convert incoming `MeshEnvelope`s from the BLE engine into normal
    /// `Message` rows so the chat UI lights up the same way regardless
    /// of transport. Same `ravenInboxMessagesReceived` notification used
    /// by the WebSocket path.
    private func setupMeshObserver() {
        NotificationCenter.default.addObserver(
            forName: .ravenMeshEnvelopeReceived,
            object: nil,
            queue: .main
        ) { note in
            guard let env = note.userInfo?["envelope"] as? MeshEnvelope else { return }
            let message = Message.fromMeshEnvelope(env)
            NotificationCenter.default.post(
                name: .ravenInboxMessagesReceived,
                object: nil,
                userInfo: ["messages": [message]]
            )
        }
    }

    // No deinit: this is a singleton (`static let shared`) wired into
    // `NSWorkspace.shared.notificationCenter`. It outlives the
    // application, so cleanup would never run. Skipping the deinit also
    // avoids the Swift 6 warning about touching MainActor-isolated
    // observer tokens from a nonisolated deinit.

    // MARK: - Public lifecycle

    /// Begin running. Idempotent — calling twice is a no-op.
    func start() {
        guard connectionState == .disconnected else { return }
        connectionState = .connecting
        connectWebSocket()
        startPolling()  // safety net; gets stopped once WS lands
        // Drain any envelopes that piled up while we were offline.
        Task { await MeshBridgeReceiver.shared.drainPendingBridges() }
    }

    /// Tear everything down — called from `AuthService.signOut`.
    func stop() {
        disconnectWebSocket(intentional: true)
        stopPolling()
        connectionState = .disconnected
        wsReconnectAttempts = 0
    }

    /// Force a fresh poll — invoked after the user pulls to refresh.
    func syncNow() async {
        await pollInbox()
    }

    // MARK: - Lifecycle observers

    private func setupLifecycleObservers() {
        // macOS apps stay running while the window is hidden, so we
        // don't tear down the WS on background. We DO want to reconnect
        // after the system wakes from sleep — Cloud Run drops idle
        // sockets after a few minutes of suspension.
        let nc = NSWorkspace.shared.notificationCenter
        didWakeObserver = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.connectionState != .disconnected else { return }
                #if DEBUG
                print("[realtime] system woke — reconnecting WS")
                #endif
                self.disconnectWebSocket(intentional: false)
                self.wsReconnectAttempts = 0
                self.connectWebSocket()
            }
        }
        willSleepObserver = nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.disconnectWebSocket(intentional: true)
            }
        }
    }

    // MARK: - WebSocket

    private func connectWebSocket() {
        // Don't stack tasks if a previous one is still around.
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        guard
            let token = KeychainService.shared.read(.accessToken),
            !token.isEmpty
        else {
            #if DEBUG
            print("[realtime] no access token — staying on polling")
            #endif
            connectionState = .polling
            return
        }

        // Build wss URL from the shared base host constant
        // (`ravenAPIBaseURL` in NetworkService.swift). We don't go
        // through the `NetworkService` actor here because we need the
        // URL synchronously, and pre-fork-2024 a stringly-typed copy
        // here let the two paths drift silently when the host changed.
        guard var comps = URLComponents(url: ravenAPIBaseURL, resolvingAgainstBaseURL: false) else {
            connectionState = .polling
            return
        }
        comps.scheme = "wss"
        comps.path = "/ws/inbox"
        comps.queryItems = [URLQueryItem(name: "token", value: token)]

        guard let wsURL = comps.url else {
            connectionState = .polling
            return
        }

        #if DEBUG
        print("[realtime] connecting WS to \(wsURL.host ?? "?")")
        #endif

        let task = Self.wsSession.webSocketTask(with: wsURL)
        webSocketTask = task
        task.resume()
        receiveLoop(task: task)
        startPingTimer()
    }

    private func receiveLoop(task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                // Only act on the in-flight task — late completions from a
                // cancelled previous socket would otherwise re-trigger
                // disconnects on a fresh one.
                guard self.webSocketTask === task else { return }

                switch result {
                case .success(let message):
                    self.handleIncoming(message)
                    self.receiveLoop(task: task)
                case .failure(let err):
                    #if DEBUG
                    print("[realtime] WS receive error: \(err.localizedDescription)")
                    #endif
                    self.handleDisconnect()
                }
            }
        }
    }

    private func handleIncoming(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            guard let d = text.data(using: .utf8) else { return }
            data = d
        case .data(let d):
            data = d
        @unknown default:
            return
        }

        // First time we receive any frame, mark the WS as live and stop
        // the polling fallback.
        if !isWebSocketConnected {
            isWebSocketConnected = true
            wsReconnectAttempts = 0
            connectionState = .websocket
            stopPolling()
            // Drain envelopes that piled up while the WS was down.
            Task { await MeshBridgeReceiver.shared.drainPendingBridges() }
            #if DEBUG
            print("[realtime] WS live — polling stopped")
            #endif
        }

        // The server multiplexes several message shapes on the same
        // channel. We sniff the JSON root before committing to a strict
        // decode. Three cases:
        //   1. JSON array of message objects — incoming DMs / group
        //      messages. Fan out to chat list + thread.
        //   2. JSON object with `type` — typed sidecar event (edited,
        //      typing, room, bridge envelope, …).
        //   3. Anything else — control frame, ignored.
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            handleMessageBatch(array, raw: data)
            return
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            handleTypedEvent(json, raw: data)
            return
        }
    }

    private func handleMessageBatch(_ array: [[String: Any]], raw: Data) {
        // Decode through the existing `Message` type so we get the same
        // ciphertext detection / display-content logic as the rest of
        // the app. Per-element try? so a single broken row doesn't drop
        // the batch.
        let decoder = makeDecoder()
        var decoded: [Message] = []
        for obj in array {
            guard let item = try? JSONSerialization.data(withJSONObject: obj),
                  let msg = try? decoder.decode(Message.self, from: item)
            else { continue }
            decoded.append(msg)
        }
        guard !decoded.isEmpty else { return }
        if let latest = decoded.map(\.timestamp).max() {
            lastInboxTimestamp = latest
        }
        lastSyncTime = Date()
        NotificationCenter.default.post(
            name: .ravenInboxMessagesReceived,
            object: nil,
            userInfo: ["messages": decoded]
        )
    }

    private func handleTypedEvent(_ json: [String: Any], raw: Data) {
        guard let typeStr = json["type"] as? String else { return }
        switch typeStr {
        case "message_edited":
            NotificationCenter.default.post(
                name: .ravenMessageEdited,
                object: nil,
                userInfo: json
            )
        case "message_deleted":
            NotificationCenter.default.post(
                name: .ravenMessageDeleted,
                object: nil,
                userInfo: json
            )
        case "message_reaction":
            NotificationCenter.default.post(
                name: .ravenMessageReaction,
                object: nil,
                userInfo: json
            )
        case "message_seen":
            NotificationCenter.default.post(
                name: .ravenMessageSeen,
                object: nil,
                userInfo: json
            )
        case "typing":
            NotificationCenter.default.post(
                name: .ravenTyping,
                object: nil,
                userInfo: json
            )
        case "message_pinned":
            NotificationCenter.default.post(
                name: .ravenMessagePinned,
                object: nil,
                userInfo: json
            )
        case "bridge_envelope", "bridge.envelope":
            // Server pushes a bridge envelope inline. Forward to the
            // mesh receiver, which dedups on idempotency_key.
            if let envelope = json["envelope_b64"] as? String,
               let key = json["idempotency_key"] as? String {
                Task {
                    await MeshBridgeReceiver.shared.ingest(
                        envelopeB64: envelope,
                        idempotencyKey: key,
                        bridgedAt: Date()
                    )
                }
            }
        default:
            // Unknown event types are forwarded under a generic name so
            // future features (room events, presence, …) can subscribe
            // without us having to ship a Mac update first.
            NotificationCenter.default.post(
                name: .ravenUnknownInboxEvent,
                object: nil,
                userInfo: json
            )
        }
    }

    private func startPingTimer() {
        wsPingTimer?.invalidate()
        // Cloud Run's HTTP/2 LB drops idle TCP after ~10 min. 30s pings
        // keep the path warm and surface half-open sockets fast.
        wsPingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let task = self.webSocketTask else { return }
                task.sendPing { [weak self] error in
                    if error != nil {
                        Task { @MainActor in self?.handleDisconnect() }
                    }
                }
            }
        }
    }

    private func handleDisconnect() {
        guard webSocketTask != nil else { return }
        isWebSocketConnected = false
        wsPingTimer?.invalidate()
        wsPingTimer = nil
        webSocketTask = nil

        // Drop back onto polling immediately so the user is not stuck
        // refreshing manually during the reconnect backoff.
        if connectionState != .disconnected {
            connectionState = .polling
            startPolling()
        }

        guard wsReconnectAttempts < maxWsReconnectAttempts else {
            #if DEBUG
            print("[realtime] reconnect budget exhausted — staying on polling")
            #endif
            return
        }
        wsReconnectAttempts += 1
        let delay = min(pow(2.0, Double(wsReconnectAttempts)), 30.0)
        #if DEBUG
        print("[realtime] reconnect in \(delay)s (attempt \(wsReconnectAttempts))")
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor in
                guard let self, self.connectionState != .disconnected else { return }
                self.connectWebSocket()
            }
        }
    }

    private func disconnectWebSocket(intentional: Bool) {
        wsPingTimer?.invalidate()
        wsPingTimer = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isWebSocketConnected = false
        if intentional {
            wsReconnectAttempts = maxWsReconnectAttempts // suppress backoff
        }
    }

    // MARK: - Polling fallback

    private func startPolling() {
        stopPolling()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            Task { await self?.pollInbox() }
        }
        // Kick one off immediately so the user sees state on first launch
        // without waiting 30s.
        Task { await pollInbox() }
    }

    private func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    private func pollInbox() async {
        guard !isPollingInFlight else { return }
        guard !isWebSocketConnected else { return }  // WS owns delivery
        isPollingInFlight = true
        defer { isPollingInFlight = false }

        do {
            let messages = try await NetworkService.shared.inboxMessages(since: lastInboxTimestamp)
            if let latest = messages.map(\.timestamp).max() {
                lastInboxTimestamp = latest
            }
            lastSyncTime = Date()
            if !messages.isEmpty {
                NotificationCenter.default.post(
                    name: .ravenInboxMessagesReceived,
                    object: nil,
                    userInfo: ["messages": messages]
                )
            }
        } catch APIError.authExpired {
            // Token died — let AuthService handle the redirect; just
            // pause realtime for now.
            connectionState = .disconnected
            stopPolling()
        } catch {
            #if DEBUG
            print("[realtime] poll failed: \(error)")
            #endif
        }
    }

    // MARK: - JSON

    private func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let secs = try? c.decode(Double.self) {
                return Date(timeIntervalSince1970: secs)
            }
            let raw = try c.decode(String.self)
            // FastAPI emits microseconds (6 digits); chop to 3 so the
            // formatters can parse, and bridge ` ` → `T` for the naive
            // shape the server occasionally returns.
            var s = raw
            if let dot = s.firstIndex(of: ".") {
                var idx = s.index(after: dot)
                while idx < s.endIndex, s[idx].isNumber { idx = s.index(after: idx) }
                let digits = s.distance(from: s.index(after: dot), to: idx)
                if digits > 3 {
                    let keep = s.index(s.index(after: dot), offsetBy: 3)
                    s = String(s[..<keep]) + String(s[idx...])
                }
            }
            if s.contains(" ") && !s.contains("T") {
                s = s.replacingOccurrences(of: " ", with: "T")
            }
            // Static, file-scope formatters — the @Sendable decode
            // closure can't capture local ISO8601DateFormatter instances
            // (non-Sendable) without tripping a Swift 6 warning. Keeping
            // them as nonisolated(unsafe) globals is the documented
            // pattern for stateless formatter reuse.
            if let v = RealtimeDateFormatters.isoFractional.date(from: s) { return v }
            if let v = RealtimeDateFormatters.iso.date(from: s) { return v }
            if let v = RealtimeDateFormatters.naive.date(from: s) { return v }
            if let v = RealtimeDateFormatters.naiveSeconds.date(from: s) { return v }
            throw DecodingError.dataCorruptedError(
                in: c,
                debugDescription: "Unrecognized date: \(raw)"
            )
        }
        return d
    }
}

/// File-scope formatter cache. Apple's `ISO8601DateFormatter` and
/// `DateFormatter` are non-Sendable so capturing them in a `@Sendable`
/// closure (which is what `JSONDecoder.dateDecodingStrategy.custom`
/// requires) warns. Statics with `nonisolated(unsafe)` is the standard
/// workaround — both formatters are documented as thread-safe for read
/// after configuration.
private enum RealtimeDateFormatters {
    nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    // DateFormatter is Sendable in current SDKs, so plain `static let`
    // is sufficient here. Only the ISO8601 variants above still need
    // `nonisolated(unsafe)`.
    static let naive: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return f
    }()
    static let naiveSeconds: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()
}

// MARK: - NotificationCenter wire

extension Notification.Name {
    /// Fired when one or more `Message` objects arrive — either via the
    /// `/ws/inbox` WebSocket or the `/api/messages/inbox` poll fallback.
    /// `userInfo["messages"]` is `[Message]`.
    static let ravenInboxMessagesReceived = Notification.Name("RavenInboxMessagesReceived")

    /// Server pushed a `message_edited` event; full server JSON in
    /// `userInfo`.
    static let ravenMessageEdited = Notification.Name("RavenMessageEdited")
    /// Server pushed a `message_deleted` event; full server JSON in
    /// `userInfo`.
    static let ravenMessageDeleted = Notification.Name("RavenMessageDeleted")
    /// Server pushed a `message_reaction` event.
    static let ravenMessageReaction = Notification.Name("RavenMessageReaction")
    /// Server pushed a `message_seen` (read receipt) event.
    static let ravenMessageSeen = Notification.Name("RavenMessageSeen")
    /// Server pushed a `typing` event.
    static let ravenTyping = Notification.Name("RavenTyping")
    /// Generic catch-all for typed inbox events the Mac shell doesn't
    /// model yet (room events, presence, …).
    static let ravenUnknownInboxEvent = Notification.Name("RavenUnknownInboxEvent")

    /// `MeshBridgeReceiver` finished draining a batch of bridge envelopes
    /// from `/api/mesh/pending-bridges` (or the WS inline push). The
    /// userInfo dict carries `count: Int` so the chat list can re-fetch
    /// `/api/messages/conversations` to surface anything the server has
    /// since promoted into a real message row.
    static let ravenMeshBridgesDrained = Notification.Name("RavenMeshBridgesDrained")

    /// One bridge envelope was successfully decrypted + signature-checked
    /// by `MeshBridgeReceiver`'s default crypto handler. UserInfo:
    ///   • "envelope" — the plaintext `MeshEnvelope`
    ///   • "signatureValid" — `Bool` (false means decrypt worked but
    ///     the inner Ed25519 signature didn't validate; UI should warn)
    ///   • "idempotencyKey" — `String` for cross-deduplication if the
    ///     same plaintext arrives again via a different transport
    /// Posted on the main thread.
    static let ravenMeshBridgeDecrypted = Notification.Name("RavenMeshBridgeDecrypted")
}
