import SwiftUI
import UserNotifications

// MARK: - Notifications Settings View
struct NotificationsSettingsView: View {
    @AppStorage("pushNotifications") private var pushNotifications = true
    @AppStorage("messageNotifications") private var messageNotifications = true
    @AppStorage("friendRequestNotifications") private var friendRequestNotifications = true
    @AppStorage("likesCommentsNotifications") private var likesCommentsNotifications = true
    @AppStorage("soundsEnabled") private var soundsEnabled = true
    @AppStorage("vibrationEnabled") private var vibrationEnabled = true
    @AppStorage("messagePreview") private var messagePreview = true
    
    @State private var systemNotificationsEnabled = true
    @State private var isSyncing = false
    @State private var syncTask: Task<Void, Never>?
    
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // System Notification Warning
                if !systemNotificationsEnabled {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Notifications Disabled")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Enable in Settings to receive notifications")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    }
                    .padding(14)
                    .background(.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                
                // Main Notifications
                SettingsSection(title: "Notifications") {
                    SettingsToggleRow(
                        title: "Push Notifications",
                        icon: "bell.badge.fill",
                        iconColor: .purple,
                        isOn: $pushNotifications
                    )
                    .onChange(of: pushNotifications) { _, newValue in
                        handlePushToggle(enabled: newValue)
                    }
                    
                    SettingsToggleRow(
                        title: "Message Notifications",
                        icon: "message.fill",
                        iconColor: .blue,
                        isOn: $messageNotifications
                    )
                    .onChange(of: messageNotifications) { _, _ in
                        syncPreferencesToServer()
                    }
                    
                    SettingsToggleRow(
                        title: "Friend Requests",
                        icon: "person.badge.plus",
                        iconColor: .green,
                        isOn: $friendRequestNotifications
                    )
                    .onChange(of: friendRequestNotifications) { _, _ in
                        syncPreferencesToServer()
                    }
                    
                    SettingsToggleRow(
                        title: "Likes & Comments",
                        icon: "heart.fill",
                        iconColor: .pink,
                        isOn: $likesCommentsNotifications
                    )
                    .onChange(of: likesCommentsNotifications) { _, _ in
                        syncPreferencesToServer()
                    }
                }
                
                // Sound & Vibration
                SettingsSection(title: "Alerts") {
                    SettingsToggleRow(
                        title: "Sounds",
                        icon: "speaker.wave.2.fill",
                        iconColor: .orange,
                        isOn: $soundsEnabled
                    )
                    .onChange(of: soundsEnabled) { _, _ in
                        syncPreferencesToServer()
                    }
                    
                    SettingsToggleRow(
                        title: "Vibration",
                        icon: "iphone.radiowaves.left.and.right",
                        iconColor: .cyan,
                        isOn: $vibrationEnabled
                    )
                    // Vibration is already handled by Haptics class reading this value
                }
                
                // Preview
                SettingsSection(title: "Content") {
                    SettingsToggleRow(
                        title: "Show Message Preview",
                        subtitle: "Display message content in notifications",
                        icon: "eye.fill",
                        iconColor: .indigo,
                        isOn: $messagePreview
                    )
                    .onChange(of: messagePreview) { _, _ in
                        syncPreferencesToServer()
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemBackground))
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            checkSystemNotificationStatus()
        }
    }
    
    /// Check if notifications are enabled at the system level
    private func checkSystemNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                systemNotificationsEnabled = settings.authorizationStatus == .authorized
            }
        }
    }
    
    /// Handle push notifications toggle
    private func handlePushToggle(enabled: Bool) {
        if enabled {
            // Request permission and register
            Task {
                let granted = await PushNotificationService.shared.requestAuthorization()
                if !granted {
                    await MainActor.run {
                        pushNotifications = false
                        Haptics.error()
                    }
                } else {
                    syncPreferencesToServer()
                }
            }
        } else {
            // Sync disabled state to server
            syncPreferencesToServer()
        }
    }
    
    /// Sync notification preferences to server (debounced)
    private func syncPreferencesToServer() {
        // Cancel any pending sync to coalesce rapid changes
        syncTask?.cancel()
        
        syncTask = Task {
            // Debounce: wait 300ms for more changes
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            
            isSyncing = true
            defer { isSyncing = false }
            
            let payload = NotificationPreferencesPayload(
                pushEnabled: pushNotifications,
                messagesEnabled: messageNotifications,
                friendRequestsEnabled: friendRequestNotifications,
                likesCommentsEnabled: likesCommentsNotifications,
                soundsEnabled: soundsEnabled,
                messagePreview: messagePreview
            )
            
            do {
                let _: EmptyNotificationResponse = try await NetworkService.shared.patch(
                    path: "/api/users/notification-preferences",
                    body: payload
                )
                #if DEBUG
                print("✅ Notification preferences synced to server")
                #endif
            } catch {
                #if DEBUG
                print("⚠️ Failed to sync notification preferences: \(error)")
                #endif
            }
        }
    }
}

// MARK: - Notification Preferences Payload
private struct NotificationPreferencesPayload: Encodable {
    let pushEnabled: Bool
    let messagesEnabled: Bool
    let friendRequestsEnabled: Bool
    let likesCommentsEnabled: Bool
    let soundsEnabled: Bool
    let messagePreview: Bool
    
    enum CodingKeys: String, CodingKey {
        case pushEnabled = "push_enabled"
        case messagesEnabled = "messages_enabled"
        case friendRequestsEnabled = "friend_requests_enabled"
        case likesCommentsEnabled = "likes_comments_enabled"
        case soundsEnabled = "sounds_enabled"
        case messagePreview = "message_preview"
    }
}

private struct EmptyNotificationResponse: Decodable {}

// MARK: - Settings Section
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            
            VStack(spacing: 1) {
                content
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.6)
            )
        }
    }
}

// MARK: - Settings Toggle Row
struct SettingsToggleRow: View {
    let title: String
    var subtitle: String? = nil
    let icon: String
    let iconColor: Color
    @Binding var isOn: Bool
    
    var body: some View {
        HStack(spacing: 14) {
            // Icon
            Circle()
                .fill(iconColor.opacity(0.15))
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(iconColor)
                )
            
            // Text
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            // Toggle
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.accentColor)
        }
        .padding(14)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.selection()
            isOn.toggle()
        }
    }
}

// MARK: - Preview
#Preview {
    NavigationStack {
        NotificationsSettingsView()
    }
}
