//! BLE transport adapter boundary for Bridge V1.
//!
//! - **CI / raven-node:** `TransportKind::MockBle` — TCP length-prefix frames
//!   carrying the same packed `RavenEnvelopeV1` (see `bridge_run`).
//! - **Live radio:** not implemented here. Headless CoreBluetooth / BlueZ
//!   remain BLOCKED_HARDWARE. `prefer_platform_gatt` is a software path flag
//!   only; it does not open a radio. iOS GATT is absent on `main`
//!   (SoT `feature/raven-serverless-v1` until B8; do not treat as present).
//! - **RBF1:** GATT chunk framing (`RBF1` magic) is **not** implemented.
//!   See `protocol/RAVEN_BLE_FRAMING_V1.md`. Held for Sprint 1.
//!
//! Mock TCP is the default for CI. These helpers are mock_ble only.

use crate::envelope::Envelope;
use crate::transport::TransportKind;

/// Adapter kind selected for BLE egress.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BleAdapterKind {
    /// Hardware-free TCP stand-in (CI / demos).
    MockTcp,
    /// Software path flag for a future platform GATT driver (not wired; no radio).
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

/// Prefer mock BLE in CI; PlatformGatt is a software path flag only (no radio).
pub fn select_ble_adapter(prefer_platform_gatt: bool) -> BleAdapterKind {
    if prefer_platform_gatt {
        BleAdapterKind::PlatformGatt
    } else {
        BleAdapterKind::MockTcp
    }
}

/// mock_ble TCP helper only: `u32 BE len || envelope`.
/// Not GATT write chunking. Real GATT RBF1 framing is not implemented
/// (see `protocol/RAVEN_BLE_FRAMING_V1.md`).
pub fn ble_frame_encode(payload: &[u8]) -> Result<Vec<u8>, String> {
    if !validate_opaque_rvn1(payload) {
        return Err("BLE_NOT_RVN1".into());
    }
    if payload.len() > 512 * 1024 {
        return Err("BLE_FRAME_TOO_LARGE".into());
    }
    let mut out = Vec::with_capacity(4 + payload.len());
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.extend_from_slice(payload);
    Ok(out)
}

/// Decode one mock_ble TCP frame (`u32 BE len || envelope`).
/// Not RBF1 / GATT reassembly. Returns (payload, bytes_consumed).
pub fn ble_frame_decode(buf: &[u8]) -> Result<Option<(Vec<u8>, usize)>, String> {
    if buf.len() < 4 {
        return Ok(None);
    }
    let n = u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
    if n == 0 || n > 512 * 1024 {
        return Err("BLE_BAD_LEN".into());
    }
    if buf.len() < 4 + n {
        return Ok(None);
    }
    let payload = buf[4..4 + n].to_vec();
    if !validate_opaque_rvn1(&payload) {
        return Err("BLE_NOT_RVN1".into());
    }
    Ok(Some((payload, 4 + n)))
}

/// Env helper: `RAVEN_BLE_PLATFORM=1` selects PlatformGatt (software path flag).
pub fn select_ble_adapter_from_env() -> BleAdapterKind {
    let prefer = std::env::var("RAVEN_BLE_PLATFORM")
        .map(|v| matches!(v.to_ascii_lowercase().as_str(), "1" | "true" | "yes" | "on"))
        .unwrap_or(false);
    select_ble_adapter(prefer)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::envelope::EnvType;
    use crate::identity::Identity;

    fn sample_packed() -> Vec<u8> {
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
        env.pack()
    }

    #[test]
    fn rejects_non_rvn1() {
        assert!(!validate_opaque_rvn1(b"{json}"));
        assert!(!validate_opaque_rvn1(b"RVN1"));
        assert!(!validate_opaque_rvn1(b"RVN2\x01rest"));
    }

    #[test]
    fn accepts_packed_envelope() {
        let packed = sample_packed();
        assert!(validate_opaque_rvn1(&packed));
        assert_eq!(select_ble_adapter(false), BleAdapterKind::MockTcp);
        assert_eq!(select_ble_adapter(true).transport(), TransportKind::Ble);
    }

    #[test]
    fn frame_roundtrip() {
        let packed = sample_packed();
        let framed = ble_frame_encode(&packed).unwrap();
        let (got, n) = ble_frame_decode(&framed).unwrap().unwrap();
        assert_eq!(n, framed.len());
        assert_eq!(got, packed);
        assert!(ble_frame_encode(b"nope").is_err());
    }
}
