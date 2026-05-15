// RAVEN — VoiceRecordingBar
// Shared bidirectional swipe-to-send / swipe-to-cancel voice recorder.
// Reused identically in: Voice Comment · Chat Composer (DM + Group)

import SwiftUI
import AVFoundation

// MARK: - VoiceRecordingBar

/// A bidirectional drag-to-send / drag-to-cancel recording bar.
///
/// Usage:
/// ```swift
/// VoiceRecordingBar(
///     isRecording: $isRecording,
///     recordedAudioURL: $recordedAudioURL,
///     previewDuration: $previewDuration,
///     maxDuration: 120,
///     onSend: { url, duration in … },
///     onCancel: { … }
/// )
/// ```
struct VoiceRecordingBar: View {

    // MARK: - Bindings (parent-owned state)

    @Binding var isRecording: Bool
    @Binding var recordedAudioURL: URL?
    @Binding var previewDuration: TimeInterval

    // MARK: - Configuration

    var maxDuration: TimeInterval = 120          // 2 min default
    var onSend: (URL, TimeInterval) -> Void      // audioURL, duration
    var onCancel: () -> Void

    // MARK: - Internal State

    @State private var recordingDuration: TimeInterval = 0
    @State private var audioRecorder: AVAudioRecorder? = nil
    @State private var recordingTimer: Timer? = nil
    @State private var thumbOffset: CGFloat = 0
    @State private var gestureLocked = false
    @State private var isPreparing = false  // UX: show loading state during Bluetooth handshake

    // Preview playback
    @State private var isPlayingPreview = false
    @State private var previewPlayer: AVAudioPlayer? = nil

    private let swipeThreshold: CGFloat = 0.65   // 65 % of bar width

    // MARK: - Body

