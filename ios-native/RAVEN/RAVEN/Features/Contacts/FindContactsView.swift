import SwiftUI
import Contacts

// MARK: - Find Contacts View
/// Displays contacts with Raven status and invite functionality
struct FindContactsView: View {
    @State private var contactsService = ContactsService.shared
    @State private var searchText = ""
    @State private var showInviteSheet = false
    @State private var inviteContact: LocalContact?
    @State private var invitedContacts: Set<String> = []
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Group {
                switch contactsService.permissionStatus {
                case .notDetermined:
                    permissionRequestView
                case .authorized:
                    contactsListView
                case .denied, .restricted:
                    permissionDeniedView
                }
            }
            .navigationTitle("Find Friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            loadInvitedState()
        }
    }
    
    // MARK: - Permission Request View
    
    private var permissionRequestView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // Icon
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(.blue.gradient)
            
            // Title
            Text("Find Friends on Raven")
                .font(.title2)
                .fontWeight(.bold)
            
            // Description
            Text("Allow Raven to access your contacts to find friends who are already using the app.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            Spacer()
            
            // Buttons
            VStack(spacing: 12) {
                Button {
                    Task {
                        let granted = await contactsService.requestPermission()
                        if granted {
                            await contactsService.loadContacts()
                            await contactsService.syncWithServer()
                        }
                    }
                } label: {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Capsule())
                
                Button {
                    dismiss()
                } label: {
                    Text("Not Now")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }
    
    // MARK: - Permission Denied View
    
    private var permissionDeniedView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            // Glass card
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                
                Text("Access Denied")
                    .font(.headline)
                
                Text("Enable Contacts access in Settings to find friends on Raven.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open Settings", systemImage: "gear")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Capsule())
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
            .padding(.horizontal, 24)
            
            Spacer()
        }
    }
    
    // MARK: - Contacts List View
    
    private var contactsListView: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search contacts", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            if contactsService.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Searching contacts…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    // On Raven section
                    if !matchedContacts.isEmpty {
                        Section {
                            ForEach(matchedContacts) { match in
                                matchedContactRow(match)
                            }
                        } header: {
                            Text("On Raven")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    // Not on Raven section
                    if !notOnRavenContacts.isEmpty {
                        Section {
                            ForEach(notOnRavenContacts) { contact in
                                localContactRow(contact)
                            }
                        } header: {
                            Text("Invite to Raven")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(TapGesture().onEnded { hideKeyboard() })
            }
        }
        .onTapGesture { hideKeyboard() }
        .task {
            if contactsService.contacts.isEmpty {
                await contactsService.loadContacts()
                await contactsService.syncWithServer()
            }
        }
        .refreshable {
            await contactsService.syncWithServer()
        }
        .sheet(isPresented: $showInviteSheet) {
            if let contact = inviteContact {
                ShareSheet(items: [
                    "Hey! Join me on RAVEN — a private messenger that works even offline. Download it here: https://ravenapp.dev/download"
                ])
                    .onDisappear {
                        // Mark as invited
                        contactsService.markInvited(contact)
                        if let phone = contact.phoneNormalized {
                            invitedContacts.insert(phone)
                        }
                    }
            }
        }
    }
    
    // MARK: - Contact Rows
    
    private func matchedContactRow(_ match: MatchedContact) -> some View {
        HStack(spacing: 12) {
            // Avatar
            GlassAvatar(
                name: match.displayName,
                path: match.avatarUrl,
                size: 44,
                showGlow: false
            )
            
            // Name & username
            VStack(alignment: .leading, spacing: 2) {
                Text(match.displayName)
                    .font(.headline)
                
                if !match.username.isEmpty {
                    Text("@\(match.username)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            // Badge + Message button
            HStack(spacing: 8) {
                Text("On Raven")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.green.opacity(0.15), in: Capsule())
                
                Button {
                    // TODO: Open chat with user
                    startConversation(userId: match.userId)
                } label: {
                    Text("Message")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.blue.gradient, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
    
    private func localContactRow(_ contact: LocalContact) -> some View {
        let isInvited = invitedContacts.contains(contact.phoneNormalized ?? "") || contactsService.isInvited(contact)
        
        return HStack(spacing: 12) {
            // Avatar with initials
            Circle()
                .fill(.gray.opacity(0.3))
                .frame(width: 44, height: 44)
                .overlay {
                    Text(contact.initials)
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
            
            // Name & phone
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName)
                    .font(.headline)
                
                if let phone = contact.phone {
                    Text(phone)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            // Invite button
            Button {
                if !isInvited {
                    inviteContact = contact
                    showInviteSheet = true
                }
            } label: {
                Text(isInvited ? "Invited" : "Invite")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(isInvited ? .secondary : Color.blue)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        isInvited ? Color.gray.opacity(0.2) : Color.blue.opacity(0.15),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .disabled(isInvited)
        }
        .padding(.vertical, 4)
    }
    
    // MARK: - Computed Properties
    
    private var matchedContacts: [MatchedContact] {
        let matches = contactsService.matches
        if searchText.isEmpty { return matches }
        return matches.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }
    
    private var notOnRavenContacts: [LocalContact] {
        // Get all matched user IDs
        let matchedPhones = Set(contactsService.matches.compactMap { $0.localContact?.phoneNormalized })
        
        // Filter out matched contacts
        let notMatched = contactsService.contacts.filter { contact in
            guard let phone = contact.phoneNormalized else { return true }
            return !matchedPhones.contains(phone)
        }
        
        if searchText.isEmpty { return notMatched }
        return notMatched.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }
    
    // MARK: - Helpers
    
    private func loadInvitedState() {
        let invited = contactsService.loadInvited()
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        invitedContacts = Set(invited.filter { $0.value > sevenDaysAgo }.keys)
    }
    
    private func startConversation(userId: String) {
        dismiss()
        // Wait for sheet dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            DeepLinkRouter.shared.navigate(to: .newChat(userId: userId))
        }
    }
}

// Note: ShareSheet is defined in FullScreenImageViewer.swift

#Preview {
    FindContactsView()
}
