// RAVEN - Notifications View
// Converted from Flutter notifications_page.dart

import SwiftUI

struct NotificationsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab = 0
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab selector
                HStack(spacing: 0) {
                    tabButton("All", index: 0)
                    tabButton("Mentions", index: 1)
                    tabButton("Requests", index: 2)
                }
                .padding()
                
                TabView(selection: $selectedTab) {
                    notificationList(filter: nil).tag(0)
                    notificationList(filter: .mention).tag(1)
                    notificationList(filter: .follow).tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .navigationTitle("Notifications")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        markAllRead()
                    } label: {
                        Image(systemName: "checkmark.circle")
                    }
                }
            }
            .onAppear {
                Task {
                    await appState.loadNotifications()
                }
            }
        }
    }
    
    @ViewBuilder
    func tabButton(_ title: String, index: Int) -> some View {
        Button {
            withAnimation { selectedTab = index }
        } label: {
            Text(title)
                .font(.subheadline)
                .fontWeight(selectedTab == index ? .semibold : .regular)
                .foregroundColor(selectedTab == index ? .primary : .secondary)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(
                    selectedTab == index ? Color.ravenPrimary.opacity(0.2) : Color.clear
                )
                .cornerRadius(8)
        }
    }
    
    @ViewBuilder
    func notificationList(filter: RAVENNotification.NotificationType?) -> some View {
        let notifications = filter == nil ? appState.notifications : appState.notifications.filter { $0.type == filter }
        
        if notifications.isEmpty {
            ContentUnavailableView(
                "No Notifications",
                systemImage: "bell.slash",
                description: Text("You're all caught up!")
            )
        } else {
            List {
                ForEach(notifications) { notification in
                    NotificationRow(notification: notification)
                        .listRowBackground(notification.isRead ? Color.clear : Color.ravenPrimary.opacity(0.05))
                }
            }
            .listStyle(.plain)
            .refreshable {
                await appState.loadNotifications()
            }
        }
    }
    
    func markAllRead() {
        // Mark all as read
    }
}

// MARK: - Notification Row
struct NotificationRow: View {
    let notification: RAVENNotification
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Icon
            ZStack {
                Circle()
                    .fill(notificationColor(notification.type).opacity(0.2))
                    .frame(width: 40, height: 40)
                
                Image(systemName: notification.type.icon)
                    .foregroundColor(notificationColor(notification.type))
            }
            
            // Content
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(notification.title)
                        .font(.subheadline.bold())
                    
                    Spacer()
                    
                    Text(notification.timestamp.timeAgo)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Text(notification.body)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                
                // Action buttons for follow requests
                if notification.type == .follow && !notification.isRead {
                    HStack(spacing: 12) {
                        Button("Accept") {
                            // Accept
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.ravenPrimary)
                        .controlSize(.small)
                        
                        Button("Decline") {
                            // Decline
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    func notificationColor(_ type: RAVENNotification.NotificationType) -> Color {
        switch type {
        case .like: return .red
        case .comment: return .blue
        case .follow: return .green
        case .message: return .purple
        case .mention: return .orange
        case .repost: return .teal
        case .system: return .gray
        }
    }
}

#Preview {
    NotificationsView()
        .environmentObject(AppState())
        .preferredColorScheme(.dark)
}
