import SwiftUI

// MARK: - Account Settings Content (Liquid Glass Redesign)
struct AccountSettingsContent: View {
    @State private var authService = AuthService.shared
    @State private var languageManager = AppLanguageManager.shared
    @State private var showEditProfile = false
    @State private var showSignOutSheet = false
    @State private var showCloseAccountSheet = false
    @State private var showFriendRequests = false
    @State private var showPaywall = false
    @State private var pendingRequestsCount = 0
    
    var body: some View {
        VStack(spacing: 20) {
            // MARK: - RAVEN+ Banner
            ravenPlusBanner
            
            // MARK: - Profile Section
            GlassSettingsCard {
                Button {
                    showEditProfile = true
                } label: {
                    GlassSettingsRow(
                        title: "edit_profile".localized,
                        icon: "pencil.circle.fill",
                        iconColor: DS.accentBlue,
                        showChevron: true
                    )
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showEditProfile) {
                    EditProfileView()
                }
                
                GlassDivider()
                
                Button {
                    showFriendRequests = true
                } label: {
                    GlassSettingsRow(
                        title: "friend_requests".localized,
                        icon: "person.fill.badge.plus",
                        iconColor: DS.accentBlue,
                        badge: pendingRequestsCount > 0 ? "\(pendingRequestsCount)" : nil,
                        showChevron: true
                    )
                }
                .buttonStyle(.plain)
                
                GlassDivider()
                
                NavigationLink {
                    FindContactsView()
                } label: {
                    GlassSettingsRow(
                        title: "find_friends".localized,
                        icon: "person.crop.circle.badge.checkmark",
                        iconColor: DS.accentBlue,
                        showChevron: true
                    )
                }
                .buttonStyle(.plain)
                
                GlassDivider()
                
                NavigationLink {
                    VerificationView()
                } label: {
                    GlassSettingsRow(
                        title: "verification".localized,
                        icon: "checkmark.seal.fill",
                        iconColor: DS.accentBlue,
                        showChevron: true
                    )
                }
                .buttonStyle(.plain)
            }
            
            // MARK: - General Section
            GlassSettingsHeader(title: "section.general".localized)
            
            GlassSettingsCard {
                NavigationLink {
                    NotificationsSettingsView()
                } label: {
                    GlassSettingsRow(
                        title: "notifications".localized,
                        icon: "bell.badge.fill",
                        iconColor: DS.accentPurple,
                        showChevron: true
                    )
                }
                .buttonStyle(.plain)
                
                GlassDivider()
                
                NavigationLink {
                    PrivacySettingsView()
                } label: {
                    GlassSettingsRow(
                        title: "privacy".localized,
                        icon: "lock.fill",
                        iconColor: DS.accentPurple,
                        showChevron: true
                    )
                }
                .buttonStyle(.plain)
                
                GlassDivider()
                
                NavigationLink {
                    SecuritySettingsView()
                } label: {
                    GlassSettingsRow(
                        title: "security".localized,
                        icon: "shield.lefthalf.filled",
                        iconColor: DS.accentPurple,
                        showChevron: true
                    )
                }
                .buttonStyle(.plain)
                
                GlassDivider()
                
                NavigationLink {
                    StorageSettingsView()
                } label: {
                    GlassSettingsRow(
                        title: "storage".localized,
                        icon: "internaldrive.fill",
                        iconColor: DS.accentPurple,
                        showChevron: true
                    )
                }
                .buttonStyle(.plain)
                
                GlassDivider()
                
                NavigationLink {
                    ModerationInboxView()
                } label: {
                    GlassSettingsRow(
                        title: "moderation_inbox".localized,
                        icon: "exclamationmark.shield.fill",
                        iconColor: DS.accentPurple,
                        badge: ModerationService.shared.unreadCount > 0 ? "\(ModerationService.shared.unreadCount)" : nil,
                        showChevron: true
                    )
                }
                .buttonStyle(.plain)
                
                GlassDivider()
                
                NavigationLink {
                    BackgroundMeshSettingsView()
                } label: {
                    GlassSettingsRow(
                        title: "mesh_settings".localized,
                        icon: "antenna.radiowaves.left.and.right",
                        iconColor: DS.accentPurple,
                        showChevron: true
                    )
                }
                .buttonStyle(.plain)
                
                GlassDivider()
                
                NavigationLink {
                    DeviceIdentitySettingsView()
                } label: {
                    GlassSettingsRow(
                        title: "device_identity".localized,
                        icon: "touchid",
                        iconColor: DS.accentPurple,
                        showChevron: true
                    )
                }
                .buttonStyle(.plain)
            }
            
            // MARK: - Appearance Section
            GlassSettingsHeader(title: "section.appearance".localized)
            
            GlassSettingsCard {
                NavigationLink {
                    LanguageSettingsView()
                } label: {
                    GlassSettingsRow(
                        title: "language".localized,
                        icon: "globe",
                        iconColor: DS.accentBlue,
                        value: languageManager.currentLanguageDetails?.nativeName ?? "English",
                        showChevron: true
                    )
                }
                .buttonStyle(.plain)
                
                GlassDivider()
                
                NavigationLink {
                    DesignSettingsView()
                } label: {
                    GlassSettingsRow(
                        title: "design".localized,
                        icon: "paintpalette.fill",
                        iconColor: DS.accentBlue,
                        showChevron: true
                    )
                }
                .buttonStyle(.plain)
            }
            
            // MARK: - About Section
            GlassSettingsHeader(title: "section.about".localized)
            
            GlassSettingsCard {
                NavigationLink {
                    AboutView()
                } label: {
                    GlassSettingsRow(
                        title: "about".localized,
                        icon: "info.circle.fill",
                        iconColor: DS.accentGray,
                        showChevron: true
                    )
                }
                .buttonStyle(.plain)
                
                GlassDivider()
                
                NavigationLink {
                    PrivacyPolicyView()
                } label: {
                    GlassSettingsRow(
                        title: "privacy_policy".localized,
                        icon: "doc.text.fill",
                        iconColor: DS.accentGray,
                        showChevron: true
                    )
                }
                .buttonStyle(.plain)
                
                GlassDivider()
                
                NavigationLink {
                    FAQView()
                } label: {
                    GlassSettingsRow(
                        title: "faq".localized,
                        icon: "questionmark.circle.fill",
                        iconColor: DS.accentGray,
                        showChevron: true
                    )
                }
                .buttonStyle(.plain)
                
                GlassDivider()
                
                Button {
                    Haptics.light()
                    if let url = URL(string: "mailto:privacy@raven-messager.com") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    GlassSettingsRow(
                        title: "contact_support".localized,
                        icon: "envelope.fill",
                        iconColor: DS.accentGray,
                        showChevron: true
                    )
                }
                .buttonStyle(.plain)
            }
            
            // MARK: - Account Actions Section
            GlassSettingsHeader(title: "section.account".localized)
            
            // Sign Out Card
            GlassActionCard(
                title: "sign_out".localized,
                icon: "rectangle.portrait.and.arrow.right.fill",
                color: .orange
            ) {
                Haptics.light()
                showSignOutSheet = true
            }
            
            // Close Account Card
            GlassActionCard(
                title: "close_account".localized,
                icon: "xmark.circle.fill",
                color: .red
            ) {
                Haptics.light()
                showCloseAccountSheet = true
            }
            
            // App Version Footer
            VStack(spacing: 4) {
                Text("RAVEN")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.6))
                Text("Version 1.0.0")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary.opacity(0.4))
            }
            .padding(.top, 16)
        }
        .sheet(isPresented: $showSignOutSheet) {
            SignOutConfirmSheet()
        }
        .sheet(isPresented: $showCloseAccountSheet) {
            CloseAccountConfirmSheet()
        }
        .sheet(isPresented: $showFriendRequests) {
            FriendRequestsView()
        }
        .sheet(isPresented: $showPaywall) {
            RavenPlusPaywallView()
        }
        .task {
            await fetchPendingRequestsCount()
        }
    }
    
    // MARK: - RAVEN+ Banner
    
    /// Calm blue accent for the banner
    private static let bannerBlue = Color(red: 0.176, green: 0.498, blue: 0.976) // #2D7FF9
    /// Soft gold for crown icon
    private static let bannerGold = Color(red: 0.788, green: 0.659, blue: 0.298) // #C9A84C
    
    @ViewBuilder
    private var ravenPlusBanner: some View {
        if SubscriptionService.shared.isPremium {
            // Active subscriber badge — glass + soft gold crown + blue border
            HStack(spacing: 12) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Self.bannerGold)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Raven+ Active")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("All premium features unlocked")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.green)
            }
            .padding(16)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                    .strokeBorder(Self.bannerBlue.opacity(0.25), lineWidth: 1)
            )
        } else {
            // Upgrade banner — glass + subtle blue, calm copy
            Button {
                Haptics.light()
                showPaywall = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Self.bannerGold)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Upgrade to Raven+")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text("Raven+ features")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.5))
                }
                .padding(16)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                        .strokeBorder(Self.bannerBlue.opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }
    
    private func fetchPendingRequestsCount() async {
        do {
            let requests: [FriendRequest] = try await NetworkService.shared.get(path: "/api/users/friend-requests")
            await MainActor.run {
                pendingRequestsCount = requests.count
            }
        } catch {
            #if DEBUG
            print("❌ Failed to fetch friend requests count: \(error)")
            #endif
        }
    }
}

