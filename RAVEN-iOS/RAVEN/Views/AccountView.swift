// RAVEN - Account View
// Converted from Flutter account_settings_page.dart

import SwiftUI

struct AccountView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authService: AuthService
    @State private var showSignOutAlert = false
    
    var body: some View {
        NavigationStack {
            List {
                // Profile Header
                Section {
                    profileHeader
                }
                .listRowBackground(Color.clear)
                
                // Quick Actions
                Section {
                    NavigationLink {
                        EditProfileView()
                    } label: {
                        Label("Edit Profile", systemImage: "person.circle")
                    }
                    
                    NavigationLink {
                        MyQRCodeView()
                    } label: {
                        Label("My QR Code", systemImage: "qrcode")
                    }
                }
                
                // Settings
                Section("Settings") {
                    NavigationLink {
                        PrivacySettingsView()
                    } label: {
                        Label("Privacy", systemImage: "lock.shield")
                    }
                    
                    NavigationLink {
                        SecuritySettingsView()
                    } label: {
                        Label("Security", systemImage: "key")
                    }
                    
                    NavigationLink {
                        NotificationSettingsView()
                    } label: {
                        Label("Notifications", systemImage: "bell")
                    }
                    
                    NavigationLink {
                        AppearanceSettingsView()
                    } label: {
                        Label("Appearance", systemImage: "paintbrush")
                    }
                }
                
                // Data & Storage
                Section("Data & Storage") {
                    NavigationLink {
                        StorageView()
                    } label: {
                        Label("Storage Usage", systemImage: "internaldrive")
                    }
                    
                    NavigationLink {
                        // Network settings
                    } label: {
                        Label("Network Mode", systemImage: "network")
                    }
                }
                
                // Help
                Section("Help") {
                    NavigationLink {
                        FAQView()
                    } label: {
                        Label("FAQ", systemImage: "questionmark.circle")
                    }
                    
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                }
                
                // Sign Out
                Section {
                    Button(role: .destructive) {
                        showSignOutAlert = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("Sign Out")
                            Spacer()
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Account")
            .alert("Sign Out", isPresented: $showSignOutAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Sign Out", role: .destructive) {
                    Task {
                        await appState.clearAllData()
                        authService.signOut()
                    }
                }
            } message: {
                Text("Are you sure you want to sign out?")
            }
        }
    }
    
    var profileHeader: some View {
        HStack(spacing: 16) {
            AvatarView(
                url: authService.currentUser?.avatarUrl,
                name: authService.currentUser?.displayName ?? "User",
                size: 70
            )
            
            VStack(alignment: .leading, spacing: 4) {
                Text(authService.currentUser?.displayName ?? "User")
                    .font(.title2.bold())
                
                Text("@\(authService.currentUser?.username ?? "username")")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                if let bio = authService.currentUser?.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Edit Profile View
struct EditProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var authService: AuthService
    
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var bio = ""
    @State private var isSaving = false
    
    var body: some View {
        Form {
            Section("Name") {
                TextField("First Name", text: $firstName)
                TextField("Last Name", text: $lastName)
            }
            
            Section("Bio") {
                TextEditor(text: $bio)
                    .frame(height: 100)
            }
            
            Section("Profile Photo") {
                Button {
                    // Photo picker
                } label: {
                    Label("Change Photo", systemImage: "camera")
                }
            }
        }
        .navigationTitle("Edit Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save") {
                    saveProfile()
                }
                .disabled(isSaving)
            }
        }
        .onAppear {
            if let user = authService.currentUser {
                firstName = user.firstName ?? ""
                lastName = user.lastName ?? ""
                bio = user.bio ?? ""
            }
        }
    }
    
    func saveProfile() {
        isSaving = true
        Task {
            if let _ = try? await APIService.shared.updateProfile(bio: bio) {
                dismiss()
            }
            isSaving = false
        }
    }
}

// MARK: - Settings Views
struct PrivacySettingsView: View {
    @State private var lastSeenVisibility = "Everyone"
    @State private var profilePhotoVisibility = "Everyone"
    @State private var readReceipts = true
    
    var body: some View {
        Form {
            Section("Visibility") {
                Picker("Last Seen", selection: $lastSeenVisibility) {
                    Text("Everyone").tag("Everyone")
                    Text("Contacts").tag("Contacts")
                    Text("Nobody").tag("Nobody")
                }
                
                Picker("Profile Photo", selection: $profilePhotoVisibility) {
                    Text("Everyone").tag("Everyone")
                    Text("Contacts").tag("Contacts")
                    Text("Nobody").tag("Nobody")
                }
            }
            
            Section {
                Toggle("Read Receipts", isOn: $readReceipts)
            } footer: {
                Text("When enabled, others can see when you've read their messages")
            }
            
            Section {
                NavigationLink("Blocked Users") {
                    BlockedUsersView()
                }
            }
        }
        .navigationTitle("Privacy")
    }
}

struct SecuritySettingsView: View {
    @State private var passcodeEnabled = false
    @State private var biometricEnabled = false
    
    var body: some View {
        Form {
            Section {
                Toggle("Passcode Lock", isOn: $passcodeEnabled)
                
                if passcodeEnabled {
                    Toggle("Face ID / Touch ID", isOn: $biometricEnabled)
                }
            }
            
            Section {
                NavigationLink("Active Sessions") {
                    ActiveSessionsView()
                }
                
                NavigationLink("Two-Factor Authentication") {
                    TwoFactorView()
                }
            }
            
            Section {
                Button("Change Password") {
                    // Change password
                }
            }
        }
        .navigationTitle("Security")
    }
}

struct NotificationSettingsView: View {
    @State private var messageNotifications = true
    @State private var groupNotifications = true
    @State private var likeNotifications = true
    @State private var commentNotifications = true
    @State private var soundEnabled = true
    @State private var vibrationEnabled = true
    
    var body: some View {
        Form {
            Section("Messages") {
                Toggle("Messages", isOn: $messageNotifications)
                Toggle("Groups", isOn: $groupNotifications)
            }
            
            Section("Social") {
                Toggle("Likes", isOn: $likeNotifications)
                Toggle("Comments", isOn: $commentNotifications)
            }
            
            Section("Sound & Haptics") {
                Toggle("Sound", isOn: $soundEnabled)
                Toggle("Vibration", isOn: $vibrationEnabled)
            }
        }
        .navigationTitle("Notifications")
    }
}

struct AppearanceSettingsView: View {
    @State private var colorScheme = "System"
    @State private var fontSize = 16.0
    
    var body: some View {
        Form {
            Section("Theme") {
                Picker("Color Scheme", selection: $colorScheme) {
                    Text("System").tag("System")
                    Text("Light").tag("Light")
                    Text("Dark").tag("Dark")
                }
            }
            
            Section("Text Size") {
                Slider(value: $fontSize, in: 12...24, step: 1) {
                    Text("Font Size")
                }
                
                Text("Preview text at \(Int(fontSize))pt")
                    .font(.system(size: fontSize))
            }
        }
        .navigationTitle("Appearance")
    }
}

// MARK: - Placeholder Views
struct MyQRCodeView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "qrcode")
                .font(.system(size: 200))
                .foregroundColor(.ravenPrimary)
            
            Text("Your QR Code")
                .font(.headline)
            
            Text("Others can scan this to add you")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .navigationTitle("QR Code")
    }
}

