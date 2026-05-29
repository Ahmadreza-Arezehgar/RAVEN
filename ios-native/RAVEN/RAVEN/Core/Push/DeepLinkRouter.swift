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
        /// Public share links carry usernames, not user ids. The leaf
        /// view resolves the username → user id lazily via the public
        /// users API. Distinct case so it doesn't collide with the
        /// notification-driven `.profile(userId:)`.
        case profileByUsername(username: String)
        case friendRequests
        case notifications
        case security
        case settings
        case inbox
        case audioRoom(slug: String)  // raven://room/{slug} or https://raven-messager.com/room/{slug}
        case post(postId: String)     // FIX: Navigate to post from like/comment notifications
        /// Echo Wall single-post view — separate from `.post` so a
        /// future router can map them to different scenes.
        case echo(echoId: String)
        /// Club join / detail page.
        case club(clubId: String)
        /// Privacy pane inside Settings. Used by `contact_shared`
        /// notifications so the user can re-confirm or flip the
        /// `allow_contact_share` toggle in one tap.
        case privacySettings
        /// The signed-in user's own profile. Used by `profile_view` and
        /// related notifications where we don't have a peer id to show.
        case myProfile

        // (2026-05-15 — round 7) Home-screen Quick Action targets.
        // Each one mirrors an entry-point that already exists inside
        // the app — the router translates the destination into a
        // notification-center post the relevant scene listens for.
        case newMessage          // Inbox tab + open New Chat composer
        case newPost             // Home tab + open New Post composer
        case search              // Home tab + open in-app search overlay
        case voiceNote           // Inbox tab + scroll to top + arm voice recorder
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
    /// Posted by the deep-link router when an HTTPS / raven:// share
    /// link resolves to a public-shareable surface. Leaf views inside
    /// MainShellView listen for the one they own.
    static let profileDeepLink = Notification.Name("raven.deepLink.profile")
    static let postDeepLink    = Notification.Name("raven.deepLink.post")
    static let echoDeepLink    = Notification.Name("raven.deepLink.echo")
    static let clubDeepLink    = Notification.Name("raven.deepLink.club")
    // (2026-05-15 — round 7) Quick Action fan-out names. The
    // MainShellView consumes the deep link, switches tabs, then posts
    // one of these so the appropriate leaf surface (InboxView,
    // FeedView, etc.) opens its composer / search / voice recorder.
    static let ravenShortcutNewMessage = Notification.Name("ravenShortcutNewMessage")
    static let ravenShortcutNewPost = Notification.Name("ravenShortcutNewPost")
    static let ravenShortcutSearch = Notification.Name("ravenShortcutSearch")
    static let ravenShortcutVoiceNote = Notification.Name("ravenShortcutVoiceNote")
    /// (2026-05-15 — round 8) Posted by AppDelegate after the Share
    /// Extension hands off a payload via the `raven://share` URL.
    /// `userInfo` carries the manifest dictionary the extension
    /// wrote into the App Group container — caption, attachments
    /// list, etc.
    static let ravenShareIncoming = Notification.Name("ravenShareIncoming")
}

// MARK: - URL Scheme Parser

extension DeepLinkRouter {
    /// Public host(s) that the iOS Universal-Links AASA file covers.
    /// Keep this list in sync with `RAVEN.entitlements` and the AASA
    /// hosted at `https://raven-messager.com/.well-known/apple-app-site-association`.
    ///
    /// 🔴 ROUND 71 phase 3 (2026-05-24) — `raven.app` REMOVED from
    /// the trusted-host list. No AASA file is published at
    /// raven.app, so the OS never validates `https://raven.app/*`
    /// links against the app — but the in-app router was happily
    /// routing them anyway, letting a random page on raven.app
    /// (typo-squat, accidental, or compromised) drive deep-link
    /// navigation inside RAVEN. Re-add only after the AASA file is
    /// hosted at `https://raven.app/.well-known/apple-app-site-association`
    /// AND the matching applinks entry stays in RAVEN.entitlements.
    private static let universalLinkHosts: Set<String> = [
        "raven-messager.com",
        "www.raven-messager.com",
    ]

    /// Parse an incoming URL and dispatch it to the right destination.
    ///
    /// Two URL families are recognized:
    ///
    /// • Custom scheme — `raven://`
    ///     - `raven://room/{slug}`     → .audioRoom
    ///     - `raven://u/{username}`    → .profileByUsername
    ///     - `raven://post/{id}`       → .post
    ///     - `raven://echo/{id}`       → .echo
    ///     - `raven://club/{id}`       → .club
    ///
    /// • Universal Links — `https://raven-messager.com/*`
    ///     - `/u/{username}`           → .profileByUsername
    ///     - `/post/{id}`              → .post
    ///     - `/echo/{id}`              → .echo
    ///     - `/club/{id}`              → .club
    ///     - `/room/{slug}`            → .audioRoom
    ///
    /// Unknown paths fall through silently so an unrecognized link
    /// drops the user on the inbox (current behavior) instead of
    /// crashing.
    @MainActor
    func handleURL(_ url: URL) {
        if url.scheme == "raven" {
            handleRavenScheme(url)
            return
        }
        if let scheme = url.scheme, (scheme == "https" || scheme == "http") {
            handleHTTPSLink(url)
            return
        }
        #if DEBUG
        print("[DeepLink] Ignoring URL with unknown scheme: \(url)")
        #endif
    }

