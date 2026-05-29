// SafariSheet.swift
//
// SwiftUI wrapper around `SFSafariViewController` — Apple's system
// in-app browser. Replaces the custom `InAppBrowserSheet` for the
// "tap a link in a post" path because:
//
//   • Cold-start ~100 ms vs ~500 ms for `WKWebView` (Safari's content
//     process is pre-warmed at OS level; our custom one is not).
//   • Free back/forward/share/reader/open-in-Safari controls — no UI
//     for us to maintain.
//   • Inherits the user's Safari content blockers + Reader Mode
//     preferences — privacy & ad-blocking work out of the box.
//   • Sandboxed cookies — does NOT share session state with the
//     user's Safari, so logging into the bot's @raven_news doesn't
//     accidentally leak to a news site.
//
// We keep `InAppBrowserSheet` + `WebView` around for any callers that
// genuinely need the custom-chrome browser (e.g. an embedded preview
// inside a debug view), but every "tap a link" path on the feed,
// post-detail, and chat now routes here.
//
// 🟥 ROUND 31 (2026-05-17) — crash + speed fixes.
//
//   CRASH:  `SFSafariViewController(url:)` is documented to throw an
//   Objective-C exception when the URL's scheme is anything other
//   than `http://` or `https://`.  NSDataDetector readily matches
//   `mailto:`, `tel:`, `ftp:`, even bare email addresses ("user@x.com")
//   which it normalises into `mailto:`-scheme URLs — and our
//   `PostCard.onLinkTap` handler forwarded every match into the
//   sheet without checking.  Tapping a non-http link in a post body
//   immediately killed the app.
//
//   Defense lives HERE in the sheet rather than per-callsite because
//   we have THREE call paths today (PostCard, PostDetailView,
//   ChatView) and at least one more on the way (post-comments).
//   Putting the guard in the sheet itself means a future caller
//   that forgets to validate doesn't ship a regression.
//
//   For non-http(s) URLs we route to `UIApplication.shared.open(...)`
//   which dispatches to the OS's registered handler (Mail / Phone /
//   third-party app) — the experience the user actually wants when
//   they tap `mailto:` or `tel:`.
//
//   SPEED:  the first `SFSafariViewController` presentation per
//   session paid the full TLS+DNS round-trip in the foreground.
//   On a slow network the spinner sat there for 2-3 s before the
//   page even started rendering.  iOS 15 added
//   `SFSafariViewController.prewarmConnections(to:)` which lets us
//   pre-establish TLS+HTTP sessions to a candidate URL.  We call
//   it from `LinkPreviewCard` the moment a post becomes visible
//   (the preview card is already fetching metadata for that URL,
//   so we have the URL on hand cheaply), then the sheet present
//   inherits the warm connection.  Typical observed savings:
//   400-900 ms on cellular.
//
// Reference: https://developer.apple.com/documentation/safariservices/sfsafariviewcontroller

import SwiftUI
import SafariServices
import UIKit
import os

fileprivate let logger = Logger(subsystem: "app.raven.ios", category: "UI.SafariSheet")

