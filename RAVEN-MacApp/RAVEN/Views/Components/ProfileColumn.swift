// ProfileColumn — middle pane on the Profile tab.
//
// Header card with the user's avatar + handle, then a stack of action
// rows (Edit profile, Settings, Linked devices, Sign out). Settings and
// edit-profile screens are stubbed for the App Store MVP — they navigate
// to placeholder sheets that we'll fill in as endpoints come online.

import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ProfileColumn: View {
    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var router: ShellRouter

    @State private var showEditProfile = false
    @State private var showSettings = false
    @State private var showLinkedDevices = false
    @State private var showFriendRequests = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Profile")
                    .font(.system(size: 22, weight: .heavy))
                    .padding(.horizontal, 20)
                    .padding(.top, 18)

                if let user = auth.currentUser {
                    VStack(spacing: 16) {
                        HStack(spacing: 16) {
                            // Bigger avatar with a soft glow and a green
                            // self-presence dot — confirms the user that
                            // their own status is "online" to others.
                            AvatarView(
                                letter: user.initials,
                                size: 72,
                                urlString: user.avatarPath,
                                showOnlineIndicator: true
                            )
                            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(displayName(user))
                                        .font(.system(size: 22, weight: .heavy))
                                    if user.isVerified == true {
                                        Image(systemName: "checkmark.seal.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(Color.blue)
                                    }
                                    if user.isPremium == true {
                                        Image(systemName: "crown.fill")
                                            .font(.system(size: 14))
                                            .foregroundStyle(Color.orange)
                                    }
                                }
                                Text("@\(user.username)")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                                if let bio = user.bio, !bio.isEmpty {
                                    Text(bio)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.primary.opacity(0.8))
                                        .padding(.top, 2)
                                }
                            }
                            Spacer()
                        }

                        // Stats row — capsule pills matching the iOS
                        // Account tab. Numbers are placeholders until
                        // the Mac app wires up follower/friend counts;
                        // the layout reflects the iOS design language.
                        HStack(spacing: 10) {
                            StatPill(label: "Posts", value: user.postCount ?? 0)
                            StatPill(label: "Friends", value: user.friendCount ?? 0)
                            StatPill(label: "Following", value: user.followingCount ?? 0)
                        }
                    }
                    .padding(20)
                    .background(
                        LinearGradient.ravenLogo.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    )
                    .padding(.horizontal, 20)
                }

                ProfileTile(icon: "pencil", title: "Edit profile") {
                    showEditProfile = true
                }
                ProfileTile(icon: "gearshape", title: "Settings") {
                    showSettings = true
                }
                ProfileTile(icon: "person.crop.circle.badge.plus", title: "Friend requests") {
                    showFriendRequests = true
                }
                ProfileTile(icon: "qrcode.viewfinder", title: "Linked devices") {
                    showLinkedDevices = true
                }
                ProfileTile(icon: "rectangle.portrait.and.arrow.right",
                            title: "Sign out", color: .red) {
                    auth.signOut()
                }

                Spacer()
            }
            .padding(.bottom, 32)
        }
        .sheet(isPresented: $showEditProfile) {
            EditProfileSheet().environmentObject(auth)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet().environmentObject(auth)
        }
        .sheet(isPresented: $showLinkedDevices) {
            LinkedDevicesSheet().environmentObject(auth)
        }
        .sheet(isPresented: $showFriendRequests) {
            FriendRequestsSheet()
                .environmentObject(auth)
                .environmentObject(router)
        }
    }
}

// MARK: - Edit profile sheet

