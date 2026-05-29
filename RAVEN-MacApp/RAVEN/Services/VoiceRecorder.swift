// VoiceRecorder — thin AVAudioRecorder wrapper for the chat composer.
// Records to an .m4a file in the app's tmp directory; caller reads the
// raw bytes after `stop()` and uploads them.

import Foundation
import AVFoundation

@MainActor
final class VoiceRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var startedAt: Date?
    private var timer: Timer?

    /// Output URL for the most recent recording, valid after `stop()`
    /// returns and until the next `start()`.
    private(set) var outputURL: URL?

    /// Begin recording into a fresh tmp file. Throws if the system
    /// denies microphone access or audio engine setup fails.
    func start() throws {
        guard !isRecording else { return }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("raven-voice-\(UUID().uuidString).m4a")
        outputURL = tmp

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        let r = try AVAudioRecorder(url: tmp, settings: settings)
        r.prepareToRecord()
        guard r.record() else {
            throw NSError(
                domain: "VoiceRecorder", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't start recording."]
            )
        }
        recorder = r
        startedAt = Date()
        isRecording = true
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let started = self.startedAt else { return }
            // The timer fires on the run loop's main thread but Swift's
            // strict concurrency demands we explicitly hop to MainActor
            // for `@Published` mutations.
            Task { @MainActor in self.elapsed = Date().timeIntervalSince(started) }
        }
    }

    /// Stop and finalize. Returns the file URL on success; nil if there
    /// was no active recording.
    @discardableResult
    func stop() -> URL? {
        guard isRecording, let r = recorder else { return nil }
        r.stop()
        timer?.invalidate()
        timer = nil
        isRecording = false
        recorder = nil
        return outputURL
    }

    /// Discard the current recording without uploading.
    func cancel() {
        _ = stop()
        if let url = outputURL { try? FileManager.default.removeItem(at: url) }
        outputURL = nil
    }
}
