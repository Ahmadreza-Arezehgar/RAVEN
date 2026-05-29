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

/// Anything that can be shared from inside the app. Pass values into
/// the static factories below to build the right URL + message.
///
/// The optional `authorUsername` + `excerpt` on `.post` / `.echo`
/// don't go into the *user-visible* share URL path — they're forwarded
/// as `?by=` and `?excerpt=` query items so the web's dynamic OG
/// image generator (`api/og.js`) can render a quote-style card with
/// the real post text and byline. Without them, the OG image falls
/// back to a clean "Post on RAVEN" plate that still looks polished.
enum RavenShareKind {
    case profile(username: String, displayName: String?)
    case post(postId: String, authorUsername: String?, excerpt: String?)
    case echo(echoId: String, authorUsername: String?, excerpt: String?)
    case club(clubId: String, name: String?)
    case audioRoom(slug: String, title: String?)
}

/// Builds public share URLs + the human-readable text that accompanies
/// them in the iOS share sheet.
enum RavenShareLink {

    /// Production host. The AASA file at
    /// `https://raven-messager.com/.well-known/apple-app-site-association`
    /// declares Universal Links for `/u/*`, `/post/*`, `/echo/*`,
    /// `/club/*`, `/room/*` — keep this list in sync with that.
    static let publicHost = "raven-messager.com"

    /// Build the public share URL for any shareable kind.
    /// `nil` when the input is malformed (empty id / username).
    ///
    /// For `.post` and `.echo` with an author and/or excerpt, the URL
    /// is decorated with `?by=` / `?excerpt=` so the unfurl card on
    /// the receiving end (iMessage / WhatsApp / Telegram / X / Discord)
    /// shows the real quote + byline. The path itself stays clean —
    /// the iOS Universal Link router strips the query items before
    /// routing into the app.
    static func url(for kind: RavenShareKind) -> URL? {
        switch kind {
        case .profile(let username, _):
            return url(path: "/u/", value: username)
        case .post(let postId, let by, let excerpt):
            return url(path: "/post/", value: postId, hints: hintItems(by: by, excerpt: excerpt))
        case .echo(let echoId, let by, let excerpt):
            return url(path: "/echo/", value: echoId, hints: hintItems(by: by, excerpt: excerpt))
        case .club(let clubId, _):
            return url(path: "/club/", value: clubId)
        case .audioRoom(let slug, _):
            return url(path: "/room/", value: slug)
        }
    }

    /// The leading line of the share-sheet message. The URL appears on
    /// the next line so users can edit either independently.
    static func message(for kind: RavenShareKind) -> String {
        switch kind {
        case .profile(let username, let displayName):
            let name = displayName?.isEmpty == false ? displayName! : username
            return "Follow \(name) (@\(username)) on RAVEN"
        case .post(_, let author, _):
            if let a = author, !a.isEmpty {
                return "View @\(a)'s post on RAVEN"
            }
            return "View this post on RAVEN"
        case .echo(_, let author, _):
            if let a = author, !a.isEmpty {
                return "Listen to @\(a)'s Echo on RAVEN"
            }
            return "Listen to this Echo on RAVEN"
        case .club(_, let name):
            if let n = name, !n.isEmpty {
                return "Join \(n) on RAVEN"
            }
            return "Join this Club on RAVEN"
        case .audioRoom(_, let title):
            if let t = title, !t.isEmpty {
                return "Join the \"\(t)\" room on RAVEN"
            }
            return "Join this room on RAVEN"
        }
    }

    /// Short subject line — used by `ShareLink.subject` and as the
    /// email subject when the user picks "Mail" from the share sheet.
    static func subject(for kind: RavenShareKind) -> String {
        switch kind {
        case .profile:    return "Profile on RAVEN"
        case .post:       return "Post on RAVEN"
        case .echo:       return "Echo on RAVEN"
        case .club:       return "Club on RAVEN"
        case .audioRoom:  return "Audio room on RAVEN"
        }
    }

    // MARK: - Internal URL builder

    private static func url(path: String, value: String,
                            hints: [URLQueryItem] = []) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Percent-encode user-controlled segments so an at-sign in a
        // username or a slash in a slug doesn't break the URL shape.
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        guard var comps = URLComponents(string: "https://\(publicHost)\(path)\(encoded)")
        else { return nil }
        if !hints.isEmpty {
            comps.queryItems = hints
        }
        return comps.url
    }

    /// Build the `?by=` / `?excerpt=` query items that the web's
    /// dynamic OG image generator reads. Excerpts are aggressively
    /// trimmed (180 chars, single line) so a long post doesn't bloat
    /// the share URL — the OG endpoint also trims defensively, but
    /// trimming on this side keeps the URL itself readable when the
    /// user pastes it into a chat composer.
    private static func hintItems(by: String?, excerpt: String?) -> [URLQueryItem] {
        var out: [URLQueryItem] = []
        if let by = by?.trimmingCharacters(in: .whitespacesAndNewlines),
           !by.isEmpty {
            out.append(URLQueryItem(name: "by", value: by))
        }
        if var ex = excerpt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ex.isEmpty {
            ex = ex.replacingOccurrences(of: "\n", with: " ")
            if ex.count > 180 {
                ex = String(ex.prefix(179)) + "…"
            }
            out.append(URLQueryItem(name: "excerpt", value: ex))
        }
        return out
    }
}

// MARK: - SwiftUI ShareLink convenience

/// Drop-in `ShareLink` view that produces RAVEN's canonical share
/// experience. Use this anywhere — chat header, profile menu, post
/// long-press, club join sheet — instead of rolling a `ShareLink` by
/// hand so the formatting stays uniform.
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
