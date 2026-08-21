// NotificationsView.swift
//
// Group mentions, message reactions and delivery alerts. Tapping a row sends
// `open` back to the phone so the iPhone surfaces the right screen —
// the Watch doesn't try to render deep targets itself because most of
// them to the corresponding conversation on the phone.

import SwiftUI

struct NotificationsView: View {
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var bridge: PhoneBridge

    private var items: [NotificationItem] {
        store.snapshot.notifications
            .filter(\.isMessagingProductEvent)
            .sorted(by: { $0.timestamp > $1.timestamp })
    }

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "bell.slash").font(.title2).foregroundStyle(.secondary)
                        Text("No alerts").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding()
                } else {
                    ForEach(items) { item in
                        Button {
                            Task {
                                _ = await bridge.deliver([
                                    "kind": "open",
                                    "target": item.target,
                                ])
                            }
                        } label: {
                            NotificationRow(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.carousel)
            .navigationTitle("Alerts")
        }
    }
}

private struct NotificationRow: View {
    let item: NotificationItem

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                AvatarCircle(initial: item.actorInitial, isGroup: false)
                    .frame(width: 28, height: 28)
                Image(systemName: kindIcon)
                    .font(.caption2)
                    .padding(2)
                    .background(.background, in: Circle())
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.actorName).font(.caption.bold())
                Text(item.summary).font(.caption2).lineLimit(2)
                Text(TimeFormatter.shortRelative(item.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var kindIcon: String {
        switch item.kind {
        case .mention: return "at"
        case .reaction: return "heart.fill"
        case .comment: return "bubble.right.fill"
        case .follow: return "person.badge.plus"
        case .bridgeArrived: return "antenna.radiowaves.left.and.right"
        }
    }
}
