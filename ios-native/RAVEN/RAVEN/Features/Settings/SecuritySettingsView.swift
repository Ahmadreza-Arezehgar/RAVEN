import SwiftUI
import LocalAuthentication

// MARK: - Security Settings View
struct SecuritySettingsView: View {
    @AppStorage("appLockEnabled") private var appLockEnabled = false
    @AppStorage("appLockTimeout") private var appLockTimeout = 0 // 0 = immediate
    @AppStorage("hideInAppSwitcher") private var hideInAppSwitcher = false
    
    @State private var biometricType: LABiometryType = .none
    
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // App Lock Section
                SettingsSection(title: "app_lock".localized) {
                    // Main toggle
                    SettingsToggleRow(
                        title: biometricTitle,
                        subtitle: "unlock_with_biometric".localized,
                        icon: biometricIcon,
                        iconColor: .blue,
                        isOn: Binding(
                            get: { appLockEnabled },
                            set: { newValue in
                                if newValue {
                                    // Authenticate before enabling
                                    authenticateToToggle(enable: true)
                                } else {
                                    // Authenticate before disabling too
                                    authenticateToToggle(enable: false)
                                }
                            }
                        )
                    )
                    
                    if appLockEnabled {
                        Divider()
                            .padding(.leading, 64)
                        
                        // Lock Timeout
                        VStack(spacing: 0) {
                            HStack(spacing: 14) {
                                Circle()
                                    .fill(Color.orange.opacity(0.15))
                                    .frame(width: 36, height: 36)
                                    .overlay(
                                        Image(systemName: "timer")
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundStyle(.orange)
                                    )
                                
                                Text("lock_timeout".localized)
                                    .font(.system(size: 16, weight: .medium))
                                
                                Spacer()
                            }
                            .padding(14)
                            
                            Picker("Timeout", selection: $appLockTimeout) {
                                Text("immediately".localized).tag(0)
                                Text("after_1_minute".localized).tag(60)
                                Text("after_5_minutes".localized).tag(300)
                                Text("after_15_minutes".localized).tag(900)
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 14)
                        }
                        
                        Divider()
                            .padding(.leading, 64)
                        
                        // Hide in App Switcher
                        SettingsToggleRow(
                            title: "hide_in_switcher".localized,
                            subtitle: "hide_in_switcher_desc".localized,
                            icon: "eye.slash.fill",
                            iconColor: .purple,
                            isOn: $hideInAppSwitcher
                        )
                    }
                }
                
                // Account Security
                SettingsSection(title: "section.account".localized) {
                    NavigationLink {
                        ChangePasswordView()
                    } label: {
                        SettingsNavigationRow(
                            title: "change_password".localized,
                            icon: "key.fill",
                            iconColor: .purple
                        )
                    }
                    .buttonStyle(.plain)
                    
                    NavigationLink {
                        TwoFactorView()
                    } label: {
                        SettingsNavigationRow(
                            title: "two_factor_auth".localized,
                            icon: "checkerboard.shield",
                            iconColor: .cyan
                        )
                    }
                    .buttonStyle(.plain)
                    
                    NavigationLink {
                        ActiveSessionsView()
                    } label: {
                        SettingsNavigationRow(
                            title: "active_sessions".localized,
                            icon: "iphone",
                            iconColor: .gray
                        )
                    }
                    .buttonStyle(.plain)
                }

