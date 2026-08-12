//! macOS CoreBluetooth experiment — **feature-gated**, off by default.
//!
//! Enable: `cargo build -p raven-node --features corebluetooth`
//!
//! This module does **not** open a live GATT radio in CI. It provides:
//! - compile-time presence of a desktop BLE driver seam
//! - runtime status string for `raven-node ble-status`
//! - hooks that a future objc2/CoreBluetooth backend can fill without
//!   changing RavenEnvelopeV1 framing (`raven_core::ble_adapter`).
//!
//! Headless always-on GATT on macOS remains BLOCKED_HARDWARE (entitlements,
//! TCC prompts, radio presence). iOS product path: `BLEMeshEngine`.

#![cfg(feature = "corebluetooth")]

use raven_core::ble_adapter::{select_ble_adapter_from_env, BleAdapterKind};

/// Desktop BLE radio backend state (experimental).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CoreBluetoothState {
    /// Feature compiled; radio not started.
    CompiledIdle,
    /// Operator requested platform GATT but host cannot bind (no entitlement / no radio).
    Unavailable,
}

impl CoreBluetoothState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::CompiledIdle => "corebluetooth_compiled_idle",
            Self::Unavailable => "corebluetooth_unavailable",
        }
    }
}

/// Probe whether the experimental backend should attempt GATT.
/// Never panics; never logs secrets.
pub fn probe() -> (BleAdapterKind, CoreBluetoothState) {
    let kind = select_ble_adapter_from_env();
    let state = match kind {
        BleAdapterKind::PlatformGatt => CoreBluetoothState::Unavailable,
        BleAdapterKind::MockTcp => CoreBluetoothState::CompiledIdle,
    };
    (kind, state)
}

/// Future: start peripheral/central. Currently refuses safely.
pub fn try_start_gatt() -> Result<(), String> {
    Err(
        "CoreBluetooth radio start is experimental and BLOCKED_HARDWARE on this build; use mock_ble or iOS BLEMeshEngine"
            .into(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn probe_does_not_panic() {
        let (_k, s) = probe();
        assert!(matches!(
            s,
            CoreBluetoothState::CompiledIdle | CoreBluetoothState::Unavailable
        ));
    }
}
