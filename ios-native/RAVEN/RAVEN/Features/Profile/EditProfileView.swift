import SwiftUI

// MARK: - Edit Profile View (Liquid Glass · Capsule-first)
struct EditProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var authService = AuthService.shared
    
    // MARK: - Form State
    @State private var displayName: String = ""
    @State private var username: String = ""
    @State private var bio: String = ""
    @State private var birthday: Date = Calendar.current.date(byAdding: .year, value: -16, to: Date()) ?? Date()
    @State private var hasBirthday: Bool = false
    @State private var showBirthdayOnProfile: Bool = true
    @State private var phoneNumber: String = ""
    @State private var countryCode: String = "+1"
    @State private var tags: [String] = []
    @State private var newTagText: String = ""
    
    // MARK: - UI State
    @State private var isSaving = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showImagePicker = false
    @State private var selectedImage: UIImage?
    @State private var showCountryPicker = false
    @State private var isEditingPhone = false
    @State private var showRemoveAvatarAlert = false
    @State private var sectionsAppeared = false
    
    // MARK: - Username Validation
    @State private var isCheckingUsername = false
    @State private var usernameAvailable: Bool? = nil
    @State private var usernameCheckTask: Task<Void, Never>? = nil
    
    // MARK: - Avatar Press
    @State private var avatarPressed = false
    @State private var safeAreaTop: CGFloat = 0
    
    // MARK: - Original Values (for dirty tracking)
    @State private var originalDisplayName = ""
    @State private var originalUsername = ""
    @State private var originalBio = ""
    @State private var originalHasBirthday = false
    @State private var originalBirthday = Calendar.current.date(byAdding: .year, value: -16, to: Date()) ?? Date()
    @State private var originalTags: [String] = []
    @State private var originalPhoneNumber = ""
    @State private var originalCountryCode = "+1"
    @State private var originalShowBirthdayOnProfile = true
    
    private var currentUser: User? { authService.currentUser }
    
    private var hasChanges: Bool {
        displayName != originalDisplayName ||
        username != originalUsername ||
        bio != originalBio ||
        hasBirthday != originalHasBirthday ||
        (hasBirthday && birthday != originalBirthday) ||
        showBirthdayOnProfile != originalShowBirthdayOnProfile ||
        tags != originalTags ||
        selectedImage != nil ||
        phoneNumber != originalPhoneNumber ||
        countryCode != originalCountryCode
    }
    
    private var canSave: Bool {
        hasChanges && !isSaving && usernameAvailable != false
    }
    
    private let maxBioLength = 160
    private let maxTags = 8
    
    // MARK: - Body
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                // Background
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()
                
                // Scrollable content
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 24) {
                        // Spacer for header (dynamic: header content + safe area)
                        Color.clear.frame(height: 56 + geo.safeAreaInsets.top)
                        
                        // Hero Avatar
                        avatarSection
                            .sectionTransition(index: 0, appeared: sectionsAppeared)
                        
                        // Card 1: Identity
                        identityCard
                            .sectionTransition(index: 1, appeared: sectionsAppeared)
                        
                        // Card 2: Bio
                        bioCard
                            .sectionTransition(index: 2, appeared: sectionsAppeared)
                        
                        // Card 3: Birthday
                        birthdayCard
                            .sectionTransition(index: 3, appeared: sectionsAppeared)
                        
                        // Card 4: Phone
                        phoneCard
                            .sectionTransition(index: 4, appeared: sectionsAppeared)
                        
                        // Card 5: Tags
                        tagsCard
                            .sectionTransition(index: 5, appeared: sectionsAppeared)
                        
                        // Bottom safe-area spacer
                        Color.clear.frame(height: 40)
                    }
                    .padding(.horizontal, 16)
                }
                .onTapGesture { hideKeyboard() }
                .scrollDismissesKeyboard(.interactively)
                
                // Sticky Glass Header
                glassHeader(safeAreaTop: geo.safeAreaInsets.top)
            }
            .onAppear {
                safeAreaTop = geo.safeAreaInsets.top
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarHidden(true)
        .onAppear {
            loadCurrentProfile()
            withAnimation(.easeOut(duration: 0.5).delay(0.15)) {
                sectionsAppeared = true
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .alert("Remove Photo?", isPresented: $showRemoveAvatarAlert) {
            Button("Remove", role: .destructive) {
                selectedImage = nil
                // Clear avatar on server
                Task {
                    struct ClearAvatarPayload: Encodable {
                        let avatarPath: String?
                        enum CodingKeys: String, CodingKey { case avatarPath = "avatar_path" }
                        func encode(to encoder: Encoder) throws {
                            var container = encoder.container(keyedBy: CodingKeys.self)
                            try container.encodeNil(forKey: .avatarPath)
                        }
                    }
                    let _: ProfileUpdateResponse = try await NetworkService.shared.patch(
                        path: "/api/users/me",
                        body: ClearAvatarPayload(avatarPath: nil)
                    )
                    await MainActor.run {
                        authService.currentUser?.avatarPath = nil
                        #if DEBUG
                        print("✅ [EditProfile] Avatar cleared on server")
                        #endif
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showImagePicker) {
            ImagePicker(image: $selectedImage)
        }
        .sheet(isPresented: $showCountryPicker) {
            CountryCodePickerSheet(selectedCode: $countryCode, isPresented: $showCountryPicker)
        }
    }
    
    // MARK: - Glass Header
    private func glassHeader(safeAreaTop: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Safe area fill (so material extends behind status bar)
            Color.clear.frame(height: safeAreaTop)
            
            HStack {
                // Close button (sheet = xmark)
                Button {
                    Haptics.light()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: DS.navButtonSize, height: DS.navButtonSize)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                Text("Edit Profile")
                    .font(.system(size: 17, weight: .semibold))
                
                Spacer()
                
                // Save button — glass capsule, theme-consistent
                Button {
                    Haptics.light()
                    Task { await saveProfile() }
                } label: {
                    Group {
                        if isSaving {
                            ProgressView()
                                .tint(DS.accentBlue)
                                .scaleEffect(0.8)
                        } else {
                            Text("Save")
                                .font(.system(size: 15, weight: .semibold))
                        }
                    }
                    .foregroundStyle(canSave ? DS.accentBlue : .secondary)
                    .frame(width: 64, height: DS.navButtonSize)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
                .animation(.spring(response: 0.3), value: canSave)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)
        .ignoresSafeArea(edges: .top)
    }
    
    // MARK: - Avatar Section
    private var avatarSection: some View {
        VStack(spacing: 14) {
            Button {
                Haptics.light()
                showImagePicker = true
            } label: {
                ZStack {
                    // Gradient ring
                    Circle()
                        .stroke(
                            AngularGradient(
                                colors: [.blue, .purple, .pink, .blue],
                                center: .center
                            ),
                            lineWidth: 3
                        )
                        .frame(width: 128, height: 128)
                    
                    // Avatar
                    if let image = selectedImage {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 120, height: 120)
                            .clipShape(Circle())
                    } else {
                        GlassAvatar(
                            name: currentUser?.initials ?? "?",
                            path: currentUser?.avatarPath,
                            size: 120,
                            showGlow: true
                        )
                    }
                    
                    // Camera overlay
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Image(systemName: "camera.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(
                                    LinearGradient(
                                        colors: [.blue, .purple],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .clipShape(Circle())
                                .overlay(
                                    Circle()
                                        .stroke(Color(.systemGroupedBackground), lineWidth: 3)
                                )
                        }
                    }
                    .frame(width: 120, height: 120)
                }
            }
            .buttonStyle(.plain)
            .scaleEffect(avatarPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: avatarPressed)
            .onLongPressGesture(minimumDuration: 0.5) {
                Haptics.warning()
                showRemoveAvatarAlert = true
            } onPressingChanged: { pressing in
                avatarPressed = pressing
            }
            
            Text("Change Photo")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.blue)
        }
        .padding(.top, 8)
    }
    
    // MARK: - Card 1: Identity
    private var identityCard: some View {
        GlassSettingsCard {
            // Section title
            cardTitle("Identity", icon: "person.text.rectangle")
            
            // Display Name
            VStack(alignment: .leading, spacing: 6) {
                Text("Display Name")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                
                TextField("Your name", text: $displayName)
                    .font(.system(size: 16))
                    .tint(.blue)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            glassDivider
            
            // Username with live-check
            VStack(alignment: .leading, spacing: 6) {
                Text("Username")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                
                HStack {
                    HStack(spacing: 2) {
                        Text("@")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                        TextField("username", text: $username)
                            .font(.system(size: 16))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .tint(.blue)
                            .onChange(of: username) { _, newValue in
                                checkUsernameAvailability(newValue)
                            }
                    }
                    
                    Spacer()
                    
                    if isCheckingUsername {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else if let available = usernameAvailable {
                        Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(available ? .green : .red)
                            .font(.system(size: 18))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                
                if usernameAvailable == false {
                    Text("This username is already taken")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                } else {
                    Text("Can be changed once every 14 days")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
    
    // MARK: - Card 2: Bio
    private var bioCard: some View {
        GlassSettingsCard {
            cardTitle("Bio", icon: "text.quote")
            
            VStack(alignment: .leading, spacing: 6) {
                TextField("Tell the world about yourself…", text: $bio, axis: .vertical)
                    .font(.system(size: 16))
                    .lineLimit(1...6)
                    .tint(.blue)
                    .onChange(of: bio) { _, newValue in
                        if newValue.count > maxBioLength {
                            bio = String(newValue.prefix(maxBioLength))
                        }
                    }
                
                HStack {
                    Spacer()
                    Text("\(bio.count) / \(maxBioLength)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(bio.count >= maxBioLength ? Color.orange : Color.gray.opacity(0.4))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
    
    // MARK: - Card 3: Birthday
    private var birthdayCard: some View {
        GlassSettingsCard {
            cardTitle("Birthday", icon: "gift")
            
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if hasBirthday {
                        let minimumAge = 16
                        let maximumBirthday = Calendar.current.date(
                            byAdding: .year, value: -minimumAge, to: Date()
                        ) ?? Date()
                        
                        DatePicker(
                            "",
                            selection: $birthday,
                            in: ...maximumBirthday,
                            displayedComponents: .date
                        )
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .tint(.blue)
                    } else {
                        Text("Not set")
                            .font(.system(size: 16))
                            .foregroundStyle(.tertiary)
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 4) {
                        Toggle("Show on profile", isOn: $showBirthdayOnProfile)
                            .font(.system(size: 13))
                            .toggleStyle(.switch)
                            .tint(.blue)
                            .labelsHidden()
                        
                        Text(showBirthdayOnProfile ? "Visible" : "Age only")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                
                HStack {
                    Toggle(isOn: $hasBirthday.animation(.spring(response: 0.3))) {
                        Text(hasBirthday ? "Birthday enabled" : "Add birthday")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .toggleStyle(.switch)
                    .tint(.blue)
                }
                
                Text("You must be at least 16 years old")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
    
    // MARK: - Card 4: Phone Number
    private var phoneCard: some View {
        GlassSettingsCard {
            cardTitle("Phone Number", icon: "phone")
            
            VStack(alignment: .leading, spacing: 8) {
                if !phoneNumber.isEmpty && !isEditingPhone {
                    // Masked display
                    HStack {
                        Text(maskedPhone)
                            .font(.system(size: 16, design: .monospaced))
                            .foregroundStyle(.primary)
                        
                        Spacer()
                        
                        Button {
                            Haptics.light()
                            withAnimation(.spring(response: 0.3)) {
                                isEditingPhone = true
                            }
                        } label: {
                            Text("Change")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    // Edit mode
                    HStack(spacing: 8) {
                        Button {
                            showCountryPicker = true
                        } label: {
                            HStack(spacing: 4) {
                                Text(countryCode)
                                    .font(.system(size: 16))
                                    .monospacedDigit()
                                Image(systemName: "chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        
                        TextField("Phone number", text: $phoneNumber)
                            .keyboardType(.phonePad)
                            .font(.system(size: 16))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        
                        if isEditingPhone && !phoneNumber.isEmpty {
                            Button {
                                Haptics.light()
                                withAnimation(.spring(response: 0.3)) {
                                    isEditingPhone = false
                                }
                            } label: {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.green)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                
                Text("Your phone number is private and never shown publicly")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
    
    // MARK: - Card 5: Tags
    private var tagsCard: some View {
        GlassSettingsCard {
            cardTitle("Tags & Interests", icon: "tag")
            
            VStack(alignment: .leading, spacing: 12) {
                // Existing tags as chips
                if !tags.isEmpty {
                    FlowLayout(spacing: 8) {
                        ForEach(tags, id: \.self) { tag in
                            HStack(spacing: 4) {
                                Text(tag)
                                    .font(.system(size: 14))
                                
                                Button {
                                    Haptics.light()
                                    withAnimation(.spring(response: 0.3)) {
                                        tags.removeAll { $0 == tag }
                                    }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
                            )
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
                
                // Add tag
                if tags.count < maxTags {
                    HStack(spacing: 8) {
                        TextField("Add a tag…", text: $newTagText)
                            .font(.system(size: 15))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .tint(.blue)
                            .onSubmit { addTag() }
                        
                        Button {
                            addTag()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                        .disabled(newTagText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                
                Text("\(tags.count) / \(maxTags) tags")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
    
    // MARK: - Shared Components
    
    private func cardTitle(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.blue)
            
            Text(title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(0.3)
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
    
    private var glassDivider: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [Color.clear, Color.primary.opacity(0.08), Color.clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 0.5)
            .padding(.horizontal, 16)
    }
    
    private var maskedPhone: String {
        let digits = phoneNumber.filter(\.isNumber)
        guard digits.count >= 4 else { return countryCode + " " + phoneNumber }
        let lastFour = String(digits.suffix(4))
        let maskedPart = String(repeating: "•", count: max(0, digits.count - 4))
        // Group with spaces
        let grouped = maskedPart.isEmpty
            ? lastFour
            : "\(countryCode) \(maskedPart) \(lastFour)"
        return grouped
    }
    
    // MARK: - Actions
    
    private func addTag() {
        let trimmed = newTagText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty, !tags.contains(trimmed), tags.count < maxTags else { return }
        Haptics.light()
        withAnimation(.spring(response: 0.3)) {
            tags.append(trimmed)
        }
        newTagText = ""
    }
    
    private func loadCurrentProfile() {
        guard let user = currentUser else { return }
        
        displayName = user.displayName
        username = user.username ?? ""
        bio = user.bio ?? ""
        tags = user.tags ?? []
        
        if let userBirthday = user.birthday {
            birthday = userBirthday
            hasBirthday = true
        }
        
        // Parse phone using known country codes (longest prefix match)
        if let phone = user.phone, !phone.isEmpty {
            if phone.hasPrefix("+") {
                // Known codes sorted by length descending for longest-prefix-first matching
                let knownCodes = [
                    "+966", "+971", "+972", "+880", "+420", "+380", "+358", "+234", "+254", "+212",
                    "+98", "+92", "+91", "+90", "+86", "+82", "+81", "+84", "+66", "+65",
                    "+64", "+63", "+62", "+61", "+60", "+57", "+56", "+55", "+54", "+52",
                    "+51", "+49", "+48", "+47", "+46", "+45", "+44", "+43", "+41", "+39",
                    "+34", "+33", "+32", "+31", "+27", "+20",
                    "+7", "+1"
                ]
                
                var matched = false
                for code in knownCodes {
                    if phone.hasPrefix(code) {
                        countryCode = code
                        phoneNumber = String(phone.dropFirst(code.count))
                        matched = true
                        break
                    }
                }
                
                if !matched {
                    // Fallback: treat first 1-3 digits as country code
                    let phoneDigits = phone.dropFirst()
                    let codeLength = min(3, phoneDigits.count)
                    countryCode = "+" + String(phoneDigits.prefix(codeLength))
                    phoneNumber = String(phoneDigits.dropFirst(codeLength))
                }
            } else {
                phoneNumber = phone
            }
        }
        
        // Snapshot originals
        originalDisplayName = displayName
        originalUsername = username
        originalBio = bio
        originalHasBirthday = hasBirthday
        originalBirthday = birthday
        originalTags = tags
        originalPhoneNumber = phoneNumber
        originalCountryCode = countryCode
        originalShowBirthdayOnProfile = showBirthdayOnProfile
    }
    
    private func checkUsernameAvailability(_ newUsername: String) {
        usernameCheckTask?.cancel()
        
        let original = currentUser?.username ?? ""
        if newUsername.lowercased() == original.lowercased() {
            usernameAvailable = true
            isCheckingUsername = false
            return
        }
        
        if newUsername.isEmpty {
            usernameAvailable = nil
            isCheckingUsername = false
            return
        }
        
        usernameCheckTask = Task {
            isCheckingUsername = true
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            
            do {
                let isAvail = try await authService.checkUsernameAvailability(newUsername)
                await MainActor.run {
                    usernameAvailable = isAvail
                    isCheckingUsername = false
                }
            } catch {
                await MainActor.run {
                    usernameAvailable = nil
                    isCheckingUsername = false
                }
            }
        }
    }
    
    private func saveProfile() async {
        isSaving = true
        defer { isSaving = false }
        
        // Upload avatar if a new image was selected
        if let image = selectedImage {
            do {
                try await uploadAvatar(image)
            } catch {
                #if DEBUG
                print("❌ Avatar upload failed: \(error)")
                #endif
                await MainActor.run {
                    errorMessage = "Failed to upload avatar: \(error.localizedDescription)"
                    showError = true
                    Haptics.error()
                }
                return
            }
        }
        
        let cleanPhone = phoneNumber.hasPrefix("0") ? String(phoneNumber.dropFirst()) : phoneNumber
        let fullPhone = cleanPhone.isEmpty ? nil : countryCode + cleanPhone
        
        let payload = ProfileUpdatePayload(
            displayName: displayName.isEmpty ? nil : displayName,
            username: username.isEmpty ? nil : username,
            bio: bio.isEmpty ? nil : bio,
            birthday: hasBirthday ? birthday : nil,
            tags: tags.isEmpty ? nil : tags,
            phone: fullPhone,
            showBirthday: showBirthdayOnProfile
        )
        
        do {
            let _: ProfileUpdateResponse = try await NetworkService.shared.patch(
                path: "/api/users/me",
                body: payload
            )
            
            let updatedUser: User = try await NetworkService.shared.get(path: "/api/users/me")
            
            await MainActor.run {
                authService.currentUser = updatedUser
                Haptics.success()
                dismiss()
            }
        } catch {
            #if DEBUG
            print("❌ Profile save error: \(error)")
            #endif
            await MainActor.run {
                errorMessage = "Failed to save profile: \(error.localizedDescription)"
                showError = true
                Haptics.error()
            }
        }
    }
    
    private func uploadAvatar(_ image: UIImage) async throws {
        // Step 1: upload via the shared, hardened multipart pipeline (retries
        // on transient network errors that older iOS devices regularly hit
        // when talking to Cloud Run over HTTP/3 — without retry the user just
        // sees "server is down" the first time the radio hiccups).
        let imageUrl = try await AttachmentService.shared.uploadAvatarImage(image)

        // Step 2: tell the server this URL is the new avatar. Small JSON
        // request, so we ride NetworkService which already has its own retry.
        struct ProfilePictureBody: Encodable { let imageUrl: String }
        let _: Empty = try await NetworkService.shared.post(
            path: "/api/users/profile-picture",
            body: ProfilePictureBody(imageUrl: imageUrl)
        )

        #if DEBUG
        print("✅ Avatar uploaded successfully via 2-step upload")
        #endif
    }
}

// MARK: - Supporting Types

private struct ProfileUpdateResponse: Decodable {
    let success: Bool?
    let bio: String?
    let hobbies: [String]?
}

private struct UsernameCheckResponse: Decodable {
    let available: Bool
}

private struct ProfileUpdatePayload: Encodable {
    let displayName: String?
    let username: String?
    let bio: String?
    let birthday: Date?
    let tags: [String]?
    let phone: String?
    let showBirthday: Bool?
    
    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case username
        case bio
        case birthday
        case tags
        case phone
        case showBirthday = "show_birthday"
    }
    
    /// Explicitly encode nil as null so the server clears the field
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(username, forKey: .username)
        // Always encode bio/birthday/tags/phone — server needs null to clear them
        if let bio = bio { try container.encode(bio, forKey: .bio) } else { try container.encodeNil(forKey: .bio) }
        if let birthday = birthday { try container.encode(birthday, forKey: .birthday) } else { try container.encodeNil(forKey: .birthday) }
        if let tags = tags { try container.encode(tags, forKey: .tags) } else { try container.encodeNil(forKey: .tags) }
        if let phone = phone { try container.encode(phone, forKey: .phone) } else { try container.encodeNil(forKey: .phone) }
        try container.encodeIfPresent(showBirthday, forKey: .showBirthday)
    }
}

// MARK: - Section Transition Modifier
private struct SectionTransitionModifier: ViewModifier {
    let index: Int
    let appeared: Bool
    
    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 20)
            .animation(
                .spring(response: 0.45, dampingFraction: 0.8)
                    .delay(Double(index) * 0.06),
                value: appeared
            )
    }
}

private extension View {
    func sectionTransition(index: Int, appeared: Bool) -> some View {
        modifier(SectionTransitionModifier(index: index, appeared: appeared))
    }
}

// MARK: - Flow Layout (wrapping chips)
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: ProposedViewSize(result.sizes[index])
            )
        }
    }
    
    private struct LayoutResult {
        var size: CGSize
        var positions: [CGPoint]
        var sizes: [CGSize]
    }
    
    private func computeLayout(proposal: ProposedViewSize, subviews: Subviews) -> LayoutResult {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            sizes.append(size)
            
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        
        return LayoutResult(
            size: CGSize(width: maxWidth, height: y + rowHeight),
            positions: positions,
            sizes: sizes
        )
    }
}




// MARK: - Preview
#Preview {
    EditProfileView()
        .preferredColorScheme(.dark)
}
