// InboxView.swift
//
// Conversation list. One row per chat, sorted by lastAt descending. The
// header lights up briefly when the phone pushes a fresh snapshot so
// the user can tell their view is live.

import SwiftUI

struct InboxView: View {
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var bridge: PhoneBridge

    private var conversations: [ConversationSummary] {
        store.snapshot.conversations.sorted(by: { $0.lastAt > $1.lastAt })
    }

    var body: some View {
        NavigationStack {
            List {
                if conversations.isEmpty {
                    EmptyInboxRow()
                } else {
                    ForEach(conversations) { conv in
                        NavigationLink(destination: ChatView(conversation: conv)) {
                            ConversationRow(conv: conv,
                                            pending: store.pendingMeshSends.contains(conv.id))
                        }
                    }
                }
            }
            .listStyle(.carousel)
            .navigationTitle("Inbox")
            .refreshable {
                _ = await bridge.requestSnapshot()
            }
        }
    }
}

private struct ConversationRow: View {
    let conv: ConversationSummary
    let pending: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AvatarCircle(initial: conv.avatarInitial, isGroup: conv.isGroup)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(conv.title).font(.headline).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(TimeFormatter.shortRelative(conv.lastAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(conv.lastPreview)
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
                if pending {
                    Label("Mesh", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            if conv.unread > 0 {
                Text("\(conv.unread)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.red, in: Capsule())
            }
        }
        .padding(.vertical, 2)
    }
}

private struct EmptyInboxRow: View {
    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            Image(systemName: "tray")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No chats yet")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Send a message from your iPhone to get started.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}
