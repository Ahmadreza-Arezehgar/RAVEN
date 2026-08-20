//! Production-safe PairInit / LAN readiness helpers for the ash CLI.
//!
//! Optional TRACE_* NDJSON is compile-time opt-in only (`debug-trace-delivery`).
//! Default builds never write session IDs, ingest URLs, or invoke `curl`.
//! Enabling `debug-trace-delivery` in Release is a hard compile error.

#[cfg(all(feature = "debug-trace-delivery", not(debug_assertions)))]
compile_error!(
    "debug-trace-delivery is forbidden in release builds; local TRACE_* logging is Debug/lab-only"
);

/// True when LAN-direct is live, or every generic PairInit tripwire is open.
/// Contact-request must not use this — it would inherit the LAN slice gate.
pub fn live_pair_init_outbound_ready() -> bool {
    if raven_core::lan_direct_live_enabled() {
        return true;
    }
    raven_core::pair_init::live_enabled()
        && raven_core::indexed_session_store::live_enabled()
        && raven_core::prekey_lifecycle::live_enabled()
        && raven_core::atsam_indexed_session::live_enabled()
}

pub fn production_gate_status() -> &'static str {
    if live_pair_init_outbound_ready() {
        if raven_core::pair_init::lab_test_a_enabled() && !raven_core::pair_init::PRODUCTION_ENABLED
        {
            "LAB_TEST_A_PAIR_INIT_READY"
        } else {
            "LIVE_PAIR_INIT_READY"
        }
    } else {
        "PRODUCTION_GATE_DISABLED:WAITING_FOR_PAIR_INIT_SESSION"
    }
}

/// Append one TRACE_* event when built with `--features debug-trace-delivery`.
/// Default builds are a no-op (no network, no hardcoded paths, no session IDs).
pub fn trace_event(
    location: &str,
    message: &str,
    status: &str,
    mid_prefix: Option<&str>,
    extra: Option<&str>,
) {
    #[cfg(all(feature = "debug-trace-delivery", debug_assertions))]
    debug_trace::emit(location, message, status, mid_prefix, extra);
    #[cfg(not(all(feature = "debug-trace-delivery", debug_assertions)))]
    {
        let _ = (location, message, status, mid_prefix, extra);
    }
}

#[cfg(all(feature = "debug-trace-delivery", debug_assertions))]
mod debug_trace {
    use std::fs::OpenOptions;
    use std::io::Write;
    use std::path::Path;
    use std::time::{SystemTime, UNIX_EPOCH};

    pub(super) fn emit(
        location: &str,
        message: &str,
        status: &str,
        mid_prefix: Option<&str>,
        extra: Option<&str>,
    ) {
        let Ok(path) = std::env::var("RAVEN_TRACE_LOG") else {
            return;
        };
        if path.is_empty() {
            return;
        }
        let mut data = serde_json::json!({
            "status": status,
            "pair_init_production": raven_core::pair_init::PRODUCTION_ENABLED,
            "pair_init_live": raven_core::pair_init::live_enabled(),
            "lab_test_a": raven_core::pair_init::lab_test_a_enabled(),
            "indexed_session_production": raven_core::INDEXED_SESSION_STORE_PRODUCTION_ENABLED,
            "indexed_session_live": raven_core::indexed_session_store::live_enabled(),
            "prekey_lifecycle_production": raven_core::PREKEY_LIFECYCLE_PRODUCTION_ENABLED,
            "prekey_lifecycle_live": raven_core::prekey_lifecycle::live_enabled(),
            "indexed_profile_production": raven_core::atsam_indexed_session::PRODUCTION_ENABLED,
            "indexed_profile_live": raven_core::atsam_indexed_session::live_enabled(),
        });
        if let Some(mid) = mid_prefix {
            data["mid_prefix"] = serde_json::json!(mid);
        }
        if let Some(x) = extra {
            data["detail"] = serde_json::json!(x);
        }
        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        let line = serde_json::json!({
            "location": location,
            "message": message,
            "data": data,
            "timestamp": now_ms,
        });
        let _ = append_line(Path::new(&path), &line.to_string());
    }

    fn append_line(path: &Path, line: &str) -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let mut f = OpenOptions::new().create(true).append(true).open(path)?;
        writeln!(f, "{line}")?;
        Ok(())
    }
}
