import SwiftUI

// MARK: - Notifications List View
/// Full list of all notifications with Liquid Glass design
struct NotificationsListView: View {
    @State private var notifications: [LocalNotification] = []
    @State private var isLoading = true
    @State private var selectedFilter: NotificationFilter = .all
    @State private var replyTarget: LocalNotification?
    
    enum NotificationFilter: String, CaseIterable {
        case all = "All"
        case unread = "Unread"
        case friends = "Friends"
        case activity = "Activity"
    }
    
    var body: some View {
        ZStack {
            // Gradient background
            LinearGradient(
                colors: [
                    Color(.systemBackground),
                    Color(.systemBackground).opacity(0.95)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Filter Pills
                filterPillsSection
                
                if isLoading {
                    loadingView
                } else if filteredNotifications.isEmpty {
                    emptyStateView
                } else {
                    notificationsList
                }
            }
        }
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        Haptics.light()
                        Task { await markAllAsRead() }
                    } label: {
                        Label("Mark All Read", systemImage: "envelope.open")
                    }
                    
                    Button(role: .destructive) {
                        Haptics.warning()
                        clearAllNotifications()
                    } label: {
                        Label("Clear All", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20))
                        .symbolRenderingMode(.hierarchical)
                }
            }
        }
        .task {
            await loadNotifications()
            // Auto-mark as read on server when user views the notification center.
            // 🔴 ROUND 70 — exclude friend requests from the sweep so the
            // pinned "Pending Requests" folder still shows them as
            // actionable (unread visual treatment) until accept/decline.
            if NetworkMonitor.shared.isOnline &&
                notifications.contains(where: { !$0.isRead && !$0.type.isPendingRequest }) {
                await markAllAsRead()
            }
        }
        // 🟢 ROUND 75 (2026-05-24) — refresh on WS friend_request push.
        //
        // USER REPORT: "friend reqeust ha … toye notification center
        // nemiyad" — friend requests don't appear in the notification
        // center.
        //
        // ROOT CAUSE: RealtimeEngine WS handler (line 1316+) fires
        // the toast banner + bumps the badge count, but does NOT
        // trigger a list refresh. NotificationsListView only loads
        // on `.task` (view appear) + `.refreshable` (pull-down). So
        // the bell shows N unread but tapping it shows an empty
        // list until either the 30s periodic poll runs or the user
        // pulls-to-refresh.
        //
        // FIX: observe a custom Notification.Name posted by the WS
        // friend_request handler, re-fetch /api/notifications on
        // each event. Cheap (single HTTP call, runs already on a
        // background queue).
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FriendRequestWSReceived"))) { _ in
            Task { await refreshNotifications() }
        }
        .sheet(item: $replyTarget) { notification in
            NotificationReplySheet(
                notification: notification,
                onSend: { text in
                    await sendReply(to: notification, text: text)
                },
                onDismiss: {
                    replyTarget = nil
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }
    
    // MARK: - Filter Pills Section
    private var filterPillsSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(NotificationFilter.allCases, id: \.self) { filter in
                    FilterPill(
                        title: filter.rawValue,
                        isSelected: selectedFilter == filter,
                        count: countFor(filter)
                    ) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            selectedFilter = filter
                            Haptics.light()
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
    
    // MARK: - Filter Pill
    struct FilterPill: View {
        let title: String
        let isSelected: Bool
        let count: Int
        let action: () -> Void
        
        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    
                    if count > 0 {
                        Text("\(count)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(isSelected ? .white : .secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(isSelected ? Color.white.opacity(0.25) : Color.secondary.opacity(0.15))
                            )
                    }
                }
                .foregroundStyle(isSelected ? .white : .primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.blue, .blue.opacity(0.8)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .shadow(color: .blue.opacity(0.3), radius: 8, x: 0, y: 4)
                    } else {
                        Capsule()
                            .fill(.ultraThinMaterial)
                            .overlay(
                                Capsule()
                                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                            )
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }
    
    // MARK: - Loading View
    private var loadingView: some View {
        VStack(spacing: 16) {
            ForEach(0..<5, id: \.self) { _ in
                ShimmerNotificationCard()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
    
    // MARK: - Shimmer Card
    struct ShimmerNotificationCard: View {
        @State private var shimmerOffset: CGFloat = -200
        
        var body: some View {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 48, height: 48)
                
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 120, height: 14)
                    
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.gray.opacity(0.15))
                        .frame(width: 180, height: 12)
                }
                
                Spacer()
            }
            .padding(16)
            .background(.regularMaterial, in: Capsule())
            .overlay(
                LinearGradient(
                    colors: [.clear, .white.opacity(0.2), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .offset(x: shimmerOffset)
                .mask(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                )
            )
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    shimmerOffset = 400
                }
            }
        }
    }
    
    // MARK: - Empty State
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 100, height: 100)
                
                Image(systemName: "bell.slash")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
            }
            
            VStack(spacing: 8) {
                Text("No notifications")
                    .font(.title3.weight(.semibold))
                
                Text("You're all caught up!")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            Spacer()
        }
    }
    
    // MARK: - Notifications List
    private var notificationsList: some View {
        List {
            // 🔴 ROUND 70 (2026-05-23) — pinned Pending Requests folder.
            //
            // Friend / follow requests ALWAYS live in their own pinned
            // section at the top of the activity center, regardless of
            // which filter pill is selected. They are PERSISTENT —
            // immune to swipe-delete, Mark-All-Read, Clear-All, and the
            // auto-mark-read-on-view sweep. They disappear ONLY when
            // the user explicitly taps Accept or Decline (or the sender
            // cancels the request server-side). This matches the
            // user's stated requirement: "follow request notification
            // bayad toye notification center biyad va ta vaghty ke
            // user behsh respond nadade nabayad bere, barash yek folder
            // khas dorsot kon toye notification center".
            if !pendingRequestNotifications.isEmpty {
                Section {
                    ForEach(pendingRequestNotifications) { notification in
                        NotificationCard(
                            notification: notification,
                            onAccept: {
                                acceptFriendRequest(notification)
                            },
                            onDecline: {
                                declineFriendRequest(notification)
                            }
                        )
                        .onTapGesture {
                            handleTap(notification)
                        }
                        // 🔴 ROUND 70 — NO swipeActions here.
                        // Friend requests are intentionally
                        // unswipeable: the only way to clear them is
                        // accept / decline.
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                } header: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.purple)
                        Text("Pending Requests")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.purple)
                            .textCase(.uppercase)
                        // Count badge — surfaces how many are
                        // waiting at a glance.
                        Text("\(pendingRequestNotifications.count)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color.purple)
                            )
                        Spacer()
                        Text("respond to clear")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 16)
                    .padding(.bottom, 4)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                }
            }

            ForEach(groupedNotifications.keys.sorted(by: >), id: \.self) { date in
                Section {
                    ForEach(groupedNotifications[date] ?? []) { notification in
                        NotificationCard(
                            notification: notification,
                            onAccept: nil,
                            onDecline: nil
                        )
                        .onTapGesture {
                            handleTap(notification)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if notification.type == .message || notification.type == .groupMessage {
                                Button {
                                    Haptics.medium()
                                    replyTarget = notification
                                } label: {
                                    Label("Reply", systemImage: "arrowshape.turn.up.left.fill")
                                }
                                .tint(.blue)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                toggleReadState(notification)
                            } label: {
                                Label(notification.isRead ? "Unread" : "Read",
                                      systemImage: notification.isRead ? "envelope.badge" : "envelope.open")
                            }
                            .tint(notification.isRead ? .indigo : .gray)

                            Button(role: .destructive) {
                                deleteNotification(notification)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button {
                                Task { await markAsRead(notification.id) }
                            } label: {
                                Label(notification.isRead ? "Mark Unread" : "Mark Read",
                                      systemImage: notification.isRead ? "envelope.badge" : "envelope.open")
                            }

                            Button(role: .destructive) {
                                deleteNotification(notification)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                } header: {
                    HStack {
                        Text(formatSectionDate(date))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 16)
                    .padding(.bottom, 4)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await refreshNotifications()
        }
    }

    // MARK: - Pending Friend / Follow Requests (sticky folder)
    //
    // 🔴 ROUND 70 — these are pulled BEFORE filter is applied so the
    // pinned folder shows the same content regardless of which filter
    // pill is selected. Sorted newest-first so the most recent
    // requesters surface at the top.
    private var pendingRequestNotifications: [LocalNotification] {
        notifications
            .filter { $0.type.isPendingRequest }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Grouped Notifications
    //
    // 🔴 ROUND 70 — friend requests EXCLUDED from the date-grouped
    // body. They live only in the pinned `pendingRequestNotifications`
    // section above, so removing them from this dictionary prevents
    // duplicate rendering.
    private var groupedNotifications: [Date: [LocalNotification]] {
        let nonRequests = filteredNotifications.filter { !$0.type.isPendingRequest }
        return Dictionary(grouping: nonRequests) { notification in
            Calendar.current.startOfDay(for: notification.createdAt)
        }
    }

    // MARK: - Filtered Notifications
    private var filteredNotifications: [LocalNotification] {
        switch selectedFilter {
        case .all:
            return notifications
        case .unread:
            return notifications.filter { !$0.isRead }
        case .friends:
            return notifications.filter { $0.type.isPendingRequest }
        case .activity:
            return notifications.filter { $0.type == .like || $0.type == .comment || $0.type == .mention || $0.type == .groupMessage }
        }
    }
    
    // MARK: - Count for Filter
    //
    // 🔴 ROUND 71 phase 3 (2026-05-24) — every pill badge now
    // counts UNREAD items only.
    //
    // Pre-fix `case .all` returned `notifications.count` (TOTAL,
    // including already-read rows). After the user opened the
    // notification center and the auto-mark-all-read sweep ran, the
    // server count dropped to zero but the "All [50]" pill still
    // displayed 50 because the local notifications array still held
    // the same 50 rows — they were just flipped to `isRead = true`.
    // The badge stayed pinned at 50 forever until the user logged
    // out or the cache aged out.
    //
    // Filter rule going forward: pill badges represent UNREAD-of-
    // that-category. Friend requests are deliberately NOT cleared
    // by mark-all-read (round-70 contract), so their pill keeps
    // showing the count of still-pending requests as before.
    private func countFor(_ filter: NotificationFilter) -> Int {
        switch filter {
        case .all:
            return notifications.filter { !$0.isRead }.count
        case .unread:
            return notifications.filter { !$0.isRead }.count
        case .friends:
            return notifications.filter { $0.type.isPendingRequest && !$0.isRead }.count
        case .activity:
            return notifications.filter {
                !$0.isRead && ($0.type == .like || $0.type == .comment || $0.type == .mention || $0.type == .groupMessage)
            }.count
        }
    }
    
    // MARK: - Format Section Date
    private func formatSectionDate(_ date: Date) -> String {
        let calendar = Calendar.current
        
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE, MMM d"
            return formatter.string(from: date)
        }
    }
    
    // MARK: - Handle Tap
    private func handleTap(_ notification: LocalNotification) {
        Haptics.light()
        
        Task { await markAsRead(notification.id) }
        
        switch notification.type {
        case .message, .groupMessage:
            if let roomId = notification.referenceId {
                DeepLinkRouter.shared.navigate(to: .chat(roomId: roomId))
            }
        case .friendRequest, .followRequest:
            DeepLinkRouter.shared.navigate(to: .friendRequests)
        case .like, .comment:
            // FIX: Navigate to the post when tapping like/comment notifications
            if let postId = notification.referenceId {
                DeepLinkRouter.shared.navigate(to: .post(postId: postId))
            }
        case .mention:
            // Navigate to the post where user was mentioned
            if let postId = notification.referenceId {
                DeepLinkRouter.shared.navigate(to: .post(postId: postId))
            }
        case .newPost:
            // Navigate to the post
            if let postId = notification.referenceId {
                DeepLinkRouter.shared.navigate(to: .post(postId: postId))
            }
        case .audioRoom:
            // Navigate to the audio room
            if let roomId = notification.referenceId {
                DeepLinkRouter.shared.navigate(to: .audioRoom(slug: roomId))
            }
        case .security, .securityAlert:
            DeepLinkRouter.shared.navigate(to: .security)
        case .liveLocationStarted, .liveLocationEnded:
            // Live-location pings tie back to the chat — referenceId is
            // the room id where the share started.
            if let roomId = notification.referenceId {
                DeepLinkRouter.shared.navigate(to: .chat(roomId: roomId))
            }
        case .reaction:
            // Reaction notifications point at the reacted-to message;
            // open the chat and let the existing scroll-to-message
            // hook take over.
            if let roomId = notification.referenceId {
                DeepLinkRouter.shared.navigate(to: .chat(roomId: roomId))
            }
        case .contactShared:
            // Send the user to Privacy Settings so they can flip the
            // "Allow others to share my contact" toggle if they're
            // unhappy. The setting we already built in PrivacySettingsView.
            DeepLinkRouter.shared.navigate(to: .privacySettings)
        case .profileView:
            // Open MY profile so the user can review what was visible.
            // referenceId carries the viewer's user id (could surface
            // later as "X viewed you" header).
            DeepLinkRouter.shared.navigate(to: .myProfile)
        case .screenshotProfile:
            // referenceId = the snitcher's user id — drop into their
            // profile so the user can decide to block / report.
            if let viewerId = notification.referenceId {
                DeepLinkRouter.shared.navigate(to: .profile(userId: viewerId))
            }
        case .screenshotChat:
            // Drop into the chat that was screenshot.
            if let roomId = notification.referenceId {
                DeepLinkRouter.shared.navigate(to: .chat(roomId: roomId))
            }
        }
    }
    
    // MARK: - Load Notifications
    private func loadNotifications() async {
        isLoading = true
        
        // FIX: Show cached notifications immediately for instant UI
        if let cached = LocalNotificationService.shared.getCachedNotifications() {
            notifications = cached
        }
        
        // Collect IDs that are already marked read locally (from cache or optimistic updates)
        let localReadIds = Set(notifications.filter { $0.isRead }.map { $0.id })
        
        // Fetch fresh data from server if online
        if NetworkMonitor.shared.isOnline {
            do {
                var fresh = try await LocalNotificationService.shared.getNotifications()
                // Merge: preserve local read state for any notification the server
                // hasn't caught up with yet (race between mark-read POST and fetch)
                for i in fresh.indices {
                    if !fresh[i].isRead && localReadIds.contains(fresh[i].id) {
                        fresh[i].isRead = true
                    }
                }
                notifications = fresh
                LocalNotificationService.shared.cacheNotifications(fresh)
            } catch {
                #if DEBUG
                print("❌ Failed to load notifications: \(error) — using cache")
                #endif
            }
        }
        
        isLoading = false
    }
    
    // MARK: - Refresh Notifications (Pull-to-Refresh)
    /// Separate from loadNotifications — does NOT set isLoading to avoid
    /// destroying the ScrollView and breaking the .refreshable spinner.
    private func refreshNotifications() async {
        Haptics.light()
        // Collect IDs that are already marked read locally (optimistic state)
        let localReadIds = Set(notifications.filter { $0.isRead }.map { $0.id })
        
        do {
            var fresh = try await LocalNotificationService.shared.getNotifications()
            // Merge: preserve local read state for any notification the server
            // hasn't caught up with yet (race between mark-read POST and fetch)
            for i in fresh.indices {
                if !fresh[i].isRead && localReadIds.contains(fresh[i].id) {
                    fresh[i].isRead = true
                }
            }
            notifications = fresh
            LocalNotificationService.shared.cacheNotifications(fresh)
        } catch {
            #if DEBUG
            print("❌ Failed to refresh notifications: \(error)")
            #endif
        }
    }
    
    // MARK: - Mark as Read
    private func markAsRead(_ id: String) async {
        do {
            try await LocalNotificationService.shared.markAsRead(id: id)
            if let index = notifications.firstIndex(where: { $0.id == id }) {
                // Snapshot the previous state BEFORE flipping isRead so we
                // know whether the badge needs decrementing. Without this
                // guard, repeated `markAsRead` calls on the same id would
                // over-decrement the unread badge into negatives (the
                // pipeline guards against negatives but the badge would
                // still drift away from the true count).
                let wasUnread = !notifications[index].isRead
                notifications[index].isRead = true
                LocalNotificationService.shared.cacheNotifications(notifications)

                // 🔴 Bug fix (2026-05-10): decrement the pipeline's unread
                // counter centrally here so EVERY caller path benefits —
                // the swipe-toggle had its own decrement (lines 670–679)
                // but the context-menu "Mark Read" (~line 295), card-tap
                // navigation (~line 389), and post-reply auto-mark (~line
                // 715) all flowed through `markAsRead(_:)` and silently
                // skipped the badge update. Symptom: badge stays at the
                // pre-tap count until the next poll catches up. The user
                // explicitly reported this. Centralising the decrement
                // here fixes all four call sites in one place; the
                // redundant decrement inside the toggle's else-branch
                // is removed to avoid a double-decrement.
                if wasUnread {
                    await MainActor.run {
                        if NotificationPipeline.shared.unreadCount > 0 {
                            NotificationPipeline.shared.unreadCount -= 1
                        }
                    }
                }
            }
        } catch {
            #if DEBUG
            print("Failed to mark as read: \(error)")
            #endif
        }
    }
    
    // MARK: - Mark All as Read
    private func markAllAsRead() async {
        // 1. Optimistic UI update immediately.
        //
        // 🔴 ROUND 70 — DO NOT mark friend requests as read.
        // A friend / follow request is an outstanding action item;
        // "reading" it without responding would silently dismiss
        // the pulse on the Pending Requests folder and let the user
        // forget about it. The folder header relies on the unread
        // state to drive its purple count badge.
        for i in notifications.indices where !notifications[i].type.isPendingRequest {
            notifications[i].isRead = true
        }
        LocalNotificationService.shared.cacheNotifications(notifications)
        // Unread badge now counts only the still-pending friend
        // requests + anything the user explicitly marked unread.
        let remainingUnread = notifications.filter { !$0.isRead }.count
        NotificationPipeline.shared.unreadCount = remainingUnread

        // 🔴 Bug fix (2026-05-09): also open the NotificationsService
        // suppression window. Previously this view bypassed
        // `NotificationsService.markAllAsRead()` and went straight to
        // `LocalNotificationService.markAllAsReadDirect()`, so the
        // poll-suppression flag was never set — the polling loop would
        // re-fetch the server count seconds later and bounce the
        // badge back to non-zero (the user-reported bug).
        await NotificationsService.shared.extendSuppressionWindow()

        // 2. Sync to server (awaited so subsequent fetches get updated data)
        do {
            try await LocalNotificationService.shared.markAllAsReadDirect()
        } catch {
            #if DEBUG
            print("❌ Failed to mark all as read on server: \(error)")
            #endif
        }

        // 3. Reset unreadCount AFTER the server call completes too —
        // covers the case where a poll raced during the await and
        // re-set it to a non-zero value before the suppression
        // window opened.
        //
        // 🔴 ROUND 71 phase 3 (2026-05-24) — preserve the friend-request
        // badge. Pre-fix this line was `unreadCount = 0`, which
        // wiped the still-pending friend-request count that
        // line ~664 had just correctly populated. Friend / follow
        // requests are NOT cleared by "mark all as read" — they
        // only leave the list via Accept or Decline (see the
        // delete-notification path below at ~697). Recompute the
        // badge from the FR-only filter so the bell stops claiming
        // 0 when there are still pending friend requests.
        let pendingFriendRequests = notifications.filter {
            $0.type.isPendingRequest && !$0.isRead
        }.count
        NotificationPipeline.shared.unreadCount = pendingFriendRequests
    }
    
    // MARK: - Delete Notification
    private func deleteNotification(_ notification: LocalNotification) {
        // 🔴 ROUND 70 — friend / follow requests are NOT deletable.
        // Block the swipe / context-menu delete path so they can only
        // leave the list via Accept or Decline. Cheap haptic warning
        // tells the user the gesture was refused.
        if notification.type.isPendingRequest {
            Haptics.warning()
            return
        }
        Haptics.light()

        Task { @MainActor in
            if !notification.isRead && NotificationPipeline.shared.unreadCount > 0 {
                NotificationPipeline.shared.unreadCount -= 1
            }
        }

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            notifications.removeAll { $0.id == notification.id }
            LocalNotificationService.shared.cacheNotifications(notifications)
        }

        Task {
            try? await LocalNotificationService.shared.deleteNotification(id: notification.id)
        }
    }

    // MARK: - Clear All Notifications
    private func clearAllNotifications() {
        // 🔴 ROUND 70 — Clear All keeps the friend-request folder
        // intact. The user must Accept / Decline each pending request
        // for it to disappear; Clear-All wiping them silently would
        // lose actionable items the user hasn't responded to.
        let preservedRequests = notifications.filter { $0.type.isPendingRequest }
        let idsToDelete = notifications
            .filter { !$0.type.isPendingRequest }
            .map { $0.id }

        Task { @MainActor in
            // Unread count drops to just the surviving friend requests.
            NotificationPipeline.shared.unreadCount = preservedRequests.filter { !$0.isRead }.count
        }

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            notifications = preservedRequests
            LocalNotificationService.shared.cacheNotifications(notifications)
        }

        Task {
            // Delete only non-friend-request rows server-side. The
            // bulk endpoint would also wipe friend requests, so we
            // fall back to per-id delete (cheap — typical Clear-All
            // touches dozens, not thousands, of rows).
            for id in idsToDelete {
                try? await LocalNotificationService.shared.deleteNotification(id: id)
            }
        }
    }
    
    // MARK: - Friend / Follow Request Actions
    //
    // 🟢 ROUND 76 (2026-05-24) — fixed two reported issues at once:
    //   (a) USER REPORT (log): "POST /api/users/friend-request//accept
    //       → HTTP 404 Not Found". The double-slash proved that
    //       `requestId` was an EMPTY STRING (not nil). The previous
    //       `guard let requestId = referenceId else { return }` only
    //       guarded nil — empty strings sailed through.
    //   (b) `follow_request` notifications previously hit this same
    //       handler but the server's endpoint is `/follow-request/
    //       {id}/accept`, NOT `/friend-request/{id}/accept`. Calling
    //       the wrong path returned 404 even when requestId was valid.
    //
    // Both fixed by: trimming the requestId + isEmpty check, AND
    // routing the endpoint stem based on `notification.type`.
    private func acceptFriendRequest(_ notification: LocalNotification) {
        guard let requestId = notification.referenceId,
              !requestId.trimmingCharacters(in: .whitespaces).isEmpty else {
            #if DEBUG
            print("⚠️ [Accept] notification \(notification.id.prefix(8)) has empty/nil referenceId (type=\(notification.type)) — refusing call")
            #endif
            Haptics.error()
            return
        }
        let endpointStem: String
        switch notification.type {
        case .followRequest:
            endpointStem = "follow-request"
        default:
            endpointStem = "friend-request"
        }

        // ⚡ Optimistic: remove immediately
        let backup = notifications
        withAnimation {
            notifications.removeAll { $0.id == notification.id }
            LocalNotificationService.shared.cacheNotifications(notifications)
        }

        Task { @MainActor in
            if NotificationPipeline.shared.unreadCount > 0 {
                NotificationPipeline.shared.unreadCount -= 1
            }
        }

        Task {
            do {
                struct EmptyBody: Encodable {}
                let _: Empty = try await NetworkService.shared.post(
                    path: "/api/users/\(endpointStem)/\(requestId)/accept",
                    body: EmptyBody()
                )
            } catch {
                // Rollback on failure
                await MainActor.run {
                    withAnimation {
                        notifications = backup
                        LocalNotificationService.shared.cacheNotifications(notifications)
                    }
                    Haptics.error()
                }
                #if DEBUG
                print("❌ Accept \(endpointStem) failed: \(error)")
                #endif
            }
        }
    }

    private func declineFriendRequest(_ notification: LocalNotification) {
        guard let requestId = notification.referenceId,
              !requestId.trimmingCharacters(in: .whitespaces).isEmpty else {
            #if DEBUG
            print("⚠️ [Decline] notification \(notification.id.prefix(8)) has empty/nil referenceId (type=\(notification.type)) — refusing call")
            #endif
            Haptics.error()
            return
        }
        let endpointStem: String
        switch notification.type {
        case .followRequest:
            endpointStem = "follow-request"
        default:
            endpointStem = "friend-request"
        }

        // ⚡ Optimistic: remove immediately
        let backup = notifications
        withAnimation {
            notifications.removeAll { $0.id == notification.id }
            LocalNotificationService.shared.cacheNotifications(notifications)
        }

        Task { @MainActor in
            if NotificationPipeline.shared.unreadCount > 0 {
                NotificationPipeline.shared.unreadCount -= 1
            }
        }

        Task {
            do {
                struct EmptyBody: Encodable {}
                let _: Empty = try await NetworkService.shared.post(
                    path: "/api/users/\(endpointStem)/\(requestId)/reject",
                    body: EmptyBody()
                )
            } catch {
                // Rollback on failure
                await MainActor.run {
                    withAnimation {
                        notifications = backup
                        LocalNotificationService.shared.cacheNotifications(notifications)
                    }
                    Haptics.error()
                }
                #if DEBUG
                print("❌ Decline \(endpointStem) failed: \(error)")
                #endif
            }
        }
    }
    
    // MARK: - Toggle Read State
    private func toggleReadState(_ notification: LocalNotification) {
        Haptics.light()
        
        if notification.isRead {
            // Mark as unread
            Task {
                do {
                    try await LocalNotificationService.shared.markAsUnread(id: notification.id)
                    if let index = notifications.firstIndex(where: { $0.id == notification.id }) {
                        notifications[index].isRead = false
                        LocalNotificationService.shared.cacheNotifications(notifications)
                    }
                    await MainActor.run {
                        NotificationPipeline.shared.unreadCount += 1
                    }
                } catch {
                    #if DEBUG
                    print("❌ Failed to mark as unread: \(error)")
                    #endif
                }
            }
        } else {
            // Mark as read — `markAsRead(_:)` now decrements the pipeline
            // unread counter itself (so context-menu / tap / post-reply
            // call sites also stay in sync). No extra decrement here.
            Task {
                await markAsRead(notification.id)
            }
        }
    }
    
    // MARK: - Send Reply
    private func sendReply(to notification: LocalNotification, text: String) async {
        guard let referenceId = notification.referenceId,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        do {
            if notification.type == .groupMessage {
                // Group message: send via group endpoint
                struct GroupReplyBody: Encodable {
                    let content: String
                    let messageType: String
                }
                struct GroupReplyResponse: Decodable {
                    let id: String
                }
                let _: GroupReplyResponse = try await NetworkService.shared.post(
                    path: "/api/groups/\(referenceId)/messages",
                    body: GroupReplyBody(content: trimmed, messageType: "text")
                )
            } else {
                // 1:1 message: use MessageService
                try await MessageService.shared.sendText(
                    to: referenceId,
                    text: trimmed
                )
            }
            
            Haptics.success()
            
            // Mark notification as read after replying
            await markAsRead(notification.id)
            
        } catch {
            Haptics.error()
            #if DEBUG
            print("❌ Failed to send reply: \(error)")
            #endif
        }
    }
}

// MARK: - Notification Card (Modern Redesign)
struct NotificationCard: View {
    let notification: LocalNotification
    var onAccept: (() -> Void)? = nil
    var onDecline: (() -> Void)? = nil
    
    private let avatarSize: CGFloat = 48
    
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // MARK: Profile Avatar with type badge
            ZStack(alignment: .bottomTrailing) {
                if notification.type == .security {
                    // RAVEN logo for system/server notifications
                    Image("RavenLogo")
                        .resizable()
                        .scaledToFill()
                        .frame(width: avatarSize, height: avatarSize)
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .stroke(.primary.opacity(0.25), lineWidth: 1.5)
                        )
                } else {
                    GlassAvatar(
                        name: notification.title,
                        path: notification.avatarUrl,
                        size: avatarSize,
                        showGlow: false
                    )
                }
                
                // Type icon badge
                ZStack {
                    Circle()
                        .fill(notification.type.color)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle()
                                .stroke(Color(.systemBackground), lineWidth: 2)
                        )
                    
                    Image(systemName: notification.type.icon)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
                .offset(x: 4, y: 4)
            }
            .frame(width: avatarSize, height: avatarSize)
            
            // MARK: Content
            VStack(alignment: .leading, spacing: 5) {
                // Rich text: bold username + regular action
                richTextLine
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                
                // Timestamp
                Text(notification.createdAt.timeAgoShort())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                
                // Friend / Follow Request action buttons
                if notification.type.isPendingRequest {
                    friendRequestActions
                        .padding(.top, 4)
                }
            }
            
            Spacer(minLength: 0)
            
            // Unread dot
            if !notification.isRead {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            notification.isRead ? Color.white.opacity(0.06) : notification.type.color.opacity(0.2),
                            lineWidth: 0.5
                        )
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    
    // MARK: - Rich Text (Bold Name + Action)
    @ViewBuilder
    private var richTextLine: some View {
        let name = notification.title
        let action = notification.body
        
        (Text(name).fontWeight(.semibold) + Text(" ") + Text(action).foregroundColor(.secondary))
            .font(.subheadline)
            .foregroundStyle(.primary)
    }
    
    // MARK: - Friend Request Actions
    private var friendRequestActions: some View {
        HStack(spacing: 8) {
            Button {
                Haptics.success()
                onAccept?()
            } label: {
                Text("Confirm")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color.blue)
                    )
            }
            .buttonStyle(.plain)
            
            Button {
                Haptics.light()
                onDecline?()
            } label: {
                Text("Delete")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color(.systemGray5))
                    )
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Local Notification Model (for NotificationsListView only)
struct LocalNotification: Identifiable, Hashable, Codable {
    let id: String
    let type: NotificationType
    let title: String
    let body: String
    let avatarUrl: String?
    let referenceId: String?
    let createdAt: Date
    var isRead: Bool
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: LocalNotification, rhs: LocalNotification) -> Bool {
        lhs.id == rhs.id
    }
    
    enum NotificationType: String, Codable {
        case message
        case groupMessage
        case friendRequest
        // 🟢 ROUND 76 (2026-05-24) — explicit `follow_request` type so
        // the cell renders accept/decline buttons + routes to the
        // /follow-request/ endpoints (NOT /friend-request/, which 404s).
        case followRequest
        case like
        case comment
        case mention
        case newPost
        case audioRoom
        case security
        // ── Added 2026-05-14 ──
        case securityAlert
        case liveLocationStarted
        case liveLocationEnded
        case reaction
        case contactShared
        case profileView
        case screenshotProfile
        case screenshotChat

        var icon: String {
            switch self {
            case .message: return "message.fill"
            case .groupMessage: return "person.3.fill"
            case .friendRequest: return "person.badge.plus"
            case .followRequest: return "person.badge.plus"
            case .like: return "heart.fill"
            case .comment: return "bubble.left.fill"
            case .mention: return "at"
            case .newPost: return "square.and.pencil"
            case .audioRoom: return "waveform"
            case .security: return "shield.fill"
            case .securityAlert: return "exclamationmark.shield.fill"
            case .liveLocationStarted: return "location.fill.viewfinder"
            case .liveLocationEnded: return "location.slash.fill"
            case .reaction: return "face.smiling.inverse"
            case .contactShared: return "person.crop.rectangle.stack.fill"
            case .profileView: return "eye.fill"
            case .screenshotProfile, .screenshotChat: return "camera.viewfinder"
            }
        }

        var color: Color {
            switch self {
            case .message: return .blue
            case .groupMessage: return .indigo
            case .friendRequest: return .purple
            case .followRequest: return .purple
            case .like: return .pink
            case .comment: return .green
            case .mention: return .cyan
            case .newPost: return .blue
            case .audioRoom: return .purple
            case .security: return .orange
            case .securityAlert: return .red
            case .liveLocationStarted: return .cyan
            case .liveLocationEnded: return .gray
            case .reaction: return .pink
            case .contactShared: return .orange
            case .profileView: return .blue
            case .screenshotProfile, .screenshotChat: return .red
            }
        }

        /// 🟢 ROUND 76 (2026-05-24) — both friend-request AND follow-
        /// request notifications live in the pinned "Pending Requests"
        /// section, show Accept/Decline buttons, and are excluded from
        /// the global mark-all-as-read sweep. Centralised so we never
        /// miss one of the two when adding/removing.
        var isPendingRequest: Bool {
            return self == .friendRequest || self == .followRequest
        }
    }
}

