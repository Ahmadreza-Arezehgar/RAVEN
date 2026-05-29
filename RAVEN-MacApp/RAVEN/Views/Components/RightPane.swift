// RightPane — the third column.
//
//   • On the Messages tab, this becomes the chat thread for the selected
//     conversation (or an empty state if nothing's selected).
//   • Everywhere else it's the X-style "What's happening" + Get RAVEN+ +
//     footer widgets.

import SwiftUI

struct RightPane: View {
    @ObservedObject var router: ShellRouter

    var body: some View {
        Group {
            if router.section == .messages {
                if let id = router.selectedConversationId {
                    ChatThreadView(
                        conversationId: id,
                        isGroup: router.selectedIsGroup
                    )
                    // `.id(...)` forces SwiftUI to recreate the view (and
                    // thus the underlying ChatStore) when the user
                    // switches between conversations. Without it the
                    // StateObject would persist and we'd send messages
                    // into the wrong thread.
                    .id("\(id)-\(router.selectedIsGroup ? "g" : "d")")
                } else {
                    EmptyConversationState()
                }
            } else {
                WidgetsView()
            }
        }
        .background(Color.black)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyConversationState: View {
    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(LinearGradient.ravenLogo.opacity(0.2))
                    .frame(width: 96, height: 96)
                Image(systemName: "bubble.left")
                    .font(.system(size: 42))
                    .foregroundStyle(RavenColors.logoStart)
            }
            Text("Select a message")
                .font(.system(size: 24, weight: .heavy))
            Text("Pick a conversation from the list, or start a new one.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}

// MARK: - Widgets

struct WidgetsView: View {
    @State private var trends: [TrendingHashtag] = []
    @State private var trendsLoaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                WidgetSearchBar()
                if !trends.isEmpty {
                    WhatsHappeningCard(trends: trends)
                }
                GetRavenPlusCard()
                FooterLinks()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 22)
        }
        .task {
            // Pull real trending hashtags from the server. If the call
            // fails or returns nothing we just don't render the card —
            // empty state beats fake data.
            if !trendsLoaded {
                trendsLoaded = true
                do {
                    trends = try await NetworkService.shared.trendingHashtags()
                } catch {
                    trends = []
                }
            }
        }
    }
}

private struct WidgetSearchBar: View {
    @State private var text: String = ""
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search RAVEN", text: $text)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.05))
        .clipShape(Capsule())
    }
}

private struct WhatsHappeningCard: View {
    let trends: [TrendingHashtag]
    @EnvironmentObject var router: ShellRouter
    var body: some View {
        WidgetCard(title: "What's happening") {
            VStack(spacing: 0) {
                ForEach(trends.prefix(5)) { t in
                    Trend(tag: "#\(t.hashtag)", posts: postsLabel(t)) {
                        router.presentedHashtag = t.hashtag
                    }
                }
                HStack {
                    Text("Show more")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(RavenColors.logoStart)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
    }

    private func postsLabel(_ t: TrendingHashtag) -> String {
        let n = t.recentPosts > 0 ? t.recentPosts : t.postCount
        if n >= 1_000_000 { return "\(n / 1_000_000)M posts" }
        if n >= 1_000 { return String(format: "%.1fK posts", Double(n) / 1000.0) }
        return n == 1 ? "1 post" : "\(n) posts"
    }
}

private struct Trend: View {
    let tag: String
    let posts: String
    let onTap: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Trending").font(.system(size: 12)).foregroundStyle(.secondary)
                Text(tag).font(.system(size: 15, weight: .bold))
                Text(posts).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(hover ? Color.white.opacity(0.04) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct GetRavenPlusCard: View {
    var body: some View {
        WidgetCard(title: "Get RAVEN+") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Bigger groups, encrypted backups, mesh-bridge priority — and a verified badge.")
                    .font(.system(size: 14))
                    .lineSpacing(2)
                Button(action: {}) {
                    Text("Subscribe")
                        .font(.system(size: 13, weight: .heavy))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(LinearGradient.ravenBrand)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }
}

private struct WidgetCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 18, weight: .heavy))
                .padding(.horizontal, 16)
                .padding(.top, 14)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.06))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}

private struct FooterLinks: View {
    var body: some View {
        HStack(spacing: 14) {
            ForEach(["Terms", "Privacy", "Cookies", "Mesh status", "© 2026 ASH Robotic"], id: \.self) { item in
                Text(item)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }
}
