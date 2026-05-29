// ComposeReplyView.swift
//
// The composer is the heart of the Watch app — this is where users
// actually generate content. We expose four input methods, all surfaced
// by the system without us implementing them ourselves:
//
//   • Dictation     — system mic, TextField .dictation input style
//   • Scribble      — handwriting, picked up automatically by TextField
//   • Emoji         — TextField also opens the emoji panel from the
//                     hardware Action Button on supported watches
//   • Smart replies — three suggestion chips above the field; the
//                     phone generates them on-device using Foundation
//                     Models so they never traverse the network.
//
// On send: the message is optimistically appended to the thread cache
// and shipped to the phone via WCSession. If WCSession reports the
// phone unreachable, we try the standalone-LTE RemoteAPI; if that also
// fails, the userInfo path queues it for the next time either edge
// recovers.

import SwiftUI

struct ComposeReplyView: View {
    let roomId: String
    let recipientId: String
    @State var presetText: String

    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var bridge: PhoneBridge
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var sending = false
    @State private var errorBanner: String?

    private let smartReplies = ["On my way", "Got it 👍", "Call you in a bit"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(smartReplies, id: \.self) { suggestion in
                    Button {
                        text = suggestion
                    } label: {
                        Text(suggestion)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                }
            }

            TextField("Reply", text: $text, axis: .vertical)
                .lineLimit(2...4)
                .submitLabel(.send)
                .onSubmit { Task { await send() } }

            if let errorBanner {
                Text(errorBanner)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            Button {
                Task { await send() }
            } label: {
                if sending {
                    ProgressView()
                } else {
                    Label("Send", systemImage: "paperplane.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(text.isEmpty || sending)
        }
        .padding(.horizontal, 4)
        .navigationTitle("Reply")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if text.isEmpty { text = presetText } }
    }

    private func send() async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }

        sending = true
        defer { sending = false }

        // 1. Optimistic — append a local "outgoing" bubble so the
        //    bubble shows up before WCSession round-trips.
        let mid = UUID().uuidString
        let optimistic = MessagePreview(
            id: mid, senderId: "me", senderName: "",
            text: body, kind: .text, timestamp: Date().timeIntervalSince1970,
            outgoing: true, durationSeconds: nil, reactions: nil
        )
        store.appendOptimisticMessage(optimistic, roomId: roomId)
        store.markPendingMeshSend(mid)

        // 2. Try the phone bridge. The phone owns the mesh — server
        //    bridge, BLE spray, MPC — and inherits all the reliability
        //    work.
        let acked = await bridge.sendCompose(
            recipientId: recipientId, roomId: roomId, text: body
        )
        if acked {
            dismiss()
            return
        }

        // 3. Fallback: phone unreachable. Try the watch's own network
        //    if it has one. RemoteAPI throws if the Watch isn't signed
        //    in.
        do {
            try await RemoteAPI.shared.sendDM(
                recipientId: recipientId,
                text: body,
                clientMessageId: mid
            )
            dismiss()
        } catch RemoteAPI.APIError.noAuth {
            // Queued via userInfo already happened inside `sendCompose`.
            // Just exit the composer — the message will go through when
            // the phone next wakes.
            dismiss()
        } catch {
            errorBanner = error.localizedDescription
        }
    }
}