private struct EditProfileSheet: View {
    @EnvironmentObject var auth: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var bio = ""
    @State private var saving = false
    @State private var uploadingAvatar = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Edit profile").font(.title3.weight(.bold))
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
            }

            // Avatar with tap-to-change. Uses NSOpenPanel for the file
            // picker (sandboxed apps still get user-controlled access for
            // panel-selected files via a temporary entitlement scope).
            Button(action: { Task { await pickAndUploadAvatar() } }) {
                ZStack(alignment: .bottomTrailing) {
                    AvatarView(
                        letter: auth.currentUser?.initials ?? "?",
                        size: 80,
                        urlString: auth.currentUser?.avatarPath
                    )
                    ZStack {
                        Circle().fill(Color.black.opacity(0.7)).frame(width: 28, height: 28)
                        Image(systemName: uploadingAvatar ? "ellipsis" : "camera.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                }
            }
            .buttonStyle(.plain)
            .disabled(uploadingAvatar)

            TextField("Display name", text: $displayName).textFieldStyle(.roundedBorder)
            TextField("Bio", text: $bio, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button {
                    Task { await save() }
                } label: {
                    Text(saving ? "Saving…" : "Save")
                        .font(.system(size: 14, weight: .heavy))
                        .padding(.horizontal, 22).padding(.vertical, 10)
                        .background(LinearGradient.ravenBrand)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(saving)
            }
        }
        .padding(28)
        .frame(width: 420)
        .onAppear {
            let first = auth.currentUser?.firstName ?? ""
            let last = auth.currentUser?.lastName ?? ""
            let composed = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
            displayName = composed
            bio = auth.currentUser?.bio ?? ""
        }
    }

    @MainActor
    private func save() async {
        saving = true
        error = nil
        do {
            try await auth.updateProfile(displayName: displayName, bio: bio)
            dismiss()
        } catch {
            self.error = "Couldn't save profile."
            print("👤 [profile] save failed: \(error)")
        }
        saving = false
    }

    @MainActor
    private func pickAndUploadAvatar() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.jpeg, .png, .image]
        panel.message = "Choose a profile picture"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            uploadingAvatar = true
            try await auth.updateAvatar(
                imageData: data,
                filename: url.lastPathComponent
            )
        } catch {
            self.error = "Couldn't upload picture: \(error.localizedDescription)"
            print("👤 [avatar] upload failed: \(error)")
        }
        uploadingAvatar = false
    }
}

// MARK: - Settings sheet (password change for now)

private struct SettingsSheet: View {
    @EnvironmentObject var auth: AuthService
    @Environment(\.dismiss) private var dismiss

    // Password change
    @State private var current = ""
    @State private var newPassword = ""
    @State private var confirm = ""
    @State private var saving = false
    @State private var error: String?
    @State private var success: String?

    // Notification preferences
    @State private var prefs = NotificationPreferences()
    @State private var prefsLoaded = false
    @State private var prefsSaving = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Settings").font(.title3.weight(.bold))
                    Spacer()
                    Button("Close") { dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
                }

                // MARK: Background mode (keeps BLE mesh alive)
                SettingsSection(title: "Mesh & background") {
                    BackgroundModeSettingsBlock()
                }

                // MARK: Notifications
                SettingsSection(title: "Notifications") {
                    VStack(spacing: 0) {
                        NotifToggle(label: "Push notifications",
                                    value: bind(\.pushEnabled))
                        NotifToggle(label: "Direct messages",
                                    value: bind(\.messagesEnabled))
                        NotifToggle(label: "Friend requests",
                                    value: bind(\.friendRequestsEnabled))
                        NotifToggle(label: "Likes & comments",
                                    value: bind(\.likesCommentsEnabled))
                        NotifToggle(label: "Mentions",
                                    value: bind(\.mentionNotifications))
                        NotifToggle(label: "Posts from people you follow",
                                    value: bind(\.newPostNotifications))
                        NotifToggle(label: "Sounds",
                                    value: bind(\.soundsEnabled))
                        NotifToggle(label: "Show message preview",
                                    value: bind(\.messagePreview))
                    }
                    .opacity(prefsLoaded ? 1 : 0.5)
                    .disabled(!prefsLoaded || prefsSaving)
                }

                // MARK: Password
                SettingsSection(title: "Change password") {
                    VStack(spacing: 8) {
                        SecureField("Current password", text: $current).textFieldStyle(.roundedBorder)
                        SecureField("New password", text: $newPassword).textFieldStyle(.roundedBorder)
                        SecureField("Confirm new password", text: $confirm).textFieldStyle(.roundedBorder)

                        if let error {
                            Text(error).font(.caption).foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let success {
                            Text(success).font(.caption).foregroundStyle(.green)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        HStack {
                            Spacer()
                            Button {
                                Task { await save() }
                            } label: {
                                Text(saving ? "Saving…" : "Save password")
                                    .font(.system(size: 14, weight: .heavy))
                                    .padding(.horizontal, 22).padding(.vertical, 10)
                                    .background(LinearGradient.ravenBrand)
                                    .foregroundStyle(.white)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(saving || current.isEmpty || newPassword.isEmpty || newPassword != confirm)
                        }
                    }
                }
            }
            .padding(28)
        }
        .frame(width: 460, height: 620)
        .task { await loadPreferences() }
    }

