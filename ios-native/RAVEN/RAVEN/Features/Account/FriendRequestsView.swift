import SwiftUI

// MARK: - Friend Request Model
struct FriendRequest: Identifiable, Codable {
    let id: String
    let requesterId: String
    let requesterUsername: String
    let requesterAvatar: String?
    let recipientId: String
    let status: String
    let createdAt: Date
}

// MARK: - Accept/Reject Response
private struct AcceptResponse: Codable {
    let message: String
    let friendId: String?
    let friendUsername: String?
    let friendAvatar: String?
}

private struct RejectResponse: Codable {
    let message: String
}

// MARK: - Friend Requests Store
@MainActor
final class FriendRequestsStore: ObservableObject {
    @Published var requests: [FriendRequest] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private let networkService = NetworkService.shared
    
    func fetchRequests() async {
        isLoading = true
        errorMessage = nil
        
        do {
            requests = try await networkService.get(path: "/api/users/friend-requests")
            #if DEBUG
            print("📥 Fetched \(requests.count) pending friend requests")
            #endif
        } catch {
            errorMessage = "Failed to load requests: \(error.localizedDescription)"
            #if DEBUG
            print("❌ Friend requests fetch error: \(error)")
            #endif
        }
        
        isLoading = false
    }
    
    func acceptRequest(_ request: FriendRequest) async -> Bool {
        // ⚡ Optimistic: remove from list immediately
        let backup = requests
        requests.removeAll { $0.id == request.id }
        Haptics.success()
        
        do {
            let response: AcceptResponse = try await networkService.post(
                path: "/api/users/friend-request/\(request.id)/accept",
                body: EmptyBody()
            )
            #if DEBUG
            print("✅ Accepted friend request from \(request.requesterUsername)")
            #endif
            return true
        } catch {
            // Rollback on failure
            requests = backup
            errorMessage = "Failed to accept: \(error.localizedDescription)"
            Haptics.error()
            #if DEBUG
            print("❌ Accept error: \(error)")
            #endif
            return false
        }
    }
    
    func rejectRequest(_ request: FriendRequest) async -> Bool {
        // ⚡ Optimistic: remove from list immediately
        let backup = requests
        requests.removeAll { $0.id == request.id }
        Haptics.success()
        
        do {
            let _: RejectResponse = try await networkService.post(
                path: "/api/users/friend-request/\(request.id)/reject",
                body: EmptyBody()
            )
            #if DEBUG
            print("❌ Rejected friend request from \(request.requesterUsername)")
            #endif
            return true
        } catch {
            // Rollback on failure
            requests = backup
            errorMessage = "Failed to reject: \(error.localizedDescription)"
            Haptics.error()
            #if DEBUG
            print("❌ Reject error: \(error)")
            #endif
            return false
        }
    }
}

// MARK: - Empty Body for POST
private struct EmptyBody: Encodable {}

// MARK: - Friend Requests View (Liquid Glass)
struct FriendRequestsView: View {
    @StateObject private var store = FriendRequestsStore()
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                Color.black.opacity(0.9)
                    .ignoresSafeArea()
                
                if store.isLoading {
                    ProgressView()
                        .scaleEffect(1.2)
                } else if store.requests.isEmpty {
                    emptyState
                } else {
                    requestsList
                }
            }
            .navigationTitle("Friend Requests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await store.fetchRequests()
            }
            .refreshable {
                await store.fetchRequests()
            }
        }
        .preferredColorScheme(.dark)
    }
    
    // MARK: - Requests List
    private var requestsList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(store.requests) { request in
                    FriendRequestCard(
                        request: request,
                        onAccept: {
                            Task {
                                await store.acceptRequest(request)
                            }
                        },
                        onReject: {
                            Task {
                                await store.rejectRequest(request)
                            }
                        }
                    )
                }
            }
            .padding()
        }
    }
    
    // MARK: - Empty State
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text("No Friend Requests")
                .font(.title3.weight(.semibold))
                .foregroundColor(.primary)
            
            Text("When someone sends you a friend request, it will appear here")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}

// MARK: - Friend Request Card (Liquid Glass)
struct FriendRequestCard: View {
    let request: FriendRequest
    let onAccept: () -> Void
    let onReject: () -> Void
    
    @State private var isAccepting = false
    @State private var isRejecting = false
    
    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            AsyncImage(url: URL(string: request.requesterAvatar ?? "")) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure, .empty:
                    Image(systemName: "person.circle.fill")
                        .resizable()
                        .foregroundColor(.secondary)
                @unknown default:
                    Color.gray
                }
            }
            .frame(width: 50, height: 50)
            .clipShape(Circle())
            
            // Username & Time
            VStack(alignment: .leading, spacing: 4) {
                Text(request.requesterUsername)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                
                Text(timeAgo(from: request.createdAt))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Actions
            HStack(spacing: 8) {
                // Reject
                Button {
                    isRejecting = true
                    onReject()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.red)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                .disabled(isRejecting || isAccepting)
                .opacity(isRejecting ? 0.5 : 1)
                
                // Accept
                Button {
                    isAccepting = true
                    onAccept()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.green)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                .disabled(isAccepting || isRejecting)
                .opacity(isAccepting ? 0.5 : 1)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.15), lineWidth: 0.6)
        )
    }
    
    // Simple time ago formatter
    private func timeAgo(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        
        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let mins = Int(interval / 60)
            return "\(mins)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }
}

// MARK: - Preview
#Preview {
    FriendRequestsView()
        .preferredColorScheme(.dark)
}
