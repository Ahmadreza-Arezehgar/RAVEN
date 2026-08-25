//! Task 0 — SPQR pin audit (hard-stop).
//!
//! Values frozen from `signalapp/SparsePostQuantumRatchet` at
//! `fd320484dcec89004021e6fdc7481825f5f261fa` (`spqr` 1.5.3):
//! `src/encoding/polynomial.rs` defines `CHUNK_SIZE = 32`.
//!
//! **`N(L)`** is the systematic recovery threshold (`L/CW`), **not** a max
//! chunk index. Redundancy indices `N..=63` remain valid
//! (`BRAID_MAX_CHUNKS_PER_EPOCH = 64`).
//!
//! **Substitution vs design prose:** the phrase `plen==CW(L)` with
//! `L ∈ {96,1152,960,160}` is interpreted as:
//! - `CW = 32` (constant codeword width)
//! - wire `RVBC1.plen == CW` for coded braid chunks
//! - `expected_source_len == L == N(L) * CW`
//!   not `plen == L`.
//!
//! Lab builds enable `spqr` feature `test-utils` to access `PolyEncoder`
//! (upstream experimental surface).

/// Git rev of audited `spqr` tip (2026-08-17).
pub const SPQR_GIT_REV: &str = "fd320484dcec89004021e6fdc7481825f5f261fa";

/// Crate version at that rev (`Cargo.toml`).
pub const SPQR_VERSION: &str = "1.5.3";

/// SPQR `CHUNK_SIZE` — codeword / chunk width in bytes.
pub const CW: usize = 32;

/// `N(L) = L / CW` for braid source lengths (exact).
pub const N_HDR: usize = 96 / CW; // 3
pub const N_EK: usize = 1152 / CW; // 36
pub const N_CT1: usize = 960 / CW; // 30
pub const N_CT2: usize = 160 / CW; // 5

pub const L_HDR: usize = 96;
pub const L_EK: usize = 1152;
pub const L_CT1: usize = 960;
pub const L_CT2: usize = 160;

/// Design §3.2 budget (Rev20).
pub const FIXED_BASE: usize = 275 + 2 + 1204 + 1346 + 6530 + 6898 + 80509; // 96764
pub const INBOUND_BUDGET: usize = 262_144 - FIXED_BASE; // 165380

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hybrid_ratchet_v2_full_braid::constants::{
        ACTIVE_SEND_MAX, BRAID_MAX_RVOR_RECORD_BYTES, EMPTY_RVBO1_LEN, MAX_RVBO1, RVFB1_PREFIX,
    };

    #[test]
    fn spqr_pin_audit_constants() {
        assert_eq!(CW, 32);
        assert_eq!(N_HDR, 3);
        assert_eq!(N_EK, 36);
        assert_eq!(N_CT1, 30);
        assert_eq!(N_CT2, 5);
        assert_eq!(N_HDR * CW, L_HDR);
        assert_eq!(N_EK * CW, L_EK);
        assert_eq!(N_CT1 * CW, L_CT1);
        assert_eq!(N_CT2 * CW, L_CT2);
        assert_eq!(FIXED_BASE, 96764);
        assert_eq!(INBOUND_BUDGET, 165380);
        assert_eq!(ACTIVE_SEND_MAX, 1204);
        assert_eq!(RVFB1_PREFIX, 275);
        assert_eq!(EMPTY_RVBO1_LEN, 14);
        assert_eq!(MAX_RVBO1, 12 + (4 + 8247) + 1 + 68 + 1 + (4 + 8208));
        assert_eq!(BRAID_MAX_RVOR_RECORD_BYTES, 196 + MAX_RVBO1);
        assert_eq!(SPQR_GIT_REV.len(), 40);
        assert_eq!(SPQR_VERSION, "1.5.3");
    }
}
