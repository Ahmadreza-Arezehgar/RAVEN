// ChatView.swift
//
// One thread. We pull the cached messages out of `WatchStore.threads`
// (populated by the phone via a `thread-snapshot` payload) and render
// them in a vertical list. Long-pressing a row opens a reactions
// picker; the navigation toolbar carries the Reply / Voice / Mark-Read
// actions.

import SwiftUI

struct ChatView: View {
    let conversation: ConversationSummary
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var bridge: PhoneBridge

    @State private var showingReactionFor: MessagePreview?

    private var messages: [MessagePreview] {
        (store.threads[conversation.id] ?? [])
            .sorted(by: { $0.timestamp < $1.timestamp })
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(messages) { msg in
                    MessageRow(msg: msg)
                        .id(msg.id)
                        .onLongPressGesture { showingReactionFor = msg }
                }
            }
            .listStyle(.carousel)
            .navigationTitle(conversation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    NavigationLink {
                        ComposeReplyView(
                            roomId: conversation.id,
                            recipientId: "",
                            presetText: ""
                        )
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left.fill")
                    }
                    NavigationLink {
                        VoiceReplyView(roomId: conversation.id, recipientId: "")
                    } label: {
                        Image(systemName: "mic.fill")
                    }
                }
            }
            .task(id: conversation.id) {
                _ = await bridge.subscribeThread(roomId: conversation.id)
            }
            .onAppear {
                if let last = messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onDisappear {
                Task { @MainActor in
                    _ = await bridge.markRead(roomId: conversation.id, upTo: Date())
                }
            }
        }
        .sheet(item: $showingReactionFor) { msg in
            ReactionPicker(messageId: msg.id, roomId: conversation.id)
        }
    }
}

private struct MessageRow: View {
    let msg: MessagePreview

    var body: some View {
        VStack(alignment: msg.outgoing ? .trailing : .leading, spacing: 2) {
            if !msg.outgoing {
                Text(msg.senderName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            bubbleContent
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(
                    msg.outgoing ? Color.accentColor.opacity(0.6) : Color.gray.opacity(0.25),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .frame(maxWidth: .infinity,
                       alignment: msg.outgoing ? .trailing : .leading)
            if let rx = msg.reactions, !rx.isEmpty {
                HStack(spacing: 3) {
                    ForEach(rx.sorted(by: { $0.value > $1.value }), id: \.key) { entry in
                        Text("\(entry.key) \(entry.value)")
                            .font(.caption2)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        switch msg.kind {
        case .text:
            Text(msg.text ?? "").font(.body)
        case .voice:
            Label("Voice \(msg.durationSeconds.map(String.init) ?? "?")s",
                  systemImage: "waveform").font(.caption)
        case .image:
            Label("Photo", systemImage: "photo").font(.caption)
        case .file:
            Label("File", systemImage: "doc").font(.caption)
        case .post:
            Label("Shared post", systemImage: "square.stack").font(.caption)
        case .system:
            Text(msg.text ?? "")
                .font(.caption2.italic())
                .foregroundStyle(.secondary)
        }
    }
}

private struct ReactionPicker: View {
    let messageId: String
    let roomId: String
    @EnvironmentObject var bridge: PhoneBridge
    @Environment(\.dismiss) private var dismiss

    private let emojis = ["👍", "❤️", "😂", "🔥", "👀", "🙏"]

    var body: some View {
        VStack(spacing: 4) {
            Text("React").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [.init(.adaptive(minimum: 36))], spacing: 6) {
                ForEach(emojis, id: \.self) { emoji in
                    Button {
                        Task {
                            _ = await bridge.toggleReaction(
                                messageId: messageId,
                                roomId: roomId,
                                emoji: emoji
                            )
                            dismiss()
                        }
                    } label: {
                        Text(emoji).font(.title3)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(6)
    }
}
