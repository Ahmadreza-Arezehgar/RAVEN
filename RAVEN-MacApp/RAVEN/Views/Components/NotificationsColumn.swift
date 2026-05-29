// NotificationsColumn — middle pane on the Notifications tab.
//
// Pulls `/api/notifications` and renders a flat list of recent activity
// (likes, replies, follows). Empty state matches the Messages tab's
// styling — same icon-in-halo + title + subtitle pattern.

import SwiftUI

struct NotificationsColumn: View {
    @State private var items: [NotificationItem] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Notifications")
                        .font(.system(size: 22, weight: .heavy))
                    Spacer()
                    if items.contains(where: { !$0.isRead }) {
                        Button("Mark all read") {
                            Task { await markAllRead() }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(RavenColors.logoStart)
                        .font(.system(size: 13, weight: .semibold))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 16)

                Divider().background(Color.white.opacity(0.05))

                if loading {
                    ProgressView()
                        .padding(.vertical, 60)
                        .frame(maxWidth: .infinity)
                        .tint(RavenColors.logoStart)
                } else if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .padding(.vertical, 60)
                        .frame(maxWidth: .infinity)
                } else if items.isEmpty {
                    EmptyNotificationsState()
                        .padding(.vertical, 80)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            NotificationRow(item: item)
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .task { await load() }
        .refreshable { await load() }
    }

    @MainActor
    private func load() async {
        loading = true
        error = nil
        do {
            items = try await NetworkService.shared.notifications()
        } catch {
            self.error = "Couldn't load notifications."
            print("🔔 [notifications] load failed: \(error)")
        }
        loading = false
    }

    @MainActor
    private func markAllRead() async {
        // Optimistically clear unread state, then call the server.
        items = items.map { item in
            NotificationItem(
                id: item.id, kind: item.kind, timestamp: item.timestamp,
                isRead: true, data: item.data
            )
        }
        try? await NetworkService.shared.markAllNotificationsRead()
    }
}

private struct NotificationRow: View {
    let item: NotificationItem
    @EnvironmentObject var router: ShellRouter
    @State private var hover = false

