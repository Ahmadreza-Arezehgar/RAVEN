//
//  RavenMacShell.swift
//  RAVEN
//
//  macOS 26 (Tahoe) Liquid Glass shell — NavigationSplitView with a
//  capsule-driven sidebar. Used ONLY on Mac Catalyst; iOS keeps
//  `MainShellView` (TabView) untouched.
//
//  Design references:
//    - Liquid Glass material across sidebar, toolbar, floating controls
//    - Capsules instead of rectangular hits for every chip/pill
//    - Three-column NavigationSplitView (sidebar / list / detail)
//    - Hover states + right-click context menus (Mac convention)
//    - Keyboard shortcuts: ⌘1-5 sidebar, ⌘N new chat, ⌘F search, ⌘, settings
//

#if targetEnvironment(macCatalyst)
import SwiftUI

// ──────────────────────────────────────────────────────────────────────────
// MARK: - Sidebar destinations
// ──────────────────────────────────────────────────────────────────────────

enum MacSidebarItem: String, CaseIterable, Identifiable, Hashable {
    case feed       = "Feed"
    case messages   = "Messages"
    case rooms      = "Rooms"
    case discover   = "Discover"
    case ravenshot  = "RavenShot"
    case account    = "Account"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .feed:      return "newspaper.fill"
        case .messages:  return "message.fill"
        case .rooms:     return "waveform.circle.fill"
        case .discover:  return "magnifyingglass"
        case .ravenshot: return "map.fill"
        case .account:   return "person.crop.circle.fill"
        }
    }

    /// Accent tint per section — picks up by `.tint(_:)` and bleeds into
    /// the Liquid Glass selection capsule.
    var tint: Color {
        switch self {
        case .feed:      return .blue
        case .messages:  return .purple
        case .rooms:     return .pink
        case .discover:  return .green
        case .ravenshot: return .orange
        case .account:   return .gray
        }
    }

    /// Matches the equivalent AppTab on iOS — used so the same
    /// underlying state model can drive both shells.
    var iosTab: AppTab? {
        switch self {
        case .feed:      return .home
        case .messages:  return .messages
        case .discover:  return .discover
        case .account:   return .account
        case .rooms, .ravenshot: return nil  // dedicated Mac sections
        }
    }

    /// Cmd+N where N maps to the index in `allCases`. Used for keyboard
    /// shortcut routing.
    var keyboardShortcut: KeyEquivalent {
        switch self {
        case .feed:      return "1"
        case .messages:  return "2"
        case .rooms:     return "3"
        case .discover:  return "4"
        case .ravenshot: return "5"
        case .account:   return "6"
        }
    }
}

// ──────────────────────────────────────────────────────────────────────────
// MARK: - Mac Shell View
// ──────────────────────────────────────────────────────────────────────────

