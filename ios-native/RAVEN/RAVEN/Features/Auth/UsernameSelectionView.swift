import SwiftUI

// MARK: - Username Selection View
// Shown after OAuth when user needs to set a username

struct UsernameSelectionView: View {
    @State private var authService = AuthService.shared
    @State private var username = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isAvailable: Bool?
    @State private var checkTask: Task<Void, Never>?
    
    private var isValidUsername: Bool {
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 3 && 
               trimmed.count <= 20 &&
               trimmed.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
    
    var body: some View {
        VStack(spacing: 32) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "at.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)
                
                Text("Choose a Username")
                    .font(.title.bold())
                
                Text("This is how others will find you on RAVEN")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 40)
            
            // Username input
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("@")
                        .font(.title2.bold())
                        .foregroundStyle(.secondary)
                    
                    TextField("username", text: $username)
                        .font(.title2)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: username) { _, newValue in
                            // Cancel previous check
                            checkTask?.cancel()
                            isAvailable = nil
                            
                            // Debounce username check
                            checkTask = Task {
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                guard !Task.isCancelled else { return }
                                await checkUsername()
                            }
                        }
                    
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else if let available = isAvailable {
                        Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(available ? .green : .red)
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                
                // Validation hint
                if !username.isEmpty {
                    if !isValidUsername {
                        Text("3-20 characters, letters, numbers, and underscores only")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if isAvailable == false {
                        Text("This username is taken")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if isAvailable == true {
                        Text("Username is available!")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
            .padding(.horizontal)
            
            // Error message
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
            
            Spacer()
            
            // Continue button
            Button {
                Task { await setUsername() }
            } label: {
                HStack {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("Continue")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(canContinue ? Color.blue : Color.gray)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(!canContinue || isLoading)
            .padding(.horizontal)
            .padding(.bottom)
        }
        .onTapGesture { hideKeyboard() }
    }
    
    // Allow continue if username is valid (backend validates on submit)
    private var canContinue: Bool {
        isValidUsername
    }
    
    private func checkUsername() async {
        guard isValidUsername else {
            isAvailable = nil
            return
        }
        
        do {
            isAvailable = try await authService.checkUsernameAvailability(username)
        } catch {
            // API might not exist - allow user to try anyway
            isAvailable = nil
        }
    }
    
    private func setUsername() async {
        isLoading = true
        errorMessage = nil
        
        do {
            try await authService.setUsername(username)
            // AuthGate will handle navigation
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }
}

#Preview {
    UsernameSelectionView()
}

