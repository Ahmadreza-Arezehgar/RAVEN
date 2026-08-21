// RootView.swift
//
// Vertical-pager tab shell — the watchOS 10 navigation idiom.
// Pages, in order:
//
//   1. Inbox        — DMs and group chats
//   2. Alerts       — group mentions, message reactions and delivery status
//
// A small "phone unreachable" pill floats over the top when WCSession
// reports the iPhone isn't paired or installed. We never block the UI on
// it — read-only state is still rendered from the on-disk snapshot.

import SwiftUI

struct RootView: View {
    @EnvironmentObject var bridge: PhoneBridge
    @EnvironmentObject var store: WatchStore

    /// Bound to `TabView.selection`. Tabs are tagged 0..3 below.
    @State private var selectedTab: Int = 0

    var body: some View {
        // Messenger pivot: Feed (Echo Wall) and Rooms tabs removed — the watch
        // is now Inbox + Alerts only.
        TabView(selection: $selectedTab) {
            InboxView()
                .containerBackground(.purple.gradient, for: .tabView)
                .tabItem { Label("Inbox", systemImage: "message.fill") }
                .tag(0)

            NotificationsView()
                .containerBackground(.pink.gradient, for: .tabView)
                .tabItem { Label("Alerts", systemImage: "bell.fill") }
                .tag(1)
        }
        .tabViewStyle(.verticalPage)
        .overlay(alignment: .top) {
            if !bridge.isReachable && !bridge.isCompanionInstalled {
                Text("Open RAVEN on iPhone")
                    .font(.caption2)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 2)
                    .transition(.opacity)
            }
        }
        .sheet(item: hapticBinding) { haptic in
            IncomingHapticSheet(haptic: haptic)
        }
        .task {
            _ = await bridge.requestSnapshot()
            // Demo auto-tour for the simulator. Triggered only when the
            // app is launched with `-RAVENWatchAutoTour YES`. Cycles
            // every tab once with enough dwell time to screenshot, then
            // exits and leaves the user on the last tab.
            if UserDefaults.standard.bool(forKey: "RAVENWatchAutoTour") {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                withAnimation { selectedTab = 1 }
            }
        }
    }

    /// Surfaces incoming-DM notifications as a sheet the user can
    /// quick-reply from. Tapping anywhere outside dismisses.
    private var hapticBinding: Binding<WatchStore.IncomingHaptic?> {
        Binding(
            get: { store.incomingHaptic },
            set: { if $0 == nil { store.clearHaptic() } }
        )
    }
}

private struct IncomingHapticSheet: View {
    let haptic: WatchStore.IncomingHaptic
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var bridge: PhoneBridge

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(haptic.senderName).font(.headline)
            Text(haptic.preview).font(.body).lineLimit(3)
            Spacer(minLength: 4)
            HStack {
                Button("Dismiss") { store.clearHaptic() }
                    .buttonStyle(.bordered)
                NavigationLink(destination: ComposeReplyView(
                    roomId: haptic.messageId,        // server resolves room from messageId
                    recipientId: "",
                    presetText: ""
                )) {
                    Label("Reply", systemImage: "arrowshape.turn.up.left.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(8)
    }
}
