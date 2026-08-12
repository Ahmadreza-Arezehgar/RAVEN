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
// OBSIDIAN REDESIGN (2026-08): expanded to the WhatsApp-style 4-tab shell —
// Contacts · Chats · Network · Settings. rawValue is the pager page index, so
// case order IS visual order. `.messages`/`.account` case names are kept so
// existing tab-bar call sites don't churn.
enum AppTab: Int, CaseIterable {
    case contacts = 0   // "Contacts"
    case messages = 1   // "Chats"
    case network  = 2   // "Network" (serverless: mesh + LAN node + bridge)
    case account  = 3   // "Settings"

    var title: String {
        switch self {
        case .contacts: return "Contacts"
        case .messages: return "Chats"
        case .network:  return "Network"
        case .account:  return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .contacts: return "person.2"
        case .messages: return "bubble.left.and.bubble.right"
        case .network:  return "point.3.connected.trianglepath.dotted"
        case .account:  return "gearshape"
        }
    }

    var selectedIcon: String {
        switch self {
        case .contacts: return "person.2.fill"
        case .messages: return "bubble.left.and.bubble.right.fill"
        case .network:  return "point.3.filled.connected.trianglepath.dotted"
        case .account:  return "gearshape.fill"
        }
    }

    var accessibilityName: String { title }
}