    /// Two-way binding into one `NotificationPreferences` field that
    /// auto-saves when toggled.
    private func bind(_ key: WritableKeyPath<NotificationPreferences, Bool?>) -> Binding<Bool> {
        Binding(
            get: { prefs[keyPath: key] ?? true },
            set: { newValue in
                prefs[keyPath: key] = newValue
                Task { await savePreferences() }
            }
        )
    }

    @MainActor
    private func loadPreferences() async {
        do {
            prefs = try await NetworkService.shared.fetchNotificationPreferences()
            prefsLoaded = true
        } catch {
            print("🔔 [prefs] load failed: \(error)")
        }
    }

    @MainActor
    private func savePreferences() async {
        prefsSaving = true
        defer { prefsSaving = false }
        do {
            _ = try await NetworkService.shared.updateNotificationPreferences(prefs)
        } catch {
            print("🔔 [prefs] save failed: \(error)")
        }
    }

    @MainActor
    private func save() async {
        saving = true
        error = nil
        success = nil
        if newPassword != confirm {
            error = "New passwords don't match."
            saving = false
            return
        }
        do {
            try await NetworkService.shared.changePassword(current: current, new: newPassword)
            success = "Password updated."
            current = ""; newPassword = ""; confirm = ""
        } catch {
            self.error = "Couldn't update password — check the current one."
            print("🔐 [password] change failed: \(error)")
        }
        saving = false
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

private struct NotifToggle: View {
    let label: String
    @Binding var value: Bool
    var body: some View {
        Toggle(label, isOn: $value)
            .toggleStyle(.switch)
            .padding(.vertical, 6)
    }
}

// MARK: - Background-mode settings block

/// Toggles surfaced in the Settings sheet so the user can opt the app
/// into "always-on" mode. The whole reason this section exists is the
/// Mac App Store sandbox forbids background BLE — by running the app
/// as an `.accessory` (menu-bar-only) process, the BLE peripheral mesh
/// keeps advertising / scanning continuously without violating the
/// sandbox, because the process itself never gets suspended.
private struct BackgroundModeSettingsBlock: View {
    @ObservedObject private var bg = BackgroundModeService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { bg.isEnabled },
                set: { bg.setEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run in background")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Keeps the BLE mesh advertising and lets nearby iPhones reach this Mac while the window is closed. Adds a menu-bar icon.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .padding(.vertical, 6)

            Toggle(isOn: Binding(
                get: { bg.launchAtLoginEnabled },
                set: { bg.setLaunchAtLogin($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch at login")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Auto-starts RAVEN when you sign in to your Mac, so the mesh is up before you open the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .disabled(!bg.isEnabled)
            .opacity(bg.isEnabled ? 1 : 0.6)
            .padding(.vertical, 6)

            // Surface live mesh status so the user has a clear signal
            // the trade-off is paying off — they enabled background
            // mode and N peers can already reach them.
            MeshStatusInline()
                .padding(.top, 6)
        }
        .onAppear { bg.refreshLaunchAtLoginState() }
    }
}

/// Tiny live-status row underneath the bg-mode toggles. Subscribes to
/// the engine via NotificationCenter so the count stays fresh.
private struct MeshStatusInline: View {
    @State private var peerCount: Int = 0
    @State private var advertising: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(advertising ? Color.green : Color.gray.opacity(0.5))
                .frame(width: 8, height: 8)
            if advertising {
                Text("Mesh active · \(peerCount) peer\(peerCount == 1 ? "" : "s") in range")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Mesh idle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ravenMeshStateChanged)) { note in
            peerCount = note.userInfo?["connectedPeerCount"] as? Int ?? 0
            advertising = note.userInfo?["advertising"] as? Bool ?? false
        }
    }
}

private struct ProfileTile: View {
    let icon: String
    let title: String
    var color: Color = .primary
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).foregroundStyle(color)
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(color)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(hover ? Color.white.opacity(0.05) : .clear)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .onHover { hover = $0 }
    }
}

// MARK: - Stat pill

private struct StatPill: View {
    let label: String
    let value: Int

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 18, weight: .bold).monospacedDigit())
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }
}

// MARK: - Helpers

private func displayName(_ user: User) -> String {
    let first = user.firstName ?? ""
    let last = user.lastName ?? ""
    let full = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
    return full.isEmpty ? user.username : full
}