                // Encryption section — the user-facing home for
                // ATSAM (Raven's production security protocol) and
                // its companion add-ons (Vault Mode for OTP text,
                // online pair flow). ATSAM core is on by default;
                // the user can toggle it off inside ATSAM settings.
                SettingsSection(title: "Encryption") {
                    NavigationLink {
                        ATSAMSettingsView()
                    } label: {
                        SettingsNavigationRow(
                            title: "ATSAM Protocol",
                            subtitle: "On by default · tap to manage or turn off",
                            icon: "atom",
                            iconColor: .purple
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        VaultModeSettingsView()
                    } label: {
                        SettingsNavigationRow(
                            title: "Vault Mode",
                            subtitle: "One-time-pad protection for sensitive text",
                            icon: "rhombus.fill",
                            iconColor: .purple
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        ATSAMOnlinePairView()
                    } label: {
                        SettingsNavigationRow(
                            title: "Pair a device",
                            subtitle: "60-digit safety number over the internet",
                            icon: "link.circle.fill",
                            iconColor: .blue
                        )
                    }
                    .buttonStyle(.plain)

                    #if DEBUG
                    NavigationLink {
                        ATSAMPairView()
                    } label: {
                        SettingsNavigationRow(
                            title: "ATSAM pair (developer)",
                            icon: "link",
                            iconColor: .gray
                        )
                    }
                    .buttonStyle(.plain)
                    #endif
                }

                // 🔴 ROUND 26 — v1.7 NEXT: 3-of-5 social key recovery.
                // Discovery surface for the new Shamir+ECIES feature;
                // crypto lives in SocialRecoveryService. The view is
                // a demo today and gets full contact-picker wiring
                // in the next round.
                SettingsSection(title: "Account Recovery") {
                    NavigationLink {
                        SocialRecoverySetupView()
                    } label: {
                        SettingsNavigationRow(
                            title: "Social Recovery (3-of-5)",
                            subtitle: "Recover your key with 3 of 5 trusted contacts",
                            icon: "person.3.sequence.fill",
                            iconColor: .purple
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(Color(.systemBackground))
        .navigationTitle("security".localized)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            checkBiometricType()
        }
    }
    
    private var biometricTitle: String {
        switch biometricType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "app_lock".localized
        }
    }
    
    private var biometricIcon: String {
        switch biometricType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        default: return "lock.fill"
        }
    }
    
    private func checkBiometricType() {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            biometricType = context.biometryType
        }
    }
    
    private func authenticateToToggle(enable: Bool) {
        let context = LAContext()
        context.localizedCancelTitle = "cancel".localized
        context.localizedFallbackTitle = "use_passcode".localized
        
        let reason = enable ? "enable_app_lock_reason".localized : "disable_app_lock_reason".localized
        
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            DispatchQueue.main.async {
                if success {
                    appLockEnabled = enable
                    Haptics.success()
                } else {
                    Haptics.error()
                }
            }
        }
    }
}

// MARK: - Settings Navigation Row
struct SettingsNavigationRow: View {
    let title: String
    var subtitle: String? = nil
    let icon: String
    let iconColor: Color

    var body: some View {
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
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.5))
        }
        .padding(14)
        .contentShape(Rectangle())
    }
}

// MARK: - Placeholder Views
struct ChangePasswordView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isSaving = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showCurrentPassword = false
    @State private var showNewPassword = false
    
    private var isFormValid: Bool {
        !currentPassword.isEmpty &&
        newPassword.count >= 8 &&
        newPassword == confirmPassword
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Current Password
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current Password")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    
                    HStack {
                        if showCurrentPassword {
                            TextField("Enter current password", text: $currentPassword)
                        } else {
                            SecureField("Enter current password", text: $currentPassword)
                        }
                        
                        Button {
                            showCurrentPassword.toggle()
                        } label: {
                            Image(systemName: showCurrentPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 16))
                    .padding(14)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                
                Divider()
                    .padding(.vertical, 8)
                
                // New Password
                VStack(alignment: .leading, spacing: 8) {
                    Text("New Password")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    
                    HStack {
                        if showNewPassword {
                            TextField("At least 8 characters", text: $newPassword)
                        } else {
                            SecureField("At least 8 characters", text: $newPassword)
                        }
                        
                        Button {
                            showNewPassword.toggle()
                        } label: {
                            Image(systemName: showNewPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 16))
                    .padding(14)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    
                    // Password strength indicator
                    if !newPassword.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(0..<4) { i in
                                Capsule()
                                    .fill(passwordStrengthColor(for: i))
                                    .frame(height: 4)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                
                // Confirm Password
                VStack(alignment: .leading, spacing: 8) {
                    Text("Confirm Password")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    
                    SecureField("Re-enter new password", text: $confirmPassword)
                        .font(.system(size: 16))
                        .padding(14)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    
                    // Match indicator
                    if !confirmPassword.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: newPassword == confirmPassword ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(newPassword == confirmPassword ? .green : .red)
                            Text(newPassword == confirmPassword ? "Passwords match" : "Passwords don't match")
                                .foregroundStyle(newPassword == confirmPassword ? .green : .red)
                        }
                        .font(.system(size: 12))
                    }
                }
                
                // Save Button
                Button {
                    Task {
                        await changePassword()
                    }
                } label: {
                    HStack {
                        if isSaving {
                            ProgressView()
                                .tint(.white)
                        }
                        Text("Change Password")
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(isFormValid ? Color.accentColor : Color.gray)
                    .clipShape(Capsule())
                }
                .disabled(!isFormValid || isSaving)
                .padding(.top, 16)
            }
            .padding(16)
        }
        .background(Color(.systemBackground))
        .navigationTitle("Change Password")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }
    
    private func passwordStrengthColor(for index: Int) -> Color {
        let strength = passwordStrength
        if index < strength {
            switch strength {
            case 1: return .red
            case 2: return .orange
            case 3: return .yellow
            default: return .green
            }
        }
        return Color(.systemGray4)
    }
    
    private var passwordStrength: Int {
        var score = 0
        if newPassword.count >= 8 { score += 1 }
        if newPassword.contains(where: { $0.isUppercase }) { score += 1 }
        if newPassword.contains(where: { $0.isNumber }) { score += 1 }
        if newPassword.contains(where: { !$0.isLetter && !$0.isNumber }) { score += 1 }
        return score
    }
    
    private func changePassword() async {
        isSaving = true
        defer { isSaving = false }
        
        do {
            let payload = ["current_password": currentPassword, "new_password": newPassword]
            let _: EmptyPasswordResponse = try await NetworkService.shared.post(
                path: "/api/users/change-password",
                body: payload
            )
            
            await MainActor.run {
                Haptics.success()
                dismiss()
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to change password"
                showError = true
                Haptics.error()
            }
        }
    }
}

