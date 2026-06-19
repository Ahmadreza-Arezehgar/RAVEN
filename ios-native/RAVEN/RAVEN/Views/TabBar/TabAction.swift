import SwiftUI

// MARK: - Tab Action Model
struct TabAction: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    let tint: Color
    let handler: () -> Void
}

// MARK: - App Tab Enum
//
// MESSENGER PIVOT (2026-06): collapsed from 4 tabs (Home/Messages/Discover/
// Account) to 2 — Chats + Settings. The case names `.messages`/`.account` are
// kept (so the tab-bar components don't churn); only their labels changed.
enum AppTab: Int, CaseIterable {
    case messages = 0   // "Chats"
    case account  = 1   // "Settings"

    var title: String {
        switch self {
        case .messages: return "Chats"
        case .account:  return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .messages: return "bubble.left.and.bubble.right"
        case .account:  return "gearshape"
        }
    }

    var selectedIcon: String {
        switch self {
        case .messages: return "bubble.left.and.bubble.right.fill"
        case .account:  return "gearshape.fill"
        }
    }

    var accessibilityName: String {
        switch self {
        case .messages: return "Chats"
        case .account:  return "Settings"
        }
    }
}
