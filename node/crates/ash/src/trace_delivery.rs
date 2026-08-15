//! End-to-end TRACE_* NDJSON for Terminal→iPhone recovery (no plaintext/keys).
//!
//! Writes to `RAVEN_TRACE_LOG` or the repo debug log when present. Also posts to
//! the local Cursor ingest URL when reachable (best-effort, never blocks send).

use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const SESSION_ID: &str = "532d3b";
const DEFAULT_INGEST: &str = "http://127.0.0.1:7731/ingest/bfe36a1d-dbc6-4a7e-b654-31e45337dcb4";

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn default_log_path() -> PathBuf {
    if let Ok(p) = std::env::var("RAVEN_TRACE_LOG") {
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
    // Prefer the recovery session log when the workspace is the cwd parent.
    let candidates = [
        PathBuf::from(".cursor/debug-532d3b.log"),
        PathBuf::from("/Users/ahmd/hybrid_messenger/.cursor/debug-532d3b.log"),
    ];
    for c in candidates {
        if c.parent().map(|p| p.exists()).unwrap_or(false) {
            return c;
        }
    }
    PathBuf::from("/tmp/raven-trace-532d3b.log")
}

/// Append one TRACE_* event. Never includes plaintext, seeds, or key material.
pub fn trace_event(
    location: &str,
    message: &str,
    status: &str,
    mid_prefix: Option<&str>,
    extra: Option<&str>,
) {
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
    let line = serde_json::json!({
        "sessionId": SESSION_ID,
        "runId": "test-a-recovery",
        "hypothesisId": "TRACE",
        "location": location,
        "message": message,
        "data": data,
        "timestamp": now_ms(),
    });
    let rendered = line.to_string();
    let path = default_log_path();
    let _ = append_line(&path, &rendered);
    post_ingest(&rendered);
}

fn append_line(path: &Path, line: &str) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let mut f = OpenOptions::new().create(true).append(true).open(path)?;
    writeln!(f, "{line}")?;
    Ok(())
}

fn post_ingest(body: &str) {
    let url = std::env::var("RAVEN_TRACE_INGEST").unwrap_or_else(|_| DEFAULT_INGEST.into());
    // Best-effort; ignore all failures (phone may be offline, ingest down).
    let _ = std::process::Command::new("curl")
        .args([
            "-sS",
            "-m",
            "1",
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "-H",
            "X-Debug-Session-Id: 532d3b",
            "--data-binary",
            body,
            &url,
        ])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
}

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
