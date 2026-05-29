import SwiftUI

// MARK: - Bell Subscription Model
struct BellSubscription: Codable {
    let subscribed: Bool
    let notifyPosts: Bool
    let notifyAudioRooms: Bool
    
    enum CodingKeys: String, CodingKey {
        case subscribed
        case notifyPosts = "notify_posts"
        case notifyAudioRooms = "notify_audio_rooms"
    }
}

struct BellSubscriptionUpdate: Encodable {
    let notifyPosts: Bool
    let notifyAudioRooms: Bool
    
    enum CodingKeys: String, CodingKey {
        case notifyPosts = "notify_posts"
        case notifyAudioRooms = "notify_audio_rooms"
    }
}

// MARK: - Profile Bell Settings Sheet
struct ProfileBellSettingsSheet: View {
    let userId: String
    let displayName: String
    let avatarUrl: String?
    let onDismiss: () -> Void
    
    @State private var notifyPosts = false
    @State private var notifyAudioRooms = false
    @State private var isLoading = true
    @State private var isSyncing = false
    @State private var syncTask: Task<Void, Never>?
    @State private var showSuccess = false
    
    @Environment(\.dismiss) private var dismiss
    
    var isSubscribed: Bool {
        notifyPosts || notifyAudioRooms
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // User Header
                    userHeader
                    
                    if isLoading {
                        ProgressView()
                            .padding(.top, 32)
                    } else {
                        // Notification Toggles
                        togglesSection
                        
                        // Quick Actions
                        quickActions
                        
                        // Info text
                        infoText
                    }
                }
                .padding(16)
            }
            .background(Color(.systemBackground))
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        Haptics.light()
                        dismiss()
                        onDismiss()
                    }
                    .font(.system(size: 16, weight: .semibold))
                }
            }
            .task {
                await loadSubscription()
            }
            .overlay(alignment: .bottom) {
                if showSuccess {
                    Text("Settings saved ✓")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.green, in: Capsule())
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 20)
                }
            }
            .animation(.spring(response: 0.3), value: showSuccess)
        }
    }
    
    // MARK: - User Header
    private var userHeader: some View {
        HStack(spacing: 14) {
            GlassAvatar(
                name: displayName,
                path: avatarUrl,
                size: 52,
                showGlow: false
            )
            
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.system(size: 18, weight: .bold))
                    .lineLimit(1)
                
                HStack(spacing: 4) {
                    Image(systemName: isSubscribed ? "bell.fill" : "bell.slash")
                        .font(.system(size: 11))
                    Text(isSubscribed ? "Notifications on" : "Notifications off")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(isSubscribed ? .yellow : .secondary)
            }
            
            Spacer()
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.6)
        )
    }
    
    // MARK: - Toggles Section
    private var togglesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NOTIFY ME ABOUT")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            
            VStack(spacing: 1) {
                // Posts toggle
                bellToggleRow(
                    title: "Posts",
                    subtitle: "When \(displayName) creates a new post",
                    icon: "square.and.pencil",
                    iconColor: .blue,
                    isOn: $notifyPosts
                )
                
                // Audio Rooms toggle
                bellToggleRow(
                    title: "Audio Rooms",
                    subtitle: "When \(displayName) starts an audio room",
                    icon: "waveform",
                    iconColor: .purple,
                    isOn: $notifyAudioRooms
                )
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.6)
            )
        }
    }
    
    // MARK: - Toggle Row
    private func bellToggleRow(
        title: String,
        subtitle: String,
        icon: String,
        iconColor: Color,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 14) {
            Circle()
                .fill(iconColor.opacity(0.15))
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(iconColor)
                )
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            
            Spacer()
            
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.accentColor)
        }
        .padding(14)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.selection()
            isOn.wrappedValue.toggle()
        }
        .onChange(of: isOn.wrappedValue) { _, _ in
            syncToServer()
        }
    }
    
    // MARK: - Quick Actions
    private var quickActions: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.light()
                withAnimation(.spring(response: 0.3)) {
                    notifyPosts = true
                    notifyAudioRooms = true
                }
                syncToServer()
            } label: {
                Label("Turn On All", systemImage: "bell.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            
            Button {
                Haptics.light()
                withAnimation(.spring(response: 0.3)) {
                    notifyPosts = false
                    notifyAudioRooms = false
                }
                syncToServer()
            } label: {
                Label("Turn Off All", systemImage: "bell.slash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }
    
    // MARK: - Info Text
    private var infoText: some View {
        Text("You'll receive push notifications for the selected activities from \(displayName). These settings only apply to this user.")
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
            .padding(.top, 4)
    }
    
    // MARK: - Network
    private func loadSubscription() async {
        isLoading = true
        do {
            let sub: BellSubscription = try await NetworkService.shared.get(
                path: "/api/notifications/subscriptions/\(userId)"
            )
            await MainActor.run {
                notifyPosts = sub.notifyPosts
                notifyAudioRooms = sub.notifyAudioRooms
                isLoading = false
            }
        } catch {
            #if DEBUG
            print("⚠️ Failed to load bell subscription: \(error)")
            #endif
            await MainActor.run { isLoading = false }
        }
    }
    
    /// Debounced sync to server (300ms)
    private func syncToServer() {
        syncTask?.cancel()
        
        syncTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            
            isSyncing = true
            defer { isSyncing = false }
            
            let update = BellSubscriptionUpdate(
                notifyPosts: notifyPosts,
                notifyAudioRooms: notifyAudioRooms
            )
            
            do {
                if !notifyPosts && !notifyAudioRooms {
                    // Delete subscription entirely when all toggles are off
                    try await NetworkService.shared.delete(
                        path: "/api/notifications/subscriptions/\(userId)"
                    )
                } else {
                    let _: BellSubscription = try await NetworkService.shared.post(
                        path: "/api/notifications/subscriptions/\(userId)",
                        body: update
                    )
                }
                
                // Show brief success indicator
                await MainActor.run {
                    showSuccess = true
                    Haptics.success()
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run { showSuccess = false }
                
                #if DEBUG
                print("✅ Bell subscription synced: posts=\(notifyPosts) audio=\(notifyAudioRooms)")
                #endif
            } catch {
                #if DEBUG
                print("⚠️ Failed to sync bell subscription: \(error)")
                #endif
                Haptics.error()
            }
        }
    }
}
