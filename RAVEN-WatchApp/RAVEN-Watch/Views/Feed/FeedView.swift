// FeedView.swift
//
// Echo Wall feed — recent posts. Each row supports:
//
//   • Tap heart → toggle like (optimistic, phone confirms)
//   • Tap chat-bubble → opens dictation-comment view
//   • Long-press → reaction palette (phone-side decides where to post)
//
// The Watch never creates new posts (no camera, no rich composer
// surface). Posts come from the phone, comments / likes go to the
// phone, the phone routes them through the normal API.

import SwiftUI

struct FeedView: View {
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var bridge: PhoneBridge

    private var posts: [PostPreview] {
        store.snapshot.feed.sorted(by: { $0.createdAt > $1.createdAt })
    }

    var body: some View {
        NavigationStack {
            List {
                if posts.isEmpty {
                    EmptyFeedRow()
                } else {
                    ForEach(posts) { post in
                        PostRow(post: post)
                    }
                }
            }
            .listStyle(.carousel)
            .navigationTitle("Echo")
            .refreshable {
                _ = await bridge.requestSnapshot()
            }
        }
    }
}

private struct PostRow: View {
    let post: PostPreview
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var bridge: PhoneBridge

    @State private var showingCommentSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                AvatarCircle(initial: post.authorInitial, isGroup: false)
                    .frame(width: 22, height: 22)
                Text(post.authorName).font(.caption.bold())
                Spacer()
                Text(TimeFormatter.shortRelative(post.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(post.text)
                .font(.caption)
                .lineLimit(5)
            if post.hasMedia {
                Label("Media", systemImage: "photo")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button {
                    store.toggleLikeOptimistic(postId: post.id)
                    Task { _ = await bridge.togglePostLike(postId: post.id) }
                } label: {
                    Label("\(post.likeCount)", systemImage: post.likedByMe ? "heart.fill" : "heart")
                        .font(.caption2)
                        .foregroundStyle(post.likedByMe ? .pink : .secondary)
                }
                .buttonStyle(.plain)

                Button {
                    showingCommentSheet = true
                } label: {
                    Label("\(post.commentCount)", systemImage: "bubble.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 3)
        .sheet(isPresented: $showingCommentSheet) {
            PostCommentView(postId: post.id, authorName: post.authorName)
        }
    }
}

private struct PostCommentView: View {
    let postId: String
    let authorName: String

    @EnvironmentObject var bridge: PhoneBridge
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reply to \(authorName)").font(.caption).foregroundStyle(.secondary)
            TextField("Comment", text: $text, axis: .vertical)
                .lineLimit(2...4)
                .submitLabel(.send)
                .onSubmit { Task { await send() } }
            Button {
                Task { await send() }
            } label: {
                if sending { ProgressView() } else { Label("Post", systemImage: "paperplane.fill") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(text.isEmpty || sending)
        }
        .padding(.horizontal, 4)
    }

    private func send() async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        sending = true
        defer { sending = false }
        _ = await bridge.commentOnPost(postId: postId, text: body)
        dismiss()
    }
}

private struct EmptyFeedRow: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.stack").font(.title2).foregroundStyle(.secondary)
            Text("Quiet on the wall").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}
