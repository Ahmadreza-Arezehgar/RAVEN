import Foundation
import SwiftUI

// MARK: - Deep Link Router
// Handles navigation from push notifications, universal links, etc.

@Observable
class DeepLinkRouter {
    static let shared = DeepLinkRouter()
    
    var pendingDestination: Destination?
    var currentChatRoomId: String?
    
    private init() {}
    
    // MARK: - Destinations
    
    enum Destination: Equatable {
        case chat(roomId: String)
        case newChat(userId: String) // Start a new chat with a user
        case profile(userId: String)
        case friendRequests
        case notifications
        case security
        case settings
        case inbox
        case audioRoom(slug: String)  // raven://room/{slug} - audio room deep link
        case post(postId: String)     // FIX: Navigate to post from like/comment notifications
    }
    
    // MARK: - Navigate (alias for route)
    
    @MainActor
    func navigate(to destination: Destination) {
        route(to: destination)
    }
    
    // MARK: - Route
    
    @MainActor
    func route(to destination: Destination) {
        // If app is not ready, store pending destination
        guard AuthService.shared.isAuthenticated else {
            pendingDestination = destination
            return
        }
        
        // Store for later consumption by UI
        pendingDestination = destination
        
        // Post notification for UI to react
        NotificationCenter.default.post(
            name: .deepLinkReceived,
            object: destination
        )
    }
    
    // MARK: - Consume Pending
    
    func consumePending() -> Destination? {
        let destination = pendingDestination
        pendingDestination = nil
        return destination
    }
    
    // MARK: - State Tracking
    
    func isInChat(roomId: String) -> Bool {
        currentChatRoomId == roomId
    }
    
    func enterChat(roomId: String) {
        currentChatRoomId = roomId
    }
    
    func exitChat() {
        currentChatRoomId = nil
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let deepLinkReceived = Notification.Name("deepLinkReceived")
    static let audioRoomDeepLink = Notification.Name("audioRoomDeepLink")
}

// MARK: - URL Scheme Parser

extension DeepLinkRouter {
    /// Parse raven:// URL scheme
    /// Supports: raven://room/{slug}
    @MainActor
    func handleURL(_ url: URL) {
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        
        if url.scheme == "raven" {
            // raven://room/{slug}
            if url.host == "room", let slug = pathComponents.first {
                route(to: .audioRoom(slug: slug))
            }
        } else if url.scheme == "https" || url.scheme == "http" {
            // https://raven.app/room/{slug}
            if url.host == "raven.app" || url.host == "www.raven.app" {
                if pathComponents.count >= 2 && pathComponents[0] == "room" {
                    route(to: .audioRoom(slug: pathComponents[1]))
                }
            }
        }
    }
}

// MARK: - Deep Link Handler View Modifier

struct DeepLinkHandler: ViewModifier {
    @State private var navigationPath = NavigationPath()
    @State private var deepLinkRouter = DeepLinkRouter.shared
    
    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .deepLinkReceived)) { notification in
                guard let destination = notification.object as? DeepLinkRouter.Destination else { return }
                handleDeepLink(destination)
            }
            .onAppear {
                // Handle pending deep link on app launch
                if let pending = deepLinkRouter.consumePending() {
                    handleDeepLink(pending)
                }
            }
    }
    
    private func handleDeepLink(_ destination: DeepLinkRouter.Destination) {
        switch destination {
        case .chat(let roomId):
            // Navigate to chat
            // This will be handled by the InboxView's navigation
            #if DEBUG
            print("[DeepLink] Navigate to chat: \(roomId)")
            #endif
            
        case .profile(let userId):
            #if DEBUG
            print("[DeepLink] Navigate to profile: \(userId)")
            #endif
            
        case .friendRequests:
            #if DEBUG
            print("[DeepLink] Navigate to friend requests")
            #endif
            
        case .notifications:
            #if DEBUG
            print("[DeepLink] Navigate to notifications")
            #endif
            
        case .security:
            #if DEBUG
            print("[DeepLink] Navigate to security settings")
            #endif
            
        case .settings:
            #if DEBUG
            print("[DeepLink] Navigate to settings")
            #endif
            
        case .inbox:
            #if DEBUG
            print("[DeepLink] Navigate to inbox")
            #endif
            
        case .newChat(let userId):
            #if DEBUG
            print("[DeepLink] Start new chat with user: \(userId)")
            #endif
        
        case .audioRoom(let slug):
            #if DEBUG
            print("[DeepLink] Navigate to audio room: \(slug)")
            #endif
            // Post notification for RoomDeepLinkHandler to pick up
            NotificationCenter.default.post(
                name: .audioRoomDeepLink,
                object: nil,
                userInfo: ["slug": slug]
            )
            
        case .post(let postId):
            #if DEBUG
            print("[DeepLink] Navigate to post: \(postId)")
            #endif
        }
    }
}

extension View {
    func handleDeepLinks() -> some View {
        modifier(DeepLinkHandler())
    }
}
