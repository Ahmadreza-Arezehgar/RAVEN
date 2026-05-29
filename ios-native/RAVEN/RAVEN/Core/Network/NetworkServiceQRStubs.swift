//
//  NetworkServiceQRStubs.swift
//  RAVEN
//
//  Surface-level stubs for the QR-login + identity-key REST API the
//  Phase-4 commit added to NetworkService and the revert removed.
//  `DesktopLoginApprovalView` still depends on every method below.
//
//  Stubs throw a "feature unavailable" error so the desktop-link
//  flow surfaces a clean message ("QR login is temporarily disabled
//  while the linked-device service is being restored") instead of
//  hanging forever. Restore against `server/routers/qr_login.py`
//  when the real Phase-4 wiring comes back.
//

import Foundation

// MARK: - DTOs

struct QRScanRequest: Encodable {
    let sessionId: String
    let nonce: String
    let deviceFingerprint: String
    let timestamp: Int
    let signature: String
}

struct QRScanResponse: Decodable {
    let requesterIp: String?
    let expiresAt: Date?
}

struct QRApproveRequest: Encodable {
    let sessionId: String
    let timestamp: Int
    let signature: String
    let desktopDeviceName: String?
    let desktopDeviceModel: String?
    let desktopDeviceOs: String?
}

struct QRApproveResponse: Decodable {
    let status: String
}

struct QRPollResponse: Decodable {
    let status: String
    let token: String?
    let refreshToken: String?
    let userId: String?
    let username: String?
}

struct QRDenyRequest: Encodable {
    let sessionId: String
}

struct IdentityKeyResponse: Decodable {
    let stored: Bool
    let status: String
}

// MARK: - NetworkService extension

extension NetworkService {
    enum QRLoginUnavailable: Error, LocalizedError {
        case disabled
        var errorDescription: String? {
            "QR login is temporarily disabled while the linked-device service is being restored."
        }
    }

    func uploadIdentityKey(publicKeyBase64: String) async throws -> IdentityKeyResponse {
        throw QRLoginUnavailable.disabled
    }

    func qrLoginScan(_ request: QRScanRequest) async throws -> QRScanResponse {
        throw QRLoginUnavailable.disabled
    }

    func qrLoginApprove(_ request: QRApproveRequest) async throws -> QRApproveResponse {
        throw QRLoginUnavailable.disabled
    }

    func qrLoginPoll(sessionId: String, nonce: String) async throws -> QRPollResponse {
        throw QRLoginUnavailable.disabled
    }

    func qrLoginDeny(_ request: QRDenyRequest) async throws -> QRApproveResponse {
        throw QRLoginUnavailable.disabled
    }
}
