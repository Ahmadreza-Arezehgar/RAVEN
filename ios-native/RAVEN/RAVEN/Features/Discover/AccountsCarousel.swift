import SwiftUI

/// Horizontal carousel of account search results
struct AccountsCarousel: View {
    let accounts: [SearchUser]
    let isLoading: Bool
    let errorMessage: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section header
            Text(accounts.isEmpty && !isLoading ? "Suggested People" : "Accounts")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 16)
            
            // Content
            if isLoading && accounts.isEmpty {
                loadingView
            } else if accounts.isEmpty {
                emptyStateView
            } else {
                accountsList
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    // MARK: - Accounts List
    private var accountsList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 16) {
                ForEach(accounts) { account in
                    NavigationLink(value: ProfileRoute(userId: account.id)) {
                        accountItem(account)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }
    
    // MARK: - Account Item
    private func accountItem(_ account: SearchUser) -> some View {
        VStack(spacing: 6) {
            // Avatar
            AsyncImage(url: AppConfig.mediaURL(from: account.avatarUrl)) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Circle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay {
                        Text(String(account.username.prefix(1)).uppercased())
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
            }
            .frame(width: 56, height: 56)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
            
            // Username
            HStack(spacing: 2) {
                Text("@\(account.username)")
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    
                if account.verifiedStatus {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.blue)
                }
                if account.premiumStatus {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color(red: 0.85, green: 0.70, blue: 0.35))
                }
            }
            
            // Display name (optional)
            if let displayName = account.displayName, !displayName.isEmpty {
                Text(displayName)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            // Mutual badge (optional)
            if account.isMutual == true {
                Text("Mutual")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.8))
                    .clipShape(Capsule())
            }
        }
        .frame(width: 80)
    }
    
    // MARK: - Loading View
    private var loadingView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(0..<5, id: \.self) { _ in
                    AccountSkeletonView()
                }
            }
            .padding(.horizontal, 16)
        }
    }
    
    // MARK: - Empty State
    private var emptyStateView: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary)
                
                Text("No accounts found")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 20)
    }
}

#Preview {
    NavigationStack {
        VStack {
            AccountsCarousel(
                accounts: [
                    SearchUser(id: "1", username: "john", displayName: "John Doe", avatarUrl: nil, isMutual: true, isVerified: true, isPremium: false),
                    SearchUser(id: "2", username: "jane", displayName: "Jane Smith", avatarUrl: nil, isMutual: false, isVerified: false, isPremium: true),
                    SearchUser(id: "3", username: "bob", displayName: nil, avatarUrl: nil, isMutual: nil, isVerified: false, isPremium: false)
                ],
                isLoading: false,
                errorMessage: nil
            )
            .frame(height: 150)
            
            Divider()
            
            AccountsCarousel(accounts: [], isLoading: true, errorMessage: nil)
                .frame(height: 150)
            
            Divider()
            
            AccountsCarousel(accounts: [], isLoading: false, errorMessage: nil)
                .frame(height: 150)
        }
    }
}