    // 🔴 ROUND 37 (2026-05-19) — deep-link value validation.
    //
    // PREVIOUSLY: `routeFor` accepted whatever string `pathComponents`
    // gave back as the `value`. Three real exposures:
    //
    //   1. Length: pathComponents preserves the full URL-decoded
    //      segment, with no cap. A pasted `raven://u/<1 MB string>`
    //      sailed through into a SwiftUI navigation push, eating
    //      memory and possibly hanging the app on cold-launch
    //      handoff.
    //   2. Character set: `pathComponents` URL-decodes `%xx` escapes,
    //      so `raven://u/foo%2Fbar` becomes `value = "foo/bar"`. The
    //      slash then breaks downstream URL builders that don't re-
    //      encode (request goes to `/users/foo/bar` not `/users/foo`).
    //      Newlines, control chars, and tabs round-trip cleanly too.
    //   3. Spoofed value: `raven://u/<weird-unicode-lookalike-username>`
    //      could be used in phishing — the visible URL claims one
    //      username, the resolved profile is a different one because
    //      the username field allows confusable glyphs. We can't
    //      defeat all confusables, but we CAN refuse the obviously
    //      adversarial inputs (control chars, length, separators).
    //
    // FIX: a single `cleanValue` guard. Validation rules:
    //   • length ≤ 128 bytes
    //   • no whitespace, newlines, or control / format Unicode
    //   • no path separators (`/`, `\\`) — pathComponents already
    //     split on `/`, so any remaining `/` means it came from
    //     `%2F` URL-encoded smuggling.
    private static let maxDeepLinkValueLen = 128
    private static func cleanValue(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.utf8.count <= maxDeepLinkValueLen else { return nil }
        for scalar in raw.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                return nil
            default:
                break
            }
            if scalar == "/" || scalar == "\\" || scalar == "\u{0000}" {
                return nil
            }
        }
        return raw
    }

    @MainActor
    private func handleRavenScheme(_ url: URL) {
        // For raven://kind/value, `url.host` is the *kind* (room, u, post, …).
        let pathParts = url.pathComponents.filter { $0 != "/" }
        guard let kind = url.host?.lowercased() else { return }
        guard let rawValue = pathParts.first,
              let value = Self.cleanValue(rawValue)
        else { return }
        routeFor(kind: kind, value: value)
    }

    @MainActor
    private func handleHTTPSLink(_ url: URL) {
        guard let host = url.host?.lowercased(),
              Self.universalLinkHosts.contains(host)
        else {
            #if DEBUG
            print("[DeepLink] Ignoring URL from unrecognised host: \(url)")
            #endif
            return
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        // First component is the kind, second is the slug / id / username.
        guard parts.count >= 2,
              let value = Self.cleanValue(parts[1])
        else { return }
        routeFor(kind: parts[0].lowercased(), value: value)
    }

    @MainActor
    private func routeFor(kind: String, value: String) {
        switch kind {
        case "u", "user", "profile":
            route(to: .profileByUsername(username: value))
        case "post":
            route(to: .post(postId: value))
        case "echo":
            route(to: .echo(echoId: value))
        case "club":
            route(to: .club(clubId: value))
        case "room":
            route(to: .audioRoom(slug: value))
        default:
            #if DEBUG
            print("[DeepLink] Unrecognised kind '\(kind)' for value '\(value)'")
            #endif
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
            NotificationCenter.default.post(
                name: .postDeepLink,
                object: nil,
                userInfo: ["postId": postId]
            )

        case .profileByUsername(let username):
            #if DEBUG
            print("[DeepLink] Navigate to profile by username: \(username)")
            #endif
            NotificationCenter.default.post(
                name: .profileDeepLink,
                object: nil,
                userInfo: ["username": username]
            )

        case .echo(let echoId):
            #if DEBUG
            print("[DeepLink] Navigate to echo: \(echoId)")
            #endif
            NotificationCenter.default.post(
                name: .echoDeepLink,
                object: nil,
                userInfo: ["echoId": echoId]
            )

        case .club(let clubId):
            #if DEBUG
            print("[DeepLink] Navigate to club: \(clubId)")
            #endif
            NotificationCenter.default.post(
                name: .clubDeepLink,
                object: nil,
                userInfo: ["clubId": clubId]
            )

        case .privacySettings:
            #if DEBUG
            print("[DeepLink] Navigate to privacy settings")
            #endif

        case .myProfile:
            #if DEBUG
            print("[DeepLink] Navigate to own profile")
            #endif

        // (2026-05-15 — round 7) Quick Actions are forwarded by
        // MainShellView via dedicated NotificationCenter names; the
        // log lines below help diagnose home-screen long-press
        // taps that don't reach a leaf view.
        case .newMessage:
            #if DEBUG
            print("[DeepLink] Quick Action: new message")
            #endif
        case .newPost:
            #if DEBUG
            print("[DeepLink] Quick Action: new post")
            #endif
        case .search:
            #if DEBUG
            print("[DeepLink] Quick Action: search")
            #endif
        case .voiceNote:
            #if DEBUG
            print("[DeepLink] Quick Action: voice note")
            #endif
        }
    }
}

extension View {
    func handleDeepLinks() -> some View {
        modifier(DeepLinkHandler())
    }
}
