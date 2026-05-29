// ExploreColumn — middle pane on the Explore tab.
//
// Search-driven: type to find users, posts, or hashtags. Empty state
// shows trending hashtags so the user has something to tap.

import SwiftUI

struct ExploreColumn: View {
    @State private var query: String = ""
    @State private var users: [User] = []
    @State private var posts: [Post] = []
    @State private var trending: [TrendingHashtag] = []
    @State private var loading = false
    @State private var error: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Explore")
                    .font(.system(size: 22, weight: .heavy))
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 12)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search people, posts, #tags", text: $query)
                        .textFieldStyle(.plain)
                        .onSubmit { run() }
                    if !query.isEmpty {
                        Button(action: { query = ""; run() }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.05))
                .clipShape(Capsule())
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

                if loading {
                    ProgressView()
                        .padding(.vertical, 60)
                        .frame(maxWidth: .infinity)
                        .tint(RavenColors.logoStart)
                } else if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 20)
                } else if query.isEmpty {
                    trendingSection
                } else {
                    resultsSection
                }
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .task { await loadTrending() }
        .onChange(of: query) { newValue in
            // Debounce: cancel any pending search and schedule a new one.
            searchTask?.cancel()
            let q = newValue.trimmingCharacters(in: .whitespaces)
            if q.isEmpty {
                users = []
                posts = []
                return
            }
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                if Task.isCancelled { return }
                await runSearch(q: q)
            }
        }
    }

    @ViewBuilder
    private var trendingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Trending hashtags")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
            if trending.isEmpty {
                Text("No trends right now.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(trending) { t in
                        TrendingHashtagRow(item: t) {
                            query = "#\(t.hashtag)"
                            run()
                        }
                        Divider().opacity(0.3)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !users.isEmpty {
                SectionHeader("People")
                LazyVStack(spacing: 0) {
                    ForEach(users) { user in
                        UserRow(user: user)
                        Divider().opacity(0.3)
                    }
                }
            }

            if !posts.isEmpty {
                SectionHeader("Posts")
                LazyVStack(spacing: 12) {
                    ForEach(Array(posts.enumerated()), id: \.element.id) { idx, post in
                        PostCardView(post: post, index: idx)
                    }
                }
                .padding(.horizontal, 16)
            }

            if users.isEmpty && posts.isEmpty {
                Text("No results.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
        }
    }

    private func run() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { users = []; posts = []; return }
        Task { await runSearch(q: q) }
    }

    @MainActor
    private func runSearch(q: String) async {
        loading = true
        error = nil

        // Tag-led search: `#raven` → posts only under that tag.
        if q.hasPrefix("#") {
            do {
                posts = try await NetworkService.shared.postsForHashtag(q)
                users = []
            } catch {
                self.error = "Couldn't search hashtag."
                print("🔎 [explore] hashtag failed: \(error)")
            }
            loading = false
            return
        }

        // Run user + post searches in parallel.
        async let usersResult = (try? await NetworkService.shared.searchUsers(query: q)) ?? []
        async let postsResult = (try? await NetworkService.shared.searchPosts(query: q)) ?? []
        users = await usersResult
        posts = await postsResult
        loading = false
    }

    @MainActor
    private func loadTrending() async {
        do {
            trending = try await NetworkService.shared.trendingHashtags()
        } catch {
            print("🔎 [explore] trending failed: \(error)")
        }
    }
}

private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
    }
}

private struct UserRow: View {
    let user: User
    @EnvironmentObject var router: ShellRouter
    @State private var hover = false
    var body: some View {
        Button(action: { router.presentedProfileUserId = user.id }) {
            HStack(spacing: 12) {
                AvatarView(letter: user.initials, size: 40, urlString: user.avatarPath)
                VStack(alignment: .leading, spacing: 2) {
                    Text(user.username).font(.system(size: 14, weight: .bold))
                    if let bio = user.bio, !bio.isEmpty {
                        Text(bio)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("@\(user.username)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(hover ? Color.white.opacity(0.03) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct TrendingHashtagRow: View {
    let item: TrendingHashtag
    let onTap: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 2) {
                Text("#\(item.hashtag)")
                    .font(.system(size: 15, weight: .bold))
                Text("\(item.recentPosts > 0 ? item.recentPosts : item.postCount) posts")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(hover ? Color.white.opacity(0.03) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
