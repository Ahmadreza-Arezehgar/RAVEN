// FeedView — the middle column on the Home tab.
//
//   • Sticky header: "Home" + tabs (For you / Friends / Local) with an
//     animated underline
//   • Compose card: avatar + "What's happening?" + Post button
//   • Floating post cards: each one is its own raised surface with
//     spacing + soft shadow + hover-lift, animated in with a 30 ms
//     stagger so the feed "settles" rather than blink-loads.
//
// Repost is intentionally not surfaced — the iOS production app doesn't
// expose it, and the user wants this build to match.

import SwiftUI

struct FeedView: View {
    @EnvironmentObject var router: ShellRouter

    @State private var tab: FeedTab = .forYou
    @State private var posts: [Post] = []
    @State private var loading = true
    @State private var error: String?

    enum FeedTab: String, CaseIterable {
        case forYou = "For you"
        case friends = "Friends"
        case local = "Local"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                FeedHeader(tab: $tab)
                ComposeCard(onPosted: { newPost in
                    withAnimation(.easeOut(duration: 0.25)) {
                        posts.insert(newPost, at: 0)
                    }
                })
                Divider().background(Color.white.opacity(0.05))

                LazyVStack(spacing: 12) {
                    if loading {
                        ProgressView()
                            .padding(.vertical, 60)
                            .tint(RavenColors.logoStart)
                    } else if let error = error {
                        Text(error)
                            .foregroundStyle(.red)
                            .padding(.vertical, 60)
                    } else if posts.isEmpty {
                        Text("Nothing here yet.")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 60)
                    } else {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, post in
                            PostCardView(
                                post: post,
                                index: idx,
                                onLikeChanged: { newLikes, liked in
                                    if let i = posts.firstIndex(where: { $0.id == post.id }) {
                                        posts[i] = posts[i].withLikeState(likes: newLikes, isLiked: liked)
                                    }
                                },
                                onDeleted: {
                                    withAnimation { posts.removeAll { $0.id == post.id } }
                                },
                                onEdited: { newContent in
                                    if let i = posts.firstIndex(where: { $0.id == post.id }) {
                                        posts[i] = posts[i].withContent(newContent)
                                    }
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Spacer().frame(height: 80)
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: tab) { _ in
            // Reload from the corresponding /feed endpoint when the user
            // switches between For you / Friends / Local. Without this the
            // tabs are purely visual.
            Task { await load() }
        }
        .onChange(of: router.lastPublishedPost?.id) { newId in
            // Rail-button compose sheet just published — prepend without a
            // refetch and clear the signal so we don't re-fire.
            guard let newPost = router.lastPublishedPost, newPost.id == newId else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                if !posts.contains(where: { $0.id == newPost.id }) {
                    posts.insert(newPost, at: 0)
                }
            }
            router.lastPublishedPost = nil
        }
    }

    private var filtered: [Post] {
        // Each tab now hits its own endpoint via `load()`, so we just
        // surface whatever the server returned.
        return posts
    }

    private func load() async {
        loading = true
        error = nil
        do {
            switch tab {
            case .forYou:  posts = try await NetworkService.shared.feed()
            case .friends: posts = try await NetworkService.shared.feedFriends()
            case .local:   posts = try await NetworkService.shared.feedLocal()
            }
        } catch {
            // Surface the actual error so we can see what shape mismatch is
            // tripping the decoder; we'll trim back to a friendly string
            // once the contract stabilizes.
            self.error = "Couldn't load feed: \(error)"
            print("📥 [feed] load failed: \(error)")
        }
        loading = false
    }
}

private struct FeedHeader: View {
    @Binding var tab: FeedView.FeedTab

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Home")
                .font(.system(size: 22, weight: .heavy))
                .padding(.horizontal, 20)
                .padding(.top, 18)

            HStack(spacing: 0) {
                ForEach(FeedView.FeedTab.allCases, id: \.rawValue) { item in
                    let isSelected = tab == item
                    Button {
                        tab = item
                    } label: {
                        VStack(spacing: 8) {
                            Text(item.rawValue)
                                .font(.system(size: 14,
                                              weight: isSelected ? .bold : .medium))
                                .foregroundStyle(isSelected
                                                 ? Color.primary
                                                 : Color.secondary)
                            Capsule()
                                .fill(isSelected
                                      ? AnyShapeStyle(LinearGradient.ravenBrand)
                                      : AnyShapeStyle(Color.clear))
                                .frame(width: 36, height: 3)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 4)

            Divider().background(Color.white.opacity(0.05))
        }
    }
}

private struct ComposeCard: View {
    @EnvironmentObject var auth: AuthService
    var onPosted: (Post) -> Void

    @State private var text: String = ""
    @State private var posting = false
    @State private var error: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(
                letter: auth.currentUser?.initials ?? "?",
                size: 44,
                urlString: auth.currentUser?.avatarPath
            )
            VStack(alignment: .trailing, spacing: 12) {
                TextField("What's happening?", text: $text, axis: .vertical)
                    .font(.system(size: 18))
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .disabled(posting)

                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                Button {
                    Task { await submit() }
                } label: {
                    Text(posting ? "Posting…" : "Post")
                        .font(.system(size: 14, weight: .heavy))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(LinearGradient.ravenBrand)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(posting || text.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(text.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @MainActor
    private func submit() async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        posting = true
        error = nil
        do {
            let new = try await NetworkService.shared.createPost(content: trimmed)
            text = ""
            onPosted(new)
        } catch {
            self.error = "Couldn't post. Try again."
            print("📝 [compose] post failed: \(error)")
        }
        posting = false
    }
}
