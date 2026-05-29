// VoiceReplyView.swift
//
// Record a short M4A clip and ship it to the phone via WCSession's
// `transferFile`. The phone treats it as a regular voice message —
// uploads to media storage, signs, and routes through the mesh.

import SwiftUI

struct VoiceReplyView: View {
    let roomId: String
    let recipientId: String

    @StateObject private var recorder = VoiceRecorder()
    @EnvironmentObject var bridge: PhoneBridge
    @Environment(\.dismiss) private var dismiss
    @State private var status: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: recorder.isRecording ? "waveform.circle.fill" : "mic.circle")
                .resizable()
                .scaledToFit()
                .frame(width: 60, height: 60)
                .foregroundStyle(recorder.isRecording ? .red : .accentColor)

            Text(formatElapsed(recorder.elapsed))
                .font(.title3.monospacedDigit())

            if let status {
                Text(status).font(.caption2).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if recorder.isRecording {
                    Button("Cancel") {
                        recorder.cancel()
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .tint(.gray)

                    Button("Send") { sendNow() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        do { try recorder.start() } catch {
                            status = "Mic unavailable"
                        }
                    } label: {
                        Label("Record", systemImage: "record.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
        }
        .padding(8)
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sendNow() {
        guard let url = recorder.stop() else {
            status = "No audio captured"
            return
        }
        bridge.sendVoiceReply(fileURL: url, recipientId: recipientId, roomId: roomId)
        dismiss()
    }

    private func formatElapsed(_ s: TimeInterval) -> String {
        let total = Int(s)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
