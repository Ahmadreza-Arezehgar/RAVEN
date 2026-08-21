// RavenShareLink.swift
//
// Single source of truth for share-link generation. Every "Share"
// button in the app routes through here so:
//
//   • The URL host is consistent (raven-messager.com) — switching to
//     a staging host later is a one-line change.
//   • Share message strings are centralized (and translatable).
//   • The link is **HTTPS**, not `raven://`. Custom schemes don't
//     unfurl in most chat apps and don't fall back to a web preview
//     when the recipient doesn't have RAVEN installed.
//
// Pair with `DeepLinkRouter.handleURL(_:)` — that's the inverse:
// HTTPS → internal navigation.

import SwiftUI

/// A private-messaging product shares identity/contact cards, not public
/// content. Additional public-content cases must not be added here.
enum RavenShareKind {
    case profile(username: String, displayName: String?)
}

/// Builds public share URLs + the human-readable text that accompanies
/// them in the iOS share sheet.
enum RavenShareLink {

    /// Production host. The AASA file at
    /// `https://raven-messager.com/.well-known/apple-app-site-association`
    /// declares Universal Links for `/u/*` — keep this in sync with that.
    static let publicHost = "raven-messager.com"

    /// Build the public share URL for any shareable kind.
    /// `nil` when the input is malformed (empty id / username).
    ///
    static func url(for kind: RavenShareKind) -> URL? {
        switch kind {
        case .profile(let username, _):
            return url(path: "/u/", value: username)
        }
    }

    /// The leading line of the share-sheet message. The URL appears on
    /// the next line so users can edit either independently.
    static func message(for kind: RavenShareKind) -> String {
        switch kind {
        case .profile(let username, let displayName):
            let name = displayName?.isEmpty == false ? displayName! : username
            return "Add \(name) (@\(username)) as a contact on RAVEN"
        }
    }

    /// Short subject line — used by `ShareLink.subject` and as the
    /// email subject when the user picks "Mail" from the share sheet.
    static func subject(for kind: RavenShareKind) -> String {
        switch kind {
        case .profile: return "Contact on RAVEN"
        }
    }

    // MARK: - Internal URL builder

    private static func url(path: String, value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 128 else { return nil }
        for scalar in trimmed.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .spaceSeparator, .lineSeparator, .paragraphSeparator:
                return nil
            default:
                break
            }
            guard scalar != "/", scalar != "\\", scalar != "\u{0000}" else {
                return nil
            }
        }
        // Percent-encode user-controlled segments so an at-sign in a
        // username or a slash in a slug doesn't break the URL shape.
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "https://\(publicHost)\(path)\(encoded)")
    }
}

// MARK: - SwiftUI ShareLink convenience

/// Drop-in `ShareLink` view that produces RAVEN's canonical share
/// experience for contact-card links.
///
/// Example:
///
///     RavenShareLink(kind: .profile(username: "shhb", displayName: "Sara"))
///         .buttonStyle(.bordered)
///
/// Falls back to a non-interactive label if the kind has an empty
/// identifier (malformed input shouldn't crash the share button).
struct RavenShareButton<Label: View>: View {
    let kind: RavenShareKind
    @ViewBuilder var label: () -> Label

    var body: some View {
        if let url = RavenShareLink.url(for: kind) {
            ShareLink(
                item: url,
                subject: Text(RavenShareLink.subject(for: kind)),
                message: Text(RavenShareLink.message(for: kind))
            ) {
                label()
            }
        } else {
            // Malformed input — render a disabled button so the layout
            // doesn't shift and the user gets a hint that this content
            // can't be shared.
            label()
                .opacity(0.4)
        }
    }
}

extension RavenShareButton where Label == SwiftUI.Label<Text, Image> {
    /// Convenience initializer that produces a system-style
    /// `Label("Share", systemImage: "square.and.arrow.up")` button.
    init(kind: RavenShareKind, title: String = "Share") {
        self.kind = kind
        self.label = { SwiftUI.Label(title, systemImage: "square.and.arrow.up") }
    }
}