struct StorageView: View {
    var body: some View {
        List {
            Section {
                HStack {
                    Text("Messages")
                    Spacer()
                    Text("12.3 MB")
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Media")
                    Spacer()
                    Text("245.6 MB")
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Cache")
                    Spacer()
                    Text("34.2 MB")
                        .foregroundColor(.secondary)
                }
            }
            
            Section {
                Button("Clear Cache", role: .destructive) {
                    // Clear cache
                }
            }
        }
        .navigationTitle("Storage")
    }
}

struct FAQView: View {
    var body: some View {
        List {
            Section("Getting Started") {
                NavigationLink("How do I send a message?") { Text("FAQ Item") }
                NavigationLink("How do I add contacts?") { Text("FAQ Item") }
            }
            
            Section("Privacy & Security") {
                NavigationLink("Is RAVEN secure?") { Text("FAQ Item") }
                NavigationLink("How does mesh networking work?") { Text("FAQ Item") }
            }
        }
        .navigationTitle("FAQ")
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "bird.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.ravenPrimary)
                        Text("RAVEN")
                            .font(.title.bold())
                        Text("Version 1.0.0")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical)
            }
            .listRowBackground(Color.clear)
            
            Section {
                Link("Privacy Policy", destination: URL(string: "https://raven.im/privacy")!)
                Link("Terms of Service", destination: URL(string: "https://raven.im/terms")!)
                Link("Open Source Licenses", destination: URL(string: "https://raven.im/licenses")!)
            }
        }
        .navigationTitle("About")
    }
}

struct BlockedUsersView: View {
    var body: some View {
        ContentUnavailableView("No Blocked Users", systemImage: "person.slash", description: Text("You haven't blocked anyone"))
            .navigationTitle("Blocked Users")
    }
}

struct ActiveSessionsView: View {
    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "iphone")
                        .font(.title2)
                    
                    VStack(alignment: .leading) {
                        Text("This Device")
                            .font(.headline)
                        Text("iPhone 15 Pro • Now")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Text("Active")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
        }
        .navigationTitle("Active Sessions")
    }
}

struct TwoFactorView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 60))
                .foregroundColor(.ravenPrimary)
            
            Text("Two-Factor Authentication")
                .font(.title2.bold())
            
            Text("Add an extra layer of security to your account")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
            Button {
                // Enable 2FA
            } label: {
                Text("Enable 2FA")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.ravenPrimary)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal)
        }
        .padding()
        .navigationTitle("2FA")
    }
}

#Preview {
    AccountView()
        .environmentObject(AppState())
        .environmentObject(AuthService.shared)
        .preferredColorScheme(.dark)
}
