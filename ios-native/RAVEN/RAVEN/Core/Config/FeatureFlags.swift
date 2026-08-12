//
//  FeatureFlags.swift
//  RAVEN
//
//  UserDefaults-backed feature flags for gradual rollout of new mesh features.
//  Each feature ships behind a flag and can be toggled via Settings → Debug.
//

import Foundation

// MARK: - Feature Flags

enum FeatureFlag: String, CaseIterable {
    case adaptiveSpray     = "adaptive_spray_v1"
    case deliveryConfidence = "delivery_confidence_v1"
    case geoFenced         = "geo_fenced_v1"
    case internetBridge    = "internet_bridge_v1"
    case dataMules         = "data_mules_v1"
    case vault             = "vault_v1"
    case proximaVault      = "proxima_vault_v3_1_2"
    case proximaVaultStealth = "proxima_vault_stealth_v3_2"
    case atsam             = "atsam_v1_stage1"
    case ravenEnvelopeV1   = "raven_envelope_v1"
    case legacyPlaintextGroupKey = "legacy_plaintext_group_key_v1"
    case legacyPlaintextRender = "legacy_plaintext_render_v1"

    /// Human-readable display name for settings UI.
    var displayName: String {
        switch self {
        case .adaptiveSpray:      return "Adaptive Spray Count"
        case .deliveryConfidence:  return "Delivery Confidence"
        case .geoFenced:          return "Geo-fenced Messages"
        case .internetBridge:     return "Internet Bridge Gateway"
        case .dataMules:          return "Intent-based Data Mules"
        case .vault:              return "Proximity Vault"
        case .proximaVault:       return "PROXIMA-VAULT (OTP)"
        case .proximaVaultStealth: return "PV-Stealth (rotating tags)"
        case .atsam:              return "ATSAM hybrid pairing"
        case .ravenEnvelopeV1:    return "RavenEnvelopeV1 (serverless)"
        case .legacyPlaintextGroupKey: return "Legacy Plaintext Group Key"
        case .legacyPlaintextRender: return "Legacy Plaintext Render"
        }
    }

    /// Feature description for settings UI.
    var description: String {
        switch self {
        case .adaptiveSpray:
            return "Dynamically adjust spray count based on network density"
        case .deliveryConfidence:
            return "Visual delivery state indicators with relay receipts"
        case .geoFenced:
            return "Send messages that only deliver in a geographic area"
        case .internetBridge:
            return "Allow online devices to bridge messages for offline peers"
        case .dataMules:
            return "Announce travel to carry messages between regions"
        case .vault:
            return "Location-encrypted content that unlocks by proximity"
        case .proximaVault:
            // Content-layer one-time-pad; stacks on top of Noise IK
            // / mesh-relay / bridge transport without changing them.
            // v3.1.2 protects message content. Metadata unlinkability
            // is deferred to PV-Stealth (v3.2).
            return "Information-theoretic one-time-pad content encryption (experimental)"
        case .proximaVaultStealth:
            // ATSAM Stage 9. Replaces the stable pad_id + per-pad
            // pseudonyms in PV envelopes with rotating per-envelope
            // lookup tags (Trunc_128(HMAC(K_lookup^dir, ...))).
            // Closes the metadata-linkability gap of PV v3.1.2
            // (Issue 10 / Patch 10). Default OFF.
            return "Rotating envelope lookup tags for metadata unlinkability (experimental, Stage 9)"
        case .atsam:
            // ATSAM is Raven's production security protocol (v1.7+).
            // Default ON. Toggling OFF disables the post-quantum
            // hybrid pairing root + HKDF key tree; existing paired
            // sessions keep working but new pairs fall back to the
            // pre-ATSAM Noise IK path.
            return "Post-quantum hybrid pairing root + HKDF key tree (Raven's production security protocol, on by default)"
        case .ravenEnvelopeV1:
            // Parallel binary envelope for terminal-node / serverless
            // interop. Default OFF — MeshEnvelope JSON remains the
            // shipping BLE/chat path until Phase G/H cutover.
            // messaging_path label: serverless_rvn1 when ON, legacy_mesh_envelope when OFF.
            // Never silent FastAPI for friendship or 1:1 delivery. Petname-first tags: docs/RAVEN_TAG_V1.md.
            return "Binary RavenEnvelopeV1 for serverless/terminal interop (MeshEnvelope default OFF; no FastAPI friendship)"
        case .legacyPlaintextGroupKey:
            return "DANGER: broadcasts the group key in cleartext over BLE to members without a post-quantum pair. Off by default — the key is otherwise withheld until pairing."
        case .legacyPlaintextRender:
            return "DANGER: render raw mesh wire from unknown/legacy peers as plaintext. Off by default — undecryptable mesh messages otherwise show a placeholder."
        }
    }