struct RavenMacShell: View {
    @State private var selection: MacSidebarItem = .messages
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // ── Sidebar (column 1) ──────────────────────────────────────
            macSidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
        } detail: {
            // ── Detail (column 2) — section content ─────────────────────
            sectionDetail
                .navigationSplitViewColumnWidth(min: 480, ideal: 720)
        }
        .navigationSplitViewStyle(.balanced)
        .background(Color(.systemBackground).ignoresSafeArea())
        // ⌘1–6 keyboard navigation between sidebar items. Each item
        // installs its own shortcut so tabs are reachable from anywhere.
        .background(
            ZStack {
                ForEach(MacSidebarItem.allCases) { item in
                    Button("") { selection = item }
                        .keyboardShortcut(item.keyboardShortcut, modifiers: .command)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
            }
        )
    }

    // ──────────────────────────────────────────────────────────────────
    // Sidebar
    // ──────────────────────────────────────────────────────────────────

    private var macSidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Branding header — capsule-style logo lockup
            HStack(spacing: 10) {
                Image(systemName: "bird.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.purple, .pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("RAVEN")
                    .font(.system(size: 19, weight: .heavy, design: .rounded))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Capsule sidebar items
            VStack(alignment: .leading, spacing: 2) {
                ForEach(MacSidebarItem.allCases) { item in
                    SidebarRow(
                        item: item,
                        isSelected: selection == item,
                        onTap: {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                selection = item
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            // Bottom mesh-status pill — shows current BLE peer count
            // so users know mesh is alive even when window is foregrounded.
            MeshStatusPill()
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // The macOS 26 sidebar comes with built-in glass — let it shine
        // (don't override with a custom background).
    }

    // ──────────────────────────────────────────────────────────────────
    // Section detail dispatcher
    // ──────────────────────────────────────────────────────────────────

    @ViewBuilder
    private var sectionDetail: some View {
        switch selection {
        case .feed:
            FeedView()
        case .messages:
            // Reuse iOS InboxView — works on Catalyst with sensible
            // defaults; we wrap it in a NavigationStack so detail
            // pushes (chat) layer on top of inbox.
            NavigationStack {
                InboxView()
                    .navigationTitle("Messages")
            }
        case .rooms:
            NavigationStack {
                RoomListView()
                    .navigationTitle("Audio Rooms")
            }
        case .discover:
            NavigationStack {
                DiscoverView()
                    .navigationTitle("Discover")
            }
        case .ravenshot:
            // RavenShot map — wrap in NavigationStack so toolbar lands.
            // The view's `isPresented` binding is a sheet-dismiss switch on
            // iOS; on Mac the section is permanent so we hand it a constant
            // `true` and ignore the toggle.
            NavigationStack {
                RavenShotView(isPresented: .constant(true))
                    .navigationTitle("RavenShot")
            }
        case .account:
            NavigationStack {
                AccountView()
                    .navigationTitle("Account")
            }
        }
    }
}

// ──────────────────────────────────────────────────────────────────────────
// MARK: - Sidebar Row (capsule with selection glass)
// ──────────────────────────────────────────────────────────────────────────

private struct SidebarRow: View {
    let item: MacSidebarItem
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 22, height: 22)
                    .foregroundStyle(isSelected ? item.tint : .secondary)

                Text(item.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)

                Spacer()

                // Cmd+number hint — appears on hover (Mac convention)
                if isHovering && !isSelected {
                    Text("⌘\(item.keyboardShortcut.character.description)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.10), in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Selection: Liquid Glass capsule tinted with section's accent.
        // Hover: dimmer surface so user knows it's interactive.
        .background(
            ZStack {
                if isSelected {
                    item.tint.opacity(0.16)
                } else if isHovering {
                    Color.primary.opacity(0.05)
                }
            }
        )
        .clipShape(Capsule())
        .overlay(
            isSelected
            ? Capsule().strokeBorder(item.tint.opacity(0.35), lineWidth: 0.75)
            : nil
        )
        .onHover { isHovering = $0 }
        .accessibilityLabel(item.rawValue)
        .help("\(item.rawValue) (⌘\(item.keyboardShortcut.character.description))")
    }
}

// ──────────────────────────────────────────────────────────────────────────
// MARK: - Mesh Status Pill
// ──────────────────────────────────────────────────────────────────────────
//
// Glass capsule at the bottom of the sidebar showing live mesh status.
// Pulses green when BLE peripheral is advertising; gray when idle.
// Click → opens Settings → Background Mesh.

private struct MeshStatusPill: View {
    @ObservedObject private var ble = BLEMeshEngine.shared
    @State private var pulse = false

    private var dotColor: Color {
        ble.isCurrentlyScanning ? .green : .secondary
    }
    private var statusText: String {
        let peers = ble.connectedPeers.count
        if !ble.isCurrentlyScanning { return "Mesh idle" }
        return peers == 0 ? "Mesh active" : "Mesh · \(peers) peer\(peers == 1 ? "" : "s")"
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .scaleEffect(pulse && ble.isCurrentlyScanning ? 1.3 : 1.0)
                .animation(
                    ble.isCurrentlyScanning
                    ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                    : .default,
                    value: pulse
                )
                .shadow(color: dotColor.opacity(0.6), radius: pulse ? 4 : 0)

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .ravenGlass(in: Capsule())
        .onAppear { pulse = true }
        .help("Tap to open Background Mesh settings")
    }
}

#endif  // targetEnvironment(macCatalyst)