// MARK: - Glass Settings Card (Capsule Container)
struct GlassSettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    
    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.primary.opacity(0.2), Color.primary.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
        .shadow(color: DS.shadowColor, radius: DS.shadowRadius, y: DS.shadowY)
    }
}

// MARK: - Glass Settings Row
struct GlassSettingsRow: View {
    let title: String
    let icon: String
    let iconColor: Color
    var value: String? = nil
    var badge: String? = nil
    var showChevron: Bool = false
    
    var body: some View {
        HStack(spacing: 14) {
            // Icon with glow effect
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 38, height: 38)
                
                Circle()
                    .fill(iconColor.opacity(0.1))
                    .frame(width: 38, height: 38)
                    .blur(radius: 4)
                
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
            
            Spacer()
            
            // Value label (like "English" for language)
            if let value = value {
                Text(value)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            
            // Badge
            if let badge = badge {
                Text(badge)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.red)
                            .shadow(color: .red.opacity(0.4), radius: 4, x: 0, y: 2)
                    )
            }
            
            // Chevron
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

// MARK: - Glass Settings Header
struct GlassSettingsHeader: View {
    let title: String
    
    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.7))
                .tracking(0.8)
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
    }
}

// MARK: - Glass Divider
struct GlassDivider: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [Color.clear, Color.primary.opacity(0.08), Color.clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 0.5)
            .padding(.leading, 68) // Align with text after icon
    }
}

