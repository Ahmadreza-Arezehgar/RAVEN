// RAVENWatchApp.swift
//
// watchOS app entry point. Wires up the singleton stores (`PhoneBridge`
// for WCSession traffic with the paired iPhone, `WatchStore` for local
// state) before the first scene renders so the root tab view can read
// snapshots immediately on cold start.
//
// The Watch is a *companion* surface — never the source of truth. The
// iPhone owns the encrypted SQLCipher database and the mesh stack. The
// Watch just shows a curated slice of that state and ferries user
// intent (replies, reactions, likes, comments) back to the phone, which
// routes them through `MessageRouter` exactly the way a phone-side
// compose would.

import SwiftUI

@main
struct RAVENWatchApp: App {
    @StateObject private var bridge = PhoneBridge.shared
    @StateObject private var store = WatchStore.shared

    init() {
        // Activate WCSession before the first view appears so the
        // application-context snapshot from the phone is already in
        // `WatchStore` when InboxView reads it. Idempotent.
        PhoneBridge.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(bridge)
                .environmentObject(store)
        }
    }
}
