//
//  ChatDetailSections.swift
//  RAVEN
//
//  (2026-05-15 — round 5) Modular section components dropped into
//  both the 1:1 ChatDetailsView and GroupSettingsView. Each section
//  is self-contained: takes a small set of state inputs, renders a
//  Liquid Glass row, and calls back when the user toggles something.
//
//  Why one file with many views (vs. one file each):
//    • These all share the same row chrome, accent palette, and
//      capsule layout. Keeping them adjacent makes drift between
//      sections obvious in review.
//    • Each section is < 80 lines on its own — small enough that the
//      grouped file still reads cleanly.

import SwiftUI
import CryptoKit

// MARK: - Shared row chrome
//
// All Tier 1/2/3 sections use the same row treatment: a glass
// rounded-rect with an icon, title, optional value chip on the
// right, and a chevron when tappable.

struct ChatDetailRow: View {
    let icon: String
    let iconTint: Color
    let title: String
    /// Trailing value chip — e.g. "Off", "5 days", "Verified". Empty
    /// hides the chip entirely.
    var value: String = ""
    var valueTint: Color = .secondary
    /// When true the row paints a chevron and the whole surface is
    /// tappable. False renders an inert info row.
    var isTappable: Bool = true
    /// Destructive variant for "Block / Report / Leave group" — paints
    /// the title in red, hides the icon tint.
    var isDestructive: Bool = false
    /// Optional accessory pill; replaces the value chip when both are set.
    var accessory: AnyView? = nil
    var onTap: (() -> Void)? = nil

    var body: some View {
        Button {
            guard isTappable else { return }
            Haptics.selection()
            onTap?()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill((isDestructive ? Color.red : iconTint).opacity(0.14))
                        .frame(width: 30, height: 30)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isDestructive ? .red : iconTint)
                }

                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(isDestructive ? .red : .primary)

                Spacer(minLength: 8)

                if let accessory {
                    accessory
                } else if !value.isEmpty {
                    Text(value)
                        .font(.subheadline)
                        .foregroundStyle(valueTint)
                }

                if isTappable {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isTappable)
    }
}

// MARK: - Tier 1 #1: Safety Number / ATSAM verification

/// Surfaces an out-of-band-verifiable fingerprint of the encryption
/// session shared with this peer.
///
/// SECURITY FIX (2026-05-15 — round 6): the previous derivation
/// folded each device's *own* agreement public key into the hash
/// alongside the *other* user's id. That meant device A computed
/// `H(pubA, userB)` and device B computed `H(pubB, userA)` — two
/// different inputs, so the fingerprints never matched, defeating
/// the entire point of verification (the user spotted this in the
/// wild). The corrected construction is symmetric: both devices
/// hash the SAME bytes regardless of who initiates, by sorting the
/// two user ids lexicographically before concatenating:
///
///     fp = SHA-256( label ‖ sortedLow ‖ "|" ‖ sortedHigh )
///
/// This is "identity verification" — it proves both sides hold the
/// same user-id pair. Binding to actual key material is a TODO that
/// requires the per-user agreement-key publication endpoint.
struct SafetyNumberRow: View {
    let peerIdentifier: String
    var isVerified: Bool = false
    var onTap: (() -> Void)? = nil

    var body: some View {
        ChatDetailRow(
            icon: isVerified ? "checkmark.shield.fill" : "shield.lefthalf.filled",
            iconTint: isVerified ? .green : .orange,
            title: "Encryption verification",
            value: isVerified ? "Verified" : "Tap to verify",
            valueTint: isVerified ? .green : .orange,
            onTap: onTap
        )
    }

