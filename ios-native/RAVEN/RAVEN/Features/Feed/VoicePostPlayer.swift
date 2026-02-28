import SwiftUI
import AVFoundation

// MARK: - Voice Post Player (Liquid Glass Capsule)
/// Reusable voice player for feed cards, detail views, and comments.
/// Fixed-height glass capsule with [Play] [Waveform] [Duration] layout.
/// Delegates playback to the global AudioPlaybackStore for mini player support.
struct VoicePostPlayer: View {
    let voiceUrl: String
    let duration: Int          // seconds
    let waveform: [Float]?
    var compact: Bool = false  // smaller variant for comments
    var contentId: String? = nil    // Post or Comment ID for transcription
    var contentType: TranscriptPill.TranscriptContentType = .post
    var senderName: String = "Voice"
    var senderAvatar: String? = nil
    
    @State private var audioStore = AudioPlaybackStore.shared
    @State private var glowPulse = false
    
    // MARK: - Local State (prevents re-rendering all voice players)
    /// Only the actively-playing voice updates these; dormant players stay at 0.
    @State private var localIsPlaying: Bool = false
    @State private var localProgress: Double = 0
    @State private var localCurrentTime: TimeInterval = 0
    @State private var progressTimer: Timer? = nil
    
    // MARK: - Derived (static, no re-render)
    private var itemId: String { contentId ?? voiceUrl }
    
