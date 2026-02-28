import SwiftUI

// MARK: - Mini Player Bar (~70pt glass capsule)
/// Sits above the tab bar. Shows sender, waveform progress, play/pause.
/// Tap to expand. Shown when AudioPlaybackStore.displayState == .mini.

struct MiniPlayerBar: View {
    @State private var audioStore = AudioPlaybackStore.shared
    
    var body: some View {
        if let item = audioStore.currentItem {
            HStack(spacing: 12) {
                // Avatar / Waveform icon
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 38, height: 38)
                    
                    Image(systemName: audioStore.isPlaying ? "waveform" : "waveform")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.teal)
                        .symbolEffect(.variableColor.iterative, isActive: audioStore.isPlaying)
                }
                
                // Waveform / Progress
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.senderName.looksEncrypted ? "Voice" : item.senderName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    
                    // Progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(.white.opacity(0.1))
                                .frame(height: 3)
                            
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [.teal, .teal.opacity(0.6)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: geo.size.width * max(0.01, audioStore.progress), height: 3)
                                .animation(.linear(duration: 0.1), value: audioStore.progress)
                        }
                    }
                    .frame(height: 3)
                }
                
                // Time
                Text(formatTime(audioStore.duration - audioStore.currentTime))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
                
                // Play / Pause
                Button {
                    Haptics.light()
                    audioStore.togglePlayPause()
                } label: {
                    Image(systemName: audioStore.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle().fill(.teal.opacity(0.3))
                        )
                }
                .buttonStyle(.plain)
                
                // Close
                Button {
                    audioStore.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(height: 64)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
            .contentShape(Capsule())
            .onTapGesture {
                audioStore.expand()
            }
        }
    }
    
    private func formatTime(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
