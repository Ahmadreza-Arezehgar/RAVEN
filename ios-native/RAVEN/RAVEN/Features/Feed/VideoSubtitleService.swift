//
//  VideoSubtitleService.swift
//  RAVEN
//
//  On-device automatic captions for videos. Uses Apple's
//  `SFSpeechRecognizer` in offline mode (`requiresOnDeviceRecognition`)
//  so audio NEVER leaves the user's device — same on-device-AI
//  privacy contract that powers our chat summary feature.
//
//  Pipeline
//  ────────
//   1. Caller asks for captions for a video URL.
//   2. We extract the audio track to a local m4a using AVAssetExportSession.
//   3. SFSpeechRecognizer transcribes the m4a, emitting partial
//      results as the audio is processed.
//   4. We split the cumulative transcript into roughly-2-second
//      cue chunks and store them in `cueCache[url]`.
//   5. The player view subscribes to `currentSecondsPublisher` and
//      reads whichever cue contains the current playhead.
//
//  Cache
//  ─────
//  Captions are deterministic per (video URL, recogniser locale)
//  and cheap to keep around — we cache them in-memory for the
//  session and on disk under `Caches/RAVEN/captions/<sha256>.json`
//  so reopening the same post doesn't redo the recognition.
//

import Foundation
import AVFoundation
import Speech
import CryptoKit

/// One displayable caption cue.
struct VideoCaptionCue: Codable, Equatable {
    let start: Double
    let end: Double
    let text: String

    func contains(_ second: Double) -> Bool {
        return second >= start && second < end
    }
}

@MainActor
final class VideoSubtitleService: ObservableObject {
    static let shared = VideoSubtitleService()

    // MARK: - Published state

    /// Caption cues keyed by the video URL string. Re-emit so SwiftUI
    /// views can `.onReceive` and rebuild their overlay when a new
    /// transcription completes.
    @Published private(set) var cueCache: [String: [VideoCaptionCue]] = [:]

    /// URLs currently mid-transcription — UI shows a tiny spinner
    /// next to the CC button while the recogniser is running.
    @Published private(set) var inProgress: Set<String> = []

    /// User's recently-chosen caption language. Defaults to the
    /// device's primary language. Persisted across launches.
    @Published var preferredLocale: Locale {
        didSet {
            UserDefaults.standard.set(
                preferredLocale.identifier,
                forKey: "raven.captions.locale"
            )
        }
    }

    // MARK: - Init

    private init() {
        let stored = UserDefaults.standard.string(forKey: "raven.captions.locale")
        self.preferredLocale = stored.map { Locale(identifier: $0) } ?? Locale.current
        loadDiskCacheIndex()
    }

    // MARK: - Public API

    /// Synchronous: which cue is showing right now, if any?
    /// Cheap O(log n) via the sorted cue list.
    func cue(for url: String, atSecond second: Double) -> VideoCaptionCue? {
        guard let cues = cueCache[url] else { return nil }
        // Linear is fine — typical 60-second clip has ~30 cues.
        return cues.first(where: { $0.contains(second) })
    }

    /// Are we already mid-transcription for this URL?
    func isWorking(on url: String) -> Bool {
        inProgress.contains(url)
    }

    /// Are captions ready (or in progress) for this URL?
    func hasCues(for url: String) -> Bool {
        return cueCache[url] != nil
    }