    /// SF Symbol for capsule icon in debug panel.
    var icon: String {
        switch self {
        case .adaptiveSpray:      return "antenna.radiowaves.left.and.right"
        case .deliveryConfidence:  return "checkmark.circle"
        case .geoFenced:          return "location.fill"
        case .internetBridge:     return "wifi.circle.fill"
        case .dataMules:          return "airplane"
        case .vault:              return "lock.shield.fill"
        case .proximaVault:       return "key.viewfinder"
        case .proximaVaultStealth: return "eye.slash.fill"
        case .atsam:              return "atom"
        case .ravenEnvelopeV1:    return "envelope"
        case .legacyPlaintextGroupKey: return "exclamationmark.lock"
        case .legacyPlaintextRender: return "eye.trianglebadge.exclamationmark"
        }
    }
    
    // MARK: - UserDefaults Backing
    
    private var defaultsKey: String {
        "raven.feature_flag.\(rawValue)"
    }
    
    /// Features that should be enabled by default for all users.
    /// Mesh-experimental features (adaptiveSpray, etc.) stay opt-in via Debug settings.
    ///
    /// `atsam` ships ON by default — ATSAM is Raven's production
    /// security protocol (v1.7+). Users can still toggle it off
    /// explicitly via Settings → Security → ATSAM, but the default
    /// state on a fresh install (and for any user who has not
    /// changed the toggle) is enabled. This matches the public
    /// positioning at raven-messager.com/atsam.
    ///
    /// `proximaVault` and `proximaVaultStealth` stay OFF by default
    /// — they are optional content-layer primitives that require
    /// per-conversation opt-in and are still field-testing.
    private var defaultEnabledValue: Bool {
        switch self {
        case .vault, .atsam: return true
        case .ravenEnvelopeV1: return false
        default: return false
        }
    }
    
    /// Whether this feature flag is currently enabled.
    var isEnabled: Bool {
        get {
            // If never explicitly set, use the feature's default value
            if UserDefaults.standard.object(forKey: defaultsKey) == nil {
                return defaultEnabledValue
            }
            return UserDefaults.standard.bool(forKey: defaultsKey)
        }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
    
    /// Enable or disable this feature flag.
    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: defaultsKey)
    }
    
    // MARK: - Convenience Static Accessors
    
    /// Quick check without constructing the enum.
    static var isAdaptiveSprayEnabled: Bool {
        FeatureFlag.adaptiveSpray.isEnabled
    }
    
    static var isDeliveryConfidenceEnabled: Bool {
        FeatureFlag.deliveryConfidence.isEnabled
    }
    
    static var isGeoFencedEnabled: Bool {
        FeatureFlag.geoFenced.isEnabled
    }
    
    static var isInternetBridgeEnabled: Bool {
        FeatureFlag.internetBridge.isEnabled
    }
    
    static var isDataMulesEnabled: Bool {
        FeatureFlag.dataMules.isEnabled
    }
    
    static var isVaultEnabled: Bool {
        FeatureFlag.vault.isEnabled
    }

    static var isProximaVaultEnabled: Bool {
        FeatureFlag.proximaVault.isEnabled
    }

    static var isProximaVaultStealthEnabled: Bool {
        FeatureFlag.proximaVaultStealth.isEnabled
    }

    static var isATSAMEnabled: Bool {
        FeatureFlag.atsam.isEnabled
    }

    /// Default OFF. When on, prefer packing/parsing RavenEnvelopeV1 on
    /// bridge/LAN paths alongside MeshEnvelope (shipping BLE path unchanged).
    static var isRavenEnvelopeV1Enabled: Bool {
        FeatureFlag.ravenEnvelopeV1.isEnabled
    }

    /// Default OFF. When off, the cleartext group-key broadcast fallback in
    /// GroupService.broadcastKey is suppressed (audit 2026-05-29, #97/H8.F5).
    static var isLegacyPlaintextGroupKeyEnabled: Bool {
        FeatureFlag.legacyPlaintextGroupKey.isEnabled
    }

    /// Default OFF. When off, undecryptable mesh wire renders as a placeholder
    /// instead of raw plaintext, and senders are never pinned to legacy
    /// (audit 2026-05-29, #95/H8.F1).
    static var isLegacyPlaintextRenderEnabled: Bool {
        FeatureFlag.legacyPlaintextRender.isEnabled
    }
}
