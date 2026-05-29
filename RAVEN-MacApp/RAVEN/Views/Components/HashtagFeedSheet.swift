// HashtagFeedSheet — opened when the user taps a hashtag chip
// (right-pane Trending widget, Explore tab tag tap, or in-post `#tag`
// links once they're highlighted). Shows posts under that tag.

import SwiftUI

struct HashtagFeedSheet: View {
    let hashtag: String

    @Environment(\.dismiss) private var dismiss
    @State private var posts: [Post] = []
    @State private var loading = true
    @State private var error: String?

    private var displayTag: String {
        hashtag.hasPrefix("#") ? hashtag : "#\(hashtag)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(displayTag)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(LinearGradient.ravenLogo)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)
            Divider()

            ScrollView {
                if loading {
                    ProgressView()
                        .padding(40)
                        .frame(maxWidth: .infinity)
                } else if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .padding(40)
                        .frame(maxWidth: .infinity)
                } else if posts.isEmpty {
                    Text("No posts under \(displayTag) yet.")
                        .foregroundStyle(.secondary)
                        .padding(40)
                        .frame(maxWidth: .infinity)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(posts.enumerated()), id: \.element.id) { idx, post in
                            PostCardView(post: post, index: idx)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
            }
        }
        .frame(width: 560, height: 640)
        .task { await load() }
    }

    @MainActor
    private func load() async {
        loading = true
        error = nil
        do {
            posts = try await NetworkService.shared.postsForHashtag(hashtag)
        } catch {
            self.error = "Couldn't load \(displayTag)."
            print("🏷️ [hashtag] load failed: \(error)")
        }
        loading = false
    }
}