    var body: some View {
        Button(action: handleTap) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(LinearGradient.ravenLogo.opacity(0.2))
                        .frame(width: 36, height: 36)
                    Image(systemName: glyph)
                        .font(.system(size: 16))
                        .foregroundStyle(RavenColors.logoStart)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(headline)
                        .font(.system(size: 14, weight: .semibold))
                    if let detail = detail {
                        Text(detail)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Text(relativeTime(item.timestamp))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !item.isRead {
                    Circle()
                        .fill(RavenColors.accent)
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(hover ? Color.white.opacity(0.03) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    /// Tap routes by notification kind:
    /// - DM/group sender → jump to that conversation in Messages tab.
    /// - Everything else (like / comment / mention / follow) → open the
    ///   actor's profile sheet.
    /// Also marks the notification as read on the server, fire-and-forget.
    private func handleTap() {
        if !item.isRead {
            Task { try? await NetworkService.shared.markNotificationRead(id: item.id) }
        }
        switch item.kind {
        case "message", "group_message":
            if let roomId = item.data.roomId {
                router.section = .messages
                router.selectedConversationId = roomId
                router.selectedIsGroup = item.kind == "group_message"
            }
        case "pinned_message", "poll_created":
            // Both types carry room_id (DM peer or group id) + is_group.
            // Open the messages tab and switch the right pane to that
            // thread; iOS's existing fetch-on-appear will surface the
            // pinned message bar / poll bubble naturally.
            if let roomId = item.data.roomId {
                router.section = .messages
                router.selectedConversationId = roomId
                router.selectedIsGroup = item.data.isGroup ?? false
                router.selectedGroupName = item.data.groupName
            }
        case "reaction",
             "live_location_started", "live_location_ended",
             "screenshot_chat":
            // All three of these resolve to "open the chat where it
            // happened" — the chat thread / message bar handles the
            // visual on its own (reactions row, live-location bubble).
            if let roomId = item.data.roomId {
                router.section = .messages
                router.selectedConversationId = roomId
                router.selectedIsGroup = item.data.isGroup ?? false
                router.selectedGroupName = item.data.groupName
            }
        case "contact_shared":
            // Closes the privacy loop on `allow_contact_share`. The
            // Mac shell doesn't have a Privacy pane yet, so route to
            // the Profile tab (Settings live there) rather than the
            // sharer's profile sheet.
            router.section = .profile
        case "profile_view", "screenshot_profile":
            // Open the snitcher's profile so the user can decide to
            // block / report. Both types carry the viewer id under
            // `actorId` (server-side).
            if let actorId = item.data.actorId {
                router.presentedProfileUserId = actorId
            }
        case "security", "security_alert":
            // Security pane lives under Profile on the Mac shell
            // (no dedicated `.security` section), so flip to Profile
            // and let the user drill down.
            router.section = .profile
        default:
            if let actorId = item.data.actorId {
                router.presentedProfileUserId = actorId
            }
        }
    }

    /// One-line summary built from `kind` + the unwrapped username.
    private var headline: String {
        // Security events (legacy `security` and the new
        // `security_alert` type the server emits on login) don't have
        // a meaningful actor — they describe an event happening to YOU.
        if item.kind == "security" || item.kind == "security_alert" {
            switch item.data.event {
            case "new_login":  return "🔐 New sign-in to your account"
            default:           return "🔐 Security alert"
            }
        }
        let actor = item.data.actorUsername ?? "Someone"
        switch item.kind {
        case "like":               return "@\(actor) liked your post"
        case "comment":            return "@\(actor) commented on your post"
        case "reply":              return "@\(actor) replied to your comment"
        case "mention":            return "@\(actor) mentioned you"
        case "follow":             return "@\(actor) followed you"
        case "friend_request":     return "@\(actor) sent you a friend request"
        case "post_from_followed": return "@\(actor) posted"
        case "pinned_message":
            if let group = item.data.groupName, !group.isEmpty {
                return "@\(actor) pinned a message in \(group)"
            }
            return "@\(actor) pinned a message"
        case "poll_created":
            if let group = item.data.groupName, !group.isEmpty {
                return "@\(actor) started a poll in \(group)"
            }
            return "@\(actor) started a poll"
        // ── Privacy & Safety types added 2026-05-14 ────────────────
        case "reaction":           return "@\(actor) reacted to your message"
        case "contact_shared":     return "@\(actor) shared your profile"
        case "profile_view":       return "@\(actor) viewed your profile"
        case "screenshot_profile": return "📸 @\(actor) screenshotted your profile"
        case "screenshot_chat":    return "📸 @\(actor) screenshotted your chat"
        case "live_location_started": return "📍 @\(actor) is sharing live location"
        case "live_location_ended":   return "📍 @\(actor) stopped sharing live location"
        default:                   return "@\(actor)"
        }
    }

    /// Comment / reply previews come through as `data.preview`; security
    /// events (new login, etc.) carry the originating device user-agent in
    /// `data.device` instead. Pinned + poll notifications also use
    /// `data.preview` for the message snippet / poll question.
    private var detail: String? {
        if let p = item.data.preview, !p.isEmpty { return p }
        if item.kind == "security", let d = item.data.device, !d.isEmpty {
            return d
        }
        return nil
    }

    private var glyph: String {
        switch item.kind {
        case "like": return "heart.fill"
        case "comment", "reply": return "bubble.left.fill"
        case "follow", "friend_request": return "person.badge.plus"
        case "mention": return "at"
        case "post_from_followed": return "doc.text.fill"
        case "security": return "shield.fill"
        case "security_alert": return "exclamationmark.shield.fill"
        case "pinned_message": return "pin.fill"
        case "poll_created": return "chart.bar.doc.horizontal.fill"
        case "reaction": return "face.smiling.inverse"
        case "contact_shared": return "person.crop.rectangle.stack.fill"
        case "profile_view": return "eye.fill"
        case "screenshot_profile", "screenshot_chat": return "camera.viewfinder"
        case "live_location_started": return "location.fill.viewfinder"
        case "live_location_ended": return "location.slash.fill"
        default: return "bell.fill"
        }
    }

    private func relativeTime(_ t: Date) -> String {
        let diff = Date().timeIntervalSince(t)
        if diff < 60 { return "\(Int(diff))s" }
        if diff < 3600 { return "\(Int(diff / 60))m" }
        if diff < 86400 { return "\(Int(diff / 3600))h" }
        if diff < 604800 { return "\(Int(diff / 86400))d" }
        let f = DateFormatter()
        f.dateStyle = .short
        return f.string(from: t)
    }
}

private struct EmptyNotificationsState: View {
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(LinearGradient.ravenLogo.opacity(0.2))
                    .frame(width: 96, height: 96)
                Image(systemName: "bell")
                    .font(.system(size: 38))
                    .foregroundStyle(RavenColors.logoStart)
            }
            Text("All caught up")
                .font(.system(size: 20, weight: .heavy))
            Text("Likes, replies, and friend requests will show up here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
    }
}