    /// Kick off transcription for a video. Idempotent — if cues
    /// are already cached or generation is in flight, returns
    /// immediately. Otherwise spawns the export + recogniser
    /// pipeline on a background actor and updates `cueCache` when
    /// done.
    func generateIfNeeded(for videoURL: URL) {
        let key = videoURL.absoluteString
        if cueCache[key] != nil { return }
        if inProgress.contains(key) { return }

        // Try disk cache first.
        if let disk = loadFromDiskCache(for: key) {
            cueCache[key] = disk
            return
        }

        inProgress.insert(key)
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            let cues = await Self.transcribe(
                videoURL: videoURL,
                locale: await self.preferredLocale
            )
            await MainActor.run {
                self.inProgress.remove(key)
                guard let cues = cues, !cues.isEmpty else { return }
                self.cueCache[key] = cues
                self.saveToDiskCache(cues: cues, for: key)
            }
        }
    }

    /// Drop the cached captions for a URL (memory + disk). Used
    /// when the user reports a bad transcription.
    func resetCaptions(for videoURL: URL) {
        let key = videoURL.absoluteString
        cueCache.removeValue(forKey: key)
        let path = Self.diskPath(for: key)
        try? FileManager.default.removeItem(at: path)
    }

    // MARK: - Authorisation

    /// Ask the user for speech-recognition permission. Subtitles
    /// are useless without it. Safe to call repeatedly.
    static func requestAuthorisation() async -> SFSpeechRecognizerAuthorizationStatus {
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    // MARK: - Transcription pipeline (off main)

    private static func transcribe(
        videoURL: URL,
        locale: Locale
    ) async -> [VideoCaptionCue]? {
        // 1. Extract audio to a local m4a in a tmp file.
        guard let audioURL = await extractAudio(from: videoURL) else {
            #if DEBUG
            print("⚠️ [Subtitles] Audio extraction failed for \(videoURL.lastPathComponent)")
            #endif
            return nil
        }
        defer { try? FileManager.default.removeItem(at: audioURL) }

        // 2. Build the recogniser. ON-DEVICE only — never sends
        //    audio off the user's phone.
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable else {
            #if DEBUG
            print("⚠️ [Subtitles] No recogniser for locale \(locale.identifier)")
            #endif
            return nil
        }
        if !recognizer.supportsOnDeviceRecognition {
            #if DEBUG
            print("⚠️ [Subtitles] Locale \(locale.identifier) doesn't support on-device — refusing to fall back to cloud")
            #endif
            return nil
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false  // we want final segmented result

        // 3. Run the recogniser. The closure-based API doesn't have
        //    a direct async wrapper, so we adapt with a continuation.
        let result: SFSpeechRecognitionResult? = await withCheckedContinuation { cont in
            var settled = false
            recognizer.recognitionTask(with: request) { res, error in
                guard !settled else { return }
                if let error = error {
                    settled = true
                    #if DEBUG
                    print("⚠️ [Subtitles] Recognition failed: \(error.localizedDescription)")
                    #endif
                    cont.resume(returning: nil)
                    return
                }
                if let res = res, res.isFinal {
                    settled = true
                    cont.resume(returning: res)
                }
            }
        }

        guard let result = result else { return nil }
        return cuesFromResult(result)
    }

    /// SFSpeechRecognitionResult exposes per-segment timestamps —
    /// we group nearby segments into ~3-second cues so on-screen
    /// captions don't change every word like a karaoke meter.
    private static func cuesFromResult(_ result: SFSpeechRecognitionResult) -> [VideoCaptionCue] {
        let segments = result.bestTranscription.segments
        guard !segments.isEmpty else { return [] }

        var cues: [VideoCaptionCue] = []
        var currentText: [String] = []
        var currentStart: TimeInterval = segments[0].timestamp
        let maxCueDuration: TimeInterval = 3.0
        let maxCueChars = 80

        for seg in segments {
            currentText.append(seg.substring)
            let candidateText = currentText.joined(separator: " ")
            let elapsed = (seg.timestamp + seg.duration) - currentStart
            if elapsed >= maxCueDuration || candidateText.count >= maxCueChars {
                cues.append(VideoCaptionCue(
                    start: currentStart,
                    end: seg.timestamp + seg.duration,
                    text: candidateText
                ))
                currentText = []
                currentStart = seg.timestamp + seg.duration
            }
        }
        if !currentText.isEmpty, let last = segments.last {
            cues.append(VideoCaptionCue(
                start: currentStart,
                end: last.timestamp + last.duration,
                text: currentText.joined(separator: " ")
            ))
        }
        return cues
    }

    /// Extract audio track to a temporary m4a — SFSpeechRecognizer
    /// is happiest with a small extracted file rather than a full
    /// video URL.
    private static func extractAudio(from videoURL: URL) async -> URL? {
        let asset = AVURLAsset(url: videoURL)
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else { return nil }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("raven_caption_\(UUID().uuidString).m4a")
        exporter.outputURL = tmp
        exporter.outputFileType = .m4a

        return await withCheckedContinuation { cont in
            exporter.exportAsynchronously {
                if exporter.status == .completed {
                    cont.resume(returning: tmp)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Disk cache

    private static func diskPath(for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8))
        let name = hash.compactMap { String(format: "%02x", $0) }.joined()
        let dir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RAVEN")
            .appendingPathComponent("captions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(name).json")
    }

    private func loadFromDiskCache(for key: String) -> [VideoCaptionCue]? {
        let path = Self.diskPath(for: key)
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode([VideoCaptionCue].self, from: data)
    }

    private func saveToDiskCache(cues: [VideoCaptionCue], for key: String) {
        let path = Self.diskPath(for: key)
        if let data = try? JSONEncoder().encode(cues) {
            try? data.write(to: path, options: [.atomic])
        }
    }

    /// Lazy hydration: nothing to do at boot, we read on demand.
    /// Kept here as a future-extension point.
    private func loadDiskCacheIndex() { }
}
