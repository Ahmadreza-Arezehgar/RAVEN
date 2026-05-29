// MainColumn — picks which middle-pane content to render based on the
// router's selected section. Keeps the routing logic out of the rail and
// the right pane.

import SwiftUI

struct MainColumn: View {
    @ObservedObject var router: ShellRouter

    var body: some View {
        Group {
            switch router.section {
            case .home: FeedView()
            case .explore: ExploreColumn()
            case .notifications: NotificationsColumn()
            case .messages: ChatListColumn()
            case .profile: ProfileColumn()
            }
        }
        .background(Color.black)
    }
}

struct PlaceholderColumn: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(LinearGradient.ravenLogo.opacity(0.2))
                    .frame(width: 96, height: 96)
                Image(systemName: icon)
                    .font(.system(size: 38))
                    .foregroundStyle(RavenColors.logoStart)
            }
            Text(title)
                .font(.system(size: 24, weight: .heavy))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
