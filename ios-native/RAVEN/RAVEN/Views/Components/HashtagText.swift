import SwiftUI

/// A text view that makes hashtags clickable
struct HashtagText: View {
    let text: String
    let onHashtagTap: (String) -> Void
    
    var body: some View {
        buildText()
            .font(.system(size: 15))
            .foregroundColor(.primary)
    }
    
    /// Parse text and create Text view with tappable hashtags
    private func buildText() -> Text {
        let nsText = text as NSString
        let matches = PerformanceConstants.hashtagRegex?.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) ?? []
        
        if matches.isEmpty {
            return Text(text)
        }
        
        var result = Text("")
        var lastEnd = 0
        
        for match in matches {
            // Add text before this hashtag
            if match.range.location > lastEnd {
                let beforeRange = NSRange(location: lastEnd, length: match.range.location - lastEnd)
                let beforeText = nsText.substring(with: beforeRange)
                result = result + Text(beforeText)
            }
            
            // Add the hashtag (styled)
            let hashtagWithSymbol = nsText.substring(with: match.range)
            result = result + Text(hashtagWithSymbol)
                .foregroundColor(.accentColor)
            
            lastEnd = match.range.location + match.range.length
        }
        
        // Add remaining text after last hashtag
        if lastEnd < nsText.length {
            let afterRange = NSRange(location: lastEnd, length: nsText.length - lastEnd)
            let afterText = nsText.substring(with: afterRange)
            result = result + Text(afterText)
        }
        
        return result
    }
}

/// Alternative: Interactive version with buttons overlay
struct InteractiveHashtagText: View {
    let text: String
    let onHashtagTap: (String) -> Void
    var onMentionTap: ((String) -> Void)? = nil
    /// Tapped a `v0:21` style chip → seek the post's video to this second.
    /// Wired by `PostCard`/`PostDetailView`; `nil` here means the post has no
    /// video, so any tokens render as plain styled text without the link.
    var onVideoTimestampTap: ((Double) -> Void)? = nil
    /// 🔴 Bug fix (2026-05-15): tapping any http(s) link inside a post
    /// used to bounce the user out to system Safari. Posts now expose a
    /// hook that routes web links into the in-app capsule
    /// `SafariSheet` — same liquid-glass viewer the chat surface uses.
    /// `nil` keeps the legacy systemAction fallback (Safari).
    var onLinkTap: ((URL) -> Void)? = nil

    @State private var hashtagRanges: [(String, CGRect)] = []

    var body: some View {
        // Use regular attributed text with tap gesture detection
        Text(attributedText)
            .font(.system(size: 15))
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "raven" && url.host == "hashtag",
                   let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let tag = components.queryItems?.first(where: { $0.name == "name" })?.value {
                    onHashtagTap(tag)
                    return .handled
                }
                if url.scheme == "raven" && url.host == "mention",
                   let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let username = components.queryItems?.first(where: { $0.name == "username" })?.value {
                    onMentionTap?(username)
                    return .handled
                }
                if url.scheme == "raven" && url.host == "timestamp",
                   let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let raw = components.queryItems?.first(where: { $0.name == "seconds" })?.value,
                   let seconds = Double(raw) {
                    onVideoTimestampTap?(seconds)
                    return .handled
                }
                // Web links → in-app capsule browser when the parent
                // wired `onLinkTap`. Otherwise fall through to Safari.
                if let scheme = url.scheme?.lowercased(),
                   scheme == "http" || scheme == "https",
                   let onLinkTap {
                    onLinkTap(url)
                    return .handled
                }
                return .systemAction
            })
    }

    private var attributedText: AttributedString {
        var attributed = AttributedString(text)

        let nsText = text as NSString

        // Process hashtags + mentions FIRST so the URL replacement step (which
        // shrinks ranges) doesn't shift the indexes they rely on. URL spans
        // never overlap hashtags or mentions in practice (NSDataDetector
        // won't match `#tag` as a URL), so processing in this order is safe.

        // Process hashtags
        let hashtagMatches = PerformanceConstants.hashtagRegex?.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) ?? []

        for match in hashtagMatches {
            guard let range = Range(match.range, in: text),
                  let attrRange = Range(range, in: attributed) else { continue }

            let hashtag = nsText.substring(with: match.range(at: 1))  // Just the tag without #

            attributed[attrRange].foregroundColor = .accentColor
            let safeHashtag = hashtag.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? hashtag
            attributed[attrRange].link = URL(string: "raven://hashtag?name=\(safeHashtag)")
        }

        // Process @mentions
        let mentionMatches = PerformanceConstants.mentionRegex?.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) ?? []

        for match in mentionMatches {
            guard let range = Range(match.range, in: text),
                  let attrRange = Range(range, in: attributed) else { continue }

            // Extract username without @ prefix
            let fullMatch = nsText.substring(with: match.range)  // "@username"
            let username = String(fullMatch.dropFirst())  // "username"

            attributed[attrRange].foregroundColor = .blue
            attributed[attrRange].font = .system(size: 15, weight: .semibold)
            let safeUsername = username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? username
            attributed[attrRange].link = URL(string: "raven://mention?username=\(safeUsername)")
        }

        // Process video-jump tokens (e.g. `v0:21`). Only style as a Liquid
        // Glass chip when the post owner wired up a target — without a
        // tappable destination we'd be lying about clickability.
        if onVideoTimestampTap != nil {
            for ts in VideoTimestampParser.extract(from: text) {
                guard let range = Range(ts.range, in: text),
                      let attrRange = Range(range, in: attributed) else { continue }

                attributed[attrRange].foregroundColor = .accentColor
                attributed[attrRange].font = .system(size: 14, weight: .semibold).monospacedDigit()
                attributed[attrRange].link = URL(string: "raven://timestamp?seconds=\(ts.seconds)")
            }
        }

        // ── URL replacement: show domain only, link to full URL ────────
        //
        // Originally we just applied a `.link` attribute on the URL text,
        // which kept the full `https://www.bbc.co.uk/persian/live/cj6...
        // ?at_medium=RSS&at_campaign=rss` visible in every news-bot post.
        // Ugly, line-wraps awkwardly, hurts skim-readability.
        //
        // Now: we REPLACE the URL's text span with just the domain
        // (`bbc.co.uk`, no `www.`), keeping the original URL as the
        // underlying `.link` target. Tap the visible "bbc.co.uk" and
        // the OpenURLAction still routes to the original full URL.
        //
        // Processed LAST + back-to-front so hashtag/mention/timestamp
        // ranges (which were resolved against the original-length
        // text) stay correct. Replacing back-to-front means each
        // shrinkage only affects positions AFTER the cursor, which
        // we've already processed.
        if let detector = PerformanceConstants.linkDetector {
            let urlMatches = detector.matches(
                in: text,
                options: [],
                range: NSRange(location: 0, length: nsText.length)
            ).sorted { $0.range.location > $1.range.location }   // descending

            for m in urlMatches {
                guard let url = m.url,
                      let range = Range(m.range, in: text),
                      let attrRange = Range(range, in: attributed) else { continue }

                // Display text = `url.host` minus a leading `www.`,
                // falls back to the original substring if the URL has
                // no host (rare — file:// etc.).
                let raw = (url.host ?? nsText.substring(with: m.range)).lowercased()
                let display = raw.hasPrefix("www.") ? String(raw.dropFirst(4)) : raw

                var span = AttributedString(display)
                span.foregroundColor = .blue
                span.underlineStyle = .single
                span.link = url

                attributed.replaceSubrange(attrRange, with: span)
            }
        }

        return attributed
    }
}

