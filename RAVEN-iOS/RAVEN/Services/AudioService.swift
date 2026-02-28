// RAVEN - Audio Service
// Converted from Flutter voice_queue_controller.dart, audio_codec_service.dart

import Foundation
import AVFoundation
import Combine

/// Handles audio recording and playback
@MainActor
class AudioService: NSObject, ObservableObject {
    static let shared = AudioService()
    
    // MARK: - Recording
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var recordingLevel: Float = 0
    
    // MARK: - Playback
    @Published var isPlaying = false
    @Published var currentPlaybackId: String?
    @Published var playbackProgress: Double = 0
    @Published var playbackDuration: TimeInterval = 0
    
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var recordingTimer: Timer?
    private var playbackTimer: Timer?
    private var levelTimer: Timer?
    
    private var currentRecordingURL: URL?
    
    override private init() {
        super.init()
        setupAudioSession()
    }
    
    // MARK: - Audio Session
    
    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        } catch {
            print("❌ [Audio] Session setup failed: \(error)")
        }
    }
    
    private func activateSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("❌ [Audio] Session activation failed: \(error)")
        }
    }
    
    // MARK: - Recording
    
    func startRecording() -> URL? {
        activateSession()
        
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileName = "voice_\(Date().timeIntervalSince1970).m4a"
        let fileURL = documentsDir.appendingPathComponent("recordings/\(fileName)")
        
        // Create directory if needed
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.delegate = self
            audioRecorder?.record()
            
            currentRecordingURL = fileURL
            isRecording = true
            recordingDuration = 0
            
            // Start timers
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.recordingDuration += 0.1
                }
            }
            
            levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.audioRecorder?.updateMeters()
                    let level = self?.audioRecorder?.averagePower(forChannel: 0) ?? -160
                    self?.recordingLevel = max(0, (level + 60) / 60)  // Normalize to 0-1
                }
            }
            
            print("🎤 [Audio] Recording started")
            return fileURL
        } catch {
            print("❌ [Audio] Recording failed: \(error)")
            return nil
        }
    }
    
    func stopRecording() -> (URL, TimeInterval)? {
        recordingTimer?.invalidate()
        levelTimer?.invalidate()
        recordingTimer = nil
        levelTimer = nil
        
        audioRecorder?.stop()
        let duration = recordingDuration
        let url = currentRecordingURL
        
        audioRecorder = nil
        currentRecordingURL = nil
        isRecording = false
        recordingDuration = 0
        recordingLevel = 0
        
        print("🎤 [Audio] Recording stopped (\(Int(duration))s)")
        
        if let url = url {
            return (url, duration)
        }
        return nil
    }
    
    func cancelRecording() {
        recordingTimer?.invalidate()
        levelTimer?.invalidate()
        audioRecorder?.stop()
        
        // Delete the file
        if let url = currentRecordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        
        audioRecorder = nil
        currentRecordingURL = nil
        isRecording = false
        recordingDuration = 0
        recordingLevel = 0
        
        print("🎤 [Audio] Recording cancelled")
    }
    
    // MARK: - Playback
    
    func play(url: URL, id: String) {
        stop()
        activateSession()
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            
            isPlaying = true
            currentPlaybackId = id
            playbackDuration = audioPlayer?.duration ?? 0
            playbackProgress = 0
            
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self = self, let player = self.audioPlayer else { return }
                    self.playbackProgress = player.currentTime / max(player.duration, 0.1)
                }
            }
            
            print("▶️ [Audio] Playing: \(id)")
        } catch {
            print("❌ [Audio] Playback failed: \(error)")
        }
    }
    
    func playRemote(urlString: String, id: String) {
        Task {
            do {
                let localURL = try await MediaService.shared.downloadFile(from: urlString)
                await MainActor.run {
                    play(url: localURL, id: id)
                }
            } catch {
                print("❌ [Audio] Remote playback failed: \(error)")
            }
        }
    }
    
    func pause() {
        audioPlayer?.pause()
        isPlaying = false
    }
    
    func resume() {
        audioPlayer?.play()
        isPlaying = true
    }
    
    func stop() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        audioPlayer?.stop()
        audioPlayer = nil
        
        isPlaying = false
        currentPlaybackId = nil
        playbackProgress = 0
        playbackDuration = 0
    }
    
    func seek(to progress: Double) {
        guard let player = audioPlayer else { return }
        player.currentTime = progress * player.duration
        playbackProgress = progress
    }
    
    // MARK: - Waveform
    
    /// Generate waveform data from audio file
    func generateWaveform(url: URL, samples: Int = 50) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else {
            return Array(repeating: 0.5, count: samples)
        }
        
        let length = Int(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(length)) else {
            return Array(repeating: 0.5, count: samples)
        }
        
        try? file.read(into: buffer)
        
        guard let channelData = buffer.floatChannelData?[0] else {
            return Array(repeating: 0.5, count: samples)
        }
        
        let validLength = Int(buffer.frameLength) // ✅ Use actual frames read, not file.length
        let frameCount = max(1, validLength / samples) // ✅ Prevent zero division
        
        var waveform: [Float] = []
        
        for i in 0..<samples {
            let start = i * frameCount
            let end = min(start + frameCount, validLength)
            
            let divisor = Float(end - start)
            if divisor <= 0 { // ✅ Prevent NaN from division by zero
                waveform.append(0.5)
                continue
            }
            
            var sum: Float = 0
            for j in start..<end {
                sum += abs(channelData[j])
            }
            
            let avg = sum / divisor
            waveform.append(min(avg * 5, 1.0))  // Amplify and clamp
        }
        
        return waveform
    }
}

// MARK: - AVAudioRecorderDelegate
extension AudioService: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            if !flag {
                print("❌ [Audio] Recording finished with error")
            }
        }
    }
}

// MARK: - AVAudioPlayerDelegate
extension AudioService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            stop()
        }
    }
}
