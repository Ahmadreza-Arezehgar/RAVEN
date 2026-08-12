//! BLE transport adapter boundary for Bridge V1.
//!
//! - **CI / raven-node:** `TransportKind::MockBle` — TCP length-prefix frames
//!   carrying the same packed `RavenEnvelopeV1` (see `bridge_run`).
//! - **iOS hardware:** `BLEMeshEngine` (+ `RavenBleRvn1Carrier`) writes raw
//!   `RVN1` bytes over existing GATT message characteristics behind
//!   `FeatureFlag.ravenEnvelopeV1`. MeshEnvelope JSON path stays default when
//!   the flag is OFF.
//!
//! This module does not open CoreBluetooth / BlueZ sockets. It validates
//! opaque envelopes before a platform driver ships them on BLE.

use crate::envelope::Envelope;
use crate::transport::TransportKind;

/// Adapter kind selected for BLE egress.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BleAdapterKind {
    /// Hardware-free TCP stand-in (CI / demos).
    MockTcp,
    /// Platform GATT / mesh engine (iOS BLEMeshEngine, future desktop).
    PlatformGatt,
}

impl BleAdapterKind {
    pub fn transport(self) -> TransportKind {
        match self {
            Self::MockTcp => TransportKind::MockBle,
            Self::PlatformGatt => TransportKind::Ble,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::MockTcp => "mock_ble",
            Self::PlatformGatt => "ble_gatt",
        }
    }
}

/// True when bytes look like a structurally unpackable RavenEnvelopeV1.
pub fn validate_opaque_rvn1(packed: &[u8]) -> bool {
    if packed.len() < 5 {
        return false;
    }
    if &packed[0..4] != b"RVN1" || packed[4] != 1 {
        return false;
    }
    Envelope::unpack(packed).is_some()
}

/// Prefer mock BLE in CI; platform GATT when explicitly requested.
pub fn select_ble_adapter(prefer_platform_gatt: bool) -> BleAdapterKind {
    if prefer_platform_gatt {
        BleAdapterKind::PlatformGatt
    } else {
        BleAdapterKind::MockTcp
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::envelope::EnvType;
    use crate::identity::Identity;

    #[test]
    fn rejects_non_rvn1() {
        assert!(!validate_opaque_rvn1(b"{json}"));
        assert!(!validate_opaque_rvn1(b"RVN1"));
        assert!(!validate_opaque_rvn1(b"RVN2\x01rest"));
    }

    #[test]
    fn accepts_packed_envelope() {
        let id = Identity::generate();
        let mut env = Envelope {
            env_type: EnvType::Message as u8,
            flags: 0,
            message_id: [1u8; 16],
            routing_tag: [2u8; 16],
            dest_device_hint: 0,
            created_at: 1,
            expires_at: u64::MAX,
            hop_limit: 4,
            replication_budget: 2,
            anti_replay_nonce: [3u8; 12],
            ratchet_header_ciphertext: vec![],
            message_ciphertext: b"opaque".to_vec(),
            sender_authentication: vec![],
        };
        env.sign_with(&id);
        let packed = env.pack();
        assert!(validate_opaque_rvn1(&packed));
        assert_eq!(select_ble_adapter(false), BleAdapterKind::MockTcp);
        assert_eq!(
            select_ble_adapter(true).transport(),
            TransportKind::Ble
        );
    }
}
