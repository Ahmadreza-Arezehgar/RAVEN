// RailView — left navigation rail (X-on-desktop style).
//
//   • RAVEN logo + wordmark at the top
//   • Nav items with icons + labels (Home / Explore / Notifications /
//     Messages / Profile)
//   • Big gradient "Post" button
//   • Profile chip pinned at the bottom

import SwiftUI

struct RailView: View {
    @ObservedObject var router: ShellRouter
    @EnvironmentObject var auth: AuthService

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image("RavenLogo")
                    .resizable()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                Text("RAVEN")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(LinearGradient.ravenLogo)
            }
            .padding(.horizontal, 18)
            .padding(.top, 32)
            .padding(.bottom, 22)

            RailItem(icon: "house", iconActive: "house.fill",
                     title: "Home",
                     selected: router.section == .home) {
                router.section = .home
            }
            RailItem(icon: "magnifyingglass", iconActive: "magnifyingglass",
                     title: "Explore",
                     selected: router.section == .explore) {
                router.section = .explore
            }
            RailItem(icon: "bell", iconActive: "bell.fill",
                     title: "Notifications",
                     selected: router.section == .notifications) {
                router.section = .notifications
            }
            RailItem(icon: "envelope", iconActive: "envelope.fill",
                     title: "Messages",
                     selected: router.section == .messages) {
                router.section = .messages
            }
            RailItem(icon: "person", iconActive: "person.fill",
                     title: "Profile",
                     selected: router.section == .profile) {
                router.section = .profile
            }

            // Big gradient Post button — opens the compose sheet from any tab
            Button(action: { router.showComposePost = true }) {
                Text("Post")
                    .font(.system(size: 17, weight: .heavy))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(LinearGradient.ravenBrand)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Spacer()

            ProfileChip(user: auth.currentUser)
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
    }
}

struct RailItem: View {
    let icon: String
    let iconActive: String
    let title: String
    let selected: Bool
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: selected ? iconActive : icon)
                    .font(.system(size: 22))
                Text(title)
                    .font(.system(size: 18, weight: selected ? .bold : .medium))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(hover ? Color.white.opacity(0.05) : Color.clear)
            )
            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.7))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .onHover { hover = $0 }
    }
}

struct ProfileChip: View {
    let user: User?
    @State private var hover = false

    var body: some View {
        guard let user = user else { return AnyView(EmptyView()) }
        return AnyView(
            HStack(spacing: 10) {
                AvatarView(letter: user.initials, size: 36, urlString: user.avatarPath)
                VStack(alignment: .leading, spacing: 1) {
                    Text(user.username)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                    Text("@\(user.username)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(hover ? Color.white.opacity(0.05) : Color.clear)
            )
            .onHover { hover = $0 }
        )
    }
}

/// Circular avatar — loads a real image from `urlString` if available,
/// otherwise falls back to the gradient + letter monogram. Matches the
/// SwiftUI iOS-native pattern (`Image("RavenLogo")` + gradient fallback)
/// and the Flutter shell's `_Avatar`.
struct AvatarView: View {
    let letter: String
    let size: CGFloat
    var urlString: String? = nil
    /// When true, renders a tiny green dot at the bottom-right indicating
    /// the user is online. Caller is responsible for passing the actual
    /// presence state — the dot never appears when this is false.
    var showOnlineIndicator: Bool = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                if let urlString, let url = URL(string: urlString) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .empty, .failure:
                            fallback
                        @unknown default:
                            fallback
                        }
                    }
                } else {
                    fallback
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())

            if showOnlineIndicator {
                Circle()
                    .fill(Color.green)
                    .frame(width: size * 0.28, height: size * 0.28)
                    .overlay(Circle().stroke(Color(NSColor.windowBackgroundColor), lineWidth: 2))
                    .offset(x: size * 0.04, y: size * 0.04)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: showOnlineIndicator)
    }

    private var fallback: some View {
        ZStack {
            Circle().fill(LinearGradient.ravenLogo)
            Text(letter)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}
