//! LAN direct-dial production gate.
//!
//! Independent of the four global `PRODUCTION_ENABLED` tripwires. Flipped only
//! after the two-node LAN script is green.

/// Hard enable for the terminal↔terminal LAN slice. Global PairInit / session
/// / prekey / ATSAM production flags stay false.
pub const LAN_DIRECT_PRODUCTION_ENABLED: bool = true;

/// Live LAN-direct path: compile-time slice gate or debug `RAVEN_LAB_TEST_A=1`.
pub fn lan_direct_live_enabled() -> bool {
    LAN_DIRECT_PRODUCTION_ENABLED || crate::pair_init::lab_test_a_enabled()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn global_production_flags_stay_false() {
        const {
            assert!(!crate::pair_init::PRODUCTION_ENABLED);
            assert!(!crate::INDEXED_SESSION_STORE_PRODUCTION_ENABLED);
            assert!(!crate::PREKEY_LIFECYCLE_PRODUCTION_ENABLED);
            assert!(!crate::atsam_indexed_session::PRODUCTION_ENABLED);
        }
    }

    #[test]
    fn lan_gate_const_is_independent() {
        const {
            assert!(LAN_DIRECT_PRODUCTION_ENABLED);
        }
        assert!(lan_direct_live_enabled());
    }

    #[test]
    fn lan_gate_does_not_open_generic_live_enabled() {
        if crate::pair_init::lab_test_a_enabled() {
            return;
        }
        assert!(!crate::pair_init::live_enabled());
        assert!(!crate::indexed_session_store::live_enabled());
        assert!(!crate::prekey_lifecycle::live_enabled());
        assert!(!crate::atsam_indexed_session::live_enabled());
    }
}
