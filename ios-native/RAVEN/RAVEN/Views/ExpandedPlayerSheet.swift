import SwiftUI

// MARK: - Expanded Player Sheet
/// Full voice player with large waveform, scrubber, skip controls, rate, transcript.

struct ExpandedPlayerSheet: View {
    @State private var audioStore = AudioPlaybackStore.shared
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    
    var body: some View {
        if let item = audioStore.currentItem {
            VStack(spacing: 0) {
                // Drag handle
                Capsule()
                    .fill(.white.opacity(0.25))
                    .frame(width: 40, height: 4)
                    .padding(.top, 14)
                    .padding(.bottom, 24)
                
                // MARK: - Sender Info
                VStack(spacing: 6) {
                    // Avatar
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [.teal.opacity(0.3), .teal.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 80, height: 80)
                        
                        Image(systemName: "waveform")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(.teal)
                            .symbolEffect(.variableColor.iterative, isActive: audioStore.isPlaying)
                    }
                    .padding(.bottom, 8)
                    
                    Text(item.senderName.looksEncrypted ? "Voice" : item.senderName)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.primary)
                    
                    Text(contextLabel(item.contentType))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 28)
                
                // MARK: - Waveform + Scrubber
                VStack(spacing: 10) {
                    waveformView(samples: item.waveform)
                        .frame(height: 48)
                        .padding(.horizontal, 8)
                    
                    // Scrubber slider
                    Slider(
                        value: Binding(
                            get: { isScrubbing ? scrubValue : audioStore.progress },
                            set: { newVal in
                                isScrubbing = true
                                scrubValue = newVal
                            }
                        ),
                        in: 0...1,
                        onEditingChanged: { editing in
                            if !editing {
                                audioStore.seek(to: scrubValue)
                                isScrubbing = false
                            }
                        }
                    )
                    .tint(.teal)
                    
                    // Time labels
                    HStack {
                        Text(formatTime(audioStore.currentTime))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                        
                        Spacer()
                        
                        Text("-\(formatTime(audioStore.duration - audioStore.currentTime))")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
                
                // MARK: - Controls
                HStack(spacing: 36) {
                    // Playback rate
                    Button {
                        Haptics.light()
                        audioStore.cycleRate()
                    } label: {
                        Text(rateLabel)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(.teal)
                            .frame(width: 44, height: 44)
                            .background(.teal.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                    
                    // Skip back 10s
                    Button {
                        Haptics.light()
                        audioStore.skip(seconds: -10)
                    } label: {
                        Image(systemName: "gobackward.10")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    
                    // Play / Pause (large)
                    Button {
                        Haptics.medium()
                        audioStore.togglePlayPause()
                    } label: {
                        Image(systemName: audioStore.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 64, height: 64)
                            .background(
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [.teal, .teal.opacity(0.7)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            )
                            .shadow(color: .teal.opacity(0.3), radius: 12, y: 4)
                    }
                    .buttonStyle(.plain)
                    
                    // Skip forward 10s
                    Button {
                        Haptics.light()
                        audioStore.skip(seconds: 10)
                    } label: {
                        Image(systemName: "goforward.10")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    
                    // Transcript (if supported)
                    if item.contentId != nil {
                        Button {
                            Haptics.light()
                            // Transcript handled by TranscriptPill in-context
                        } label: {
                            Image(systemName: "text.quote")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.teal)
                                .frame(width: 44, height: 44)
                                .background(.teal.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 20)
                
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
            )
        }
    }
    
    // MARK: - Waveform
    
    private func waveformView(samples: [Float]?) -> some View {
        HStack(spacing: 2) {
            let bars = samples ?? Array(repeating: Float(0.3), count: 40)
            let displayBars = Array(bars.prefix(50))
            
            ForEach(Array(displayBars.enumerated()), id: \.offset) { index, sample in
                let barProgress = Double(index) / Double(max(1, displayBars.count - 1))
                let isPlayed = barProgress <= audioStore.progress
                
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isPlayed ? Color.teal : Color.white.opacity(0.2))
                    .frame(width: 3, height: max(4, CGFloat(sample) * 44))
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - Helpers
    
    private var rateLabel: String {
        switch audioStore.playbackRate {
        case 1.5: return "1.5"
        case 2.0: return "2×"
        default:  return "1×"
        }
    }
    
    private func contextLabel(_ type: String) -> String {
        switch type {
        case "post":    return "Voice Post"
        case "comment": return "Voice Comment"
        case "dm":      return "Voice Message"
        case "group":   return "Group Voice Message"
        default:        return "Voice"
        }
    }
    
    private func formatTime(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
