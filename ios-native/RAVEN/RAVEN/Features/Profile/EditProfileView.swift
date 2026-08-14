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
                // Serverless build: there is no server record to PATCH. The avatar
                // is a purely local value, so clear it on-device only — drop the
                // picked image and null out the in-memory avatar path. (The old
                // /api/users/me PATCH hit the dead server and threw .unauthorized
                // before any HTTP fired.) No NetworkService call here.
                selectedImage = nil
                authService.setLocalAvatarPath(nil)   // clears the persisted avatar too
                #if DEBUG
                print("✅ [EditProfile] Avatar cleared locally")
                #endif
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

        // Serverless build: the device fingerprint IS the account — there is no
        // server record to PATCH/GET. The display name is a purely local,
        // on-device value, so persist it to the local key and rebuild
        // currentUser in place. This both updates the UI immediately and
        // survives relaunch (bootstrapLocalIdentity reads the same key).
        //
        // The old /api/users/me PATCH + GET round-trip is dead in the
        // serverless pivot (no token ⇒ NetworkService throws .unauthorized
        // before any HTTP fires), which made the name effectively un-editable
        // and surfaced a "Failed to save profile" alert. We also drop the
        // server-only avatar upload and the username/bio/birthday/tags/phone
        // payload from this save path — those endpoints only hit the dead
        // server. We deliberately do NOT call NetworkService here.
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? "Raven User" : trimmedName

        let saved = await MainActor.run {
            authService.setLocalDisplayName(finalName)
        }

        guard saved else {
            #if DEBUG
            print("❌ Profile save error: device fingerprint unavailable")
            #endif
            await MainActor.run {
                errorMessage = "Couldn't save your name. Please try again."
                showError = true
                Haptics.error()
            }
            return
        }

        // Avatar — LOCAL-only. No NetworkService, no /api/users/me upload.
        // If the user picked a new photo, persist the bytes to the app
        // container (Documents/avatars/) and point currentUser.avatarPath at
        // the file:// URL. AppConfig.mediaURL + GlassAvatar already render
        // file:// paths, so the new photo shows immediately everywhere
        // currentUser.avatarPath is read (Account/Settings, group create, …).
        //
        // NOTE: setLocalDisplayName above rebuilt currentUser with a nil
        // avatarPath, so we set the path AFTER that call. This is the source
        // of truth for the current session. It does NOT survive relaunch:
        // bootstrapLocalIdentity rebuilds currentUser with avatarPath=nil and
        // lives in AuthService (out of scope for this edit). Persisting the
        // path across launches would require an AuthService change.
        if let picked = selectedImage,
           let localPath = persistAvatarLocally(picked) {
            await MainActor.run {
                authService.setLocalAvatarPath(localPath)   // persists across relaunch (serverless)
            }
            #if DEBUG
            print("✅ [EditProfile] Avatar saved locally → \(localPath)")
            #endif
        }

        await MainActor.run {
            Haptics.success()
            dismiss()
        }
    }

    /// Write the picked avatar to the app container and return a `file://`
    /// URL string suitable for `currentUser.avatarPath`. LOCAL-only — never
    /// touches the network. Returns `nil` if encoding/writing fails (the
    /// save then proceeds without changing the avatar rather than erroring).
    private func persistAvatarLocally(_ image: UIImage) -> String? {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Stable filename keyed to our own id so we overwrite our previous
        // avatar instead of leaking a new file on every save.
        let selfId = currentUser?.id ?? "self"
        let fileURL = dir.appendingPathComponent("me-\(selfId).jpg", isDirectory: false)
        do {
            try data.write(to: fileURL, options: .atomic)
            return fileURL.absoluteString   // file:///…/avatars/me-<id>.jpg
        } catch {
            #if DEBUG
            print("⚠️ [EditProfile] Failed to persist avatar locally: \(error)")
            #endif
            return nil
        }
    }
}

// MARK: - Supporting Types

private struct UsernameCheckResponse: Decodable {
    let available: Bool
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
