import SwiftUI

/// Glass-styled search bar for Discover
struct SearchBar: View {
    @Binding var text: String
    var placeholder: String = "Search users and posts..."
    
    @FocusState private var isFocused: Bool
    
    var body: some View {
        HStack(spacing: 10) {
            // Search icon
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.secondary)
            
            // Text field
            TextField(placeholder, text: $text)
                .font(.system(size: 16))
                .focused($isFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            
            // Clear button
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // Apple Native Liquid Glass Effect (iOS 26+)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

#Preview {
    VStack {
        SearchBar(text: .constant(""))
        SearchBar(text: .constant("test query"))
    }
    .background(Color.black.opacity(0.1))
}