// MARK: - Date Extension
extension Date {
    func timeAgoShort() -> String {
        let interval = Date().timeIntervalSince(self)
        
        if interval < 60 {
            return "now"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m"
        } else if interval < 86400 {
            return "\(Int(interval / 3600))h"
        } else if interval < 604800 {
            return "\(Int(interval / 86400))d"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: self)
        }
    }
}

// MARK: - Notification Service
class LocalNotificationService {
    static let shared = LocalNotificationService()
    private let networkService = NetworkService.shared
    private let cacheKey = "raven_notifications_cache_v1"
    
    private init() {}
    
    // MARK: - Offline Cache
    
    /// Return cached notifications from UserDefaults (nil if no cache)
    func getCachedNotifications() -> [LocalNotification]? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode([LocalNotification].self, from: data)
    }
    
    /// Save notifications to UserDefaults cache
    func cacheNotifications(_ notifications: [LocalNotification]) {
        if let data = try? JSONEncoder().encode(notifications) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }
    
    func getNotifications() async throws -> [LocalNotification] {
        struct ServerNotification: Decodable {
            let id: String
            let type: String
            let data: NotificationData
            let timestamp: Date
            let isRead: Bool
            
            struct NotificationData: Decodable {
                let postId: String?
                let likerId: String?
                let likerUsername: String?
                let likerAvatar: String?
                let commentId: String?
                let commenterId: String?
                let commenterUsername: String?
                let commenterAvatar: String?
                let preview: String?
                let requestId: String?
                let requesterId: String?
                let requesterUsername: String?
                let requesterAvatar: String?
                let roomId: String?
                let senderId: String?
                let senderUsername: String?
                let senderAvatar: String?
                let messagePreview: String?
                let groupId: String?
                let groupName: String?
                let authorUsername: String?
                let postPreview: String?
                let hostUsername: String?
                let hostId: String?
                let roomTitle: String?
                let mentionerId: String?
                let mentionerUsername: String?
                let mentionerAvatar: String?
                let addedBy: String?
                let addedById: String?
                // Generic actor fields used by newer notification types
                // (pinned_message, poll_created) — keeps the case bodies
                // small instead of forcing every type to hand-roll its own
                // username key.
                let actorId: String?
                let actorUsername: String?
                let actorAvatar: String?
                /// Pinned-message reference for `type=pinned_message`.
                let messageId: String?
                /// Poll id for `type=poll_created`, lets the row tap navigate
                /// straight to the chat thread + scroll to the poll bubble.
                let pollId: String?
                let isGroup: Bool?

                // ── Newer notification types (added 2026-05-14) ──
                /// Wire `message_type` carried on `type=message` /
                /// `type=group_message` data — lets us paint a verb-shaped
                /// preview ("sent a 🎤 voice message") instead of leaking
                /// the raw text or showing nothing for media.
                let messageType: String?
                /// Reaction emoji for `type=reaction`.
                let emoji: String?
                /// Reactor identity for `type=reaction`.
                let reactorId: String?
                let reactorUsername: String?
                let reactorAvatar: String?
                /// Sharer identity for `type=contact_shared` (the user who
                /// shared MY contact with someone else).
                let sharerId: String?
                let sharerUsername: String?
                let sharerAvatar: String?
                /// Recipient identity for `type=contact_shared` — who got
                /// my card. Helps the row read "X shared your contact with Y".
                let recipientId: String?
                let recipientUsername: String?
                /// Viewer identity for `type=profile_view` /
                /// `type=screenshot_profile`.
                let viewerId: String?
                let viewerUsername: String?
                let viewerAvatar: String?

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: FlexibleCodingKeys.self)

                    func flexKey(_ key: String) -> FlexibleCodingKeys {
                        FlexibleCodingKeys(stringValue: key) ?? FlexibleCodingKeys(key)
                    }
                    
                    postId = try? container.decode(String.self, forKey: flexKey("postId"))
                    likerId = try? container.decode(String.self, forKey: flexKey("likerId"))
                    likerUsername = try? container.decode(String.self, forKey: flexKey("likerUsername"))
                    likerAvatar = try? container.decode(String.self, forKey: flexKey("likerAvatar"))
                    commentId = try? container.decode(String.self, forKey: flexKey("commentId"))
                    commenterId = try? container.decode(String.self, forKey: flexKey("commenterId"))
                    commenterUsername = try? container.decode(String.self, forKey: flexKey("commenterUsername"))
                    commenterAvatar = try? container.decode(String.self, forKey: flexKey("commenterAvatar"))
                    preview = try? container.decode(String.self, forKey: flexKey("preview"))
                    requestId = try? container.decode(String.self, forKey: flexKey("requestId"))
                    requesterId = try? container.decode(String.self, forKey: flexKey("requesterId"))
                    requesterUsername = try? container.decode(String.self, forKey: flexKey("requesterUsername"))
                    requesterAvatar = try? container.decode(String.self, forKey: flexKey("requesterAvatar"))
                    roomId = try? container.decode(String.self, forKey: flexKey("roomId"))
                    senderId = try? container.decode(String.self, forKey: flexKey("senderId"))
                    senderUsername = try? container.decode(String.self, forKey: flexKey("senderUsername"))
                    senderAvatar = try? container.decode(String.self, forKey: flexKey("senderAvatar"))
                    messagePreview = try? container.decode(String.self, forKey: flexKey("messagePreview"))
                    groupId = try? container.decode(String.self, forKey: flexKey("groupId"))
                    groupName = try? container.decode(String.self, forKey: flexKey("groupName"))
                    authorUsername = try? container.decode(String.self, forKey: flexKey("authorUsername"))
                    postPreview = try? container.decode(String.self, forKey: flexKey("postPreview"))
                    hostUsername = try? container.decode(String.self, forKey: flexKey("hostUsername"))
                    hostId = try? container.decode(String.self, forKey: flexKey("hostId"))
                    roomTitle = try? container.decode(String.self, forKey: flexKey("roomTitle"))
                    mentionerId = try? container.decode(String.self, forKey: flexKey("mentionerId"))
                    mentionerUsername = try? container.decode(String.self, forKey: flexKey("mentionerUsername"))
                    mentionerAvatar = try? container.decode(String.self, forKey: flexKey("mentionerAvatar"))
                    addedBy = try? container.decode(String.self, forKey: flexKey("added_by"))
                    addedById = try? container.decode(String.self, forKey: flexKey("added_by_id"))
                    // Try the camelCase form first (the outer decoder applies
                    // .convertFromSnakeCase) and fall back to the raw snake
                    // form so older payloads still decode.
                    actorId = (try? container.decode(String.self, forKey: flexKey("actorId")))
                        ?? (try? container.decode(String.self, forKey: flexKey("actor_id")))
                    actorUsername = (try? container.decode(String.self, forKey: flexKey("actorUsername")))
                        ?? (try? container.decode(String.self, forKey: flexKey("actor_username")))
                    actorAvatar = (try? container.decode(String.self, forKey: flexKey("actorAvatar")))
                        ?? (try? container.decode(String.self, forKey: flexKey("actor_avatar")))
                    messageId = (try? container.decode(String.self, forKey: flexKey("messageId")))
                        ?? (try? container.decode(String.self, forKey: flexKey("message_id")))
                    pollId = (try? container.decode(String.self, forKey: flexKey("pollId")))
                        ?? (try? container.decode(String.self, forKey: flexKey("poll_id")))
                    isGroup = (try? container.decode(Bool.self, forKey: flexKey("isGroup")))
                        ?? (try? container.decode(Bool.self, forKey: flexKey("is_group")))

                    // Newer fields — same camelCase-with-snake-fallback pattern.
                    messageType = (try? container.decode(String.self, forKey: flexKey("messageType")))
                        ?? (try? container.decode(String.self, forKey: flexKey("message_type")))
                    emoji = try? container.decode(String.self, forKey: flexKey("emoji"))
                    reactorId = (try? container.decode(String.self, forKey: flexKey("reactorId")))
                        ?? (try? container.decode(String.self, forKey: flexKey("reactor_id")))
                    reactorUsername = (try? container.decode(String.self, forKey: flexKey("reactorUsername")))
                        ?? (try? container.decode(String.self, forKey: flexKey("reactor_username")))
                    reactorAvatar = (try? container.decode(String.self, forKey: flexKey("reactorAvatar")))
                        ?? (try? container.decode(String.self, forKey: flexKey("reactor_avatar")))
                    sharerId = (try? container.decode(String.self, forKey: flexKey("sharerId")))
                        ?? (try? container.decode(String.self, forKey: flexKey("sharer_id")))
                    sharerUsername = (try? container.decode(String.self, forKey: flexKey("sharerUsername")))
                        ?? (try? container.decode(String.self, forKey: flexKey("sharer_username")))
                    sharerAvatar = (try? container.decode(String.self, forKey: flexKey("sharerAvatar")))
                        ?? (try? container.decode(String.self, forKey: flexKey("sharer_avatar")))
                    recipientId = (try? container.decode(String.self, forKey: flexKey("recipientId")))
                        ?? (try? container.decode(String.self, forKey: flexKey("recipient_id")))
                    recipientUsername = (try? container.decode(String.self, forKey: flexKey("recipientUsername")))
                        ?? (try? container.decode(String.self, forKey: flexKey("recipient_username")))
                    viewerId = (try? container.decode(String.self, forKey: flexKey("viewerId")))
                        ?? (try? container.decode(String.self, forKey: flexKey("viewer_id")))
                    viewerUsername = (try? container.decode(String.self, forKey: flexKey("viewerUsername")))
                        ?? (try? container.decode(String.self, forKey: flexKey("viewer_username")))
                    viewerAvatar = (try? container.decode(String.self, forKey: flexKey("viewerAvatar")))
                        ?? (try? container.decode(String.self, forKey: flexKey("viewer_avatar")))
                }
                
                struct FlexibleCodingKeys: CodingKey {
                    var stringValue: String
                    var intValue: Int? { nil }
                    init?(stringValue: String) { self.stringValue = stringValue }
                    init(_ stringValue: String) { self.stringValue = stringValue }
                    init?(intValue: Int) { nil }
                }
            }
        }
        
        let serverNotifications: [ServerNotification] = try await networkService.get(path: "/api/notifications")
        
        let conversations = await MainActor.run { ConversationStore.shared.conversations }
        
        let mapped = serverNotifications.map { n in
            let notifType: LocalNotification.NotificationType
            var title = ""
            var body = ""
            var avatarUrl: String? = nil
            var referenceId: String? = nil
            
            switch n.type {
            case "message":
                notifType = .message
                referenceId = n.data.roomId
                avatarUrl = n.data.senderAvatar

                var senderName = n.data.senderUsername ?? "New message"
                if senderName.looksEncrypted || senderName.isEmpty {
                    if let roomId = referenceId, let conv = conversations.first(where: { $0.roomId == roomId }) {
                        senderName = conv.isGroup ? (conv.groupName ?? conv.peer.displayName) : conv.peer.displayName
                    } else {
                        senderName = "New message"
                    }
                }
                title = senderName

                // Verb-shaped, type-aware preview so non-text messages
                // never show as just the sender's name with no context.
                // Falls back to the server-supplied `preview` when the
                // type is unknown.
                let rawPreview = n.data.messagePreview ?? n.data.preview ?? ""
                let safePreview = rawPreview.looksEncrypted ? "" : rawPreview
                body = formatMessagePreview(
                    messageType: n.data.messageType,
                    preview: safePreview
                )
                
            case "like":
                notifType = .like
                var senderName = n.data.likerUsername ?? "Someone"
                if senderName.looksEncrypted { senderName = "Someone" }
                title = senderName
                body = "liked your post"
                referenceId = n.data.postId
                avatarUrl = n.data.likerAvatar
                
            case "comment":
                notifType = .comment
                var senderName = n.data.commenterUsername ?? "Someone"
                if senderName.looksEncrypted { senderName = "Someone" }
                title = senderName
                
                var preview = n.data.preview ?? "..."
                if preview.looksEncrypted { preview = "Secure comment" }
                body = "commented: \(preview)"
                referenceId = n.data.postId
                avatarUrl = n.data.commenterAvatar
                
            case "follow_request":
                // 🟢 ROUND 76 (2026-05-24) — follow_request notification
                // type was previously falling into the `default` case
                // (.security) because no switch arm matched it. Result:
                // notifType=.security, referenceId=nil, no Accept/
                // Decline buttons. The server's `data` payload mirrors
                // `friend_request` (requester_id/username/avatar +
                // request_id = follow.id), so we reuse the same field
                // extraction here but route the accept/decline action
                // to /api/users/follow-request/{id}/accept|reject
                // instead of /friend-request/.
                notifType = .followRequest
                var senderName = n.data.requesterUsername ?? ""
                if senderName.isEmpty || senderName.looksEncrypted {
                    if let rid = n.data.requesterId,
                       let conv = conversations.first(where: { $0.peer.userId == rid }) {
                        senderName = conv.peer.displayName
                    } else {
                        senderName = "Someone"
                    }
                }
                title = senderName

                var resolvedAvatar = n.data.requesterAvatar
                if (resolvedAvatar == nil || resolvedAvatar?.isEmpty == true),
                   let rid = n.data.requesterId,
                   let conv = conversations.first(where: { $0.peer.userId == rid }),
                   let peerAvatar = conv.peer.avatarPath, !peerAvatar.isEmpty {
                    resolvedAvatar = peerAvatar
                }
                avatarUrl = resolvedAvatar

                body = "wants to follow you"
                referenceId = n.data.requestId

            case "friend_request":
                notifType = .friendRequest
                // 🔴 ROUND 71 phase 3 — fall back to the peer cache
                // when the server-supplied requester_username is nil
                // (legacy rows pre-server-fix) or looks encrypted.
                // The ConversationStore peer entry typically has the
                // requester's display name + avatar from any prior
                // 1:1 chat, so this lights up most existing rows
                // that today render as "Someone" with no avatar.
                var senderName = n.data.requesterUsername ?? ""
                if senderName.isEmpty || senderName.looksEncrypted {
                    if let rid = n.data.requesterId,
                       let conv = conversations.first(where: { $0.peer.userId == rid }) {
                        senderName = conv.peer.displayName
                    } else {
                        senderName = "Someone"
                    }
                }
                title = senderName

                // Same fallback for the avatar: prefer the
                // server-supplied URL, otherwise reach into the
                // peer cache so the row paints with a real face.
                var resolvedAvatar = n.data.requesterAvatar
                if (resolvedAvatar == nil || resolvedAvatar?.isEmpty == true),
                   let rid = n.data.requesterId,
                   let conv = conversations.first(where: { $0.peer.userId == rid }),
                   let peerAvatar = conv.peer.avatarPath, !peerAvatar.isEmpty {
                    resolvedAvatar = peerAvatar
                }
                avatarUrl = resolvedAvatar

                body = "sent you a friend request"
                referenceId = n.data.requestId


            case "mention":
                notifType = .mention
                var senderName = n.data.mentionerUsername ?? n.data.authorUsername ?? n.data.commenterUsername ?? "someone"
                if senderName.looksEncrypted { senderName = "someone" }
                title = senderName
                
                var preview = n.data.postPreview ?? n.data.preview ?? "in a post"
                if preview.looksEncrypted { preview = "in a post" }
                body = "mentioned you: \(preview)"
                referenceId = n.data.postId
                avatarUrl = n.data.mentionerAvatar
                
            case "group_message":
                notifType = .groupMessage
                referenceId = n.data.roomId ?? n.data.groupId
                avatarUrl = n.data.senderAvatar

                var sender = n.data.senderUsername ?? "Someone"
                if sender.looksEncrypted {
                    if let senderId = n.data.senderId, let conv = conversations.first(where: { $0.peer.userId == senderId }) {
                        sender = conv.peer.displayName
                    } else {
                        sender = "Someone"
                    }
                }

                var group = n.data.groupName ?? "Group"
                if group.looksEncrypted {
                    if let roomId = referenceId, let conv = conversations.first(where: { $0.roomId == roomId }) {
                        group = conv.groupName ?? conv.displayTitle
                    } else {
                        group = "Group"
                    }
                }

                title = sender
                let rawPreview = n.data.preview ?? n.data.messagePreview ?? ""
                let safePreview = rawPreview.looksEncrypted ? "" : rawPreview
                let inner = formatMessagePreview(
                    messageType: n.data.messageType,
                    preview: safePreview
                )
                body = "in \(group): \(inner)"
                
            case "new_post":
                notifType = .newPost
                var senderName = n.data.authorUsername ?? "Someone"
                if senderName.looksEncrypted { senderName = "Someone" }
                title = "\(senderName) posted"
                
                var preview = n.data.postPreview ?? n.data.preview ?? "New post"
                if preview.looksEncrypted { preview = "New post" }
                body = preview
                referenceId = n.data.postId
                
            case "audio_room":
                notifType = .audioRoom
                var senderName = n.data.hostUsername ?? n.data.authorUsername ?? n.data.senderUsername ?? "Someone"
                if senderName.looksEncrypted { senderName = "Someone" }
                title = "\(senderName) started a room"
                body = n.data.roomTitle ?? n.data.preview ?? "Join the audio room"
                referenceId = n.data.roomId
                
            case "added_to_group":
                notifType = .groupMessage
                var adder = n.data.addedBy ?? n.data.senderUsername ?? "Someone"
                if adder.looksEncrypted { adder = "Someone" }

                var groupName = n.data.groupName ?? "a group"
                if groupName.looksEncrypted { groupName = "a group" }

                title = adder
                body = "added you to \(groupName)"
                referenceId = n.data.groupId ?? n.data.roomId
                avatarUrl = n.data.senderAvatar

            case "pinned_message":
                notifType = .groupMessage  // visually fits with thread events
                var actor = n.data.actorUsername ?? n.data.senderUsername ?? "Someone"
                if actor.looksEncrypted { actor = "Someone" }
                title = actor
                var preview = n.data.preview ?? n.data.messagePreview ?? "a message"
                if preview.looksEncrypted { preview = "a message" }
                if let group = n.data.groupName, !group.isEmpty, !group.looksEncrypted {
                    body = "pinned in \(group): \(preview)"
                } else {
                    body = "pinned a message: \(preview)"
                }
                referenceId = n.data.roomId ?? n.data.groupId
                avatarUrl = n.data.actorAvatar ?? n.data.senderAvatar

            case "poll_created":
                notifType = .groupMessage
                var actor = n.data.actorUsername ?? n.data.senderUsername ?? "Someone"
                if actor.looksEncrypted { actor = "Someone" }
                title = actor
                var question = n.data.preview ?? "a new poll"
                if question.looksEncrypted { question = "a new poll" }
                if let group = n.data.groupName, !group.isEmpty, !group.looksEncrypted {
                    body = "started a poll in \(group): \(question)"
                } else {
                    body = "started a poll: \(question)"
                }
                referenceId = n.data.roomId ?? n.data.groupId
                avatarUrl = n.data.actorAvatar ?? n.data.senderAvatar

            case "security_alert", "security":
                // Server-side security event (new sign-in, account
                // change, etc.). The server stores `preview` carrying a
                // human-readable summary; fall back to a short generic
                // when missing or encrypted.
                notifType = .securityAlert
                title = "RAVEN"
                var preview = n.data.preview ?? n.data.messagePreview ?? "New activity detected on your account"
                if preview.looksEncrypted { preview = "New activity detected on your account" }
                body = preview

            case "reaction":
                notifType = .reaction
                var actor = n.data.reactorUsername ?? n.data.senderUsername ?? "Someone"
                if actor.looksEncrypted { actor = "Someone" }
                title = actor
                let emoji = n.data.emoji?.trimmingCharacters(in: .whitespaces) ?? ""
                body = emoji.isEmpty
                    ? "reacted to your message"
                    : "reacted with \(emoji) to your message"
                referenceId = n.data.roomId
                avatarUrl = n.data.reactorAvatar ?? n.data.senderAvatar

            case "contact_shared":
                notifType = .contactShared
                var sharer = n.data.sharerUsername ?? n.data.senderUsername ?? "Someone"
                if sharer.looksEncrypted { sharer = "Someone" }
                title = sharer
                if let to = n.data.recipientUsername, !to.isEmpty, !to.looksEncrypted {
                    body = "shared your contact with \(to)"
                } else {
                    body = "shared your contact"
                }
                referenceId = n.data.roomId
                avatarUrl = n.data.sharerAvatar ?? n.data.senderAvatar

            case "profile_view":
                notifType = .profileView
                var viewer = n.data.viewerUsername ?? n.data.senderUsername ?? "Someone"
                if viewer.looksEncrypted { viewer = "Someone" }
                title = viewer
                body = "viewed your profile"
                referenceId = n.data.viewerId ?? n.data.senderId
                avatarUrl = n.data.viewerAvatar ?? n.data.senderAvatar

            case "screenshot_profile":
                notifType = .screenshotProfile
                var viewer = n.data.viewerUsername ?? n.data.senderUsername ?? "Someone"
                if viewer.looksEncrypted { viewer = "Someone" }
                title = viewer
                body = "took a screenshot of your profile"
                referenceId = n.data.viewerId ?? n.data.senderId
                avatarUrl = n.data.viewerAvatar ?? n.data.senderAvatar

            case "screenshot_chat":
                notifType = .screenshotChat
                var viewer = n.data.viewerUsername ?? n.data.senderUsername ?? "Someone"
                if viewer.looksEncrypted { viewer = "Someone" }
                title = viewer
                body = "took a screenshot of your chat"
                referenceId = n.data.roomId
                avatarUrl = n.data.viewerAvatar ?? n.data.senderAvatar

            case "live_location_started":
                notifType = .liveLocationStarted
                var sharer = n.data.senderUsername ?? n.data.sharerUsername ?? "Someone"
                if sharer.looksEncrypted { sharer = "Someone" }
                title = sharer
                body = "started sharing live location"
                referenceId = n.data.roomId
                avatarUrl = n.data.senderAvatar ?? n.data.sharerAvatar

            case "live_location_ended":
                notifType = .liveLocationEnded
                var sharer = n.data.senderUsername ?? n.data.sharerUsername ?? "Someone"
                if sharer.looksEncrypted { sharer = "Someone" }
                title = sharer
                body = "stopped sharing live location"
                referenceId = n.data.roomId
                avatarUrl = n.data.senderAvatar ?? n.data.sharerAvatar

            default:
                notifType = .security
                title = "RAVEN"
                // Prettify raw type: "app_update" → "App update"
                body = n.type.replacingOccurrences(of: "_", with: " ").capitalized
            }
            
            // ═══════════════════════════════════════════════════════════
            // FALLBACK: Client-side avatar lookup from ConversationStore
            // Old notifications in the DB won't have avatar fields.
            // Resolve from cached conversations using sender/liker IDs.
            // ═══════════════════════════════════════════════════════════
            if avatarUrl == nil {
                let lookupId = n.data.senderId ?? n.data.likerId ?? n.data.commenterId ?? n.data.requesterId ?? n.data.mentionerId ?? n.data.hostId
                if let uid = lookupId {
                    // Check ConversationStore for avatar
                    if let conv = conversations.first(where: { $0.peer.userId == uid }) {
                        avatarUrl = conv.peer.avatarPath
                    }
                }
            }
            
            return LocalNotification(
                id: n.id,
                type: notifType,
                title: title,
                body: body,
                avatarUrl: avatarUrl,
                referenceId: referenceId,
                createdAt: n.timestamp,
                isRead: n.isRead
            )
        }
        
        // FIX: Cache successful server response for offline use
        cacheNotifications(mapped)

        return mapped
    }

    /// Build a verb-shaped, type-aware row body for `message` /
    /// `group_message` notifications. Goal: never render a row that
    /// only shows the sender name with no context — the user reported
    /// seeing exactly that for voice / photo / media messages because
    /// the previous code dumped the raw server preview into the body
    /// (and for some media types the server-side preview was empty).
    ///
    /// `messageType` is the wire string the server stores alongside
    /// each notification ("text", "voice", "image", "video",
    /// "video_note", "location", "file", "post_share",
    /// "contact_card", "snap"). `preview` is whatever the server
    /// already prepared — used as-is for text and as the caption for
    /// media. Both can be nil/empty.
    fileprivate func formatMessagePreview(messageType: String?, preview: String?) -> String {
        let trimmed = preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasPreview = !trimmed.isEmpty
        switch (messageType ?? "text").lowercased() {
        case "text":
            return hasPreview ? trimmed : "sent you a message"
        case "image", "photo":
            return hasPreview ? "sent a 📷 photo: \(trimmed)" : "sent a 📷 photo"
        case "video":
            return hasPreview ? "sent a 🎬 video: \(trimmed)" : "sent a 🎬 video"
        case "video_note", "videonote":
            return "sent a 🎥 video note"
        case "voice", "audio":
            return "sent a 🎤 voice message"
        case "file", "document":
            return "sent a 📎 file"
        case "location":
            return "shared a 📍 location"
        case "post_share", "postshare":
            return "shared a 📬 post"
        case "contact_card", "contactcard":
            return "shared a 👤 contact"
        case "ephemeral_photo", "ephemeralphoto", "snap":
            return "sent a 📸 snap"
        case "poll":
            return hasPreview ? "started a 📊 poll: \(trimmed)" : "started a 📊 poll"
        default:
            return hasPreview ? trimmed : "sent you a message"
        }
    }

    func markAsRead(id: String) async throws {
        await PendingReadService.shared.enqueue(type: "notification", targetId: id, isAll: false)
    }
    
    func markAsUnread(id: String) async throws {
        struct EmptyBody: Encodable {}
        let _: Empty = try await networkService.post(path: "/api/notifications/\(id)/unread", body: EmptyBody())
    }
    
    func markAllAsRead() async throws {
        await PendingReadService.shared.enqueue(type: "notification", targetId: nil, isAll: true)
    }
    
    /// Direct server call — awaits the POST so the server state is updated
    /// before any subsequent fetch. Use this from UI actions where you need
    /// the next fetch to reflect read state immediately.
    func markAllAsReadDirect() async throws {
        struct EmptyBody: Encodable {}
        let _: Empty = try await networkService.post(
            path: "/api/notifications/read-all",
            body: EmptyBody()
        )
    }
    
    func deleteNotification(id: String) async throws {
        try await networkService.delete(path: "/api/notifications/\(id)")
    }
    
    func clearAllNotifications() async throws {
        try await networkService.delete(path: "/api/notifications")
    }
}

