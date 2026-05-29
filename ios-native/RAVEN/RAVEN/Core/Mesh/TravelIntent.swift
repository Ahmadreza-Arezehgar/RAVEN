//
//  TravelIntent.swift
//  RAVEN
//
//  Travel intent model for Intent-based Data Mules.
//  Users announce travel plans (e.g., "Tehran → Isfahan") so their device
//  can carry messages for that corridor.
//
//  Security: Ed25519 signed, max 1 active per user, 2h broadcast lead time.
//

import Foundation
import CryptoKit

// MARK: - Travel Intent

struct TravelIntent: Codable, Identifiable {
    var id: String { intentId }
    
    let intentId: String              // UUID
    let userIdHashed: String          // HMAC hash for privacy
    let fromRegion: UInt64            // H3 cell of origin
    let toRegion: UInt64              // H3 cell of destination
    let viaRegions: [UInt64]          // Optional waypoint H3 cells
    let departureTime: Date
    let estimatedArrivalTime: Date
    let capacityMB: Int               // Payload capacity (10, 50, 200)
    let createdAt: Date
    
    // Security
    let signature: String?            // Ed25519 signature (base64)
    let signerPublicKey: String?      // Signer's public key (base64)
    
    // MARK: - Coding Keys (Short for BLE)
    
    enum CodingKeys: String, CodingKey {
        case intentId = "ii"
        case userIdHashed = "uh"
        case fromRegion = "fr"
        case toRegion = "tr"
        case viaRegions = "vr"
        case departureTime = "dt"
        case estimatedArrivalTime = "eat"
        case capacityMB = "cap"
        case createdAt = "ca"
        case signature = "s"
        case signerPublicKey = "spk"
    }
    
    // MARK: - Constants
    
    /// Maximum 1 active intent per user.
    static let maxActivePerUser = 1
    
    /// Broadcast lead time: start announcing 2 hours before departure.
    static let broadcastLeadTime: TimeInterval = 7200  // 2 hours
    
    /// Maximum intent validity: 48 hours from departure.
    static let maxDuration: TimeInterval = 172800
    
    /// Capacity options.
    static let capacityOptions: [Int] = [10, 50, 200]
    
    // MARK: - Computed Properties
    
    /// Whether this intent is currently active (between broadcast time and arrival).
    var isActive: Bool {
        let now = Date()
        let broadcastStart = departureTime.addingTimeInterval(-Self.broadcastLeadTime)
        return now >= broadcastStart && now <= estimatedArrivalTime
    }
    
    /// Whether it's time to start broadcasting this intent.
    var shouldBroadcast: Bool {
        let now = Date()
        let broadcastStart = departureTime.addingTimeInterval(-Self.broadcastLeadTime)
        return now >= broadcastStart && now <= departureTime
    }
    
    /// Whether this intent has expired.
    var isExpired: Bool {
        Date() > estimatedArrivalTime
    }
    
    /// Estimated travel duration.
    var estimatedDuration: TimeInterval {
        estimatedArrivalTime.timeIntervalSince(departureTime)
    }
    
    /// Time remaining until arrival (nil if already arrived).
    var timeRemaining: TimeInterval? {
        let remaining = estimatedArrivalTime.timeIntervalSince(Date())
        return remaining > 0 ? remaining : nil
    }
    
    // MARK: - Signing
    
    /// Data used for signing — covers all immutable fields.
    func signingData() -> Data {
        let delimiter = Data("|".utf8)
        var data = Data()
        data.append(intentId.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(userIdHashed.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(String(fromRegion).data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(String(toRegion).data(using: .utf8) ?? Data())
        data.append(delimiter)
        let departureTs = String(Int64(round(departureTime.timeIntervalSince1970 * 1000)))
        data.append(departureTs.data(using: .utf8) ?? Data())
        data.append(delimiter)
        let arrivalTs = String(Int64(round(estimatedArrivalTime.timeIntervalSince1970 * 1000)))
        data.append(arrivalTs.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(String(capacityMB).data(using: .utf8) ?? Data())
        return data
    }
    
    /// Return a signed copy of this intent.
    func signed() -> TravelIntent {
        let data = signingData()
        guard let sig = DeviceIdentityService.shared.sign(data) else { return self }
        
        return TravelIntent(
            intentId: intentId,
            userIdHashed: userIdHashed,
            fromRegion: fromRegion,
            toRegion: toRegion,
            viaRegions: viaRegions,
            departureTime: departureTime,
            estimatedArrivalTime: estimatedArrivalTime,
            capacityMB: capacityMB,
            createdAt: createdAt,
            signature: sig.base64EncodedString(),
            signerPublicKey: DeviceIdentityService.shared.publicKeyBase64
        )
    }
    
    /// Verify signature on this intent.
    func isSignatureValid() -> Bool {
        guard let sigBase64 = signature,
              let sig = Data(base64Encoded: sigBase64),
              let pubKeyBase64 = signerPublicKey,
              let pubKey = Data(base64Encoded: pubKeyBase64) else {
            return false
        }
        return DeviceIdentityService.shared.verify(
            signature: sig,
            data: signingData(),
            publicKey: pubKey
        )
    }
}

// MARK: - Creation Helper

extension TravelIntent {
    /// Create a new travel intent for the current user.
    static func create(
        fromRegion: UInt64,
        toRegion: UInt64,
        viaRegions: [UInt64] = [],
        departureTime: Date,
        estimatedArrivalTime: Date,
        capacityMB: Int = 50
    ) -> TravelIntent {
        // HMAC hash user ID for privacy
        let userId = DeviceIdentityService.shared.fingerprint ?? ""
        let key = SymmetricKey(data: SHA256.hash(data: Data("raven-mule-key".utf8)))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(userId.utf8), using: key)
        let hashedId = Data(mac).prefix(12).base64EncodedString()
        
        let intent = TravelIntent(
            intentId: UUID().uuidString,
            userIdHashed: hashedId,
            fromRegion: fromRegion,
            toRegion: toRegion,
            viaRegions: viaRegions,
            departureTime: departureTime,
            estimatedArrivalTime: estimatedArrivalTime,
            capacityMB: capacityMB,
            createdAt: Date(),
            signature: nil,
            signerPublicKey: nil
        )
        
        return intent.signed()
    }
}