private struct EmptyPasswordResponse: Decodable {}

struct TwoFactorView: View {
    @AppStorage("twoFactorEnabled") private var twoFactorEnabled = false
    @State private var showSetupSheet = false
    @State private var showDisableAlert = false
    @State private var verificationCode = ""
    @State private var isDisabling = false
    @State private var showError = false
    @State private var errorMessage = ""
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Status Card
                VStack(spacing: 16) {
                    Image(systemName: twoFactorEnabled ? "lock.shield.fill" : "lock.shield")
                        .font(.system(size: 50))
                        .foregroundStyle(twoFactorEnabled ? .green : .secondary)
                    
                    Text(twoFactorEnabled ? "2FA is Enabled" : "2FA is Disabled")
                        .font(.title2.weight(.semibold))
                    
                    Text(twoFactorEnabled 
                         ? "Your account is protected with an additional layer of security."
                         : "Add an extra layer of security to your account.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                
                // Toggle Button
                Button {
                    Haptics.light()
                    if twoFactorEnabled {
                        showDisableAlert = true
                    } else {
                        showSetupSheet = true
                    }
                } label: {
                    HStack {
                        if isDisabling {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(twoFactorEnabled ? "Disable 2FA" : "Enable 2FA")
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(twoFactorEnabled ? Color.red : Color.green)
                    .clipShape(Capsule())
                }
                .disabled(isDisabling)
                
                // Info Section
                if twoFactorEnabled {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Recovery Codes")
                            .font(.headline)
                        
                        Text("Make sure to save your recovery codes in a safe place. You'll need them if you lose access to your authenticator app.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                        Button {
                            Haptics.selection()
                            // Show recovery codes
                        } label: {
                            Text("View Recovery Codes")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(16)
        }
        .background(Color(.systemBackground))
        .navigationTitle("Two-Factor Auth")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSetupSheet) {
            TwoFactorSetupSheet(onComplete: {
                twoFactorEnabled = true
            })
        }
        .alert("Disable 2FA", isPresented: $showDisableAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Disable", role: .destructive) {
                Task { await disable2FA() }
            }
        } message: {
            Text("Are you sure you want to disable two-factor authentication? This will make your account less secure.")
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }
    
    private func disable2FA() async {
        isDisabling = true
        defer { isDisabling = false }
        
        do {
            let _: TwoFactorEmptyResponse = try await NetworkService.shared.post(
                path: "/api/users/2fa/disable",
                body: EmptyBody()
            )
            await MainActor.run {
                twoFactorEnabled = false
                Haptics.warning()
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to disable 2FA. Please try again."
                showError = true
                Haptics.error()
            }
        }
    }
}

// MARK: - Two Factor Setup Sheet
struct TwoFactorSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onComplete: () -> Void
    
    @State private var step = 1
    @State private var verificationCode = ""
    @State private var isVerifying = false
    @State private var isLoadingSetup = true
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var secret = ""
    @State private var provisioningUri = ""
    @State private var recoveryCodes: [String] = []
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if isLoadingSetup {
                    ProgressView("Setting up 2FA...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if step == 1 {
                    // Step 1: Show QR Code
                    VStack(spacing: 16) {
                        Text("Scan this QR code with your authenticator app")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        
                        // Generate QR code from provisioning URI
                        if let qrImage = generateQRCode(from: provisioningUri) {
                            Image(uiImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 200, height: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        } else {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color(.systemGray5))
                                .frame(width: 200, height: 200)
                                .overlay(
                                    Image(systemName: "qrcode")
                                        .font(.system(size: 80))
                                        .foregroundStyle(.secondary)
                                )
                        }
                        
                        Text("Or enter this code manually:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                        Text(secret)
                            .font(.system(.body, design: .monospaced))
                            .padding(12)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .textSelection(.enabled)
                        
                        Button {
                            step = 2
                        } label: {
                            Text("Next")
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.accentColor)
                                .clipShape(Capsule())
                        }
                    }
                } else {
                    // Step 2: Verify Code
                    VStack(spacing: 16) {
                        Text("Enter the code from your authenticator app")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        
                        TextField("000000", text: $verificationCode)
                            .font(.system(size: 32, weight: .bold, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .keyboardType(.numberPad)
                            .padding(16)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .frame(maxWidth: 200)
                        
                        Button {
                            Task { await verifyAndEnable() }
                        } label: {
                            HStack {
                                if isVerifying {
                                    ProgressView()
                                        .tint(.white)
                                }
                                Text("Verify & Enable")
                                    .fontWeight(.semibold)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(verificationCode.count == 6 && !isVerifying ? Color.green : Color.gray)
                            .clipShape(Capsule())
                        }
                        .disabled(verificationCode.count != 6 || isVerifying)
                    }
                }
                
                Spacer()
            }
            .padding(24)
            .navigationTitle("Setup 2FA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                await fetchSetup()
            }
            .alert("Verification Failed", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }
    
    private func fetchSetup() async {
        isLoadingSetup = true
        defer { isLoadingSetup = false }
        
        do {
            let response: TwoFactorSetupResponse = try await NetworkService.shared.post(
                path: "/api/users/2fa/setup",
                body: EmptyBody()
            )
            await MainActor.run {
                secret = response.secret
                provisioningUri = response.provisioningUri
                recoveryCodes = response.recoveryCodes ?? []
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to set up 2FA. Please try again."
                showError = true
            }
        }
    }
    
    private func generateQRCode(from string: String) -> UIImage? {
        guard let data = string.data(using: .ascii),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ciImage = filter.outputImage else { return nil }
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = ciImage.transformed(by: transform)
        return UIImage(ciImage: scaledImage)
    }
    
    private func verifyAndEnable() async {
        isVerifying = true
        defer { isVerifying = false }
        
        do {
            let payload = TwoFactorVerifyPayload(code: verificationCode)
            let _: TwoFactorEmptyResponse = try await NetworkService.shared.post(
                path: "/api/users/2fa/verify",
                body: payload
            )
            await MainActor.run {
                onComplete()
                Haptics.success()
                dismiss()
            }
        } catch {
            await MainActor.run {
                errorMessage = "Invalid code. Please check your authenticator app and try again."
                showError = true
                verificationCode = ""
                Haptics.error()
            }
        }
    }
}

private struct TwoFactorSetupResponse: Decodable {
    let secret: String
    let provisioningUri: String
    let recoveryCodes: [String]?
}

private struct TwoFactorVerifyPayload: Encodable {
    let code: String
}

private struct TwoFactorEmptyResponse: Decodable {}

private struct EmptyBody: Encodable {}

// MARK: - Active Sessions View
struct ActiveSessionsView: View {
    @State private var sessions: [Session] = []
    @State private var isLoading = true
    @State private var showRevokeAlert = false
    @State private var sessionToRevoke: Session?
    @State private var showRevokeAllAlert = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if isLoading {
                    ForEach(0..<3, id: \.self) { _ in
                        SessionSkeletonView()
                    }
                } else if sessions.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "iphone.slash")
                            .font(.system(size: 50))
                            .foregroundStyle(.secondary)
                        Text("No active sessions")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 60)
                } else {
                    // Current Session
                    if let current = sessions.first(where: { $0.isCurrent }) {
                        SessionCard(session: current, isCurrent: true) {}
                    }
                    
                    // Other Sessions
                    let otherSessions = sessions.filter { !$0.isCurrent }
                    if !otherSessions.isEmpty {
                        Text("Other Sessions")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 16)
                        
                        ForEach(otherSessions) { session in
                            SessionCard(session: session, isCurrent: false) {
                                sessionToRevoke = session
                                showRevokeAlert = true
                            }
                        }
                    }
                    
                    // Revoke All Button
                    if otherSessions.count > 1 {
                        Button {
                            Haptics.warning()
                            showRevokeAllAlert = true
                        } label: {
                            Text("Revoke All Other Sessions")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.red)
                        }
                        .padding(.top, 16)
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemBackground))
        .navigationTitle("Active Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await fetchSessions()
        }
        .refreshable {
            await fetchSessions()
        }
        .alert("Revoke Session", isPresented: $showRevokeAlert, presenting: sessionToRevoke) { session in
            Button("Cancel", role: .cancel) {}
            Button("Revoke", role: .destructive) {
                Task {
                    await revokeSession(session)
                }
            }
        } message: { session in
            Text("'\(session.deviceName)' will be logged out immediately.")
        }
        .alert("Revoke All Sessions", isPresented: $showRevokeAllAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Revoke All", role: .destructive) {
                Task {
                    await revokeAllOtherSessions()
                }
            }
        } message: {
            Text("All other devices will be logged out immediately.")
        }
    }
    
    private func fetchSessions() async {
        isLoading = true
        
        do {
            let response: [Session] = try await NetworkService.shared.get(path: "/api/users/sessions")
            await MainActor.run {
                sessions = response
                isLoading = false
            }
            #if DEBUG
            print("📱 Fetched \(response.count) active sessions")
            #endif
        } catch {
            // Fallback to current session only on error
            await MainActor.run {
                sessions = [
                    Session(
                        id: "current",
                        deviceName: UIDevice.current.name,
                        location: "Current Device",
                        lastActive: Date(),
                        isCurrent: true,
                        platform: "iOS"
                    )
                ]
                isLoading = false
            }
            #if DEBUG
            print("⚠️ Failed to fetch sessions: \(error)")
            #endif
        }
    }
    
    private func revokeSession(_ session: Session) async {
        do {
            let _: EmptySessionResponse = try await NetworkService.shared.delete(
                path: "/api/users/sessions/\(session.id)"
            )
            
            await MainActor.run {
                sessions.removeAll { $0.id == session.id }
                Haptics.success()
            }
            #if DEBUG
            print("✅ Revoked session: \(session.deviceName)")
            #endif
        } catch {
            #if DEBUG
            print("❌ Failed to revoke session: \(error)")
            #endif
            await MainActor.run {
                Haptics.error()
            }
        }
    }
    
    private func revokeAllOtherSessions() async {
        do {
            let _: EmptySessionResponse = try await NetworkService.shared.delete(
                path: "/api/users/sessions/all"
            )
            
            await MainActor.run {
                sessions.removeAll { !$0.isCurrent }
                Haptics.success()
            }
            #if DEBUG
            print("✅ Revoked all other sessions")
            #endif
        } catch {
            #if DEBUG
            print("❌ Failed to revoke all sessions: \(error)")
            #endif
            await MainActor.run {
                Haptics.error()
            }
        }
    }
}

