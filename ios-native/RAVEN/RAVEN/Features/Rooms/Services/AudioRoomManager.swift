import SwiftUI
import Combine
import LiveKit
import AVFoundation

// MARK: - LiveKit Audio Manager

/// Manager for LiveKit audio room connections
@MainActor
class AudioRoomManager: ObservableObject {
    static let shared = AudioRoomManager()
    
    // Connection state
    @Published var isConnecting = false
    @Published var isConnected = false
    @Published var connectionError: String?
    
    // Audio state
    @Published var isMicEnabled = false
    @Published var audioLevel: Float = 0
    
    // Participants with audio levels
    @Published var speakingParticipants: Set<String> = []
    @Published var remoteParticipants: [RemoteParticipant] = []
    /// Continuous audio level per participant (keyed by `participant.identity`,
    /// i.e. the user_id from the JWT `sub` claim). Range [0.0 … 1.0].
    /// Powers the waveform meter on the speaker tiles. Updated 10×/s while
    /// connected; cleared on disconnect.
    @Published var audioLevels: [String: Float] = [:]
    private var audioLevelPollTask: Task<Void, Never>?
    
    // Debug logs
    @Published var debugLogs: [String] = []
    
    // LiveKit Room
    private var room: Room?
    private var roomId: String?
    
    // Bug 3 fix: heartbeat — uses a Task.sleep loop instead of Timer so it
    // keeps firing even when the main run-loop is busy with animations.
    // Was `Timer.scheduledTimer` on main → during a heavy SwiftUI transition
    // the heartbeat would skip and the server would mark the participant
    // stale (auto-removed after 30 s).
    private var heartbeatTask: Task<Void, Never>?
    private let heartbeatInterval: UInt64 = 15_000_000_000  // 15 s in nanoseconds

    // Last participant name used for the connection — needed by refreshToken
    // when a server WS event tells us the role changed.
    private var lastParticipantName: String?

    private var interruptionObserver: NSObjectProtocol?
    