    var body: some View {
        if isPreparing {
            // UX: Show pulsing mic indicator during Bluetooth/audio session handshake
            HStack(spacing: 10) {
                ProgressView()
                    .tint(.accentColor)
                    .scaleEffect(0.8)
                Text("Preparing mic…")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .transition(.opacity)
        } else if isRecording {
            recordingBar
                .onAppear {
                    // Auto-start recording when the bar is shown by the parent
                    if audioRecorder == nil {
                        startRecording()
                    }
                }
                .onDisappear {
                    // Bug 4 fix: Stop recording when view disappears (e.g., user navigates back)
                    // Prevents hot-mic: microphone staying active in background
                    if isRecording { cancelRecording() }
                }
        } else if let audioURL = recordedAudioURL {
            voicePreviewBar(audioURL: audioURL)
                .padding(.horizontal, DS.space16)
                .padding(.vertical, DS.space8)
                .transition(.scale.combined(with: .opacity))
        }
    }

    // MARK: - Recording Overlay Visualization

    /// Drop this into a ZStack above your content list to show
    /// animated rings + timer while recording.
    var recordingOverlay: some View {
        VStack(spacing: DS.space16) {
            // Animated rings
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(Color.accentColor.opacity(0.15 - Double(i) * 0.04), lineWidth: 2)
                        .frame(width: CGFloat(60 + i * 30), height: CGFloat(60 + i * 30))
                        .scaleEffect(isRecording ? 1.15 : 0.9)
                        .animation(
                            .easeInOut(duration: 1.2)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.2),
                            value: isRecording
                        )
                }

                Image(systemName: "mic.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.accentColor)
            }

            // Timer + progress
            VStack(spacing: DS.space8) {
                Text(formatDuration(recordingDuration))
                    .font(.system(size: 32, weight: .light, design: .monospaced))
                    .foregroundColor(.primary)

                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.gray.opacity(0.15))
                            .frame(height: 4)

                        Capsule()
                            .fill(
                                recordingDuration > maxDuration * 0.85
                                ? Color.orange
                                : Color.accentColor
                            )
                            .frame(
                                width: geo.size.width * min(1.0, recordingDuration / maxDuration),
                                height: 4
                            )
                            .animation(.linear(duration: 0.1), value: recordingDuration)
                    }
                }
                .frame(height: 4)
                .frame(maxWidth: 200)

                Text("\(formatDuration(maxDuration - recordingDuration)) remaining")
                    .font(.system(size: 12))
                    .foregroundColor(
                        recordingDuration > maxDuration * 0.85
                        ? .orange
                        : .secondary
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Recording Bar (← cancel | → send)

    private var recordingBar: some View {
        GeometryReader { geo in
            let barWidth = geo.size.width - DS.space16 * 2
            let halfThreshold = barWidth * swipeThreshold * 0.5
            let leftProgress = thumbOffset < 0 ? min(1.0, abs(thumbOffset) / halfThreshold) : 0.0
            let rightProgress = thumbOffset > 0 ? min(1.0, thumbOffset / halfThreshold) : 0.0

            VStack(spacing: 8) {
                // ── Timer capsule (ABOVE the drag track, never overlapped) ──
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                        .shadow(color: .red.opacity(0.6), radius: 4)

                    Text(formatDuration(recordingDuration))
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                )
                .opacity(1.0 - max(leftProgress, rightProgress) * 1.5)

                // ── Drag track ──
                ZStack {
                    // Background glow zones
                    HStack(spacing: 0) {
                        Color.red.opacity(leftProgress * 0.12)
                        Color.accentColor.opacity(rightProgress * 0.12)
                    }
                    .clipShape(Capsule())

                    // Glass background
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                        )

                    // Left: Cancel icon
                    HStack {
                        HStack(spacing: DS.space4) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Cancel")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundColor(.red.opacity(0.4 + leftProgress * 0.6))
                        .scaleEffect(1.0 + leftProgress * 0.1)
                        .padding(.leading, DS.space16)

                        Spacer()
                    }

                    // Right: Send icon
                    HStack {
                        Spacer()

                        HStack(spacing: DS.space4) {
                            Text("Send")
                                .font(.system(size: 13, weight: .medium))
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(.accentColor.opacity(0.4 + rightProgress * 0.6))
                        .scaleEffect(1.0 + rightProgress * 0.1)
                        .padding(.trailing, DS.space16)
                    }

                    // Center: swipe hint (below thumb, fades on drag)
                    HStack(spacing: DS.space4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9, weight: .semibold))
                        Text("swipe")
                            .font(.system(size: 10, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundColor(.secondary.opacity(0.5))
                    .opacity(1.0 - max(leftProgress, rightProgress) * 1.5)

                    // Draggable thumb
                    Circle()
                        .fill(.ultraThickMaterial)
                        .frame(width: 44, height: 44)
                        .overlay(
                            Image(systemName: "mic.fill")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(
                                    leftProgress > 0.5 ? .red :
                                    rightProgress > 0.5 ? .accentColor :
                                    .primary.opacity(0.7)
                                )
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                        .offset(x: thumbOffset)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard !gestureLocked else { return }

                                    let maxTravel = halfThreshold * 1.1
                                    thumbOffset = max(-maxTravel, min(maxTravel, value.translation.width))

                                    if thumbOffset < -halfThreshold {
                                        // ← Cancel
                                        gestureLocked = true
                                        Haptics.warning()
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                            thumbOffset = -(barWidth * 0.45)
                                        }
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                            cancelRecording()
                                            resetThumb()
                                        }
                                    } else if thumbOffset > halfThreshold {
                                        // → Send
                                        gestureLocked = true
                                        Haptics.success()
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                            thumbOffset = barWidth * 0.45
                                        }
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                            sendRecordingImmediately()
                                            resetThumb()
                                        }
                                    }
                                }
                                .onEnded { _ in
                                    if !gestureLocked {
                                        // Spring back → preview mode
                                        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                            thumbOffset = 0
                                        }
                                        stopRecording()
                                    }
                                }
                        )
                        .animation(.interactiveSpring(response: 0.15, dampingFraction: 0.8), value: thumbOffset)
                }
                .frame(height: 56)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 90) // 26 (timer capsule) + 8 (spacing) + 56 (track)
        .padding(.horizontal, DS.space16)
        .padding(.bottom, DS.space16)
        .padding(.bottom, DS.space12)
    }

    // MARK: - Voice Preview Bar

    private func voicePreviewBar(audioURL: URL) -> some View {
        HStack(spacing: DS.space12) {
            // Play / Pause
            Button {
                togglePreviewPlayback(url: audioURL)
            } label: {
                Image(systemName: isPlayingPreview ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.accentColor)
            }

            // Waveform
            HStack(spacing: 2) {
                ForEach(0..<24, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.accentColor.opacity(0.4 + 0.3 * sin(Double(i) * 0.5)))
                        .frame(width: 2.5, height: waveformHeight(for: i))
                }
            }
            .frame(height: 24)

            // Duration
            Text(formatDuration(previewDuration))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)

            Spacer()

            // Re-record
            Button {
                withAnimation(.spring(response: 0.3)) {
                    deleteRecording()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        startRecording()
                    }
                }
            } label: {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.secondary)
            }

            // Delete
            Button {
                withAnimation(.spring(response: 0.25)) {
                    deleteRecording()
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.secondary)
            }

            // Send preview
            Button {
                guard let url = recordedAudioURL else { return }
                let dur = previewDuration
                withAnimation(.spring(response: 0.25)) {
                    recordedAudioURL = nil
                    previewDuration = 0
                }
                Haptics.success()
                onSend(url, dur)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.horizontal, DS.space12)
        .padding(.vertical, DS.space8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusInner))
    }

    // MARK: - Recording Logic

    func startRecording() {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            guard granted else {
                #if DEBUG
                print("🎤 Microphone permission denied")
                #endif
                return
            }

            // Bug 6 fix: Use async Task to properly await setActive before recording
            Task { @MainActor in
                // UX: Show preparing indicator immediately so user knows the tap registered
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.isPreparing = true
                }
                
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
                    // ✅ Bug 6 fix: Await setActive — Bluetooth handshake can take 0.5-3s
                    await Task.detached(priority: .userInitiated) {
                        try? session.setActive(true)
                    }.value

                    let tempDir = FileManager.default.temporaryDirectory
                    let fileName = "voice_\(UUID().uuidString).m4a"
                    let audioURL = tempDir.appendingPathComponent(fileName)

                    let settings: [String: Any] = [
                        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                        AVSampleRateKey: 44100.0,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                    ]

                    let recorder = try AVAudioRecorder(url: audioURL, settings: settings)
                    recorder.record()

                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        self.isPreparing = false
                        self.audioRecorder = recorder
                        self.isRecording = true
                        self.recordingDuration = 0
                    }
                    // UX: Success haptic confirms mic is now live
                    Haptics.success()

                    self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                        DispatchQueue.main.async {
                            self.recordingDuration = recorder.currentTime
                            if self.recordingDuration >= self.maxDuration {
                                self.stopRecording()
                            }
                        }
                    }
                } catch {
                    self.isPreparing = false
                    #if DEBUG
                    print("❌ Failed to start recording: \(error)")
                    #endif
                }
            }
        }
    }

    private func stopRecording() {
        guard let recorder = audioRecorder, isRecording else { return }

        recordingTimer?.invalidate()
        recordingTimer = nil

        let finalDuration = max(recordingDuration, recorder.currentTime)
        recorder.stop()

        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            isRecording = false
        }

        // Keep if > 0.5s → preview mode
        if finalDuration > 0.5 {
            withAnimation(.spring(response: 0.3)) {
                recordedAudioURL = recorder.url
                previewDuration = finalDuration
            }
            Haptics.success()
        } else {
            try? FileManager.default.removeItem(at: recorder.url)
            recordedAudioURL = nil
            Haptics.light()
        }

        audioRecorder = nil
    }

    private func cancelRecording() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        audioRecorder?.stop()

        if let url = audioRecorder?.url {
            try? FileManager.default.removeItem(at: url)
        }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            isRecording = false
            recordedAudioURL = nil
            audioRecorder = nil
            recordingDuration = 0
        }
        onCancel()
    }

    private func sendRecordingImmediately() {
        guard let recorder = audioRecorder, isRecording else { return }

        recordingTimer?.invalidate()
        recordingTimer = nil

        let finalDuration = max(recordingDuration, recorder.currentTime)
        recorder.stop()

        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            isRecording = false
        }

        guard finalDuration > 0.5 else {
            try? FileManager.default.removeItem(at: recorder.url)
            audioRecorder = nil
            return
        }

        let audioURL = recorder.url
        audioRecorder = nil
        recordedAudioURL = nil
        previewDuration = 0

        onSend(audioURL, finalDuration)
    }

    private func deleteRecording() {
        previewPlayer?.stop()
        isPlayingPreview = false
        if let url = recordedAudioURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordedAudioURL = nil
        previewDuration = 0
    }

    // MARK: - Preview Playback

    private func togglePreviewPlayback(url: URL) {
        if isPlayingPreview {
            previewPlayer?.stop()
            isPlayingPreview = false
        } else {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)

                previewPlayer = try AVAudioPlayer(contentsOf: url)
                previewPlayer?.play()
                isPlayingPreview = true

                DispatchQueue.main.asyncAfter(deadline: .now() + (previewPlayer?.duration ?? 0) + 0.1) {
                    isPlayingPreview = false
                }
            } catch {
                #if DEBUG
                print("❌ Preview playback failed: \(error)")
                #endif
            }
        }
    }

    // MARK: - Helpers

    private func resetThumb() {
        thumbOffset = 0
        gestureLocked = false
    }

    private func waveformHeight(for index: Int) -> CGFloat {
        let seed = sin(Double(index) * 1.3 + 0.7) * cos(Double(index) * 0.8)
        return CGFloat(4 + abs(seed) * 16)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
