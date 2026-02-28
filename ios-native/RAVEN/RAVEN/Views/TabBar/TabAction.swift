import SwiftUI

// MARK: - Tab Action Model
struct TabAction: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    let tint: Color
    let handler: () -> Void
}

// MARK: - App Tab Enum (Order: Home → Messages → Discover → Account)
enum AppTab: Int, CaseIterable {
    case home = 0
    case messages = 1
    case discover = 2
    case account = 3
    
    var title: String {
        switch self {
        case .home: return "home".localized
        case .messages: return "messages".localized
        case .discover: return "discover".localized
        case .account: return "account".localized
        }
    }
    
    var icon: String {
        switch self {
        case .home: return "house"
        case .messages: return "bubble.left.and.bubble.right"
        case .discover: return "magnifyingglass"
        case .account: return "person.circle"
        }
    }
    
    var selectedIcon: String {
        switch self {
        case .home: return "house.fill"
        case .messages: return "bubble.left.and.bubble.right.fill"
        case .discover: return "magnifyingglass"
        case .account: return "person.circle.fill"
        }
    }
    
    var accessibilityName: String {
        switch self {
        case .home: return "Home"
        case .messages: return "Messages"
        case .discover: return "Discover"
        case .account: return "Account"
        }
    }
}
