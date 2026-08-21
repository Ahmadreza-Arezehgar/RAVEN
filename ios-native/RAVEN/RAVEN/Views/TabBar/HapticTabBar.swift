import SwiftUI

// MARK: - Haptic Tab Bar ("RAVEN://TERMINAL" status bar)
/// TERMINAL REDESIGN (2026-08): the liquid-glass capsule is replaced by a
/// full-width console status bar:
/// - Opaque near-black surface with a phosphor hairline on top
/// - Monospace cell labels in tmux style — `1:peers 2:chats 3:mesh 4:cfg`
/// - The active cell is an inverse block (phosphor fill, ink text) that
///   slides between cells via `matchedGeometryEffect`
/// - Unread badge renders as an inline `[n]` block counter
/// - Long-press still surfaces the per-tab quick-action context menu
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
        .padding(.vertical, 7)
        .background(barBackground)
    }

    // MARK: Outer bar — console status surface
    private var barBackground: some View {
        ZStack(alignment: .top) {
            DS.inkElevated.opacity(0.98)
            Rectangle()
                .fill(DS.hairline)
                .frame(height: 1)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: Tab cell

    @ViewBuilder
    private func tabCell(for tab: AppTab) -> some View {
        let isActive = selected == tab

        ZStack {
            // Active inverse block — morphs between cells.
            if isActive {
                RoundedRectangle(cornerRadius: DS.radiusPill, style: .continuous)
                    .fill(DS.phosphor)
                    .matchedGeometryEffect(id: "activePill", in: pillNS)
                    .shadow(color: DS.phosphor.opacity(0.35), radius: 6, y: 0)
            }

            tabContent(for: tab, isActive: isActive)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .contentShape(Rectangle())
        .onTapGesture {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
            )
            Haptics.selection()
            // Short delay lets the keyboard finish dismissing before the
            // tab actually flips (carried over from the glass bar).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(DS.tabSpring) {
                    selected = tab
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.accessibilityName)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    // MARK: Cell content

    @ViewBuilder
    private func tabContent(for tab: AppTab, isActive: Bool) -> some View {
        if isActive {
            activeContent(for: tab)
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(DS.ink)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
        } else {
            inactiveContent(for: tab)
                .transition(.opacity)
        }
    }

    /// Active cell: `2:chats` inverse-block text (avatar for Settings).
    @ViewBuilder
    private func activeContent(for tab: AppTab) -> some View {
        if tab == .account, let url = userAvatarURL {
            AsyncImage(url: url) { phase in
                if let img = phase.image {
                    img.resizable().scaledToFill()
                } else {
                    Text(tab.statusLabel.uppercased())
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(width: 20, height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(DS.ink.opacity(0.6), lineWidth: 1)
            )
        } else {
            HStack(spacing: 5) {
                Text(tab.statusLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if tab == .messages && badgeCount > 0 {
                    Text("[\(badgeCount > 9 ? "9+" : "\(badgeCount)")]")
                        .minimumScaleFactor(0.8)
                }
            }
        }
    }

    /// Inactive cell: dim monospace `n:label` + unread marker.
    @ViewBuilder
    private func inactiveContent(for tab: AppTab) -> some View {
        HStack(spacing: 4) {
            if tab == .account, let url = userAvatarURL {
                AsyncImage(url: url) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill()
                    } else {
                        Text(tab.indexMarker)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .opacity(0.85)
            } else {
                Text(tab.statusLabel)
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .foregroundStyle(DS.mist.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            if tab == .messages && badgeCount > 0 {
                Text("[\(badgeCount > 9 ? "9+" : "\(badgeCount)")]")
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(DS.phosphor)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusPill, style: .continuous)
                .strokeBorder(DS.hairlineDim, lineWidth: 1)
        )
    }
}

// MARK: - Status-bar label helpers

extension AppTab {
    /// Zero-based console index, e.g. "1".
    var indexNumber: Int {
        (AppTab.allCases.firstIndex(of: self) ?? 0) + 1
    }

    /// `n:` prefix shown before the label.
    var indexMarker: String {
        "\(indexNumber):"
    }

    /// Compact tmux-style status label — `1:peers`.
    var statusLabel: String {
        switch self {
        case .contacts: return "\(indexMarker)peers"
        case .messages: return "\(indexMarker)chats"
        case .network: return "\(indexMarker)mesh"
        case .account: return "\(indexMarker)cfg"
        }
    }
}

// MARK: - Preview
#Preview {
    ZStack {
        RavenScreenBackground()
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
