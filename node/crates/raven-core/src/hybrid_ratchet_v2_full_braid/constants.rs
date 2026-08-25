//! Design §3 constants + Task 0 budget (lab-only).

pub use crate::hybrid_ratchet_v2_full_braid::agent::{
    AGENT_CT1_ACKNOWLEDGED, AGENT_CT1_RECEIVED, AGENT_CT1_SAMPLED, AGENT_CT2_SAMPLED,
    AGENT_EK_RECEIVED_CT1_SAMPLED, AGENT_EK_SENT_CT1_RECEIVED, AGENT_HEADER_RECEIVED,
    AGENT_HEADER_SENT, AGENT_KEYS_SAMPLED, AGENT_KEYS_UNSAMPLED, AGENT_NO_HEADER_RECEIVED,
    AGENT_TERMINAL,
};

/// Empty RVBO1: magic(8)+schema(2)+num_frames=0(2)+ch_out=0(1)+sealed=0(1).
pub const EMPTY_RVBO1_LEN: usize = 14;

/// Max single RVBO1: 12 + (4+8247) + 1+68 + 1+(4+8208).
pub const MAX_RVBO1: usize = 16545;

/// Single RVOR1 max = 196 + MAX_RVBO1.
pub const BRAID_MAX_RVOR_RECORD_BYTES: usize = 16741;

/// Aggregate RVOR store budget (not a single-record cap).
pub const BRAID_MAX_RVOR_BYTES: usize = 1_100_000;

pub const BRAID_MAX_RVOR_ENTRIES: usize = 64;
pub const BRAID_MAX_RVQI_ENTRIES: usize = 64;

pub const BRAID_MAX_CANONICAL_STATE_BYTES: usize = 262_144;
pub const RVFB1_PREFIX: usize = 275;
pub const ACTIVE_SEND_MAX: usize = 1204;
pub const RVBJ1_HEADER_LEN: usize = 366;

pub const ERR_OK: i32 = 0;
pub const ERR_NEED_CAPACITY: i32 = 1;
pub const ERR_PARSE: i32 = 2;
pub const ERR_EPOCH: i32 = 3;
pub const ERR_CAS: i32 = 8;
pub const ERR_TERMINAL_STATE_OP: i32 = 9;
pub const ERR_INTERNAL: i32 = 10;

/// Canonical RVFB1 flags (design §6.1).
pub const FLAG_AWAITING_COMPLETE: u32 = 1 << 0;
pub const FLAG_TERMINAL: u32 = 1 << 1;
pub const FLAG_CT1_ACK_APPLIED: u32 = 1 << 2;
