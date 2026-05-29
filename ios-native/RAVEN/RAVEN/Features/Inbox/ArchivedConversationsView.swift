//
//  ArchivedConversationsView.swift
//  RAVEN
//
//  The destination behind the "Archived Chats" pill — shows the
//  archived bucket, lets the user open a chat, unarchive (swipe
//  left), or permanently delete.
//
//  We deliberately reuse `ConversationRowView` from the main inbox
//  so visually the list looks identical to a regular inbox; the
//  only differences are the navigation title, the empty state, and
//  the swipe-action set ("Unarchive" + "Delete" instead of
//  "Archive" + "Mute" + "Delete").
//

import SwiftUI

struct ArchivedConversationsView: View {
    /// `@Observable`-aware reference. Reading `store.conversations`
    /// inside `body` registers this view with the Observation runtime,
    /// so SwiftUI re-renders whenever ConversationStore mutates — the
    /// previous design held a hand-managed `archived` snapshot that
    /// only refreshed on `.task` / `.onAppear`, so a server-sync that
    /// archived a new room while this screen was visible left stale
    /// rows on screen until the user navigated away. Bug fix
    /// (2026-05-10): drive the list directly off the store.
    private let store = ConversationStore.shared

    /// Optimistic slide-out — when a row is unarchived we want it to
    /// fade out before the underlying store snapshot refreshes.
    @State private var pendingRemoval: Set<String> = []

    /// Live-derived list. Reading `store.conversations` here is the
    /// observation entry-point that wires us into Observation tracking.
    private var archived: [Conversation] {
        store.conversations.filter { $0.isArchived && !pendingRemoval.contains($0.roomId) }
    }

    var body: some View {
        Group {
            if archived.isEmpty {
                emptyState
            } else {
                listContent
            }
        }
        .navigationTitle("Archived Chats")
        .navigationBarTitleDisplayMode(.inline)
        // Initial fetch in case the store hasn't been hydrated yet
        // (cold-launch into this screen via deep link). Subsequent
        // updates come for free from Observation.
        .task { await refresh() }
    }

    // MARK: - List

    private var listContent: some View {
        List {
            ForEach(archived) { conversation in
                NavigationLink(value: conversation.roomId) {
                    ConversationRowView(conversation: conversation)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        let roomId = conversation.roomId
                        Task {
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            await store.deleteConversation(roomId: roomId)
                            await refresh()
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }

                    Button {
                        let roomId = conversation.roomId
                        // Optimistic slide-out so the row leaves the
                        // archive list immediately when tapped.
                        withAnimation(.easeInOut(duration: 0.22)) {
                            pendingRemoval.insert(roomId)
                        }
                        Task {
                            try? await Task.sleep(nanoseconds: 220_000_000)
                            await store.toggleArchive(roomId: roomId)
                            await refresh()
                        }
                    } label: {
                        Label("Unarchive", systemImage: "tray.and.arrow.up.fill")
                    }
                    .tint(.green)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationDestination(for: String.self) { roomId in
            if let conv = store.conversations.first(where: { $0.roomId == roomId })
                ?? archived.first(where: { $0.roomId == roomId }) {
                ChatView(conversation: conv).id(roomId)
            } else {
                RoutedChatView(chatId: roomId, isGroup: false).id(roomId)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.indigo.opacity(0.12))
                    .frame(width: 88, height: 88)
                Image(systemName: "archivebox")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(Color.indigo)
            }
            Text("No archived chats")
                .font(.headline)
            Text("Swipe a conversation in your inbox to archive it.\nIt will land here, out of the way but not deleted.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data

    private func refresh() async {
        // Side-effect call: populates store.conversations from disk
        // and triggers any server-side hydration. The view re-renders
        // automatically because `archived` reads from store.conversations
        // which is `@Observable`-tracked.
        _ = await store.loadArchivedConversations()
        await MainActor.run {
            self.pendingRemoval.removeAll()
        }
    }
}