    // MARK: - Layout Constants
    private var playerHeight: CGFloat { compact ? 40 : 48 }
    private var buttonSize: CGFloat { compact ? 30 : 36 }
    private var waveformHeight: CGFloat { compact ? 16 : 20 }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // ── Glass Player Row ──────────────────────────────
            HStack(spacing: compact ? 8 : 10) {
                // Play / Pause
                Button {
                    Haptics.light()
                    playViaGlobalStore()
                } label: {
                    Image(systemName: localIsPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: compact ? 12 : 14, weight: .semibold))
                        .foregroundStyle(localIsPlaying ? .teal : .primary)
                        .frame(width: buttonSize, height: buttonSize)
                        .background(
                            Circle()
                                .fill(localIsPlaying ? .teal.opacity(0.15) : Color.primary.opacity(0.06))
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    localIsPlaying ? .teal.opacity(0.3) : Color.primary.opacity(0.12),
                                    lineWidth: 0.5
                                )
                        )
                        .shadow(
                            color: localIsPlaying ? .teal.opacity(0.3) : .clear,
                            radius: glowPulse ? 8 : 3
                        )
                        .scaleEffect(glowPulse && localIsPlaying ? 1.05 : 1.0)
                }
                .buttonStyle(.plain)
                
                // Waveform or fallback progress bar
                Group {
                    if let waveform = waveform, !waveform.isEmpty {
                        waveformView(samples: waveform)
                    } else {
                        progressBarView
                    }
                }
                .frame(height: waveformHeight)
                .clipped()
                
                // Duration — fixed-width column, never overlaps waveform
                Text(formatTime(localIsPlaying ? localCurrentTime : TimeInterval(duration)))
                    .font(.system(size: compact ? 10 : 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: compact ? 32 : 40, alignment: .trailing)
            }
            .padding(.horizontal, compact ? 8 : 12)
            .frame(height: playerHeight)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background(Color(.systemGray6).opacity(0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        localIsPlaying ? .teal.opacity(0.25) : Color.primary.opacity(0.08),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: localIsPlaying ? .teal.opacity(0.1) : .black.opacity(0.04),
                radius: 6, y: 2
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .animation(.easeInOut(duration: 0.3), value: localIsPlaying)
            
            // ── Transcript chip row ──────────────────────────
            if let id = contentId {
                TranscriptPill(contentId: id, contentType: contentType)
            }
        }
        .onChange(of: localIsPlaying) { _, playing in
            if playing {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    glowPulse = true
                }
            } else {
                withAnimation { glowPulse = false }
            }
        }
        // Detect when this voice starts/stops playing
        .onChange(of: audioStore.currentItem?.id) { _, newId in
            let shouldPlay = (newId == itemId) && audioStore.isPlaying
            if shouldPlay != localIsPlaying {
                localIsPlaying = shouldPlay
            }
            if !shouldPlay {
                // Reset progress when a different item starts playing
                stopProgressTimer()
                localProgress = 0
                localCurrentTime = 0
            } else {
                startProgressTimer()
            }
        }
        .onChange(of: audioStore.isPlaying) { _, playing in
            let shouldPlay = playing && audioStore.currentItem?.id == itemId
            if shouldPlay != localIsPlaying {
                localIsPlaying = shouldPlay
            }
            if shouldPlay {
                startProgressTimer()
            } else {
                stopProgressTimer()
            }
        }
        .onDisappear {
            stopProgressTimer()
        }
    }
    
    // MARK: - Progress Timer (only runs for the active player)
    
    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                guard audioStore.currentItem?.id == itemId else {
                    stopProgressTimer()
                    return
                }
                localProgress = audioStore.progress
                localCurrentTime = audioStore.currentTime
            }
        }
    }
    
    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
    
    // MARK: - Delegate to Global Store
    private func playViaGlobalStore() {
        let typeString: String
        switch contentType {
        case .post: typeString = "post"
        case .comment: typeString = "comment"
        case .message: typeString = "message"
        }
        
        let item = AudioItem(
            id: itemId,
            voiceUrl: voiceUrl,
            duration: duration,
            waveform: waveform,
            senderName: senderName,
            senderAvatar: senderAvatar,
            contentId: contentId,
            contentType: typeString
        )
        audioStore.play(item: item)
    }
    
    // MARK: - Waveform View (Canvas-based, respects parent width)
    private func waveformView(samples: [Float]) -> some View {
        Canvas { context, size in
            let barWidth: CGFloat = 3
            let barSpacing: CGFloat = 2
            let step = barWidth + barSpacing
            let maxBars = max(1, Int(size.width / step))
            
            // Downsample if needed
            let displaySamples: [Float]
            if samples.count > maxBars {
                let ratio = Float(samples.count) / Float(maxBars)
                displaySamples = (0..<maxBars).map { i in
                    let idx = min(Int(Float(i) * ratio), samples.count - 1)
                    return samples[idx]
                }
            } else {
                displaySamples = samples
            }
            
            let totalBarsWidth = CGFloat(displaySamples.count) * step - barSpacing
            let startX = (size.width - totalBarsWidth) / 2 // center
            
            for (i, sample) in displaySamples.enumerated() {
                let normalized = max(0.15, CGFloat(sample))
                let barH = size.height * normalized
                let x = startX + CGFloat(i) * step
                let y = (size.height - barH) / 2
                let isPlayed = Double(i) / Double(max(1, displaySamples.count)) <= localProgress
                
                let rect = CGRect(x: x, y: y, width: barWidth, height: barH)
                let path = RoundedRectangle(cornerRadius: 1.5).path(in: rect)
                context.fill(path, with: .color(isPlayed ? .teal : Color.primary.opacity(0.22)))
            }
        }
        .frame(height: waveformHeight)
    }
    
    // MARK: - Progress Bar (No GeometryReader)
    private var progressBarView: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 4)
            
            Capsule()
                .fill(Color.teal.opacity(0.7))
                .frame(height: 4)
                .scaleEffect(x: max(0.001, localProgress), y: 1, anchor: .leading)
                .animation(.linear(duration: 0.1), value: localProgress)
        }
        .frame(height: 4)
    }
    
    // MARK: - Format
    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}


// MARK: - Voice Recording Sheet for CreatePostView
/// Bottom sheet with Liquid Glass design for recording voice posts.
struct VoiceRecordingSheet: View {
    @Bindable var recorder: AudioRecorderService
    let onDone: () -> Void
    let onCancel: () -> Void
    
    @State private var pulseScale: CGFloat = 1.0
    