// MARK: - Notification Reply Sheet
/// Liquid Glass styled reply composer for Activity Center notifications
struct NotificationReplySheet: View {
    let notification: LocalNotification
    let onSend: (String) async -> Void
    let onDismiss: () -> Void
    
    @State private var replyText = ""
    @State private var isSending = false
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Context card — shows what you're replying to
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        // Avatar (matches redesigned NotificationCard)
                        GlassAvatar(
                            name: notification.title,
                            path: notification.avatarUrl,
                            size: 40,
                            showGlow: false
                        )
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(notification.title)
                                .font(.subheadline.weight(.semibold))
                            Text(notification.body)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        
                        Spacer()
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                        )
                )
                
                // Text input
                HStack(spacing: 12) {
                    TextField("Type a reply...", text: $replyText, axis: .vertical)
                        .focused($isTextFieldFocused)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                                )
                        )
                    
                    // Send button
                    Button {
                        Task {
                            isSending = true
                            await onSend(replyText)
                            isSending = false
                            onDismiss()
                        }
                    } label: {
                        Group {
                            if isSending {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 32))
                            }
                        }
                        .foregroundStyle(canSend ? .blue : .gray.opacity(0.5))
                    }
                    .disabled(!canSend || isSending)
                }
                
                Spacer()
            }
            .padding(20)
            .navigationTitle("Reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onDismiss()
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            isTextFieldFocused = true
        }
    }
    
    private var canSend: Bool {
        !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Preview
#Preview {
    NavigationStack {
        NotificationsListView()
    }
}