    private init() {
        log("🔧 AudioRoomManager initialized")
        // Observe audio session interruptions (phone calls, alarms, Siri)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleAudioInterruption(notification)
            }
        }
    }
    
    private func handleAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        
        CrashGuard.shared.log(.audio, "Audio interruption", metadata: [
            "type": type == .began ? "began" : "ended",
            "roomId": roomId ?? "none"
        ])
        
        switch type {
        case .began:
            if isMicEnabled {
                log("⚠️ Audio interrupted — muting mic")
                Task { try? await setMicrophone(enabled: false) }
            }
        case .ended:
            // FIX: Only reactivate if we're actually in a voice room.
            // AudioRoomManager is a singleton — this handler fires for ALL interruptions,
            // even when the user is just texting. Without this guard, ending a phone call
            // would hijack audio to HFP voice chat mode, degrading quality & killing Spotify.
            guard self.room != nil else { return }
            
            // FIX: Reactivate session on background thread — setActive(true) can
            // block 1–3s with Bluetooth headphones, freezing the entire UI.
            Task.detached(priority: .userInitiated) {
                let session = AVAudioSession.sharedInstance()
                try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
                try? session.setActive(true)
            }
            log("▶️ Audio interruption ended — session reactivating on background")
        @unknown default:
            break
        }
    }
    
    // MARK: - Debug Logging
    
    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logMessage = "[\(timestamp)] \(message)"
        #if DEBUG
        print(logMessage)
        // Only mutate the @Published debugLogs in DEBUG. In release, every log
        // call was triggering a SwiftUI re-render of any view observing
        // `audioManager` — wasted CPU + battery during long rooms.
        debugLogs.append(logMessage)
        if debugLogs.count > 50 {
            debugLogs.removeFirst()
        }
        #endif
    }
    
    // MARK: - Token Request
    
    struct TokenResponse: Codable {
        let token: String
        let url: String
    }
    
    /// Get LiveKit token from server
    func fetchToken(roomId: String, participantName: String) async throws -> TokenResponse {
        log("📡 STEP 1: Fetching token from server...")
        log("   Room ID: \(roomId)")
        log("   Participant: \(participantName)")
        
        struct TokenRequest: Codable {
            let roomId: String
            let participantName: String
        }
        
        let request = TokenRequest(roomId: roomId, participantName: participantName)
        
        do {
            let response: TokenResponse = try await NetworkService.shared.post(
                path: "/api/livekit/token",
                body: request
            )
            
            log("✅ STEP 1 SUCCESS: Got token!")
            log("   URL: \(response.url)")
            log("   Token length: \(response.token.count) chars")
            
            return response
        } catch {
            log("❌ STEP 1 FAILED: Token fetch error: \(error)")
            throw error
        }
    }
    
    // MARK: - Connect/Disconnect
    
    /// Connect to a LiveKit audio room
    func connect(roomId: String, participantName: String) async throws {
        // 🛡️ Prevent double-connect: if user rapid-taps "Join", the first Room()
        // would be overwritten and leak forever (zombie connection with open mic).
        guard !isConnecting, self.room == nil else {
            log("⚠️ CONNECT REJECTED — already connecting or connected")
            return
        }
        
        log("🚀 CONNECT STARTED for room: \(roomId)")
        CrashGuard.shared.log(.audio, "AudioRoom connecting", metadata: [
            "roomId": roomId,
            "participant": participantName
        ])
        
        self.roomId = roomId
        isConnecting = true
        connectionError = nil
        
        defer { 
            isConnecting = false 
            log("🔄 Connect process finished. isConnected: \(isConnected)")
        }
        
        do {
            // STEP 0: Check microphone permission
            log("🎤 STEP 0: Checking microphone permission...")
            let granted = await requestMicrophonePermission()
            if granted {
                log("✅ STEP 0 SUCCESS: Microphone permission granted")
            } else {
                log("❌ STEP 0 FAILED: Microphone permission DENIED")
                connectionError = "Microphone permission denied"
                throw NSError(domain: "AudioRoomManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"])
            }
            
            // STEP 0.5: Configure AVAudioSession for voice chat BEFORE LiveKit connects
            log("🔊 STEP 0.5: Configuring AVAudioSession...")
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
                // ⚡ FIX: setActive is blocking (0.5-3s with Bluetooth) — run on background
                await Task.detached(priority: .userInitiated) {
                    try? session.setActive(true)
                }.value
                log("✅ STEP 0.5 SUCCESS: AVAudioSession configured (playAndRecord, voiceChat)")
            } catch {
                log("⚠️ STEP 0.5: AVAudioSession config failed (non-fatal): \(error)")
                // Non-fatal — LiveKit will attempt its own session setup
            }
            
            // STEP 1: Get token from server
            self.lastParticipantName = participantName  // remember for refreshToken
            let tokenResponse = try await fetchToken(roomId: roomId, participantName: participantName)
            
            // STEP 2: Create Room object
            log("🏠 STEP 2: Creating LiveKit Room object...")
            let room = Room()
            self.room = room
            room.add(delegate: self)
            log("✅ STEP 2 SUCCESS: Room object created, delegate set")
            
            // STEP 3: Configure connection options
            log("⚙️ STEP 3: Configuring connection options...")
            let connectOptions = ConnectOptions(
                autoSubscribe: true
            )
            
            let roomOptions = RoomOptions(
                defaultCameraCaptureOptions: CameraCaptureOptions(),
                defaultScreenShareCaptureOptions: ScreenShareCaptureOptions(),
                defaultVideoPublishOptions: VideoPublishOptions(),
                defaultAudioPublishOptions: AudioPublishOptions()
            )
            log("✅ STEP 3 SUCCESS: Options configured (autoSubscribe: true)")
            
            // STEP 4: Connect to LiveKit server
            log("🌐 STEP 4: Connecting to LiveKit server...")
            log("   URL: \(tokenResponse.url)")
            
            try await room.connect(
                url: tokenResponse.url,
                token: tokenResponse.token,
                connectOptions: connectOptions,
                roomOptions: roomOptions
            )
            
            log("✅ STEP 4 SUCCESS: Connected to LiveKit!")
            log("   Room name: \(room.name ?? "unknown")")
            log("   Local participant: \(room.localParticipant.identity?.stringValue ?? "unknown")")
            log("   Remote participants: \(room.remoteParticipants.count)")
            
            // STEP 5: Disable camera (audio-only)
            log("📷 STEP 5: Disabling camera (audio-only mode)...")
            try await room.localParticipant.setCamera(enabled: false)
            log("✅ STEP 5 SUCCESS: Camera disabled")
            
            // STEP 6: Initially mute mic
            log("🔇 STEP 6: Setting mic initially muted...")
            try await room.localParticipant.setMicrophone(enabled: false)
            log("✅ STEP 6 SUCCESS: Mic initially muted")
            
            isConnected = true
            CrashGuard.shared.log(.audio, "AudioRoom connected", metadata: ["roomId": roomId])
            log("🎉 ALL STEPS COMPLETE! Room connected successfully!")
            
            // Bug 3 fix: start heartbeat timer so server knows we're still alive
            startHeartbeat()
            
        } catch {
            connectionError = error.localizedDescription
            CrashGuard.shared.log(.error, "AudioRoom connect failed", metadata: [
                "roomId": roomId,
                "error": error.localizedDescription
            ])
            log("💥 CONNECTION FAILED: \(error)")
            log("   Error type: \(type(of: error))")
            log("   Description: \(error.localizedDescription)")
            
            // Bug fix: Deactivate audio session on connection failure
            // Without this, the device stays in .voiceChat mode permanently,
            // muting music playback and routing audio through the earpiece.
            Task.detached(priority: .userInitiated) {
                let session = AVAudioSession.sharedInstance()
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                try? session.setCategory(.playback, mode: .default)
            }
            self.room = nil
            
            throw error
        }
    }
    
    /// Disconnect from current room
    func disconnect() async {
        log("👋 Disconnecting from room...")
        CrashGuard.shared.log(.audio, "AudioRoom disconnecting", metadata: ["roomId": roomId ?? "none"])
        await room?.disconnect()
        room = nil
        roomId = nil
        isConnected = false
        isMicEnabled = false
        speakingParticipants.removeAll()
        remoteParticipants.removeAll()
        AudioRoomActivityManager.shared.endActivity()
        
        // Release the microphone hardware. Errors are already swallowed by
        // `try?` inside the detached task, so no enclosing do/catch needed.
        // ⚡ FIX: setActive is blocking — run on background
        await Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? session.setCategory(.playback, mode: .default)
        }.value
        
        // Bug 3 fix: stop heartbeat timer
        stopHeartbeat()
        
        log("✅ Disconnected")
    }
    
    // MARK: - Heartbeat (Bug 3 fix)
    
    /// Start sending heartbeats to the server every 15s so the server knows
    /// this participant is still active (server removes stale participants after 30s).
    private func startHeartbeat() {
        stopHeartbeat()
        guard let rid = roomId else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.heartbeatInterval ?? 15_000_000_000)
                if Task.isCancelled { break }
                await self?.sendHeartbeat(roomId: rid)
            }
        }
        log("💓 Heartbeat started (Task loop, every 15 s)")
        startAudioLevelPolling()
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        stopAudioLevelPolling()
    }

    // MARK: - Audio Level Polling (drives waveform meter)
    //
    // LiveKit publishes an `audioLevel: Float` on each Participant that
    // updates as the SDK measures the incoming audio. We poll 10×/s and
    // expose it as `audioLevels[identity]` for the SpeakerBubble waveform.
    // Cheaper than rendering N CADisplayLink animators per tile.

    private func startAudioLevelPolling() {
        audioLevelPollTask?.cancel()
        audioLevelPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms = 10 fps
                if Task.isCancelled { break }
                await self?.sampleAudioLevels()
            }
        }
    }

    private func stopAudioLevelPolling() {
        audioLevelPollTask?.cancel()
        audioLevelPollTask = nil
        audioLevels.removeAll()
    }

    private func sampleAudioLevels() async {
        guard let room = self.room else { return }
        var snapshot: [String: Float] = [:]
        // Local participant
        if let id = room.localParticipant.identity?.stringValue {
            snapshot[id] = Float(room.localParticipant.audioLevel)
        }
        // Remote participants
        for p in room.remoteParticipants.values {
            if let id = p.identity?.stringValue {
                snapshot[id] = Float(p.audioLevel)
            }
        }
        // Only update if something changed (avoids triggering 10 needless
        // SwiftUI re-renders per second when the room is silent).
        if snapshot != audioLevels {
            audioLevels = snapshot
        }
    }
    
    private func sendHeartbeat(roomId: String) async {
        do {
            struct EmptyBody: Codable {}
            let _: Empty = try await NetworkService.shared.post(
                path: "/api/rooms/\(roomId)/heartbeat",
                body: EmptyBody()
            )
        } catch {
            log("⚠️ Heartbeat failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Audio Controls
    
    /// Toggle microphone on/off
    func toggleMicrophone() async throws {
        guard let room = room else {
            log("❌ toggleMicrophone: No room connected!")
            return
        }
        
        let newState = !isMicEnabled
        log("🎤 Toggling microphone: \(isMicEnabled) -> \(newState)")
        
        do {
            // Ensure audio session is active before unmuting
            if newState {
                // ⚡ FIX: setActive is blocking — run on background
                await Task.detached(priority: .userInitiated) {
                    let session = AVAudioSession.sharedInstance()
                    try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
                    try? session.setActive(true)
                }.value
            }
            
            try await room.localParticipant.setMicrophone(enabled: newState)
            
            // Read actual state from track to stay in sync (single source of truth)
            let audioTrack = room.localParticipant.trackPublications.values.first { $0.kind == .audio }
            if let audioTrack = audioTrack {
                isMicEnabled = !audioTrack.isMuted
                log("✅ Microphone now: \(isMicEnabled ? "ON 🔊" : "OFF 🔇") (from track state)")
                log("   Track: \(audioTrack.name), muted: \(audioTrack.isMuted)")
            } else {
                // No audio track published yet; trust the requested state
                isMicEnabled = newState
                log("✅ Microphone now: \(newState ? "ON 🔊" : "OFF 🔇") (no track yet, using requested state)")
            }
        } catch {
            log("❌ Failed to toggle mic: \(error)")
            throw error
        }
    }
    
    // MARK: - Token Refresh
    //
    // LiveKit grants (roomJoin, canPublish, canSubscribe) are baked into the
    // JWT — they don't change at runtime. So when the host promotes us
    // listener→speaker, the `canPublish:true` flag must come from a NEW
    // token. Same when our token is about to expire.
    //
    // LiveKit Swift SDK 2.11 doesn't expose `Room.updateToken`, so the
    // reliable way to apply a fresh token is a quick disconnect→connect
    // cycle. We minimise the audio outage by:
    //   1. Pre-fetching the new token BEFORE tearing down the connection
    //   2. Using a 0.3 s reconnect delay (down from the previous 0.5 s)
    // Net outage: ~0.5–1 s vs the >2 s of the original promotion path
    // (which fetched token AFTER disconnect).
    //
    // For role changes, the server has ALREADY updated the participant's
    // SFU permissions via livekit_service.update_participant_grants by the
    // time we get here, so the new token is just the cherry on top.

    /// Re-fetch a fresh LiveKit token and apply it to the live room.
    /// Used after server-side role changes and as a safety net when
    /// connection state drops to `.reconnecting`.
    func refreshToken(roomId: String, participantName: String) async throws {
        log("🔁 Refreshing LiveKit token for \(roomId.prefix(8))…")
        // Pre-fetch first so we minimise the disconnected window.
        let resp = try await fetchToken(roomId: roomId, participantName: participantName)
        guard let oldRoom = room else {
            log("⚠️ refreshToken called with no active room — skipping")
            return
        }
        // Quick reconnect with the fresh token.
        await oldRoom.disconnect()
        try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 s
        let newRoom = Room()
        newRoom.add(delegate: self)
        try await newRoom.connect(url: resp.url, token: resp.token)
        self.room = newRoom
        log("✅ Token refreshed via reconnect (fast path)")
    }

    /// Set microphone state
    func setMicrophone(enabled: Bool) async throws {
        guard let room = room else {
            log("⚠️ setMicrophone skipped: no room")
            return
        }
        
        // Always send to LiveKit even if we think state matches — handles drift
        log("🎤 Setting microphone to: \(enabled) (current UI state: \(isMicEnabled))")
        
        if enabled {
            // ⚡ FIX: setActive is blocking — run on background
            await Task.detached(priority: .userInitiated) {
                let session = AVAudioSession.sharedInstance()
                try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
                try? session.setActive(true)
            }.value
        }
        
        try await room.localParticipant.setMicrophone(enabled: enabled)
        
        // Read actual track state
        let audioTrack = room.localParticipant.trackPublications.values.first { $0.kind == .audio }
        isMicEnabled = audioTrack.map { !$0.isMuted } ?? enabled
        log("✅ Microphone set to: \(isMicEnabled ? "ON 🔊" : "OFF 🔇")")
    }
    
    // MARK: - Permissions
    
    private func requestMicrophonePermission() async -> Bool {
        log("📱 Requesting microphone permission...")
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
    
    // MARK: - Debug Info
    
    func getDebugInfo() -> String {
        var info = """
        === AudioRoomManager Debug Info ===
        isConnecting: \(isConnecting)
        isConnected: \(isConnected)
        isMicEnabled: \(isMicEnabled)
        connectionError: \(connectionError ?? "none")
        roomId: \(roomId ?? "none")
        room object: \(room != nil ? "exists" : "nil")
        """
        
        if let room = room {
            info += """
            
            
            --- Room Info ---
            Room name: \(room.name ?? "unknown")
            Room SID: \(room.sid?.stringValue ?? "unknown")
            Connection state: \(room.connectionState)
            Local participant: \(room.localParticipant.identity?.stringValue ?? "unknown")
            Remote participants: \(room.remoteParticipants.count)
            """
            
            info += "\n\n--- Local Tracks ---"
            for (_, pub) in room.localParticipant.trackPublications {
                info += "\n  - \(pub.kind): muted=\(pub.isMuted), subscribed=\(pub.isSubscribed)"
            }
            
            info += "\n\n--- Remote Participants ---"
            for (_, participant) in room.remoteParticipants {
                info += "\n  - \(participant.identity?.stringValue ?? "unknown")"
                for (_, pub) in participant.trackPublications {
                    info += "\n      Track: \(pub.kind), muted=\(pub.isMuted)"
                }
            }
        }
        
        return info
    }
}

// MARK: - RoomDelegate

extension AudioRoomManager: RoomDelegate {
    
    nonisolated func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldValue: ConnectionState) {
        Task { @MainActor in
            log("🔄 Connection state: \(oldValue) -> \(connectionState)")
            
            switch connectionState {
            case .connected:
                isConnected = true
                isConnecting = false
                log("✅ DELEGATE: Room fully connected")
            case .disconnected:
                isConnected = false
                log("❌ DELEGATE: Room disconnected")
            case .disconnecting:
                isConnecting = false
                log("👋 DELEGATE: Room disconnecting…")
            case .connecting, .reconnecting:
                isConnecting = true
                log("⏳ DELEGATE: Room connecting/reconnecting...")
                // 🔁 Token-refresh on reconnect.
                // LiveKit's auto-reconnect uses the original cached token —
                // once it's expired, we're toast. Pre-emptively fetch a
                // fresh token so when reconnect succeeds, the session is
                // already validated against current grants.
                if let rid = roomId, let pname = lastParticipantName {
                    Task { [weak self] in
                        try? await self?.refreshToken(roomId: rid, participantName: pname)
                    }
                }
            @unknown default:
                log("❓ DELEGATE: Unknown connection state")
            }
        }
    }
    
    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor in
            remoteParticipants = room.remoteParticipants.map { $0.value }
            log("👤 DELEGATE: Participant joined: \(participant.identity?.stringValue ?? "unknown")")
            Haptics.selection()
        }
    }
    
    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor in
            remoteParticipants = room.remoteParticipants.map { $0.value }
            speakingParticipants.remove(participant.identity?.stringValue ?? "")
            log("👤 DELEGATE: Participant left: \(participant.identity?.stringValue ?? "unknown")")
        }
    }
    
    nonisolated func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        Task { @MainActor in
            let identity = participant.identity?.stringValue ?? "unknown"
            
            if isMuted {
                speakingParticipants.remove(identity)
            }
            
            // Sync isMicEnabled when the LOCAL participant's audio track mute changes
            // This catches: host muting us, server-side mute, LiveKit-level changes
            if participant.identity == room.localParticipant.identity && trackPublication.kind == .audio {
                let oldState = isMicEnabled
                isMicEnabled = !isMuted
                if oldState != isMicEnabled {
                    log("🔄 DELEGATE: Local mic state synced: \(oldState) -> \(isMicEnabled)")
                }
            }
            
            log("🔇 DELEGATE: \(identity) mute: \(isMuted)")
        }
    }
    
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication, track: Track) {
        Task { @MainActor in
            log("📡 DELEGATE: Subscribed to \(track.kind) from: \(participant.identity?.stringValue ?? "unknown")")
        }
    }
    
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication, track: Track) {
        Task { @MainActor in
            log("📡 DELEGATE: Unsubscribed from \(track.kind) from: \(participant.identity?.stringValue ?? "unknown")")
        }
    }
    
    // The single-participant `didUpdateSpeaking` callback was removed from
    // RoomDelegate; LiveKit now emits the full speaking set in one call.
    // Reconcile against `speakingParticipants` so we still log transitions.
    nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        let identities = participants.compactMap { $0.identity?.stringValue }
        Task { @MainActor in
            let next = Set(identities)
            for added in next.subtracting(speakingParticipants) {
                log("🗣️ DELEGATE: \(added) is speaking")
            }
            for removed in speakingParticipants.subtracting(next) {
                log("🤫 DELEGATE: \(removed) stopped speaking")
            }
            speakingParticipants = next
        }
    }

    nonisolated func room(_ room: Room, didFailToConnectWithError error: LiveKitError?) {
        Task { @MainActor in
            log("💥 DELEGATE: Failed to connect: \(error?.localizedDescription ?? "unknown")")
            CrashGuard.shared.log(.error, "AudioRoom delegate: connection failed", metadata: [
                "error": error?.localizedDescription ?? "unknown"
            ])
            connectionError = error?.localizedDescription
            isConnected = false
            isConnecting = false
        }
    }
    

}
