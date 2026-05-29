//
//  ContactCardMessageView.swift
//  RAVEN
//
//  Renders a `MessageType.contactCard` payload as a postcard:
//    ┌──────────────────────────────────┐
//    │  [avatar]   Display Name         │
//    │             @username            │
//    │                                  │
//    │            [ QR code ]           │
//    │                                  │
//    │      [ Open profile ]            │
//    └──────────────────────────────────┘
//
//  Wire format: `ContactSharePayload` JSON in `message.text`. Sent by
//  `MessageService.sendContactShare(...)`, triggered from the Contact tab
//  in `LiquidGlassAttachmentSheet`.
//

import SwiftUI
import CoreImage.CIFilterBuiltins

struct ContactCardMessageView: View {
    let message: ChatMessage
    let isFromMe: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var showQR = false

    private var payload: ContactSharePayload? {
        guard let text = message.text, !text.isEmpty else { return nil }
        // Filter out raw encrypted / failed-decrypt content so we don't
        // try to JSON-decode a base64 ciphertext.
        if text.hasPrefix("gAAAA") || text.contains("DECRYPT_FAILED") {
            return nil
        }
        return ContactSharePayload.decode(from: text)
    }

    private var accentColor: Color {
        switch message.deliveryAuthority {
        case .mesh: return .purple
        case .server: return .orange
        case .unknown: return .gray
        }
    }

    var body: some View {
        if let payload {
            cardBody(payload: payload)
        } else {
            placeholder
        }
    }

    @ViewBuilder
    private func cardBody(payload: ContactSharePayload) -> some View {
        // Compact glass postcard — avatar + name + QR-button + Open profile.
        // The QR is intentionally a single icon-button: tap to expand it
        // full-screen so the receiver can scan it from another device. Keeps
        // the bubble small in the chat thread (Telegram-style).
        HStack(spacing: 12) {
            ContactAvatar(payload: payload, accent: accentColor)
                .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 2) {
                Text(payload.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("@\(payload.username)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // QR icon — tap → full-screen QR sheet
            Button {
                Haptics.light()
                showQR = true
            } label: {
                Image(systemName: "qrcode")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle().fill(.ultraThinMaterial)
                    )
                    .overlay(
                        Circle().stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)

            // Open profile arrow capsule — kept as a small chevron pill so
            // the row stays single-line and the card doesn't grow tall.
            Button {
                Haptics.light()
                NotificationCenter.default.post(
                    name: .ravenContactCardOpenTapped,
                    object: nil,
                    userInfo: [
                        "userId": payload.userId,
                        "username": payload.username
                    ]
                )
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle().fill(
                            LinearGradient(
                                colors: [accentColor, accentColor.opacity(0.78)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    )
                    .overlay(Circle().stroke(Color.white.opacity(0.20), lineWidth: 0.5))
                    .shadow(color: accentColor.opacity(0.35), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 280)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    colorScheme == .dark
                        ? Color.white.opacity(0.14)
                        : Color.black.opacity(0.06),
                    lineWidth: 0.5
                )
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.30 : 0.10), radius: 10, y: 4)
        .sheet(isPresented: $showQR) {
            ContactQRSheet(payload: payload, accent: accentColor)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
        }
    }

    private var placeholder: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Shared contact")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }
}

// MARK: - Avatar

private struct ContactAvatar: View {
    let payload: ContactSharePayload
    let accent: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [accent.opacity(0.55), accent.opacity(0.25)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let path = payload.avatarUrl, !path.isEmpty,
               let url = AppConfig.mediaURL(from: path) {
                CachedAsyncImage(url: url) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    initials
                }
                .clipShape(Circle())
            } else {
                initials
            }
        }
        .overlay(
            Circle().stroke(Color.white.opacity(0.20), lineWidth: 1)
        )
    }

    private var initials: some View {
        let letters = payload.displayName
            .split(separator: " ")
            .compactMap { $0.first }
            .prefix(2)
            .map(String.init)
            .joined()
            .uppercased()
        return Text(letters.isEmpty ? String(payload.username.prefix(1)).uppercased() : letters)
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
    }
}

// MARK: - QR Sheet (full-screen QR for scanning)

private struct ContactQRSheet: View {
    let payload: ContactSharePayload
    let accent: Color

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { proxy in
            // Size the QR card to a sensible fraction of the viewport so
            // it never gets clipped by the drag indicator at the top or
            // the home indicator at the bottom — fixed 260pt looked fine
            // on a Pro but cramped on smaller devices.
            let cardSide = min(proxy.size.width - 64, 320)

            VStack(spacing: 18) {
                // Header — name + handle. Padded down from the drag
                // indicator so the title doesn't get hidden behind it.
                VStack(spacing: 4) {
                    Text(payload.displayName)
                        .font(.system(size: 22, weight: .semibold))
                        .lineLimit(1)
                    Text("@\(payload.username)")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.top, 28)

                Spacer(minLength: 8)

                // QR card. Background MUST be solid white — scanners need
                // a high-contrast quiet zone around the modules and the
                // glass material was making the code unreadable when the
                // sheet sat on a dark chat behind it.
                if let url = payload.profileURL {
                    ContactQRCode(url: url, tint: accent)
                        .frame(width: cardSide - 40, height: cardSide - 40)
                        .padding(20)               // quiet zone
                        .frame(width: cardSide, height: cardSide)
                        .background(
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .fill(Color.white)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .stroke(Color.black.opacity(0.06), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.22), radius: 22, y: 10)
                }

                Text("Scan with another phone to open this profile.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 4)

                Spacer(minLength: 12)

                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            Capsule().fill(
                                LinearGradient(
                                    colors: [accent, accent.opacity(0.78)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        )
                        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 22)
                // Respect the home-indicator inset; without this the
                // capsule sits flush against the bottom edge.
                .padding(.bottom, max(16, proxy.safeAreaInsets.bottom))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - QR Code

private struct ContactQRCode: View {
    let url: URL
    let tint: Color

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                ZStack {
                    Color.gray.opacity(0.10)
                    ProgressView().scaleEffect(0.7)
                }
            }
        }
        .task(id: url.absoluteString) {
            image = await Self.render(url: url)
        }
    }

    /// CIFilter-based QR generation. Runs off the main actor — the cost
    /// of the bitmap render is non-trivial on the first frame and we
    /// don't want it to hitch the message-list scroll.
    nonisolated private static func render(url: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(url.absoluteString.utf8)
            filter.correctionLevel = "M"
            guard let output = filter.outputImage else { return nil as UIImage? }
            // Upscale the tiny native CI output so the QR doesn't blur
            // when SwiftUI scales it to fit a 130pt frame.
            let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
            let context = CIContext()
            guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil as UIImage? }
            return UIImage(cgImage: cg)
        }.value
    }
}

// MARK: - Notification names

extension Notification.Name {
    /// Posted when the user taps "Open profile" on a shared-contact card.
    /// Observed by ChatView (or any host) to route to the user's profile.
    static let ravenContactCardOpenTapped = Notification.Name("raven.contactCardOpenTapped")
}