private struct EmptySessionResponse: Decodable {}


// MARK: - Session Model
struct Session: Identifiable, Codable {
    let id: String
    let deviceName: String
    let location: String
    let lastActive: Date
    let isCurrent: Bool
    let platform: String
    
    enum CodingKeys: String, CodingKey {
        case id
        case deviceName = "device_name"
        case location
        case lastActive = "last_active"
        case isCurrent = "is_current"
        case platform
    }
    
    var platformIcon: String {
        switch platform {
        case "iOS": return "iphone"
        case "iPadOS": return "ipad"
        case "macOS": return "laptopcomputer"
        case "Web": return "globe"
        default: return "desktopcomputer"
        }
    }
}

// MARK: - Session Card
struct SessionCard: View {
    let session: Session
    let isCurrent: Bool
    let onRevoke: () -> Void
    
    var body: some View {
        HStack(spacing: 14) {
            // Device Icon
            Circle()
                .fill(isCurrent ? Color.green.opacity(0.15) : Color(.systemGray5))
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: session.platformIcon)
                        .font(.system(size: 20))
                        .foregroundStyle(isCurrent ? .green : .secondary)
                )
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(session.deviceName)
                        .font(.system(size: 16, weight: .medium))
                    
                    if isCurrent {
                        Text("Current")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green)
                            .clipShape(Capsule())
                    }
                }
                
                Text(session.location)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                
                Text(session.lastActive, style: .relative)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            
            Spacer()
            
            if !isCurrent {
                Button {
                    Haptics.light()
                    onRevoke()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.red.opacity(0.7))
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Session Skeleton View
struct SessionSkeletonView: View {
    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(Color(.systemGray5))
                .frame(width: 44, height: 44)
            
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(.systemGray5))
                    .frame(width: 120, height: 14)
                
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(.systemGray6))
                    .frame(width: 80, height: 12)
            }
            
            Spacer()
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Preview
#Preview {
    NavigationStack {
        SecuritySettingsView()
    }
}
