import SwiftUI
import AVFoundation
import Combine

// MARK: - Playback State
enum PlayerDisplayState: Equatable {
    case hidden
    case mini
    case expanded
}

// MARK: - Audio Playback Store (Global Singleton)
/// Single source of truth for all voice playback — posts, messages, comments.
/// Manages AVPlayer lifecycle, progress tracking, and UI state.

@Observable
@MainActor
final class AudioPlaybackStore {
    static let shared = AudioPlaybackStore()
    
    // MARK: - Published State
    var currentItem: AudioItem?
    var displayState: PlayerDisplayState = .hidden
    var isPlaying: Bool = false
    var progress: Double = 0        // 0…1
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 1
    var playbackRate: Float = 1.0
    
    // MARK: - Private
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var interruptionObserver: NSObjectProtocol?
    
    private init() {
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
        
        switch type {
        case .began:
            if isPlaying {
                pause()
                #if DEBUG
                print("⚠️ [AudioPlayback] Interrupted — paused")
                #endif
            }
        case .ended:
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    resume()
                    #if DEBUG
                    print("▶️ [AudioPlayback] Interruption ended — resumed")
                    #endif
                }
            }
        @unknown default:
            break
        }
    }
    
    // MARK: - Play
    
    /// Start playing a new audio item. If same item, toggle play/pause.
    func play(item: AudioItem) {
        // Same item — toggle
        if currentItem?.id == item.id {
            if isPlaying { pause() } else { resume() }
            return
        }
        
        // New item — crossfade
        cleanup()
        currentItem = item
        duration = max(1, TimeInterval(item.duration))
        progress = 0
        currentTime = 0
        playbackRate = 1.0
        
        guard let url: URL = {
            // Handle local file URLs (from media cache) directly
            if item.voiceUrl.hasPrefix("file://") {
                return URL(string: item.voiceUrl)
            }
            // Remote or relative URLs go through AppConfig resolver
            return AppConfig.mediaURL(from: item.voiceUrl)
        }() else {
            #if DEBUG
            print("❌ [AudioStore] Invalid URL: \(item.voiceUrl)")
            #endif
            return
        }
        
        // Configure audio session — avoid clobbering voiceChat if user is in a room
        if RoomService.shared.isInRoom {
            try? AVAudioSession.sharedInstance().setCategory(
                .playAndRecord, mode: .voiceChat,
                options: [.mixWithOthers, .defaultToSpeaker]
            )
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
        }
        // ⚠️ Bug 2 fix: setActive can block main thread for seconds during
        // audio hardware negotiation (e.g. with Spotify). Run on background thread.
        // Wrapped in Task since play() is not async — player setup continues after activation.
        Task { [weak self] in
            guard let self = self else { return }
            
            var finalURL = url
            
            // Download remote audio to temp file first to avoid AVPlayer auth header dropping bugs
            if !url.isFileURL {
                do {
                    var request = URLRequest(url: url)
                    // ✅ Bug 8 fix: Only attach auth token for our own API domain.
                    // Without this check, a malicious voice message URL (e.g. https://hacker.com/voice.m4a)
                    // would receive the user's bearer token, enabling account takeover.
                    let isTrustedDomain = url.absoluteString.hasPrefix(AppConfig.apiBaseURL)
                    if isTrustedDomain, let (token, _) = await KeychainService.shared.getToken() {
                        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    }
                    let (tempURL, response) = try await URLSession.shared.download(for: request)
                    if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                        let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
                        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(item.id).\(ext)")
                        if FileManager.default.fileExists(atPath: cacheURL.path) {
                            try? FileManager.default.removeItem(at: cacheURL)
                        }
                        try FileManager.default.moveItem(at: tempURL, to: cacheURL)
                        finalURL = cacheURL
                    }
                } catch {
                    #if DEBUG
                    print("⚠️ [AudioPlaybackStore] Audio download failed: \(error)")
                    #endif
                }
            }
            
            await Task.detached(priority: .userInitiated) {
                try? AVAudioSession.sharedInstance().setActive(true)
            }.value
            
            // Prevent stale Task from overwriting player if user tapped another item
            guard self.currentItem?.id == item.id else { return }
            
            let asset = AVURLAsset(url: finalURL)
            let playerItem = AVPlayerItem(asset: asset)
            self.player = AVPlayer(playerItem: playerItem)
            self.player?.rate = self.playbackRate
            
            // Observe duration from asset
            self.statusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
                if item.status == .readyToPlay {
                    let dur = CMTimeGetSeconds(item.duration)
                    if dur.isFinite && dur > 0 {
                        Task { @MainActor [weak self] in
                            self?.duration = dur
                        }
                    }
                }
            }
            
            // Time observer — update progress ~15x per second
            self.timeObserver = self.player?.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.066, preferredTimescale: 600),
                queue: .main
            ) { [weak self] time in
                Task { @MainActor [weak self] in
                    guard let self, self.duration > 0 else { return }
                    self.currentTime = CMTimeGetSeconds(time)
                    self.progress = min(1, self.currentTime / self.duration)
                }
            }
            
            // End observer
            self.endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: playerItem,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handlePlaybackEnded()
                }
            }
            
            self.player?.play()
            self.isPlaying = true
            Self.setKeepScreenOn(true)

            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                self.displayState = .mini
            }
        }
    }

    // MARK: - Controls

    func pause() {
        player?.pause()
        isPlaying = false
        Self.setKeepScreenOn(false)
    }

    func resume() {
        player?.play()
        isPlaying = true
        Self.setKeepScreenOn(true)
    }

    /// Keep the screen awake while voice is playing — auto-lock during a
    /// long voice message is a sharp annoyance because the audio routes to
    /// the speaker but the user's hands are off the device. Released the
    /// moment playback pauses or ends.
    private static func setKeepScreenOn(_ keepOn: Bool) {
        Task { @MainActor in
            UIApplication.shared.isIdleTimerDisabled = keepOn
        }
    }
    
    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }
    
    func seek(to fraction: Double) {
        let target = CMTime(seconds: fraction * duration, preferredTimescale: 600)
        player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        progress = fraction
        currentTime = fraction * duration
    }
    
    func skip(seconds: Double) {
        let newTime = min(duration, max(0, currentTime + seconds))
        seek(to: newTime / duration)
    }
    
    func setRate(_ rate: Float) {
        playbackRate = rate
        player?.rate = isPlaying ? rate : 0
    }
    
    func cycleRate() {
        switch playbackRate {
        case 1.0: setRate(1.5)
        case 1.5: setRate(2.0)
        default:  setRate(1.0)
        }
    }
    
    // MARK: - Display
    
    func expand() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            displayState = .expanded
        }
    }
    
    func collapse() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            displayState = .mini
        }
    }
    
    func dismiss() {
        cleanup()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            displayState = .hidden
            currentItem = nil
        }
    }
    
    // MARK: - Query
    
    /// Check if a specific item is currently playing
    func isCurrentlyPlaying(itemId: String) -> Bool {
        currentItem?.id == itemId && isPlaying
    }
    
    /// Get progress for a specific item (0 if not current)
    func progressFor(itemId: String) -> Double {
        currentItem?.id == itemId ? progress : 0
    }
    
    // MARK: - Private
    
    private func handlePlaybackEnded() {
        isPlaying = false
        Self.setKeepScreenOn(false)
        progress = 1
        currentTime = duration
        // Reset to beginning for replay
        player?.seek(to: .zero)
        progress = 0
        currentTime = 0
    }
    
    private func cleanup() {
        player?.pause()
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
        if let endObs = endObserver {
            NotificationCenter.default.removeObserver(endObs)
        }
        statusObserver?.invalidate()
        player = nil
        timeObserver = nil
        endObserver = nil
        statusObserver = nil
        isPlaying = false
        progress = 0
        currentTime = 0
    }
    
}