    /// 60-digit numeric fingerprint that is **identical on both
    /// devices** for a given (myUserId, peerUserId) pair. The two
    /// ids are sorted before hashing, so order doesn't matter — A
    /// looking at B's chat and B looking at A's chat compute the
    /// same value.
    ///
    /// 🔴 ROUND 26 (2026-05-17) — CRITICAL FIX.
    ///
    /// PREVIOUSLY used `SHA256` which produces only 32 bytes, but
    /// the loop ran 60 times. After iteration 32, `byteIter.next()`
    /// returned nil and the code fell back to
    /// `UInt8.random(in: 0...255)` — generating NON-DETERMINISTIC
    /// random digits for the last 28 positions. Two devices viewing
    /// the same conversation saw the FIRST ~32 digits match but the
    /// LAST 28 digits diverge — exactly the bug the user reported
    /// with screenshots showing matching prefix + diverging suffix.
    ///
    /// Worse: the Safety-Number compare flow tells the user
    /// "matching numbers prove your conversation isn't being
    /// intercepted." With the broken digits, mismatches looked
    /// like MITM attacks when they were just RNG noise.
    ///
    /// FIX: switch to `SHA512` which produces 64 bytes (plenty for
    /// 60 digits). No more random fallback. Both devices now
    /// compute identical fingerprints from the same (sorted-userId-
    /// pair) input.
    ///
    /// NOTE: fingerprints generated under the old code are now
    /// invalid — users who marked verifications under the old
    /// fingerprint will see a "new" fingerprint after this fix and
    /// may need to re-verify. Acceptable cost since old data was
    /// non-deterministic garbage.
    static func fingerprint(myUserId: String?, peerUserId: String) -> String {
        guard let myUserId, !myUserId.isEmpty else {
            return String(repeating: "0", count: 60)
        }
        let (low, high) = myUserId < peerUserId
            ? (myUserId, peerUserId)
            : (peerUserId, myUserId)
        var hasher = SHA512()
        hasher.update(data: Data("ATSAM/v1/safety-number/identity".utf8))
        hasher.update(data: Data(low.utf8))
        hasher.update(data: Data("|".utf8))
        hasher.update(data: Data(high.utf8))
        let digest = hasher.finalize()
        // 5 chunks × 12 digits each = 60 digits total.
        // SHA-512 gives us 64 bytes — exactly enough, with 4 to spare.
        var digits = ""
        var byteIter = digest.makeIterator()
        for _ in 0..<60 {
            guard let b = byteIter.next() else {
                // Should be unreachable with SHA-512 (64 bytes ≥ 60),
                // but if it ever happens, return zeros — NEVER random.
                // Random would re-introduce the original divergence bug.
                return String(repeating: "0", count: 60)
            }
            digits.append("\(Int(b) % 10)")
        }
        return digits
    }
}

// MARK: - Tier 1 #2: Mesh Proximity / Last Seen

/// Three-state pill: online via server, reachable via mesh, offline.
/// Backed by `MeshPresenceProbe` (small wrapper that asks
/// `BLEMeshEngine` whether the peer is currently advertising).
struct MeshProximityRow: View {
    enum State: Equatable {
        case onlineServer
        case onlineMesh(lastSeen: Date)
        case offline(lastSeen: Date?)

        var icon: String {
            switch self {
            case .onlineServer: return "wifi"
            case .onlineMesh:   return "antenna.radiowaves.left.and.right"
            case .offline:      return "wifi.slash"
            }
        }

        var tint: Color {
            switch self {
            case .onlineServer: return .green
            case .onlineMesh:   return .blue
            case .offline:      return .secondary
            }
        }

        var label: String {
            switch self {
            case .onlineServer: return "Online"
            case .onlineMesh(let last): return "Mesh · \(Self.relative(last))"
            case .offline(let last):
                if let last { return "Last seen \(Self.relative(last))" }
                return "Last seen unknown"
            }
        }

        private static func relative(_ date: Date) -> String {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return formatter.localizedString(for: date, relativeTo: Date())
        }
    }

    let state: State

    var body: some View {
        ChatDetailRow(
            icon: state.icon,
            iconTint: state.tint,
            title: "Reachability",
            value: state.label,
            valueTint: state.tint,
            isTappable: false
        )
    }
}

// MARK: - Tier 1 #3 & #4: Disappearing messages + Always-Vault

struct DisappearingMessagesRow: View {
    let timer: DisappearingTimer
    var onTap: (() -> Void)? = nil

    var body: some View {
        ChatDetailRow(
            icon: timer.symbolName,
            iconTint: timer == .off ? .secondary : .accentColor,
            title: "Disappearing messages",
            value: timer.displayName,
            valueTint: timer == .off ? .secondary : .accentColor,
            onTap: onTap
        )
    }
}

struct AlwaysVaultRow: View {
    let isOn: Bool
    var onToggle: ((Bool) -> Void)? = nil

    var body: some View {
        ChatDetailRow(
            icon: isOn ? "lock.fill" : "lock.open",
            iconTint: isOn ? .accentColor : .secondary,
            title: "Always send as Vault",
            isTappable: false,
            accessory: AnyView(
                Toggle("", isOn: Binding(
                    get: { isOn },
                    set: { onToggle?($0) }
                ))
                .labelsHidden()
                .tint(.accentColor)
            )
        )
    }
}

// MARK: - Tier 2 #5: Quick action row (no audio/video calls)

struct QuickActionRow: View {
    var onSearch: (() -> Void)? = nil
    var onShareContact: (() -> Void)? = nil
    /// Optional third action — group-only "Add member".
    var trailing: QuickAction? = nil