// MARK: - Video Timestamp Parser
// Detects inline video-jump commands inside post bodies. The author writes
// `v0:21` (or `v1:23`, `v1:02:34`) anywhere in the description; the feed
// renders that token as a tappable chip that opens the video full-screen at
// that second.

/// One detected command. `range` is in NSString units so we can safely apply
/// it to an `AttributedString` built from the same source string.
struct VideoTimestamp: Hashable {
    /// NSRange of the command in the post body, including the leading `v`.
    let range: NSRange
    /// The original literal token, e.g. `v0:21`.
    let token: String
    /// Resolved seconds (0-based) — what `AVPlayer.seek` should jump to.
    let seconds: Double
    /// Human label for chips on the scrub bar (`0:21`).
    var label: String { String(token.dropFirst()) }
}

enum VideoTimestampParser {

    /// Matches: lookbehind-non-alphanum + `v` (or `V`) + 1–2 hour
    /// digits (optional) + `:` + 1–2 minutes + `:` + 1–2 seconds.
    /// Case-insensitive on the leading `v` because users naturally
    /// write `V0:21` at the start of a sentence and we want both
    /// forms to work. The lookbehind still blocks matches inside
    /// words like "developer" or "vM:00".
    private static let regex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9])[vV](?:(\d{1,2}):)?(\d{1,2}):(\d{1,2})\b"#
        )
    }()

    /// Pulls every `v[H:]M:SS` token out of a post body. The returned ranges
    /// point at the original `text`, suitable for both `AttributedString`
    /// styling (`Range<String.Index>`-via-NSRange) and server-side echo.
    static func extract(from text: String) -> [VideoTimestamp] {
        guard let regex else { return [] }
        let nsText = text as NSString
        let matches = regex.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: nsText.length)
        )
        return matches.compactMap { m -> VideoTimestamp? in
            let token = nsText.substring(with: m.range)

            let hours: Int
            if m.range(at: 1).location != NSNotFound {
                hours = Int(nsText.substring(with: m.range(at: 1))) ?? 0
            } else {
                hours = 0
            }
            guard m.range(at: 2).location != NSNotFound,
                  m.range(at: 3).location != NSNotFound,
                  let mins = Int(nsText.substring(with: m.range(at: 2))),
                  let secs = Int(nsText.substring(with: m.range(at: 3))),
                  mins < 60, secs < 60 else {
                return nil
            }
            let total = Double(hours * 3600 + mins * 60 + secs)
            return VideoTimestamp(range: m.range, token: token, seconds: total)
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 20) {
        InteractiveHashtagText(
            text: "Check out this #tech post about #iOS development! 🚀",
            onHashtagTap: { tag in print("Tapped: #\(tag)") }
        )
        
        InteractiveHashtagText(
            text: "Hey @john check this out! #cool @jane",
            onHashtagTap: { tag in print("Tapped: #\(tag)") },
            onMentionTap: { username in print("Tapped: @\(username)") }
        )
        
        InteractiveHashtagText(
            text: "No hashtags or mentions here",
            onHashtagTap: { _ in }
        )
        
        InteractiveHashtagText(
            text: "#first at the start",
            onHashtagTap: { _ in }
        )
    }
    .padding()
}
