//
//  OfflinePairingService.swift
//  RAVEN
//
//  Offline BLE-based friend pairing with verification
//

import Foundation
import CoreBluetooth
import Combine

/// Manages offline friend pairing via Bluetooth
/// Exchange public keys and verify with 6-digit code
@MainActor
final class OfflinePairingService: NSObject, ObservableObject {
    static let shared = OfflinePairingService()
    
    // MARK: - Published State
    
    @Published var pairingState: PairingState = .idle
    @Published var incomingRequests: [PairingRequest] = []
    @Published var currentVerificationCode: String?
    @Published var pendingPeer: PairingRequest?
    
    // MARK: - BLE UUIDs
    
    private let pairingServiceUUID = CBUUID(string: "A1B2C3D4-1234-1234-1234-000000000001")
    private let publicKeyCharUUID = CBUUID(string: "A1B2C3D4-1234-1234-1234-000000000002")
    private let userIdCharUUID = CBUUID(string: "A1B2C3D4-1234-1234-1234-000000000003")
    private let nonceCharUUID = CBUUID(string: "A1B2C3D4-1234-1234-1234-000000000004")
    
    // MARK: - Dependencies
    
    private let identity = DeviceIdentityService.shared
    private let deviceRepo = FriendDeviceRepository.shared
    
    // MARK: - Internal State
    
    private var centralManager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var pairingNonce: Data?
    
    private override init() {
        super.init()
    }
    
    // MARK: - Pairing States
    
    enum PairingState {
        case idle
        case advertising      // Broadcasting our identity
        case scanning         // Looking for peers
        case exchanging       // Exchanging keys
        case verifying        // Waiting for code confirmation
        case paired           // Successfully paired
        case failed(String)   // Failed with reason
    }
    
    // MARK: - Pairing Request Model
    
    struct PairingRequest: Identifiable {
        let id: String
        let fingerprint: String
        let publicKey: Data
        let userId: String?
        let deviceName: String?
        let receivedAt: Date
        var verificationCode: String?
    }
    
    // MARK: - Public API
    
    /// Start pairing mode (advertise + scan)
    func startPairing() {
        #if DEBUG
        print("🔗 [Pairing] Starting offline pairing mode")
        #endif
        
        // Generate nonce for this session
        pairingNonce = generateNonce()
        
        pairingState = .advertising
        
        // Start BLE advertising and scanning
        // Note: In real implementation, use CBCentralManager and CBPeripheralManager
        
        #if DEBUG
        print("🔗 [Pairing] Advertising fingerprint: \(identity.fingerprint ?? "unknown")")
        #endif
    }
    
    /// Handle incoming pairing request
    func handleIncomingPairing(publicKey: Data, userId: String?, deviceName: String?) {
        let fingerprint = DeviceIdentityService.deriveFingerprint(from: publicKey)
        
        let request = PairingRequest(
            id: UUID().uuidString,
            fingerprint: fingerprint,
            publicKey: publicKey,
            userId: userId,
            deviceName: deviceName,
            receivedAt: Date()
        )
        
        // Auto-generate nonce if user scanned QR directly without tapping "Start Pairing"
        if pairingNonce == nil {
            pairingNonce = generateNonce()
        }
        
        // Generate verification code
        guard let localPubKey = identity.publicKeyData,
              let nonce = pairingNonce else {
            pairingState = .failed("No local identity")
            return
        }
        
        let code = DeviceIdentityService.generateVerificationCode(
            localPubKey: localPubKey,
            remotePubKey: publicKey,
            nonce: nonce
        )
        
        var requestWithCode = request
        requestWithCode.verificationCode = code
        
        pendingPeer = requestWithCode
        currentVerificationCode = code
        pairingState = .verifying
        
        #if DEBUG
        print("🔗 [Pairing] Received request from: \(fingerprint)")
        print("🔗 [Pairing] Verification code: \(code)")
        #endif
    }
    
    /// Confirm pairing after code verification
    func confirmPairing() async throws {
        guard let peer = pendingPeer else {
            throw PairingError.noPendingPeer
        }
        
        // Create friend device entry
        let friendDevice = FriendDevice(
            friendUserId: peer.userId ?? peer.fingerprint,
            fingerprint: peer.fingerprint,
            publicKey: peer.publicKey,
            trustState: .trusted,
            verifiedAt: Date(),
            deviceName: peer.deviceName
        )
        
        // Save to database
        try await deviceRepo.upsert(friendDevice)
        
        pairingState = .paired
        pendingPeer = nil
        currentVerificationCode = nil
        
        #if DEBUG
        print("✅ [Pairing] Successfully paired with: \(peer.fingerprint)")
        #endif
    }
    
    /// Reject pairing request
    func rejectPairing() {
        #if DEBUG
        print("❌ [Pairing] Rejected pairing request")
        #endif
        pendingPeer = nil
        currentVerificationCode = nil
        pairingState = .idle
    }
    
    /// Stop pairing mode
    func stopPairing() {
        pairingState = .idle
        pendingPeer = nil
        currentVerificationCode = nil
        pairingNonce = nil
        
        // Stop BLE advertising/scanning
        
        #if DEBUG
        print("🔗 [Pairing] Stopped pairing mode")
        #endif
    }
    
    // MARK: - QR Code Pairing (Alternative)
    
    /// Generate QR code data for pairing
    func generateQRCodeData() -> Data? {
        guard let publicKey = identity.publicKeyData,
              let fingerprint = identity.fingerprint else {
            return nil
        }
        
        // Bug 7 fix: Generate and include nonce in QR payload
        // so both devices use the same nonce for verification code
        if pairingNonce == nil {
            pairingNonce = generateNonce()
        }
        
        let payload = PairingQRPayload(
            fingerprint: fingerprint,
            publicKey: publicKey.base64EncodedString(),
            userId: AuthService.shared.currentUser?.id,
            nonce: pairingNonce?.base64EncodedString()
        )
        
        return try? JSONEncoder().encode(payload)
    }
    
    /// Process scanned QR code
    func processQRCode(_ data: Data) async throws {
        let payload = try JSONDecoder().decode(PairingQRPayload.self, from: data)
        
        guard let publicKeyData = Data(base64Encoded: payload.publicKey) else {
            throw PairingError.invalidQRCode
        }
        
        // Bug 7 fix: Use nonce from QR payload (generated by the other device)
        // so both devices derive the same verification code
        if let nonceBase64 = payload.nonce,
           let nonceData = Data(base64Encoded: nonceBase64) {
            pairingNonce = nonceData
        }
        
        handleIncomingPairing(
            publicKey: publicKeyData,
            userId: payload.userId,
            deviceName: nil
        )
    }
    
    // MARK: - Private Helpers
    
    private func generateNonce() -> Data {
        var nonce = Data(count: 16)
        nonce.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, 16, baseAddress)
        }
        return nonce
    }
    
    // MARK: - Errors
    
    enum PairingError: Error {
        case noPendingPeer
        case invalidQRCode
        case noLocalIdentity
        case bleUnavailable
    }
}

// MARK: - QR Payload

struct PairingQRPayload: Codable {
    let fingerprint: String
    let publicKey: String
    let userId: String?
    let nonce: String?  // Bug 7 fix: Include nonce for consistent verification codes
}