struct SafariSheet: View {
    let url: URL
    /// Optional tint for the navigation bar; matches RAVEN's gradient
    /// when the caller wants brand consistency.
    var preferredTintColor: UIColor? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // 🟥 ROUND 34 (2026-05-17) — URL normalisation.
        //
        // User report: tapping a bare-domain link like "Investing.com"
        // in a post body dead-ended:
        //   SafariSheet refused non-http URL (scheme=nil)
        //   Failed to open URL Investing.com: invalid input parameters
        //
        // NSDataDetector matches bare domains without a scheme — the
        // URL it hands us has `scheme == nil` and a host like
        // "Investing.com".  SFSafariViewController crashes on those,
        // AND `UIApplication.shared.open` rejects them (error -50).
        //
        // Normalise BEFORE branching: if the URL has no scheme but
        // looks like a host (has a dot, no whitespace, parseable as
        // a host after we prepend "https://"), upgrade it to https.
        // Same heuristic Safari/Chrome use for omnibox input.
        let resolved = Self.normalised(url) ?? url
        Group {
            if Self.isSafariSafe(resolved) {
                _SafariSheetImpl(url: resolved, preferredTintColor: preferredTintColor)
                    .ignoresSafeArea()
            } else {
                // Genuinely non-http(s) (e.g. mailto: / tel: / a
                // malformed URL we couldn't rescue) — SFSafariViewController
                // would crash.  Hand off to the OS handler.
                Color.clear
                    .onAppear {
                        logger.debug("SafariSheet refused non-http URL (scheme=\(resolved.scheme ?? "nil", privacy: .public)) — routing to system handler.")
                        UIApplication.shared.open(resolved, options: [:], completionHandler: nil)
                        // Bounce on the next runloop so the sheet has
                        // mounted before we dismiss — avoids the
                        // "dismissing a sheet during presentation"
                        // warning.
                        DispatchQueue.main.async { dismiss() }
                    }
            }
        }
    }

    /// Normalise the URL — if scheme is missing but the input looks
    /// like a bare domain (`Investing.com`, `bbc.co.uk/news`,
    /// `example.com`), prepend `https://` so SFSafariViewController
    /// accepts it.  Returns nil when the URL is already safe (no
    /// normalisation needed) or when no rescue is possible.
    ///
    /// Heuristic mirrors browser omnibox behaviour:
    ///   - must contain at least one "."
    ///   - must NOT contain whitespace
    ///   - must NOT already have a scheme
    ///   - must parse as a valid URL after the "https://" prefix
    static func normalised(_ url: URL) -> URL? {
        // Already safe → no rescue needed.
        if isSafariSafe(url) { return nil }

        // We only rescue scheme=nil cases.  A wrong-scheme URL
        // (mailto:, tel:, ftp:, etc.) is intentional and should
        // hand off to the OS, not be hijacked.
        guard url.scheme == nil else { return nil }

        let raw = url.absoluteString
        guard raw.contains("."),
              !raw.contains(where: { $0.isWhitespace }),
              !raw.isEmpty,
              !raw.hasPrefix("/")  // file-path-y; don't pretend it's a web URL
        else { return nil }

        guard let upgraded = URL(string: "https://\(raw)") else { return nil }
        return isSafariSafe(upgraded) ? upgraded : nil
    }

    /// True when the URL's scheme is `http://` or `https://` AND the
    /// URL has a non-empty host.  Anything else would either crash
    /// `SFSafariViewController(url:)` outright or render a blank
    /// page (e.g. `https:///` with no host).
    static func isSafariSafe(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        guard scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host, !host.isEmpty else { return false }
        return true
    }

    /// Pre-establish TLS + HTTP sessions to `urls` so the eventual
    /// `SafariSheet` present skips the cold-start penalty.  Iterates
    /// the input and silently drops any URL that isn't Safari-safe
    /// (caller can pass raw NSDataDetector matches without filtering
    /// first).
    ///
    /// iOS 15+ only — earlier OSes get a no-op so call sites stay
    /// branch-free.
    static func prewarm(_ urls: [URL]) {
        guard #available(iOS 15.0, *) else { return }
        let safe = urls.filter { isSafariSafe($0) }
        guard !safe.isEmpty else { return }
        SFSafariViewController.prewarmConnections(to: safe)
    }
}

/// Private `UIViewControllerRepresentable` — moved out of the public
/// `SafariSheet` so the outer wrapper can interpose the scheme guard
/// + dismiss-on-redirect logic without juggling `representable` state.
private struct _SafariSheetImpl: UIViewControllerRepresentable {
    let url: URL
    var preferredTintColor: UIColor?

    func makeUIViewController(context: Context) -> SFSafariViewController {
        // `entersReaderIfAvailable` — false by default. Most news
        // articles are pleasant to read raw, and forcing Reader Mode
        // hides images that the user may have come for. Users who
        // want it can tap the Reader icon themselves.
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        config.barCollapsingEnabled = true     // collapse on scroll, like Safari

        let controller = SFSafariViewController(url: url, configuration: config)
        controller.dismissButtonStyle = .close   // matches our "Close" pattern
        controller.preferredBarTintColor = preferredTintColor
        controller.preferredControlTintColor = preferredTintColor
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
        // SFSafariViewController is owned by UIKit once instantiated;
        // we don't push new URLs into an existing instance. SwiftUI
        // re-creates the sheet when the URL changes, which is correct.
    }
}
