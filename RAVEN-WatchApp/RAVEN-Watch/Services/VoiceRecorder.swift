// VoiceRecorder.swift
//
// Records a short M4A voice clip on the Watch and hands the file URL to
// `PhoneBridge.sendVoiceReply`. The phone receives it via
// `transferFile`, re-encodes if needed, and ships it as a regular
// type=.voice mesh envelope.

import Foundation
import AVFoundation

@MainActor
final class VoiceRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastFileURL: URL?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?

    /// Bound by the Watch's typing budget — 60s max is a reasonable
    /// upper limit that matches the iPhone composer.
    let maxDuration: TimeInterval = 60

    func start() throws {
        guard !isRecording else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers])
        try session.setActive(true, options: [])

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("raven-watch-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.record(forDuration: maxDuration)
        self.recorder = rec
        self.startedAt = Date()
        self.isRecording = true
        self.elapsed = 0
        self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let started = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(started)
                if self.elapsed >= self.maxDuration { self.stop() }
            }
        }
    }

    @discardableResult
    func stop() -> URL? {
        timer?.invalidate(); timer = nil
        recorder?.stop()
        let url = recorder?.url
        recorder = nil
        isRecording = false
        lastFileURL = url
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        return url
    }

    func cancel() {
        _ = stop()
        if let url = lastFileURL { try? FileManager.default.removeItem(at: url) }
        lastFileURL = nil
        elapsed = 0
    }
}
