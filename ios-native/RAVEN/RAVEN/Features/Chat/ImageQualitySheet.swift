import SwiftUI

// MARK: - Image Send Quality

enum ImageSendQuality: String, CaseIterable {
    case full = "full"
    case compressed = "compressed"
    
    var title: String {
        switch self {
        case .full: return "Full Quality"
        case .compressed: return "Compressed"
        }
    }
    
    var subtitle: String {
        switch self {
        case .full: return "Original resolution, larger file size"
        case .compressed: return "Faster upload, reduced file size"
        }
    }
    
    var icon: String {
        switch self {
        case .full: return "photo.artframe"
        case .compressed: return "arrow.down.right.and.arrow.up.left"
        }
    }
    
    var compressionQuality: CGFloat {
        switch self {
        case .full: return 0.95
        case .compressed: return 0.65
        }
    }
}

// MARK: - Image Quality Sheet

struct ImageQualitySheet: View {
    let image: UIImage
    let onSend: (UIImage, ImageSendQuality) -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Preview
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal)
                
                // Quality options
                VStack(spacing: 12) {
                    Text("Choose Quality")
                        .font(.headline)
                    
                    ForEach(ImageSendQuality.allCases, id: \.self) { quality in
                        qualityButton(quality)
                    }
                }
                .padding(.horizontal)
                
                Spacer()
            }
            .padding(.top)
            .navigationTitle("Send Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
    
    @ViewBuilder
    private func qualityButton(_ quality: ImageSendQuality) -> some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .medium)
            impact.impactOccurred()
            dismiss()
            onSend(image, quality)
        } label: {
            HStack(spacing: 16) {
                Image(systemName: quality.icon)
                    .font(.title2)
                    .frame(width: 40)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(quality.title)
                        .font(.headline)
                    Text(quality.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ImageQualitySheet(image: UIImage(systemName: "photo")!) { _, quality in
        print("Selected: \(quality)")
    }
}
