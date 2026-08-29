use std::io::Write;
use std::process::{Command, Stdio};

fn ash_for(data_dir: &std::path::Path) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_ash"));
    command
        .arg("--data-dir")
        .arg(data_dir)
        .env("NO_COLOR", "1")
        .env("RAVEN_ALLOW_EPHEMERAL_DATA_DIR", "1");
    command
}

#[test]
fn contact_list_is_dispatched_instead_of_succeeding_silently() {
    let dir = tempfile::tempdir().expect("tempdir");
    let output = ash_for(dir.path())
        .args(["contact", "list"])
        .output()
        .expect("run ash contact list");

    assert!(output.status.success(), "status={:?}", output.status);
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("CONTACTS"), "stdout={stdout:?}");
}

#[test]
fn node_policy_command_is_dispatched_and_persisted() {
    let dir = tempfile::tempdir().expect("tempdir");
    let output = ash_for(dir.path())
        .args(["node", "bridge", "off"])
        .output()
        .expect("run ash node bridge off");

    assert!(output.status.success(), "status={:?}", output.status);
    let policy = raven_core::load_policy(dir.path());
    assert!(!policy.bridge);
    assert!(!policy.auto_policy);
}

#[test]
fn send_without_identity_fails_instead_of_succeeding_silently() {
    let dir = tempfile::tempdir().expect("tempdir");
    let output = ash_for(dir.path())
        .env("RAVEN_IDENTITY_BACKEND", "locked-file")
        .args([
            "send",
            "--peer",
            "127.0.0.1:7420",
            "--peer-pub-hex",
            "0000000000000000000000000000000000000000000000000000000000000000",
        ])
        .output()
        .expect("run ash send");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("identity missing"), "stderr={stderr:?}");
}

#[test]
fn send_without_authenticated_session_fails_closed() {
    let dir = tempfile::tempdir().expect("tempdir");
    let init = ash_for(dir.path())
        .env("RAVEN_IDENTITY_BACKEND", "locked-file")
        .arg("init")
        .output()
        .expect("initialize test identity");
    assert!(init.status.success(), "init status={:?}", init.status);

    let mut child = ash_for(dir.path())
        .env("RAVEN_IDENTITY_BACKEND", "locked-file")
        .env_remove("RAVEN_LAB_TEST_A")
        .args([
            "send",
            "--peer",
            "127.0.0.1:7420",
            "--peer-pub-hex",
            "0000000000000000000000000000000000000000000000000000000000000000",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("run ash send");
    child
        .stdin
        .take()
        .expect("send stdin")
        .write_all(b"must not downgrade\n")
        .expect("write message");
    let output = child.wait_with_output().expect("wait for ash send");

    assert!(!output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("send refused"), "stderr={stderr:?}");
    assert!(!stdout.contains("unsafe-interim"), "stdout={stdout:?}");
    assert!(!stderr.contains("unsafe-interim"), "stderr={stderr:?}");
}

#[test]
fn product_cli_contains_no_demo_crypto_downgrade() {
    let source = include_str!("../src/cli.rs");
    assert!(!source.contains("unsafe-interim"));
    assert!(!source.contains("direct_interim_send"));
    assert!(source.contains("interactive_authenticated_send"));
    assert!(source.contains("run_send_secure"));
}

#[test]
fn installer_uses_release_defaults_and_never_hard_resets() {
    let installer = include_str!("../../../scripts/install.sh");
    assert!(installer.contains("/main/node/scripts/install.sh"));
    assert!(installer.contains("cargo build -q --locked --release -p ash -p raven-node"));
    assert!(installer.contains("target/release"));
    assert!(!installer.contains("unsafe-demo-crypto"));
    assert!(!installer.contains("reset --hard"));
    assert!(installer.contains("git -C \"$DIR\" status --porcelain"));
    assert!(installer.contains("merge --ff-only origin/main"));
    assert!(installer.contains("Linux release install is blocked in R1"));
    assert!(installer.contains("refusing to overwrite it"));
    assert!(!installer.contains("ln -sf"));
    assert!(!installer.contains("RAVEN_IDENTITY_BACKEND=locked-file"));
}

#[test]
fn unsigned_release_builder_uses_locked_default_features() {
    let builder = include_str!("../../../scripts/release/build_unsigned.sh");
    assert!(builder.contains("--locked"));
    assert!(builder.contains("--release"));
    assert!(builder.contains("CARGO_TARGET_DIR=\"$BUILD_TARGET\""));
    assert!(builder.contains("--target \"$HOST_TRIPLE\""));
    assert!(builder.contains("BUILT_BIN=\"$BUILD_TARGET/$HOST_TRIPLE/release\""));
    assert!(!builder.contains("$NODE_ROOT/target/release/raven"));
    assert!(!builder.contains("--features"));
    assert!(!builder.contains("unsafe-demo-crypto"));
    assert!(!builder.contains("experimental-offline-mailbox"));
    assert!(!builder.contains("experimental-nat-connectivity"));
}
