import SwiftUI

// MARK: - Haptic Tab Bar (Liquid Glass capsule with morphing active pill)
/// Matches the iOS 26 liquid-glass bottom-bar design:
/// - Outer translucent capsule with `.ultraThinMaterial`
/// - Inner glass pill that morphs between cells via `matchedGeometryEffect`
/// - Chromatic refraction stroke (cyan / white / magenta / amber) on the
///   active pill — approximates the iOS 26 `.glassEffect(.interactive())`
///   look while remaining compatible with the iOS 17.0 deployment target
/// - Active tab shows label text + green status dot; inactive cells are
///   icon-only at reduced opacity
/// - Long-press on a tab still surfaces the per-tab quick-action menu via
///   the native SwiftUI `.contextMenu`
struct HapticTabBar: View {
    @Binding var selected: AppTab
    let badgeCount: Int
    var userAvatarURL: URL? = nil
    let actionsProvider: (AppTab) -> [TabAction]

    @Namespace private var pillNS

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                tabCell(for: tab)
                    .contextMenu {
                        ForEach(actionsProvider(tab)) { action in
                            Button {
                                Haptics.light()
                                action.handler()
                            } label: {
                                Label(action.title, systemImage: action.systemImage)
                            }
                        }
                    }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(barBackground)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Outer bar background (frosted glass capsule)
    /// Uses the unified `liquidGlass(in:)` modifier so the bar shares its
    /// material/stroke/shadow with every other glass surface in the app.
    private var barBackground: some View {
        Color.clear.glassSurface(in: Capsule())
    }

    // MARK: - Tab cell

    @ViewBuilder
    private func tabCell(for tab: AppTab) -> some View {
        let isActive = selected == tab

        ZStack {
            // Active glass pill — only rendered on the selected cell.
            // matchedGeometryEffect causes SwiftUI to interpolate its frame
            // between the old and new cells, producing the morphing slide.
            if isActive {
                activePill
                    .matchedGeometryEffect(id: "activePill", in: pillNS)
            }

            tabContent(for: tab, isActive: isActive)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .contentShape(Capsule())
        .onTapGesture {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
            )
            Haptics.selection()
            // 0.15s delay matches the prior ContextMenuTabItem behaviour —
            // lets the keyboard finish dismissing before the tab actually flips.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(DS.tabSpring) {
                    selected = tab
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.accessibilityName)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    // MARK: - Active glass pill (chromatic refraction via shared accent modifier)
    private var activePill: some View {
        Color.clear
            .glassAccent(in: Capsule())
            .padding(.vertical, 2)
            .padding(.horizontal, 2)
    }

    // MARK: - Tab content (icon for inactive, label + dot for active)

    @ViewBuilder
    private func tabContent(for tab: AppTab, isActive: Bool) -> some View {
        if isActive {
            VStack(spacing: 3) {
                activeContent(for: tab)
                Circle()
                    .fill(DS.cyan)
                    .frame(width: 5, height: 5)
                    .shadow(color: DS.cyan.opacity(0.7), radius: 4)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        } else {
            inactiveContent(for: tab)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private func activeContent(for tab: AppTab) -> some View {
        if tab == .account, let url = userAvatarURL {
            AsyncImage(url: url) { phase in
                if let img = phase.image {
                    img.resizable().scaledToFill()
                } else {
                    fallbackIcon(name: tab.selectedIcon, size: 18, weight: .semibold, opacity: 1.0)
                }
            }
            .frame(width: 18, height: 18)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.45), lineWidth: 0.8))
        } else {
            Text(tab.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    @ViewBuilder
    private func inactiveContent(for tab: AppTab) -> some View {
        ZStack {
            if tab == .account, let url = userAvatarURL {
                AsyncImage(url: url) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill()
                    } else {
                        fallbackIcon(name: tab.icon, size: 20, weight: .regular, opacity: 0.55)
                    }
                }
                .frame(width: 22, height: 22)
                .clipShape(Circle())
                .opacity(0.7)
            } else {
                fallbackIcon(name: tab.icon, size: 20, weight: .regular, opacity: 0.55)
            }

            // Unread badge (only on Messages tab)
            if tab == .messages && badgeCount > 0 {
                Text(badgeCount > 99 ? "99+" : "\(badgeCount)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(DS.violet))
                    .offset(x: 12, y: -10)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private func fallbackIcon(name: String, size: CGFloat, weight: Font.Weight, opacity: Double) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(.primary.opacity(opacity))
    }
}

// MARK: - Preview
#Preview {
    ZStack {
        LinearGradient(
            colors: [.blue.opacity(0.4), .purple.opacity(0.4)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        VStack {
            Spacer()
            HapticTabBar(
                selected: .constant(.messages),
                badgeCount: 3,
                actionsProvider: { _ in
                    [
                        TabAction(title: "Action A", systemImage: "star", tint: .blue) {},
                        TabAction(title: "Action B", systemImage: "bolt", tint: .orange) {}
                    ]
                }
            )
        }
    }
}
