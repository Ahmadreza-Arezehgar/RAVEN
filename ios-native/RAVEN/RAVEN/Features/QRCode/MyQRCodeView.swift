import SwiftUI
import CoreImage.CIFilterBuiltins

// MARK: - My QR Code View
//
// Displays the user's unique QR for **friend requests only**.
//
// Important: this is NOT a login QR. RAVEN deliberately keeps the
// login-QR pattern desktop-only (the macOS / Web client shows the
// login QR; this phone scans it via `ScanQRCodeView` →
// `DesktopLoginApprovalView`). Showing a login QR on the phone would
// invert the security model — anyone snapping a photo of your screen
// could attempt to sign in. The friend QR below is harmless: at worst
// it lets a stranger send you a friend request you can decline.
struct MyQRCodeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var authService = AuthService.shared
    
    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                
                // QR Code Card (Liquid Glass)
                VStack(spacing: 20) {
                    // QR Code
                    if let qrImage = generateQRCode() {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 200, height: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        ProgressView()
                            .frame(width: 200, height: 200)
                    }
                    
                    // Username
                    VStack(spacing: 4) {
                        let user = authService.currentUser
                        let name = user?.displayName ?? "User"
                        Text(name)
                            .font(.system(size: 20, weight: .semibold))

                        // Only show the "@username" line when a *distinct*
                        // username exists. `User.displayName` already falls back
                        // to `username` when there's no first/last name, so
                        // rendering both unconditionally would print the same
                        // string twice (serverless local identity case).
                        if let username = user?.username,
                           !username.isEmpty,
                           username != name {
                            Text("@\(username)")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    // Hint — explicit "for adding friends" so the
                    // user can never confuse this with a login QR
                    // (login QR is desktop-only; phones scan, never
                    // display, login codes).
                    VStack(spacing: 6) {
                        Text("Friend request code")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("Let others scan this to send you a friend request. This code does NOT log anyone into your account.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                .padding(24)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.8)
                )
                .shadow(color: .black.opacity(0.1), radius: 20, x: 0, y: 10)
                .padding(.horizontal, 32)
                
                Spacer()
                
                Spacer()
            }
            .navigationTitle("My Friend QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
                #if DEBUG
                // 🧪 DEBUG-only: copy the signed QR payload to the clipboard so
                // it can be exchanged as text (sim/desktop testing, where there's
                // no camera). Mirrors ScanQRCodeView's DEBUG paste button.
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Copy code") {
                        if let s = qrPayloadString() {
                            UIPasteboard.general.string = s
                        }
                    }
                }
                #endif
            }
        }
        .allowScreenshots()  // 📸 Allow screenshots for QR code sharing
    }
    
    // MARK: - Generate QR Code

    /// Build the signed `raven://friend?v=2&d=…` payload string (the exact text
    /// encoded into the QR image). Factored out so DEBUG builds can also copy it
    /// to the clipboard for text-based contact exchange.
    private func qrPayloadString() -> String? {
        guard let userId = authService.currentUser?.id else { return nil }
        let agreementB64 = DeviceIdentityService.shared.agreementPublicKeyData?.base64EncodedString()
        let identityB64 = DeviceIdentityService.shared.publicKeyBase64
        let fingerprint = DeviceIdentityService.shared.fingerprint
        let now = Date().timeIntervalSince1970
        let transcript = FriendQRPayload.canonicalTranscript(
            userId: userId,
            agreementPubBase64: agreementB64,
            identityPubBase64: identityB64,
            issuedAt: now
        )
        let signatureB64: String? = DeviceIdentityService.shared.sign(transcript)?.base64EncodedString()
        let payloadStruct = FriendQRPayload(
            userId: userId,
            displayName: authService.currentUser?.displayName,
            username: authService.currentUser?.username,
            agreementPubBase64: agreementB64,
            identityPubBase64: identityB64,
            fingerprint: fingerprint,
            issuedAt: now,
            signatureB64: signatureB64
        )
        // Fall back to v1 if encoding fails so a legacy-aware scanner can still
        // pick up the userId.
        return payloadStruct.toQRString() ?? "raven://friend?user_id=\(userId)"
    }

    private func generateQRCode() -> UIImage? {
        // v2 packs everything the scanner needs (display name, X25519 agreement
        // pub for sealed E2EE on first contact, Ed25519 identity pub for Safety
        // Number, optional fingerprint) directly inside the URL as a signed
        // base64 blob — see qrPayloadString().
        guard let payload = qrPayloadString(),
              let data = payload.data(using: .utf8) else { return nil }
        
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel") // High error correction
        
        guard let outputImage = filter.outputImage else { return nil }
        
        // Scale up for better quality
        let scale = 10.0
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Preview
#Preview {
    MyQRCodeView()
}
