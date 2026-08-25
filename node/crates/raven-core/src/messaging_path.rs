//! Messaging path diagnostics + feature-flag clarity (§54).
//!
//! The serverless (`rvn1`) path must **never** silently fall back to FastAPI
//! or MeshEnvelope. Labels are for ash doctor/status and operator logs only.

use std::env;

/// Explicit opt-in for serverless RavenEnvelopeV1 on nodes that also carry
/// legacy code. Terminal `ash` / `raven-node` are always serverless.
pub const ENV_SERVERLESS_RVN1: &str = "RAVEN_SERVERLESS_RVN1";

/// Force-label legacy path for dual-stack hosts under migration (diagnostics).
pub const ENV_FORCE_LEGACY_LABEL: &str = "RAVEN_DIAG_FORCE_LEGACY_LABEL";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MessagingPath {
    /// Canonical serverless: RavenEnvelopeV1 / raven-node / ash. No FastAPI.
    ServerlessRvn1,
    /// Legacy MeshEnvelope BLE/mesh JSON (iOS default when flag OFF).
    LegacyMeshEnvelope,
    /// Legacy FastAPI / central inbox — must never be selected by serverless code.
    LegacyFastApi,
}

impl MessagingPath {
    pub fn as_diag_label(self) -> &'static str {
        match self {
            Self::ServerlessRvn1 => "serverless_rvn1",
            Self::LegacyMeshEnvelope => "legacy_mesh_envelope",
            Self::LegacyFastApi => "legacy_fastapi",
        }
    }

    pub fn human(self) -> &'static str {
        match self {
            Self::ServerlessRvn1 => "Serverless RavenEnvelopeV1 (no central message server)",
            Self::LegacyMeshEnvelope => "Legacy MeshEnvelope (flag OFF / parallel path)",
            Self::LegacyFastApi => "Legacy FastAPI inbox (NOT used by serverless path)",
        }
    }

    /// True when this label is allowed for ash / raven-node binary diagnostics.
    pub fn allowed_for_serverless_binary(self) -> bool {
        matches!(self, Self::ServerlessRvn1)
    }
}

/// Resolve path for the **terminal node** binaries. Always serverless unless
/// an explicit diagnostic override is set (never routes to FastAPI).
pub fn resolve_terminal_messaging_path() -> MessagingPath {
    if env_truthy(ENV_FORCE_LEGACY_LABEL) {
        // Diagnostic-only override for dual-stack screenshots — does not enable FastAPI.
        return MessagingPath::LegacyMeshEnvelope;
    }
    // RAVEN_SERVERLESS_RVN1 defaults ON for ash/raven-node; OFF would be a
    // misconfiguration and we still refuse FastAPI.
    let _ = env_truthy(ENV_SERVERLESS_RVN1); // documented opt-in for dual stacks
    MessagingPath::ServerlessRvn1
}

/// iOS / dual-stack host helper: map FeatureFlag.ravenEnvelopeV1 to a label.
pub fn path_from_raven_envelope_flag(enabled: bool) -> MessagingPath {
    if enabled {
        MessagingPath::ServerlessRvn1
    } else {
        MessagingPath::LegacyMeshEnvelope
    }
}

/// Hard rule: serverless code paths must not select FastAPI.
pub fn assert_no_silent_fastapi(path: MessagingPath) -> Result<(), String> {
    if path == MessagingPath::LegacyFastApi {
        return Err(
            "REFUSE: serverless path must never silently use FastAPI for message delivery".into(),
        );
    }
    Ok(())
}

fn env_truthy(name: &str) -> bool {
    match env::var(name) {
        Ok(v) => matches!(v.to_ascii_lowercase().as_str(), "1" | "true" | "yes" | "on"),
        Err(_) => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terminal_defaults_serverless() {
        // Unset override in this process for the assertion.
        std::env::remove_var(ENV_FORCE_LEGACY_LABEL);
        let p = resolve_terminal_messaging_path();
        assert_eq!(p, MessagingPath::ServerlessRvn1);
        assert_eq!(p.as_diag_label(), "serverless_rvn1");
        assert!(p.allowed_for_serverless_binary());
        assert!(assert_no_silent_fastapi(p).is_ok());
    }

    #[test]
    fn flag_mapping() {
        assert_eq!(
            path_from_raven_envelope_flag(true),
            MessagingPath::ServerlessRvn1
        );
        assert_eq!(
            path_from_raven_envelope_flag(false),
            MessagingPath::LegacyMeshEnvelope
        );
    }

    #[test]
    fn refuse_fastapi_label_as_active_path() {
        assert!(assert_no_silent_fastapi(MessagingPath::LegacyFastApi).is_err());
    }
}