// MARK: - Glass Action Card (Sign Out / Close Account)
struct GlassActionCard: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 38, height: 38)
                    
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(color)
                }
                
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(color)
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                    .stroke(color.opacity(0.2), lineWidth: 0.5)
            )
            .shadow(color: color.opacity(0.1), radius: 8, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Account Settings List (Standalone)
struct AccountSettingsList: View {
    var body: some View {
        ScrollView {
            AccountSettingsContent()
                .padding(16)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Keeping Old Components for Compatibility

// Settings Section Header (legacy compatibility)
struct SettingsSectionHeader: View {
    let title: String
    
    var body: some View {
        GlassSettingsHeader(title: title)
    }
}

// Settings Row View (legacy compatibility)
struct SettingsRowView: View {
    let title: String
    let icon: String
    let iconColor: Color
    
    var body: some View {
        GlassSettingsRow(
            title: title,
            icon: icon,
            iconColor: iconColor,
            showChevron: true
        )
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
        )
    }
}

// Settings Row With Badge (legacy compatibility)
struct SettingsRowWithBadge: View {
    let title: String
    let icon: String
    let iconColor: Color
    let badgeCount: Int
    
    var body: some View {
        GlassSettingsRow(
            title: title,
            icon: icon,
            iconColor: iconColor,
            badge: badgeCount > 0 ? "\(badgeCount)" : nil,
            showChevron: true
        )
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
    }
}

// Settings Row With Value (legacy compatibility)
struct SettingsRowWithValue: View {
    let title: String
    let value: String
    let icon: String
    let iconColor: Color
    
    var body: some View {
        GlassSettingsRow(
            title: title,
            icon: icon,
            iconColor: iconColor,
            value: value,
            showChevron: true
        )
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
        )
    }
}

// MARK: - Edit Profile View (moved to Features/Profile/EditProfileView.swift)


// MARK: - Country Code Picker Sheet
struct CountryCodePickerSheet: View {
    @Binding var selectedCode: String
    @Binding var isPresented: Bool
    @State private var searchText = ""
    
    // Common country codes
    private let countryCodes: [(code: String, flag: String, name: String)] = [
        ("+1", "🇺🇸", "United States"),
        ("+44", "🇬🇧", "United Kingdom"),
        ("+49", "🇩🇪", "Germany"),
        ("+33", "🇫🇷", "France"),
        ("+39", "🇮🇹", "Italy"),
        ("+34", "🇪🇸", "Spain"),
        ("+31", "🇳🇱", "Netherlands"),
        ("+32", "🇧🇪", "Belgium"),
        ("+41", "🇨🇭", "Switzerland"),
        ("+43", "🇦🇹", "Austria"),
        ("+46", "🇸🇪", "Sweden"),
        ("+47", "🇳🇴", "Norway"),
        ("+45", "🇩🇰", "Denmark"),
        ("+358", "🇫🇮", "Finland"),
        ("+48", "🇵🇱", "Poland"),
        ("+420", "🇨🇿", "Czech Republic"),
        ("+7", "🇷🇺", "Russia"),
        ("+380", "🇺🇦", "Ukraine"),
        ("+90", "🇹🇷", "Turkey"),
        ("+98", "🇮🇷", "Iran"),
        ("+966", "🇸🇦", "Saudi Arabia"),
        ("+971", "🇦🇪", "UAE"),
        ("+972", "🇮🇱", "Israel"),
        ("+91", "🇮🇳", "India"),
        ("+92", "🇵🇰", "Pakistan"),
        ("+880", "🇧🇩", "Bangladesh"),
        ("+86", "🇨🇳", "China"),
        ("+81", "🇯🇵", "Japan"),
        ("+82", "🇰🇷", "South Korea"),
        ("+66", "🇹🇭", "Thailand"),
        ("+84", "🇻🇳", "Vietnam"),
        ("+60", "🇲🇾", "Malaysia"),
        ("+65", "🇸🇬", "Singapore"),
        ("+62", "🇮🇩", "Indonesia"),
        ("+63", "🇵🇭", "Philippines"),
        ("+61", "🇦🇺", "Australia"),
        ("+64", "🇳🇿", "New Zealand"),
        ("+55", "🇧🇷", "Brazil"),
        ("+52", "🇲🇽", "Mexico"),
        ("+54", "🇦🇷", "Argentina"),
        ("+57", "🇨🇴", "Colombia"),
        ("+56", "🇨🇱", "Chile"),
        ("+51", "🇵🇪", "Peru"),
        ("+20", "🇪🇬", "Egypt"),
        ("+234", "🇳🇬", "Nigeria"),
        ("+27", "🇿🇦", "South Africa"),
        ("+254", "🇰🇪", "Kenya"),
        ("+212", "🇲🇦", "Morocco"),
    ]
    
    private var filteredCodes: [(code: String, flag: String, name: String)] {
        if searchText.isEmpty { return countryCodes }
        return countryCodes.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.code.contains(searchText)
        }
    }
    
    var body: some View {
        NavigationStack {
            List(filteredCodes, id: \.code) { country in
                Button {
                    selectedCode = country.code
                    isPresented = false
                } label: {
                    HStack {
                        Text(country.flag)
                            .font(.title2)
                        Text(country.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(country.code)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        if country.code == selectedCode {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $searchText, prompt: "Search countries")
            .navigationTitle("Select Country")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }
}
