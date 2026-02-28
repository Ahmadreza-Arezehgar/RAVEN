// RAVEN - Contacts View
// Converted from Flutter contact_picker_page.dart

import SwiftUI

struct ContactsView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var showAddContact = false
    @State private var selectedSection: ContactSection = .all
    
    enum ContactSection: String, CaseIterable {
        case all = "All"
        case favorites = "Favorites"
        case blocked = "Blocked"
    }
    
    var filteredContacts: [Contact] {
        var contacts = appState.contacts
        
        switch selectedSection {
        case .favorites:
            contacts = contacts.filter { $0.isFavorite }
        case .blocked:
            contacts = contacts.filter { $0.isBlocked }
        case .all:
            contacts = contacts.filter { !$0.isBlocked }
        }
        
        if !searchText.isEmpty {
            contacts = contacts.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText) ||
                $0.username.localizedCaseInsensitiveContains(searchText)
            }
        }
        
        return contacts.sorted { $0.displayName < $1.displayName }
    }
    
    var groupedContacts: [(String, [Contact])] {
        Dictionary(grouping: filteredContacts) { contact in
            String(contact.displayName.prefix(1)).uppercased()
        }
        .sorted { $0.key < $1.key }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Segment picker
                Picker("Section", selection: $selectedSection) {
                    ForEach(ContactSection.allCases, id: \.self) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding()
                
                // Search
                SearchBar(text: $searchText, placeholder: "Search contacts...")
                    .padding(.horizontal)
                
                // List
                if filteredContacts.isEmpty {
                    ContentUnavailableView(
                        "No Contacts",
                        systemImage: "person.crop.circle.badge.plus",
                        description: Text(searchText.isEmpty ? "Add contacts to get started" : "No matches found")
                    )
                } else {
                    List {
                        ForEach(groupedContacts, id: \.0) { letter, contacts in
                            Section(letter) {
                                ForEach(contacts) { contact in
                                    NavigationLink {
                                        ChatView(recipientId: contact.userId, recipientName: contact.effectiveName)
                                    } label: {
                                        ContactRow(contact: contact)
                                    }
                                    // 🚀 Swipe to block/unblock
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: contact.isBlocked ? .cancel : .destructive) {
                                            Task {
                                                await appState.toggleBlockStatus(
                                                    userId: contact.userId,
                                                    username: contact.username,
                                                    displayName: contact.displayName,
                                                    avatarUrl: contact.avatarUrl,
                                                    isCurrentlyBlocked: contact.isBlocked
                                                )
                                            }
                                        } label: {
                                            Label(contact.isBlocked ? "Unblock" : "Block", systemImage: contact.isBlocked ? "hand.raised.slash.fill" : "hand.raised.fill")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Contacts")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showAddContact = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                }
            }
            .sheet(isPresented: $showAddContact) {
                AddContactView()
            }
            .onAppear {
                Task {
                    await appState.loadContacts()
                }
            }
        }
    }
}

// MARK: - Contact Row
struct ContactRow: View {
    let contact: Contact
    
    var body: some View {
        HStack(spacing: 12) {
            AvatarView(url: contact.avatarUrl, name: contact.displayName, size: 44)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(contact.effectiveName)
                        .font(.headline)
                    
                    if contact.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundColor(.yellow)
                    }
                }
                
                Text("@\(contact.username)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Add Contact View
struct AddContactView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var searchResults: [User] = []
    @State private var isSearching = false
    
    var body: some View {
        NavigationStack {
            VStack {
                SearchBar(text: $searchText, placeholder: "Search by username...")
                    .padding()
                    .onChange(of: searchText) { _, newValue in
                        performSearch(newValue)
                    }
                
                if isSearching {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if searchResults.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView("No Users Found", systemImage: "person.slash", description: Text("Try a different username"))
                } else if !searchResults.isEmpty {
                    List(searchResults) { user in
                        HStack(spacing: 12) {
                            AvatarView(url: user.avatarUrl, name: user.displayName, size: 44)
                            
                            VStack(alignment: .leading) {
                                Text(user.displayName)
                                    .font(.headline)
                                Text("@\(user.username)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Button {
                                addContact(user)
                            } label: {
                                Image(systemName: "person.badge.plus")
                                    .foregroundColor(.ravenPrimary)
                            }
                        }
                    }
                    .listStyle(.plain)
                } else {
                    ContentUnavailableView("Search Users", systemImage: "magnifyingglass", description: Text("Find users by their username"))
                }
            }
            .navigationTitle("Add Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    func performSearch(_ query: String) {
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        
        isSearching = true
        
        Task {
            searchResults = await appState.searchUsers(query)
            isSearching = false
        }
    }
    
    func addContact(_ user: User) {
        let contact = Contact(
            userId: user.id,
            username: user.username,
            displayName: user.displayName,
            avatarUrl: user.avatarUrl
        )
        
        Task {
            await DatabaseService.shared.insertContact(contact)
            await appState.loadContacts()
            dismiss()
        }
    }
}

#Preview {
    ContactsView()
        .environmentObject(AppState())
        .preferredColorScheme(.dark)
}
