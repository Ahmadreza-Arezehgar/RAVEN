// RAVEN - Voice Widgets
// Converted from Flutter voice_recorder.dart, voice_message_bubble.dart

import SwiftUI
import AVFoundation

// MARK: - Voice Recorder Button
struct VoiceRecorderButton: View {
    @ObservedObject var audioService = AudioService.shared
    @State private var isPressed = false
    @State private var showCancel = false
    
    var onSend: ((URL, TimeInterval) -> Void)?
    
    var body: some View {
        ZStack {
            // Cancel zone
            if audioService.isRecording {
                HStack {
                    ZStack {
                        Circle()
                            .fill(showCancel ? Color.red : Color(UIColor.systemGray4))
                            .frame(width: 60, height: 60)
                        
                        Image(systemName: "trash")
                            .foregroundColor(showCancel ? .white : .secondary)
                    }
                    
                    Spacer()
                }
                .padding(.horizontal)
            }
            
            // Recording indicator
            if audioService.isRecording {
                VStack {
                    // Waveform
                    HStack(spacing: 2) {
                        ForEach(0..<20, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.ravenPrimary)
                                .frame(width: 3, height: CGFloat.random(in: 8...(20 + CGFloat(audioService.recordingLevel) * 30)))
                                .animation(.easeInOut(duration: 0.1), value: audioService.recordingLevel)
                        }
                    }
                    .frame(height: 40)
                    
                    // Duration
                    Text(formatDuration(audioService.recordingDuration))
                        .font(.headline.monospacedDigit())
                        .foregroundColor(.ravenPrimary)
                }
            }
            
            // Mic button
            Circle()
                .fill(audioService.isRecording ? Color.ravenPrimary : Color(UIColor.systemGray5))
                .frame(width: isPressed ? 70 : 50, height: isPressed ? 70 : 50)
                .overlay(
                    Image(systemName: "mic.fill")
                        .font(.title2)
                        .foregroundColor(audioService.isRecording ? .white : .ravenPrimary)
                )
                .scaleEffect(isPressed ? 1.1 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isPressed)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isPressed {
                                isPressed = true
                                Haptics.impact(.medium)
                                _ = audioService.startRecording()
                            }
                            
                            // Check if dragged to cancel zone
                            showCancel = value.translation.width < -100
                        }
                        .onEnded { _ in
                            isPressed = false
                            
                            if showCancel {
                                audioService.cancelRecording()
                                Haptics.notification(.warning)
                            } else if let result = audioService.stopRecording() {
                                onSend?(result.0, result.1)
                                Haptics.notification(.success)
                            }
                            
                            showCancel = false
                        }
                )
        }
    }
    
    func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Voice Message Bubble
struct VoiceMessageBubble: View {
    let message: ChatMessage
    let isFromMe: Bool
    
    @ObservedObject var audioService = AudioService.shared
    @State private var waveformData: [Float] = Array(repeating: 0.5, count: 30)
    
    var isPlaying: Bool {
        audioService.isPlaying && audioService.currentPlaybackId == message.id
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Play/Pause button
            Button {
                if isPlaying {
                    audioService.pause()
                } else if let url = message.audioUrl {
                    audioService.playRemote(urlString: url, id: message.id)
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.ravenPrimary)
                        .frame(width: 44, height: 44)
                    
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .foregroundColor(.white)
                        .offset(x: isPlaying ? 0 : 2)
                }
            }
            
            // Waveform
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 2) {
                    ForEach(0..<30, id: \.self) { i in
                        let progress = isPlaying ? audioService.playbackProgress : 0
                        let isActive = Double(i) / 30.0 < progress
                        
                        RoundedRectangle(cornerRadius: 1)
                            .fill(isActive ? Color.ravenPrimary : Color(UIColor.systemGray4))
                            .frame(width: 2, height: CGFloat(8 + waveformData[i] * 20))
                    }
                }
                .frame(height: 30)
                .onTapGesture { location in
                    // Seek on tap
                    let progress = location.x / 100  // Approximate
                    audioService.seek(to: min(1, max(0, progress)))
                }
                
                // Duration
                HStack {
                    Text(formatDuration(isPlaying ? audioService.playbackProgress * (message.audioDuration ?? 0) : 0))
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text(formatDuration(message.audioDuration ?? 0))
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 100)
        }
        .padding(12)
        .background(isFromMe ? Color.ravenPrimary.opacity(0.15) : Color(UIColor.systemGray6))
        .cornerRadius(16)
        .onAppear {
            // Generate random waveform data (in real app, extract from audio)
            waveformData = (0..<30).map { _ in Float.random(in: 0.3...1.0) }
        }
    }
    
    func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Push to Talk Overlay
struct PTTOverlay: View {
    @Binding var isActive: Bool
    @ObservedObject var audioService = AudioService.shared
    
    var onSend: ((URL, TimeInterval) -> Void)?
    
    var body: some View {
        ZStack {
            // Background
            Color.black.opacity(0.8)
                .ignoresSafeArea()
            
            VStack(spacing: 32) {
                // Waveform
                HStack(spacing: 4) {
                    ForEach(0..<30, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.ravenPrimary)
                            .frame(width: 4, height: CGFloat(10 + CGFloat(audioService.recordingLevel) * 50))
                            .animation(.easeInOut(duration: 0.1), value: audioService.recordingLevel)
                    }
                }
                .frame(height: 60)
                
                // Duration
                Text(formatDuration(audioService.recordingDuration))
                    .font(.system(size: 48, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                
                // Status
                Text("Recording...")
                    .font(.headline)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                // Buttons
                HStack(spacing: 40) {
                    Button {
                        audioService.cancelRecording()
                        isActive = false
                    } label: {
                        VStack {
                            ZStack {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 60, height: 60)
                                
                                Image(systemName: "xmark")
                                    .font(.title2)
                                    .foregroundColor(.white)
                            }
                            Text("Cancel")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Button {
                        if let result = audioService.stopRecording() {
                            onSend?(result.0, result.1)
                        }
                        isActive = false
                    } label: {
                        VStack {
                            ZStack {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 60, height: 60)
                                
                                Image(systemName: "arrow.up")
                                    .font(.title2)
                                    .foregroundColor(.white)
                            }
                            Text("Send")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.bottom, 40)
            }
            .padding()
        }
        .onAppear {
            _ = audioService.startRecording()
        }
    }
    
    func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

#Preview {
    VStack {
        VoiceRecorderButton()
        
        VoiceMessageBubble(
            message: ChatMessage(
                id: "1",
                roomId: "room",
                senderId: "me",
                senderName: "Me",
                recipientId: "them",
                text: "",
                timestamp: Date(),
                type: .voice,
                audioUrl: "test.m4a",
                audioDuration: 15
            ),
            isFromMe: true
        )
    }
    .padding()
    .background(Color.black)
    .preferredColorScheme(.dark)
}
