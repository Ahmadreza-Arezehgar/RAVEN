//! Lab-only staticlib binder for Hybrid Ratchet V2 Full Braid (`raven_fb_*`).
//!
//! The durable C ABI lives in `raven-core` (`hybrid_ratchet_v2_full_braid::ffi`).
//! This crate archives those symbols into a linkable Debug-only static library
//! and exports size helpers for the Swift XCTest binder.
//!
//! **Release and App Store builds must not link this crate.**

#![forbid(unsafe_op_in_unsafe_fn)]

#[cfg(not(debug_assertions))]
compile_error!("raven-fb-ffi is lab-only and must not be linked in Release/App Store builds");

#[cfg(all(debug_assertions, feature = "lab"))]
mod lab {
    use raven_core::hybrid_ratchet_v2_full_braid::constants::{
        BRAID_MAX_CANONICAL_STATE_BYTES, BRAID_MAX_RVOR_RECORD_BYTES, MAX_RVBO1, RVBJ1_HEADER_LEN,
    };
    use raven_core::hybrid_ratchet_v2_full_braid::ffi::{
        raven_fb_clear_pending_measure, raven_fb_clear_pending_write, raven_fb_init_measure,
        raven_fb_init_write, raven_fb_promote_measure, raven_fb_promote_write,
        raven_fb_recover_measure, raven_fb_recover_write, raven_fb_rvor_materialize_measure,
        raven_fb_rvor_materialize_write, raven_fb_terminalize_conflict_measure,
        raven_fb_terminalize_conflict_write, raven_fb_terminalize_expired_measure,
        raven_fb_terminalize_expired_write, raven_fb_transition_measure, raven_fb_transition_write,
    };
    use raven_core::hybrid_ratchet_v2_full_braid::pipeline::MAX_RVBJ1;

    pub use raven_core::hybrid_ratchet_v2_full_braid::ffi::{RavenFbResultMeta, RavenFbSizes};

    pub const RAVEN_FB_OK: i32 = 0;
    pub const RAVEN_FB_ERR_NEED_CAPACITY: i32 = 1;
    pub const RAVEN_FB_ERR_PARSE: i32 = 2;
    pub const RAVEN_FB_ERR_EPOCH: i32 = 3;
    pub const RAVEN_FB_ERR_CAS: i32 = 8;
    pub const RAVEN_FB_ERR_TERMINAL_STATE_OP: i32 = 9;
    pub const RAVEN_FB_ERR_INTERNAL: i32 = 10;

    const _: [(); 16] = [(); core::mem::size_of::<RavenFbSizes>()];
    const _: [(); 64] = [(); core::mem::size_of::<RavenFbResultMeta>()];
    const _: [(); 279_055] = [(); RVBJ1_HEADER_LEN + BRAID_MAX_CANONICAL_STATE_BYTES + MAX_RVBO1];
    const _: [(); 279_055] = [(); MAX_RVBJ1];

    #[inline(never)]
    #[no_mangle]
    pub extern "C" fn raven_fb_ffi_keep_alive() -> usize {
        let mut acc = 0usize;
        acc ^= raven_fb_init_measure as *const () as usize;
        acc ^= raven_fb_init_write as *const () as usize;
        acc ^= raven_fb_transition_measure as *const () as usize;
        acc ^= raven_fb_transition_write as *const () as usize;
        acc ^= raven_fb_promote_measure as *const () as usize;
        acc ^= raven_fb_promote_write as *const () as usize;
        acc ^= raven_fb_rvor_materialize_measure as *const () as usize;
        acc ^= raven_fb_rvor_materialize_write as *const () as usize;
        acc ^= raven_fb_clear_pending_measure as *const () as usize;
        acc ^= raven_fb_clear_pending_write as *const () as usize;
        acc ^= raven_fb_recover_measure as *const () as usize;
        acc ^= raven_fb_recover_write as *const () as usize;
        acc ^= raven_fb_terminalize_conflict_measure as *const () as usize;
        acc ^= raven_fb_terminalize_conflict_write as *const () as usize;
        acc ^= raven_fb_terminalize_expired_measure as *const () as usize;
        acc ^= raven_fb_terminalize_expired_write as *const () as usize;
        acc
    }

    #[no_mangle]
    pub extern "C" fn raven_fb_len_sizes() -> usize {
        core::mem::size_of::<RavenFbSizes>()
    }

    #[no_mangle]
    pub extern "C" fn raven_fb_len_meta() -> usize {
        core::mem::size_of::<RavenFbResultMeta>()
    }

    #[no_mangle]
    pub extern "C" fn raven_fb_max_state() -> usize {
        BRAID_MAX_CANONICAL_STATE_BYTES
    }

    #[no_mangle]
    pub extern "C" fn raven_fb_max_rvbo1() -> usize {
        MAX_RVBO1
    }

    #[no_mangle]
    pub extern "C" fn raven_fb_max_rvbj1() -> usize {
        MAX_RVBJ1
    }

    #[no_mangle]
    pub extern "C" fn raven_fb_max_rvor_record() -> usize {
        BRAID_MAX_RVOR_RECORD_BYTES
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn keep_alive_is_nonzero() {
            assert_ne!(raven_fb_ffi_keep_alive(), 0);
        }

        #[test]
        fn exported_layout_constants() {
            assert_eq!(raven_fb_len_sizes(), 16);
            assert_eq!(raven_fb_len_meta(), 64);
            assert_eq!(raven_fb_max_state(), 262_144);
            assert_eq!(raven_fb_max_rvbo1(), 16_545);
            assert_eq!(raven_fb_max_rvbj1(), 279_055);
            assert_eq!(raven_fb_max_rvor_record(), 16_741);
        }
    }
}

#[cfg(all(debug_assertions, feature = "lab"))]
pub use lab::*;
