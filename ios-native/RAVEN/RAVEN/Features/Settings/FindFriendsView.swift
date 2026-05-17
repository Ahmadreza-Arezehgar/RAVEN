import SwiftUI

/// View for finding friends from contacts
struct FindFriendsView: View {
    @State private var contactsService = ContactsService.shared
    @State private var errorMessage: String?
    @State private var allowDiscovery = true
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                switch contactsService.permissionStatus {
                case .notDetermined:
                    prePermissionView
                    
                case .denied, .restricted:
                    deniedView
                    
                case .authorized:
                    if contactsService.isLoading {
                        loadingView
                    } else if contactsService.matches.isEmpty {
                        emptyView
                    } else {
                        matchesView
                    }
                }
                
                Spacer()
            }
            .padding()
        }
        .navigationTitle("Find Friends")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            contactsService.updatePermissionStatus()
            if contactsService.permissionStatus == .authorized {
                await contactsService.syncWithServer()
            }
        }
        // BUG FIX (2026-05-10): replaced `.constant(...)` with a real
        // two-way binding. `.constant` only re-evaluates on body
        // recompute, so SwiftUI could see `isPresented=true` again on
        // the next pass after the OK button niled errorMessage,
        // flickering the alert open/closed/open. The custom Binding
        // forwards the dismiss directly into the source-of-truth.
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
    
    // MARK: - Pre-Permission View
    
    private var prePermissionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.2.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.blue.gradient)
            
            Text("Find Friends on Raven")
                .font(.title2.bold())
            
            VStack(alignment: .leading, spacing: 12) {
                FindFriendsFeatureRow(icon: "checkmark.shield.fill", title: "Your contacts are never stored in plain text")
                FindFriendsFeatureRow(icon: "lock.fill", title: "Only hashed data is sent to our servers")
                FindFriendsFeatureRow(icon: "xmark.circle.fill", title: "You can remove your data anytime")
            }
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            
            Button {
                Task { await requestPermission() }
            } label: {
                HStack {
                    Image(systemName: "person.crop.circle.badge.plus")
                    Text("Sync Contacts")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(.blue.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            
            Text("We'll check which of your contacts are on Raven.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 40)
    }
    
    // MARK: - Denied View
    
    private var deniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            
            Text("Contacts Access Denied")
                .font(.title2.bold())
            
            Text("Enable contacts access in Settings to find friends on Raven.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.top, 40)
    }
    
    // MARK: - Loading View
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            
            Text("Searching for friends...")
                .foregroundColor(.secondary)
        }
        .padding(.top, 60)
    }
    
    // MARK: - Empty View
    
    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("No Friends Found")
                .font(.title2.bold())
            
            Text("None of your contacts are on Raven yet. Invite them!")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
            Button {
                Task { await contactsService.syncWithServer() }
            } label: {
                Label("Sync Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
        .padding(.top, 40)
    }
    
    // MARK: - Matches View
    
    private var matchesView: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Friends on Raven")
                    .font(.headline)
                Spacer()
                Text("\(contactsService.matches.count) found")
                    .foregroundColor(.secondary)
            }
            
            LazyVStack(spacing: 12) {
                ForEach(contactsService.matches) { match in
                    FindFriendMatchRow(match: match)
                }
            }
            
            Divider()
                .padding(.vertical)
            
            Button {
                Task { await contactsService.syncWithServer() }
            } label: {
                Label("Sync Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
    }
    
    // MARK: - Actions
    
    private func requestPermission() async {
        let granted = await contactsService.requestPermission()
        if granted {
            await contactsService.syncWithServer()
        }
    }
}

// MARK: - Supporting Views

/// Feature row unique to FindFriendsView (avoids collision with AuthGateView's FeatureRow)
private struct FindFriendsFeatureRow: View {
    let icon: String
    let title: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 24)
            Text(title)
                .font(.subheadline)
        }
    }
}

/// Row for displaying a matched contact
private struct FindFriendMatchRow: View {
    let match: MatchedContact
    @State private var isSendingRequest = false
    @State private var requestSent = false
    
    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            AsyncImage(url: match.avatarUrl.flatMap { URL(string: $0) }) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(.gray.opacity(0.2))
                    .overlay {
                        Text(match.displayName.prefix(1).uppercased())
                            .font(.headline)
                            .foregroundColor(.gray)
                    }
            }
            .frame(width: 48, height: 48)
            .clipShape(Circle())
            
            // Name
            VStack(alignment: .leading, spacing: 2) {
                Text(match.displayName)
                    .font(.headline)
                Text("@\(match.username)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Add Friend Button
            Button {
                sendFriendRequest()
            } label: {
                if isSendingRequest {
                    ProgressView()
                } else if requestSent {
                    Image(systemName: "checkmark")
                        .foregroundColor(.green)
                } else {
                    Image(systemName: "person.badge.plus")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isSendingRequest || requestSent)
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    private func sendFriendRequest() {
        // ⚡ Optimistic: immediately show success checkmark
        requestSent = true
        Haptics.success()
        
        Task {
            do {
                let _: Empty = try await NetworkService.shared.post(
                    path: "/api/users/friend-request?recipient_id=\(match.userId)",
                    body: EmptyBody()
                )
                // Server confirmed — keep requestSent = true
            } catch {
                // Rollback on failure
                await MainActor.run {
                    requestSent = false
                    Haptics.error()
                }
                #if DEBUG
                print("❌ [FindFriends] Failed to send friend request: \(error)")
                #endif
            }
        }
    }
}

private struct EmptyBody: Encodable {}

#Preview {
    NavigationStack {
        FindFriendsView()
    }
}