    struct QuickAction: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let action: () -> Void
    }

    var body: some View {
        HStack(spacing: 8) {
            actionPill(icon: "magnifyingglass", title: "Search", action: onSearch)
            actionPill(icon: "person.crop.rectangle.stack", title: "Share", action: onShareContact)
            if let trailing {
                actionPill(icon: trailing.icon, title: trailing.title, action: trailing.action)
            }
        }
    }

    @ViewBuilder
    private func actionPill(icon: String, title: String, action: (() -> Void)?) -> some View {
        Button {
            guard let action else { return }
            Haptics.selection()
            action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                Text(title)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary.opacity(0.85))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

// MARK: - Tier 2 #6: Block / Report (DM) and Leave (group)

struct BlockReportRow: View {
    var blockTitle: String = "Block this contact"
    var reportTitle: String = "Report"
    var onBlock: (() -> Void)? = nil
    var onReport: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            ChatDetailRow(
                icon: "hand.raised.fill",
                iconTint: .red,
                title: blockTitle,
                isTappable: onBlock != nil,
                isDestructive: true,
                onTap: onBlock
            )
            ChatDetailRow(
                icon: "exclamationmark.triangle.fill",
                iconTint: .red,
                title: reportTitle,
                isTappable: onReport != nil,
                isDestructive: true,
                onTap: onReport
            )
        }
    }
}

// MARK: - Tier 2 #7: Pinned messages

struct PinnedMessagesRow: View {
    let pinnedCount: Int
    var onTap: (() -> Void)? = nil

    var body: some View {
        ChatDetailRow(
            icon: "pin.fill",
            iconTint: .yellow,
            title: "Pinned messages",
            value: pinnedCount == 0 ? "None" : "\(pinnedCount)",
            isTappable: pinnedCount > 0,
            onTap: onTap
        )
    }
}

// MARK: - Tier 2 #8: Wallpaper picker

struct WallpaperRow: View {
    let current: ChatWallpaper
    var onTap: (() -> Void)? = nil

    var body: some View {
        ChatDetailRow(
            icon: "paintpalette.fill",
            iconTint: .purple,
            title: "Wallpaper",
            value: current.displayName,
            onTap: onTap
        )
    }
}

struct WallpaperPickerSheet: View {
    @Binding var selection: ChatWallpaper
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(ChatWallpaper.allCases) { wp in
                        Button {
                            Haptics.selection()
                            selection = wp
                            dismiss()
                        } label: {
                            VStack(spacing: 8) {
                                wallpaperPreview(wp)
                                    .frame(height: 140)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(
                                                wp == selection ? Color.accentColor : Color.primary.opacity(0.12),
                                                lineWidth: wp == selection ? 2.5 : 0.5
                                            )
                                    )
                                Text(wp.displayName)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Wallpaper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func wallpaperPreview(_ wp: ChatWallpaper) -> some View {
        if let stops = wp.gradientStops, stops.count == 2,
           let top = colorFromHex(stops[0]), let bottom = colorFromHex(stops[1]) {
            LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
        } else {
            Color(.systemBackground)
                .overlay(
                    Image(systemName: "circle.dotted")
                        .font(.title)
                        .foregroundStyle(.secondary)
                )
        }
    }
}

// MARK: - Tier 3 #9: Common groups

struct CommonGroupsRow: View {
    let count: Int
    var onTap: (() -> Void)? = nil

    var body: some View {
        ChatDetailRow(
            icon: "person.3.fill",
            iconTint: .teal,
            title: "Groups in common",
            value: count == 0 ? "None" : "\(count)",
            isTappable: count > 0,
            onTap: onTap
        )
    }
}

// MARK: - Tier 3 #10: Storage usage

struct StorageRow: View {
    let bytes: Int64
    var onManage: (() -> Void)? = nil

    private var human: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        ChatDetailRow(
            icon: "internaldrive.fill",
            iconTint: .gray,
            title: "Storage",
            value: bytes == 0 ? "Empty" : human,
            isTappable: onManage != nil,
            onTap: onManage
        )
    }
}

// MARK: - Tier 3 #11: Encryption details

struct EncryptionDetailsRow: View {
    let protocolLabel: String
    let pqcEnabled: Bool
    var onTap: (() -> Void)? = nil

    var body: some View {
        ChatDetailRow(
            icon: "key.fill",
            iconTint: .indigo,
            title: "Encryption details",
            value: pqcEnabled ? "\(protocolLabel) · PQC" : protocolLabel,
            valueTint: pqcEnabled ? .indigo : .secondary,
            onTap: onTap
        )
    }
}

// MARK: - Tier 3 #12: Export chat

struct ExportChatRow: View {
    var onTap: (() -> Void)? = nil

    var body: some View {
        ChatDetailRow(
            icon: "square.and.arrow.up.on.square",
            iconTint: .blue,
            title: "Export chat",
            value: "",
            onTap: onTap
        )
    }
}

// MARK: - Color hex helper
//
// `Color(hex: String)` already exists elsewhere in the codebase as a
// throwing/non-optional init. Use a tiny local helper that returns
// an Optional<Color> so the wallpaper picker's optional-binding
// (`if let top = colorFromHex(stops[0])`) compiles cleanly.
fileprivate func colorFromHex(_ hex: String) -> Color? {
    var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
    let r = Double((v >> 16) & 0xFF) / 255.0
    let g = Double((v >> 8) & 0xFF) / 255.0
    let b = Double(v & 0xFF) / 255.0
    return Color(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
}
