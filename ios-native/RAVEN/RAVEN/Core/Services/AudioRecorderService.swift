import AVFoundation
import SwiftUI

// MARK: - Audio Recorder Service
/// Observable service for recording voice posts and voice comments.
/// Records to m4a (AAC), samples waveform data, enforces duration limits.
@Observable
final class AudioRecorderService: NSObject {
    
    enum RecordingState: Equatable {
        case idle
        case recording
        case recorded(URL, TimeInterval, [Float])  // fileURL, duration, waveform
        case playing
        
        static func == (lhs: RecordingState, rhs: RecordingState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.recording, .recording), (.playing, .playing):
                return true
            case (.recorded(let a, _, _), .recorded(let b, _, _)):
                return a == b
            default:
                return false
            }
        }
    }
    
    // MARK: - Public State
    var state: RecordingState = .idle
    var currentTime: TimeInterval = 0
    var waveformSamples: [Float] = []
    var permissionDenied = false
    
    // MARK: - Configuration
    let minDuration: TimeInterval = 2.0   // Minimum 2 seconds
    var maxDuration: TimeInterval { PremiumLimits.voiceMessageMaxDuration } // Free: 2min, RAVEN+: 10min
    
    // MARK: - Private
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var displayLink: CADisplayLink?
    private var recordingURL: URL?
    private var recordingStartTime: Date?
    
    override init() {
        super.init()
        // Observe audio session interruptions (phone calls, alarms, Siri)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }
    
    deinit {
        displayLink?.invalidate()
        displayLink = nil
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        
        switch type {
        case .began:
            // Interruption started (phone call, alarm, etc.)
            if case .recording = state {
                #if DEBUG
                print("⚠️ [AudioRecorder] Interrupted — stopping recording")
                #endif
                stopRecording()
            }
            if case .playing = state {
                stopPreview()
            }
        case .ended:
            // Interruption ended — reactivate session
            // FIX: setActive(true) can block 1–3s with Bluetooth — run on background
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    Task.detached(priority: .userInitiated) {
                        try? AVAudioSession.sharedInstance().setActive(true)
                    }
                }
            }
        @unknown default:
            break
        }
    }
    
    // MARK: - Permissions
    
    func requestPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }
    
    // MARK: - Recording
    
    func startRecording() async {
        // Check permission
        let granted = await requestPermission()
        guard granted else {
            permissionDenied = true
            #if DEBUG
            print("🎤 [AudioRecorder] Microphone permission denied")
            #endif
            return
        }
        permissionDenied = false
        
        // Configure audio session
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            // ⚡ FIX: setActive is blocking (0.5-3s with Bluetooth) — run on background
            await Task.detached(priority: .userInitiated) {
                try? AVAudioSession.sharedInstance().setActive(true)
            }.value
        } catch {
            #if DEBUG
            print("❌ [AudioRecorder] Audio session error: \(error)")
            #endif
            return
        }
        
        // Create temp file
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "voice_\(UUID().uuidString).m4a"
        let fileURL = tempDir.appendingPathComponent(filename)
        recordingURL = fileURL
        
        // Recording settings: AAC, 44.1kHz mono
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 128000
        ]
        
        do {
            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.delegate = self
            recorder.record()
            
            audioRecorder = recorder
            state = .recording
            waveformSamples = []
            recordingStartTime = Date()
            currentTime = 0
            
            // Start metering timer
            startMeteringTimer()
            
            #if DEBUG
            print("🎤 [AudioRecorder] Recording started: \(filename)")
            #endif
            Haptics.light()
        } catch {
            #if DEBUG
            print("❌ [AudioRecorder] Failed to start recording: \(error)")
            #endif
        }
    }
    
    func stopRecording() {
        guard let recorder = audioRecorder, recorder.isRecording else { return }
        
        let duration = recorder.currentTime
        recorder.stop()
        stopMeteringTimer()
        
        // Only deactivate session if user is NOT in an Audio Room
        // Bug 2 fix: RoomService is @MainActor — use Task dispatch instead of assumeIsolated,
        // because handleAudioInterruption can fire on a background thread (phone call, alarm)
        Task { @MainActor in
            let inRoom = RoomService.shared.isInRoom
            if !inRoom {
                // ⚡ FIX: setActive(false) is blocking — run on background (fire-and-forget)
                Task.detached(priority: .background) {
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                }
            }
        }
        
        guard let url = recordingURL else { return }
        
        if duration < minDuration {
            // Too short — discard
            #if DEBUG
            print("⚠️ [AudioRecorder] Recording too short (\(String(format: "%.1f", duration))s < \(minDuration)s), discarding")
            #endif
            deleteRecording()
            Haptics.error()
            return
        }
        
        // Normalize waveform to 0...1
        let maxSample = waveformSamples.max() ?? 1.0
        let normalizedWaveform = waveformSamples.map { min(1.0, $0 / max(maxSample, 0.01)) }
        
        // Downsample to ~50 points for UI
        let targetCount = 50
        let downsampled = downsample(normalizedWaveform, to: targetCount)
        
        state = .recorded(url, duration, downsampled)
        currentTime = duration
        
        #if DEBUG
        print("🎤 [AudioRecorder] Recording stopped: \(String(format: "%.1f", duration))s, \(downsampled.count) waveform samples")
        #endif
        Haptics.medium()
    }
    
    func deleteRecording() {
        audioRecorder?.stop()
        audioPlayer?.stop()
        stopMeteringTimer()
        
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        
        audioRecorder = nil
        audioPlayer = nil
        recordingURL = nil
        waveformSamples = []
        currentTime = 0
        state = .idle
        
        #if DEBUG
        print("🗑️ [AudioRecorder] Recording deleted")
        #endif
    }
    
    // MARK: - Preview Playback
    
    func playPreview() {
        guard case .recorded(let url, _, _) = state else { return }
        
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            // ⚡ FIX: setActive is blocking — run on background (fire-and-forget)
            Task.detached(priority: .userInitiated) {
                try? AVAudioSession.sharedInstance().setActive(true)
            }
            
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.play()
            audioPlayer = player
            state = .playing
            
            #if DEBUG
            print("▶️ [AudioRecorder] Playing preview")
            #endif
        } catch {
            #if DEBUG
            print("❌ [AudioRecorder] Preview playback error: \(error)")
            #endif
        }
    }
    
    func stopPreview() {
        audioPlayer?.stop()
        audioPlayer = nil
        
        if let url = recordingURL {
            let duration = currentTime
            state = .recorded(url, duration, waveformSamples)
        }
    }
    
    // MARK: - File Info
    
    var recordedFileURL: URL? {
        if case .recorded(let url, _, _) = state { return url }
        return nil
    }
    
    var recordedDuration: TimeInterval {
        if case .recorded(_, let dur, _) = state { return dur }
        return currentTime
    }
    
    var recordedWaveform: [Float] {
        if case .recorded(_, _, let wf) = state { return wf }
        return waveformSamples
    }
    
    var fileSize: Int64 {
        guard let url = recordedFileURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return 0 }
        return size
    }
    
    // MARK: - Private Helpers
    
    // MARK: - Weak Proxy (breaks CADisplayLink retain cycle)
    
    /// CADisplayLink holds a strong reference to its target.
    /// Using a weak proxy prevents a retain cycle that would leak this service.
    private class WeakProxy: NSObject {
        weak var target: AudioRecorderService?
        init(_ target: AudioRecorderService) { self.target = target }
        @objc func tick(_ link: CADisplayLink) { target?.updateMeters() }
    }
    
    private func startMeteringTimer() {
        let proxy = WeakProxy(self)
        let link = CADisplayLink(target: proxy, selector: #selector(WeakProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 15)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }
    
    private func stopMeteringTimer() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    @objc private func updateMeters() {
        guard let recorder = audioRecorder, recorder.isRecording else { return }
        
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0) // dBFS, typically -160 to 0
        
        // Normalize: -60dB → 0.0, 0dB → 1.0
        let normalized = max(0, (power + 60) / 60)
        waveformSamples.append(normalized)
        
        currentTime = recorder.currentTime
        
        // Auto-stop at max duration
        if currentTime >= maxDuration {
            // FIX: Provide haptic feedback (heavy vibration) before stopping recording
            Haptics.heavy()
            
            stopRecording()
            
            // Show Paywall only for free users
            if !PremiumLimits.isPremium {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: NSNotification.Name("ShowPaywall"), object: nil)
                }
            }
        }
    }
    
    private func downsample(_ samples: [Float], to count: Int) -> [Float] {
        guard samples.count > count else { return samples }
        let chunkSize = samples.count / count
        return stride(from: 0, to: samples.count, by: chunkSize).prefix(count).map { start in
            let end = min(start + chunkSize, samples.count)
            let chunk = samples[start..<end]
            return chunk.max() ?? 0
        }
    }
}

// MARK: - AVAudioRecorderDelegate
extension AudioRecorderService: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            #if DEBUG
            print("❌ [AudioRecorder] Recording finished with error")
            #endif
            deleteRecording()
        }
    }
}

// MARK: - AVAudioPlayerDelegate
extension AudioRecorderService: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if let url = recordingURL {
            state = .recorded(url, currentTime, recordedWaveform)
        }
        audioPlayer = nil
    }
}
