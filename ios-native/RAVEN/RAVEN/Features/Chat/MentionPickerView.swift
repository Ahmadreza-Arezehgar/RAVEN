import SwiftUI

// MARK: - Mention Picker View
/// Glassmorphism dropdown that appears above the composer when "@" is typed.
/// Shows filtered list of group members for chat, or users for comments.

struct MentionPickerView: View {
    let members: [MentionCandidate]
    let searchText: String
    let onSelect: (MentionCandidate) -> Void
    
    private var filtered: [MentionCandidate] {
        if searchText.isEmpty {
            return Array(members.prefix(8))
        }
        return members.filter {
            $0.username.localizedCaseInsensitiveContains(searchText) ||
            ($0.displayName?.localizedCaseInsensitiveContains(searchText) ?? false)
        }.prefix(8).map { $0 }
    }
    
    var body: some View {
        if !filtered.isEmpty {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(filtered) { candidate in
                        Button {
                            onSelect(candidate)
                        } label: {
                            HStack(spacing: 10) {
                                // Avatar
                                AsyncImage(url: URL(string: candidate.avatarUrl ?? "")) { image in
                                    image
                                        .resizable()
                                        .scaledToFill()
                                } placeholder: {
                                    Circle()
                                        .fill(
                                            LinearGradient(
                                                colors: [.blue.opacity(0.4), .purple.opacity(0.4)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .overlay(
                                            Text(String(candidate.username.prefix(1)).uppercased())
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(.white)
                                        )
                                }
                                .frame(width: 32, height: 32)
                                .clipShape(Circle())
                                
                                // Name
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("@\(candidate.username)")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(.primary)
                                    
                                    if let display = candidate.displayName, !display.isEmpty, display != candidate.username {
                                        Text(display)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        
                        if candidate.id != filtered.last?.id {
                            Divider()
                                .padding(.leading, 56)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 220)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: -4)
            .transition(.asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .opacity
            ))
        }
    }
}


// MARK: - Mention Candidate Model

struct MentionCandidate: Identifiable, Hashable {
    let id: String       // userId
    let username: String
    let displayName: String?
    let avatarUrl: String?
}


// MARK: - Mention Tracking Helper

/// Tracks mention entities as the user types in the composer.
@Observable
class MentionTracker {
    var entities: [MentionEntity] = []
    var isShowingPicker = false
    var mentionSearchText = ""
    var mentionTriggerLocation: Int = 0
    
    /// Check if the current text change should trigger the mention picker
    func processTextChange(_ text: String, cursorPosition: Int? = nil) {
        let pos = cursorPosition ?? text.count
        
        // Search backwards from cursor for "@"
        let beforeCursor = String(text.prefix(pos))
        
        if let atIndex = beforeCursor.lastIndex(of: "@") {
            let atPos = String(beforeCursor[..<atIndex]).count
            let afterAt = String(beforeCursor[beforeCursor.index(after: atIndex)...])
            
            // Only show picker if we're typing right after @
            // (no space between @ and cursor, and @ is at word boundary)
            let isAtWordBoundary = atPos == 0 || {
                let charBefore = beforeCursor[beforeCursor.index(before: atIndex)]
                return charBefore == " " || charBefore == "\n"
            }()
            
            if isAtWordBoundary && !afterAt.contains(" ") && !afterAt.contains("\n") {
                isShowingPicker = true
                mentionSearchText = afterAt
                mentionTriggerLocation = atPos
                return
            }
        }
        
        isShowingPicker = false
        mentionSearchText = ""
    }
    
    /// Insert a selected mention into text, replacing the @query
    func insertMention(into text: String, candidate: MentionCandidate) -> String {
        let mentionText = "@\(candidate.username)"
        let prefix = String(text.prefix(mentionTriggerLocation))
        let suffix: String
        let afterTrigger = String(text.dropFirst(mentionTriggerLocation))
        
        if let spaceIndex = afterTrigger.firstIndex(of: " ") {
            suffix = String(afterTrigger[spaceIndex...])
        } else {
            suffix = ""
        }
        
        let newText = prefix + mentionText + " " + suffix
        
        let entity = MentionEntity(
            type: "mention",
            userId: candidate.id,
            username: candidate.username,
            rangeStart: mentionTriggerLocation,
            rangeLength: mentionText.utf16.count
        )
        
        entities.removeAll { $0.userId == candidate.id }
        entities.append(entity)
        isShowingPicker = false
        mentionSearchText = ""
        
        return newText
    }
    
    /// Reset state
    func reset() {
        entities = []
        isShowingPicker = false
        mentionSearchText = ""
        mentionTriggerLocation = 0
    }
}
