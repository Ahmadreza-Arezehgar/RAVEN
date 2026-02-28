//
//  PairingView.swift
//  RAVEN
//
//  Offline friend pairing UI with verification code
//

import SwiftUI
import CoreImage.CIFilterBuiltins

struct PairingView: View {
    @ObservedObject private var pairingService = OfflinePairingService.shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var showingScanner = false
    @State private var verificationInput = ""
    
    // Reusable QR code generation resources (CIContext is GPU-heavy)
    private let ciContext = CIContext()
    private let qrFilter = CIFilter.qrCodeGenerator()
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    // Header
                    headerSection
                    
                    // Local Identity
                    localIdentitySection
                    
                    // Pairing State
                    pairingStateSection
                    
                    // Action Buttons
                    actionSection
                }
                .padding()
            }
            .navigationTitle("Offline Pairing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingScanner) {
                PairingQRScannerView(pairingService: pairingService)
            }
        }
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            
            Text("Pair with friends nearby")
                .font(.headline)
            
            Text("Exchange encrypted identities via Bluetooth to enable offline messaging")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
    
    // MARK: - Local Identity
    
    private var localIdentitySection: some View {
        VStack(spacing: 16) {
            Text("Your Device Fingerprint")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            if let fingerprint = DeviceIdentityService.shared.fingerprint {
                Text(fingerprint)
                    .font(.system(.title2, design: .monospaced))
                    .fontWeight(.semibold)
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                
                // QR Code
                if let qrImage = generateQRCode(from: pairingService.generateQRCodeData()) {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                        .padding()
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                }
            } else {
                ProgressView("Generating identity...")
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
    
    // MARK: - Pairing State
    
    @ViewBuilder
    private var pairingStateSection: some View {
        switch pairingService.pairingState {
        case .idle:
            EmptyView()
            
        case .advertising:
            HStack(spacing: 12) {
                ProgressView()
                Text("Broadcasting identity...")
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            
        case .scanning:
            HStack(spacing: 12) {
                ProgressView()
                Text("Scanning for devices...")
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            
        case .exchanging:
            HStack(spacing: 12) {
                ProgressView()
                Text("Exchanging keys...")
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            
        case .verifying:
            verificationSection
            
        case .paired:
            successSection
            
        case .failed(let reason):
            VStack(spacing: 12) {
                Image(systemName: "xmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.red)
                Text("Pairing failed")
                    .font(.headline)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
    
    // MARK: - Verification Section
    
    private var verificationSection: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            
            Text("Verify with Partner")
                .font(.headline)
            
            if let code = pairingService.currentVerificationCode {
                Text(code)
                    .font(.system(size: 48, weight: .bold, design: .monospaced))
                    .tracking(8)
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            
            Text("Compare this code with your partner's device")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            HStack(spacing: 16) {
                Button {
                    pairingService.rejectPairing()
                } label: {
                    Label("Reject", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                
                Button {
                    Task {
                        try? await pairingService.confirmPairing()
                    }
                } label: {
                    Label("Confirm", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
    
    // MARK: - Success Section
    
    private var successSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
            
            Text("Paired Successfully!")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("You can now exchange messages offline")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
    
    // MARK: - Action Section
    
    private var actionSection: some View {
        VStack(spacing: 16) {
            switch pairingService.pairingState {
            case .idle:
                Button {
                    pairingService.startPairing()
                } label: {
                    Label("Start Pairing", systemImage: "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)
                
                Button {
                    showingScanner = true
                } label: {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.bordered)
                
            case .advertising, .scanning, .exchanging:
                Button {
                    pairingService.stopPairing()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.bordered)
                .tint(.red)
                
            case .paired:
                Button {
                    dismiss()
                } label: {
                    Label("Done", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)
                
            default:
                EmptyView()
            }
        }
    }
    
    // MARK: - QR Code Generator
    
    private func generateQRCode(from data: Data?) -> UIImage? {
        guard let data = data else { return nil }
        
        qrFilter.setValue(data, forKey: "inputMessage")
        qrFilter.setValue("H", forKey: "inputCorrectionLevel")
        
        guard let outputImage = qrFilter.outputImage else { return nil }
        
        let scale = UIScreen.main.scale * 10
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let scaledImage = outputImage.transformed(by: transform)
        
        guard let cgImage = ciContext.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }
        
        return UIImage(cgImage: cgImage)
    }
}

#Preview {
    PairingView()
}

// MARK: - Pairing QR Scanner View
struct PairingQRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = QRScannerViewModel()
    @ObservedObject var pairingService: OfflinePairingService
    @State private var showError = false

    var body: some View {
        NavigationStack {
            ZStack {
                QRScannerCameraView(scanner: scanner)
                    .ignoresSafeArea()

                VStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white, lineWidth: 3)
                        .frame(width: 250, height: 250)
                    Spacer()
                    Text("Scan a RAVEN Pairing QR Code")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .padding(.bottom, 60)
                }
            }
            .navigationTitle("Scan to Pair")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .onChange(of: scanner.scannedCode) { _, code in
                if let code = code, let data = code.data(using: .utf8) {
                    handleScannedData(data)
                }
            }
            .alert("Invalid QR Code", isPresented: $showError) {
                Button("OK", role: .cancel) { scanner.resumeScanning() }
            } message: {
                Text("This QR code is not a valid RAVEN offline pairing code.")
            }
        }
    }
    
    private func handleScannedData(_ data: Data) {
        Haptics.success()
        scanner.stopScanning()
        Task {
            do {
                try await pairingService.processQRCode(data)
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run {
                    showError = true
                    Haptics.error()
                }
            }
        }
    }
}