    var body: some View {
        VStack(spacing: 20) {
            // Handle bar
            Capsule()
                .fill(Color.primary.opacity(0.2))
                .frame(width: 40, height: 4)
                .padding(.top, 12)
            
            // Title
            Text(titleText)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
            
            // Waveform / Recorded Preview
            waveformDisplay
                .frame(height: 60)
                .padding(.horizontal, 20)
            
            // Duration
            Text(formattedDuration)
                .font(.system(size: 28, weight: .light, design: .monospaced))
                .foregroundStyle(.primary)
            
            // Duration limits
            if case .recording = recorder.state {
                Text("Min \(Int(recorder.minDuration))s • Max \(Int(recorder.maxDuration))s")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            
            // Controls
            HStack(spacing: 32) {
                switch recorder.state {
                case .idle:
                    // Record button
                    recordButton
                    
                case .recording:
                    // Stop button
                    stopButton
                    
                case .recorded:
                    // Delete / Play / Done
                    deleteButton
                    playButton
                    doneButton
                    
                case .playing:
                    deleteButton
                    stopPlaybackButton
                    doneButton
                }
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 20, y: -5)
        .alert("Microphone Access Required", isPresented: $recorder.permissionDenied) {
            Button("Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Please enable microphone access in Settings to record voice posts.")
        }
        .onDisappear {
            // SAFETY: Stop recording if sheet is dismissed interactively (swipe-down)
            // without tapping Cancel/Done — prevents hot-mic privacy leak.
            if case .recording = recorder.state {
                recorder.stopRecording()
            }
        }
    }
    
    // MARK: - Subviews
    
    private var titleText: String {
        switch recorder.state {
        case .idle: return "Record Voice"
        case .recording: return "Recording..."
        case .recorded: return "Preview"
        case .playing: return "Playing..."
        }
    }
    
    private var formattedDuration: String {
        let t = recorder.currentTime
        let mins = Int(t) / 60
        let secs = Int(t) % 60
        return String(format: "%d:%02d", mins, secs)
    }
    
    private var waveformDisplay: some View {
        GeometryReader { geo in
            let samples = recorder.waveformSamples
            if samples.isEmpty {
                // Placeholder bars
                HStack(spacing: 3) {
                    ForEach(0..<30, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.primary.opacity(0.12))
                            .frame(width: 3, height: 8)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                // Live / recorded waveform
                HStack(spacing: 2) {
                    let maxBars = Int(geo.size.width / 5)
                    let displaySamples = samples.suffix(maxBars)
                    ForEach(Array(displaySamples.enumerated()), id: \.offset) { _, sample in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.primary.opacity(0.7))
                            .frame(width: 3, height: max(4, CGFloat(sample) * geo.size.height))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
        }
    }
    
    private var recordButton: some View {
        Button {
            Task { await recorder.startRecording() }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.15))
                    .frame(width: 72, height: 72)
                
                Circle()
                    .fill(Color.red)
                    .frame(width: 56, height: 56)
                    .overlay(
                        Image(systemName: "mic.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.white)
                    )
            }
        }
        .buttonStyle(.plain)
    }
    
    private var stopButton: some View {
        Button {
            recorder.stopRecording()
        } label: {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.15))
                    .frame(width: 72, height: 72)
                    .scaleEffect(pulseScale)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                            pulseScale = 1.15
                        }
                    }
                    .onDisappear { pulseScale = 1.0 }
                
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.red)
                    .frame(width: 28, height: 28)
            }
        }
        .buttonStyle(.plain)
    }
    
    private var deleteButton: some View {
        Button {
            Haptics.light()
            recorder.deleteRecording()
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.red)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
    
    private var playButton: some View {
        Button {
            Haptics.light()
            recorder.playPreview()
        } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 56, height: 56)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
    
    private var stopPlaybackButton: some View {
        Button {
            recorder.stopPreview()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 56, height: 56)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
    
    private var doneButton: some View {
        Button {
            Haptics.medium()
            onDone()
        } label: {
            Image(systemName: "checkmark")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.accentColor)
                .clipShape(Circle())
                .shadow(color: .accentColor.opacity(0.3), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }
}
