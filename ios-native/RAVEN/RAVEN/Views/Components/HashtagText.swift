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
                return .systemAction
            })
    }
    
    private var attributedText: AttributedString {
        var attributed = AttributedString(text)
        
        let regex = PerformanceConstants.hashtagRegex
        
        let nsText = text as NSString
        let matches = regex?.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) ?? []
        
        for match in matches {
            guard let range = Range(match.range, in: text),
                  let attrRange = Range(range, in: attributed) else { continue }
            
            let hashtag = nsText.substring(with: match.range(at: 1))  // Just the tag without #
            
            attributed[attrRange].foregroundColor = .accentColor
            let safeHashtag = hashtag.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? hashtag
            attributed[attrRange].link = URL(string: "raven://hashtag?name=\(safeHashtag)")
        }
        
        return attributed
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 20) {
        InteractiveHashtagText(
            text: "Check out this #tech post about #iOS development! 🚀",
            onHashtagTap: { tag in print("Tapped: #\(tag)") }
        )
        
        InteractiveHashtagText(
            text: "No hashtags here",
            onHashtagTap: { _ in }
        )
        
        InteractiveHashtagText(
            text: "#first at the start",
            onHashtagTap: { _ in }
        )
    }
    .padding()
}
