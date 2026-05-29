// MacShellView — the three-column main shell.
//
//   ┌─────────┬────────────────────┬────────────────┐
//   │  Rail   │   Main column      │  Right pane    │
//   │  (240)  │   (Feed / Chats /  │  (Trending /   │
//   │         │   Notifications…)  │  ChatThread…)  │
//   └─────────┴────────────────────┴────────────────┘
//
// Mirrors the same skeleton as the macOS Flutter build (`lib/screens/
// macos_shell.dart`) and the inspiration the user picked (X for desktop):
// nav rail with icons + labels, a wide main column, and a dedicated
// widgets / chat-thread pane on the right.

import SwiftUI

enum ShellSection: Hashable {
    case home, explore, notifications, messages, profile
}

@MainActor
final class ShellRouter: ObservableObject {
    @Published var section: ShellSection = .home
    /// Peer user id of the open conversation (matches the path parameter on
    /// `/api/messages/conversation/{other_user_id}`).
    @Published var selectedConversationId: String?
    /// Selected peer info, set by ChatListColumn when a row is tapped so
    /// ChatThreadView can render the header (avatar + username) without
    /// having to fetch the peer separately.
    @Published var selectedPeer: ConversationPeer?
    /// Whether the selected conversation is a group chat. Drives which
    /// `/api/messages/conversation/...` vs `/api/groups/.../messages`
    /// endpoint ChatThreadView calls.
    @Published var selectedIsGroup: Bool = false
    /// Group display name when the selected conversation is a group.
    @Published var selectedGroupName: String?
    /// Group avatar URL when the selected conversation is a group.
    @Published var selectedGroupAvatar: String?
    /// Message-request fields for the selected 1:1 conversation. Set by
    /// ChatListColumn when a row is opened so ChatThreadView can render
    /// the receiver Block/Decline/Accept UI or the sender "X/3 left"
    /// counter without re-fetching the conversation summary.
    @Published var selectedRequestStatus: String?
    @Published var selectedIsRequestSender: Bool?
    @Published var selectedRequestId: String?
    @Published var selectedPendingSentCount: Int?
    @Published var showComposePost: Bool = false
    /// Set by ComposeSheet to nudge FeedView into prepending the new post
    /// without a refetch — `nil` outside an active publish.
    @Published var lastPublishedPost: Post?
    /// Non-nil while the user is viewing another user's profile in a
    /// modal sheet. Set by tapping a user row / post avatar.
    @Published var presentedProfileUserId: String?
    /// Non-nil while a hashtag feed sheet is open (set by tapping a `#tag`
    /// in a post body, the right-pane "What's happening" widget, or the
    /// Explore screen).
    @Published var presentedHashtag: String?
}

struct MacShellView: View {
    @StateObject private var router = ShellRouter()
    @EnvironmentObject var auth: AuthService

    var body: some View {
        HStack(spacing: 0) {
            RailView(router: router)
                .frame(width: 240)

            Divider().background(Color.white.opacity(0.05))

            MainColumn(router: router)
                .frame(maxWidth: .infinity)

            Divider().background(Color.white.opacity(0.05))

            RightPane(router: router)
                .frame(width: 340)
        }
        .background(Color.black)
        .environmentObject(router)
        .sheet(isPresented: $router.showComposePost) {
            // Sheets create a new view tree, so re-inject the AuthService
            // env object — `ComposeSheet` reads it for the avatar + initials.
            ComposeSheet { newPost in
                router.lastPublishedPost = newPost
                router.section = .home  // jump back to feed so the user sees it
            }
            .environmentObject(auth)
        }
        .sheet(item: Binding(
            get: { router.presentedProfileUserId.map(IDWrapper.init) },
            set: { router.presentedProfileUserId = $0?.id }
        )) { wrapper in
            UserProfileSheet(userId: wrapper.id)
                .environmentObject(auth)
                .environmentObject(router)
        }
        .sheet(item: Binding(
            get: { router.presentedHashtag.map(IDWrapper.init) },
            set: { router.presentedHashtag = $0?.id }
        )) { wrapper in
            HashtagFeedSheet(hashtag: wrapper.id)
                .environmentObject(auth)
                .environmentObject(router)
        }
    }
}

/// `Identifiable` wrapper so we can drive `.sheet(item:)` off a plain
/// `String?` user id without making `String` itself `Identifiable`.
private struct IDWrapper: Identifiable {
    let id: String
}
