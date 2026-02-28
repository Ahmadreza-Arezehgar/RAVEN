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
            // Auto-mark as read on server when user views the notification center
            if NetworkMonitor.shared.isOnline && notifications.contains(where: { !$0.isRead }) {
                await markAllAsRead()
            }
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
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 120, height: 14)
                    
                    RoundedRectangle(cornerRadius: 4)
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
                    RoundedRectangle(cornerRadius: 24)
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
            ForEach(groupedNotifications.keys.sorted(by: >), id: \.self) { date in
                Section {
                    ForEach(groupedNotifications[date] ?? []) { notification in
                        NotificationCard(
                            notification: notification,
                            onAccept: notification.type == .friendRequest ? {
                                acceptFriendRequest(notification)
                            } : nil,
                            onDecline: notification.type == .friendRequest ? {
                                declineFriendRequest(notification)
                            } : nil
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
    
    // MARK: - Grouped Notifications
    private var groupedNotifications: [Date: [LocalNotification]] {
        Dictionary(grouping: filteredNotifications) { notification in
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
            return notifications.filter { $0.type == .friendRequest }
        case .activity:
            return notifications.filter { $0.type == .like || $0.type == .comment || $0.type == .groupMessage }
        }
    }
    
    // MARK: - Count for Filter
    private func countFor(_ filter: NotificationFilter) -> Int {
        switch filter {
        case .all:
            return notifications.count
        case .unread:
            return notifications.filter { !$0.isRead }.count
        case .friends:
            return notifications.filter { $0.type == .friendRequest }.count
        case .activity:
            return notifications.filter { $0.type == .like || $0.type == .comment || $0.type == .groupMessage }.count
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
        case .friendRequest:
            DeepLinkRouter.shared.navigate(to: .friendRequests)
        case .like, .comment:
            // referenceId is a postId, not a userId — don't navigate to profile
            break
        case .security:
            DeepLinkRouter.shared.navigate(to: .security)
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
                notifications[index].isRead = true
                LocalNotificationService.shared.cacheNotifications(notifications)
            }
        } catch {
            #if DEBUG
            print("Failed to mark as read: \(error)")
            #endif
        }
    }
    
    // MARK: - Mark All as Read
    private func markAllAsRead() async {
        // 1. Optimistic UI update immediately
        for i in notifications.indices {
            notifications[i].isRead = true
        }
        LocalNotificationService.shared.cacheNotifications(notifications)
        NotificationPipeline.shared.unreadCount = 0
        
        // 2. Sync to server (awaited so subsequent fetches get updated data)
        do {
            try await LocalNotificationService.shared.markAllAsReadDirect()
        } catch {
            #if DEBUG
            print("❌ Failed to mark all as read on server: \(error)")
            #endif
        }
    }
    
    // MARK: - Delete Notification
    private func deleteNotification(_ notification: LocalNotification) {
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
        Task { @MainActor in
            NotificationPipeline.shared.unreadCount = 0
        }
        
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            notifications.removeAll()
            LocalNotificationService.shared.cacheNotifications(notifications)
        }
        
        Task {
            try? await LocalNotificationService.shared.clearAllNotifications()
        }
    }
    
    // MARK: - Friend Request Actions
    private func acceptFriendRequest(_ notification: LocalNotification) {
        guard let requestId = notification.referenceId else { return }
        
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
                    path: "/api/users/friend-request/\(requestId)/accept",
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
                print("❌ Accept friend request failed: \(error)")
                #endif
            }
        }
    }
    
    private func declineFriendRequest(_ notification: LocalNotification) {
        guard let requestId = notification.referenceId else { return }
        
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
                    path: "/api/users/friend-request/\(requestId)/decline",
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
                print("❌ Decline friend request failed: \(error)")
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
            // Mark as read
            Task {
                await markAsRead(notification.id)
                await MainActor.run {
                    if NotificationPipeline.shared.unreadCount > 0 {
                        NotificationPipeline.shared.unreadCount -= 1
                    }
                }
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

// MARK: - Notification Card (Liquid Glass Capsule)
struct NotificationCard: View {
    let notification: LocalNotification
    var onAccept: (() -> Void)? = nil
    var onDecline: (() -> Void)? = nil
    
    var body: some View {
        HStack(spacing: 14) {
            // Avatar with glow
            ZStack {
                // Glow ring for unread
                if !notification.isRead {
                    Circle()
                        .stroke(notification.type.color.opacity(0.4), lineWidth: 2)
                        .frame(width: 54, height: 54)
                        .blur(radius: 3)
                }
                
                // Avatar
                if let avatarUrl = notification.avatarUrl,
                   let url = constructAvatarURL(avatarUrl) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        default:
                            iconBackground
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())
                } else {
                    iconBackground
                }
                
                // Type badge
                ZStack {
                    Circle()
                        .fill(notification.type.color)
                        .frame(width: 20, height: 20)
                    
                    Image(systemName: notification.type.icon)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
                .offset(x: 18, y: 18)
            }
            .frame(width: 54, height: 54)
            
            // Content
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(notification.title)
                        .font(.subheadline.weight(notification.isRead ? .medium : .bold))
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Text(notification.createdAt.timeAgoShort())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                
                Text(notification.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            
            // Friend Request Actions
            if notification.type == .friendRequest {
                HStack(spacing: 8) {
                    Button {
                        Haptics.success()
                        onAccept?()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(
                                Circle()
                                    .fill(Color.green.gradient)
                                    .shadow(color: .green.opacity(0.3), radius: 4, y: 2)
                            )
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        Haptics.light()
                        onDecline?()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .background(
                                Circle()
                                    .fill(.ultraThinMaterial)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .stroke(
                            notification.isRead ? Color.white.opacity(0.08) : notification.type.color.opacity(0.3),
                            lineWidth: notification.isRead ? 0.5 : 1
                        )
                )
                .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
        }
        .contentShape(Capsule())
    }
    
    private var iconBackground: some View {
        ZStack {
            Circle()
                .fill(notification.type.color.opacity(0.15))
                .frame(width: 48, height: 48)
            
            Image(systemName: notification.type.icon)
                .font(.system(size: 20))
                .foregroundStyle(notification.type.color)
        }
    }
    
    private func constructAvatarURL(_ path: String) -> URL? {
        return AppConfig.mediaURL(from: path)
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
        case like
        case comment
        case security
        
        var icon: String {
            switch self {
            case .message: return "message.fill"
            case .groupMessage: return "person.3.fill"
            case .friendRequest: return "person.badge.plus"
            case .like: return "heart.fill"
            case .comment: return "bubble.left.fill"
            case .security: return "shield.fill"
            }
        }
        
        var color: Color {
            switch self {
            case .message: return .blue
            case .groupMessage: return .indigo
            case .friendRequest: return .purple
            case .like: return .pink
            case .comment: return .green
            case .security: return .orange
            }
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
                let commentId: String?
                let commenterId: String?
                let commenterUsername: String?
                let preview: String?
                let requestId: String?
                let requesterId: String?
                let requesterUsername: String?
                let requesterAvatar: String?
                let roomId: String?
                let senderId: String?
                let senderUsername: String?
                let messagePreview: String?
                let groupId: String?
                let groupName: String?
                
                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: FlexibleCodingKeys.self)
                    
                    func flexKey(_ key: String) -> FlexibleCodingKeys {
                        FlexibleCodingKeys(stringValue: key) ?? FlexibleCodingKeys(key)
                    }
                    
                    postId = try? container.decode(String.self, forKey: flexKey("postId"))
                    likerId = try? container.decode(String.self, forKey: flexKey("likerId"))
                    likerUsername = try? container.decode(String.self, forKey: flexKey("likerUsername"))
                    commentId = try? container.decode(String.self, forKey: flexKey("commentId"))
                    commenterId = try? container.decode(String.self, forKey: flexKey("commenterId"))
                    commenterUsername = try? container.decode(String.self, forKey: flexKey("commenterUsername"))
                    preview = try? container.decode(String.self, forKey: flexKey("preview"))
                    requestId = try? container.decode(String.self, forKey: flexKey("requestId"))
                    requesterId = try? container.decode(String.self, forKey: flexKey("requesterId"))
                    requesterUsername = try? container.decode(String.self, forKey: flexKey("requesterUsername"))
                    requesterAvatar = try? container.decode(String.self, forKey: flexKey("requesterAvatar"))
                    roomId = try? container.decode(String.self, forKey: flexKey("roomId"))
                    senderId = try? container.decode(String.self, forKey: flexKey("senderId"))
                    senderUsername = try? container.decode(String.self, forKey: flexKey("senderUsername"))
                    messagePreview = try? container.decode(String.self, forKey: flexKey("messagePreview"))
                    groupId = try? container.decode(String.self, forKey: flexKey("groupId"))
                    groupName = try? container.decode(String.self, forKey: flexKey("groupName"))
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
                
                var senderName = n.data.senderUsername ?? "New message"
                if senderName.looksEncrypted || senderName.isEmpty {
                    if let roomId = referenceId, let conv = conversations.first(where: { $0.roomId == roomId }) {
                        senderName = conv.isGroup ? (conv.groupName ?? conv.peer.displayName) : conv.peer.displayName
                    } else {
                        senderName = "New message"
                    }
                }
                title = senderName
                
                var preview = n.data.messagePreview ?? n.data.preview ?? "Sent you a message"
                if preview.looksEncrypted { preview = "Secure message" }
                body = preview
                
            case "like":
                notifType = .like
                var senderName = n.data.likerUsername ?? "Someone"
                if senderName.looksEncrypted { senderName = "Someone" }
                title = senderName
                body = "liked your post ❤️"
                referenceId = n.data.postId
                
            case "comment":
                notifType = .comment
                var senderName = n.data.commenterUsername ?? "Someone"
                if senderName.looksEncrypted { senderName = "Someone" }
                title = senderName
                
                var preview = n.data.preview ?? "..."
                if preview.looksEncrypted { preview = "Secure comment" }
                body = "commented: \(preview)"
                referenceId = n.data.postId
                
            case "friend_request":
                notifType = .friendRequest
                var senderName = n.data.requesterUsername ?? "Someone"
                if senderName.looksEncrypted { senderName = "Someone" }
                title = senderName
                body = "sent you a friend request"
                avatarUrl = n.data.requesterAvatar
                referenceId = n.data.requestId
                
            case "mention":
                notifType = .comment
                var senderName = n.data.commenterUsername ?? "someone"
                if senderName.looksEncrypted { senderName = "someone" }
                title = "Mentioned by \(senderName)"
                
                var preview = n.data.preview ?? "in a comment"
                if preview.looksEncrypted { preview = "in a secure comment" }
                body = preview
                referenceId = n.data.postId
                
            case "group_message":
                notifType = .groupMessage
                referenceId = n.data.roomId ?? n.data.groupId
                
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
                
                title = "\(sender) in \(group)"
                var preview = n.data.preview ?? n.data.messagePreview ?? "Sent a message"
                if preview.looksEncrypted { preview = "Sent a secure message" }
                body = preview
                
            default:
                notifType = .security
                title = "Notification"
                body = n.type
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
                        // Avatar
                        ZStack {
                            Circle()
                                .fill(notification.type.color.opacity(0.15))
                                .frame(width: 40, height: 40)
                            
                            Image(systemName: notification.type.icon)
                                .font(.system(size: 16))
                                .foregroundStyle(notification.type.color)
                        }
                        
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
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
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
                            RoundedRectangle(cornerRadius: 20)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20)
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
