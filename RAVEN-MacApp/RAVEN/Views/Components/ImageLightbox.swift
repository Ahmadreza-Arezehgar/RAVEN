// ImageLightbox — full-screen single-image viewer presented as a sheet
// from any post media tap. Click outside or hit Escape to dismiss.

import SwiftUI

struct ImageLightbox: View {
    let url: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            if let imageURL = URL(string: url) {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .empty:
                        ProgressView().tint(.white)
                    case .failure:
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 36))
                            Text("Couldn't load image")
                                .font(.subheadline)
                        }
                        .foregroundStyle(.white)
                    @unknown default:
                        Color.clear
                    }
                }
                .padding(20)
            }

            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(14)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .frame(minWidth: 600, minHeight: 480)
    }
}
