import SwiftUI

// MARK: - TerminalSyntax (2026-08 "RAVEN://TERMINAL v2" redesign)
/// BitChat-style source-code highlighting for chat text plus deterministic
/// per-sender nick colors. Message bodies are treated like a line of code:
/// URLs, @mentions, #channels, /commands, `inline code`, "strings" and
/// numbers each get their own terminal color so a chat log reads the way
/// a syntax-highlighted buffer does.
enum TerminalSyntax {

    // MARK: Nick palette (ANSI-inspired, readable on ink)

    /// IRC-client style palette for other people's nicks. The user's own
    /// nick always renders in the live accent (`DS.phosphor`).
    static var nickPalette: [Color] {
        [
            DS.pathBlue,                                     // cyan-blue
            DS.amber,                                        // amber
            Color(red: 1.0, green: 0.478, blue: 0.776),      // #FF7AC6 magenta
            Color(red: 0.639, green: 0.745, blue: 1.0),      // #A3BEFF periwinkle
            Color(red: 1.0, green: 0.573, blue: 0.396),      // #FF9265 coral
            Color(red: 0.529, green: 0.918, blue: 0.855),    // #87EADA aqua
            Color(red: 0.855, green: 0.788, blue: 1.0),      // #DAC9FF lilac
            Color(red: 0.980, green: 0.898, blue: 0.459),    // #FAE575 lemon
        ]
    }

    /// Stable (cross-launch) color for a sender. `String.hashValue` is
    /// seed-randomized per process, so use FNV-1a over UTF-8 instead.
    static func nickColor(for senderId: String, isMe: Bool) -> Color {
        if isMe { return DS.phosphor }
        let palette = nickPalette
        return palette[Int(fnv1a(senderId) % UInt64(palette.count))]
    }

    private static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    // MARK: Log-line builders

    /// `[HH:mm]` gutter timestamp.
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// `<nick> ` prefix styled like an IRC client.
    static func nickPrefix(_ name: String, senderId: String, isMe: Bool, fontSize: CGFloat) -> AttributedString {
        var prefix = AttributedString("<\(displayNick(name))> ")
        prefix.foregroundColor = nickColor(for: senderId, isMe: isMe)
        prefix.font = .system(size: fontSize, weight: .bold, design: .monospaced)
        return prefix
    }

    /// Lowercased, despaced handle — terminal identity aesthetics.
    static func displayNick(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "anon" }
        return trimmed.lowercased().replacingOccurrences(of: " ", with: "_")
    }

    // MARK: Syntax highlighting

    /// Highlight a message body like code. Order matters: weak token
    /// classes first (numbers, strings), strong classes last (code spans,
    /// mentions, channels, URLs, commands) so they override overlaps.
    static func highlight(
        _ text: String,
        fontSize: CGFloat,
        baseColor: Color? = nil
    ) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.foregroundColor = baseColor ?? DS.mist
        attributed.font = .system(size: fontSize, design: .monospaced)

        // number literals → soft accent
        applyColor(&attributed, in: text, regex: /\b\d+(?:[.:]\d+)*\b/, color: DS.phosphorSoft)

        // "quoted strings" → amber (like string literals)
        applyColor(&attributed, in: text, regex: /"[^"\n]{1,120}"/, color: DS.amber.opacity(0.92))

        // `inline code` → accent-soft on raised charcoal
        for range in text.ranges(of: /`[^`\n]{1,200}`/) {
            guard let attrRange = attributedRange(range, in: text, attributed: attributed) else { continue }
            attributed[attrRange].foregroundColor = DS.phosphor
            attributed[attrRange].backgroundColor = DS.charcoal
        }

        // #channel / #hashtag → path blue, semibold
        // (`\B#` ≈ lookbehind "no word char before #": Swift Regex has no lookbehind)
        applyColor(
            &attributed, in: text,
            regex: /\B#[\p{L}\p{N}_\-]{1,48}/,
            color: DS.pathBlue,
            weight: .semibold, fontSize: fontSize
        )

        // @mention → amber block, bold
        applyColor(
            &attributed, in: text,
            regex: /\B@[\p{L}\p{N}_\-.]{1,48}/,
            color: DS.amber,
            weight: .bold, fontSize: fontSize
        )

        // leading /command → accent, bold
        applyColor(
            &attributed, in: text,
            regex: /^\/[a-zA-Z][a-zA-Z0-9_\-]*/,
            color: DS.phosphor,
            weight: .bold, fontSize: fontSize
        )

        // URLs → underlined path blue + tappable link
        for range in text.ranges(of: /(?:https?:\/\/|www\.)[^\s<>"']+/) {
            guard let attrRange = attributedRange(range, in: text, attributed: attributed) else { continue }
            attributed[attrRange].foregroundColor = DS.pathBlue
            attributed[attrRange].underlineStyle = .single
            let raw = String(text[range])
            let urlString = raw.hasPrefix("www.") ? "https://\(raw)" : raw
            if let url = URL(string: urlString) {
                attributed[attrRange].link = url
            }
        }

        return attributed
    }

    // MARK: Range helpers

    private static func applyColor(
        _ attributed: inout AttributedString,
        in text: String,
        regex: some RegexComponent,
        color: Color,
        weight: Font.Weight? = nil,
        fontSize: CGFloat = 15
    ) {
        for range in text.ranges(of: regex) {
            guard let attrRange = attributedRange(range, in: text, attributed: attributed) else { continue }
            attributed[attrRange].foregroundColor = color
            if let weight {
                attributed[attrRange].font = .system(size: fontSize, weight: weight, design: .monospaced)
            }
        }
    }

    private static func attributedRange(
        _ range: Range<String.Index>,
        in text: String,
        attributed: AttributedString
    ) -> Range<AttributedString.Index>? {
        guard
            let lower = AttributedString.Index(range.lowerBound, within: attributed),
            let upper = AttributedString.Index(range.upperBound, within: attributed)
        else { return nil }
        return lower..<upper
    }
}
