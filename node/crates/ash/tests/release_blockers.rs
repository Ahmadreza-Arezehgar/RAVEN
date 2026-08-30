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
fn cli_reports_cargo_package_version() {
    let output = Command::new(env!("CARGO_BIN_EXE_ash"))
        .arg("--version")
        .output()
        .expect("ash --version");
    assert!(output.status.success());
    assert_eq!(
        String::from_utf8_lossy(&output.stdout).trim(),
        format!("ash {}", env!("CARGO_PKG_VERSION"))
    );

    let raven = Command::new(env!("CARGO_BIN_EXE_raven"))
        .arg("--version")
        .output()
        .expect("raven --version");
    assert!(raven.status.success());
    assert_eq!(
        String::from_utf8_lossy(&raven.stdout).trim(),
        format!("raven {}", env!("CARGO_PKG_VERSION"))
    );
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
fn invalid_prekey_fetch_returns_nonzero_instead_of_printing_success_status() {
    let dir = tempfile::tempdir().expect("tempdir");
    let output = ash_for(dir.path())
        .args(["prekey", "fetch", "not-a-public-key"])
        .output()
        .expect("run invalid prekey fetch");

    assert!(
        !output.status.success(),
        "validation/read/verify/store failures must propagate to the shell"
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(!stderr.trim().is_empty(), "failure must explain itself");
}

#[test]
fn status_fails_nonzero_and_read_only_on_corrupt_custody_database() {
    let dir = tempfile::tempdir().expect("tempdir");
    let init = ash_for(dir.path())
        .env("RAVEN_IDENTITY_BACKEND", "locked-file")
        .env("RAVEN_PREKEY_BACKEND", "locked-file")
        .arg("init")
        .output()
        .expect("initialize test profile");
    assert!(init.status.success(), "init status={:?}", init.status);
    let database = dir.path().join("forward_queue.sqlite");
    let corrupt = b"not a sqlite custody database";
    std::fs::write(&database, corrupt).expect("write corrupt fixture");

    let output = ash_for(dir.path())
        .env("RAVEN_IDENTITY_BACKEND", "locked-file")
        .env("RAVEN_PREKEY_BACKEND", "locked-file")
        .arg("status")
        .output()
        .expect("run ash status");

    assert!(!output.status.success(), "corrupt custody status must fail");
    assert!(String::from_utf8_lossy(&output.stderr).contains("bridge custody queue unavailable"));
    assert_eq!(std::fs::read(&database).unwrap(), corrupt);
    assert!(!dir.path().join("forward_queue.sqlite-wal").exists());
    assert!(!dir.path().join("forward_queue.sqlite-shm").exists());
}

#[test]
fn status_rejects_non_regular_custody_path_instead_of_reporting_zero() {
    let dir = tempfile::tempdir().expect("tempdir");
    let init = ash_for(dir.path())
        .env("RAVEN_IDENTITY_BACKEND", "locked-file")
        .env("RAVEN_PREKEY_BACKEND", "locked-file")
        .arg("init")
        .output()
        .expect("initialize test profile");
    assert!(init.status.success(), "init status={:?}", init.status);
    std::fs::create_dir(dir.path().join("forward_queue.sqlite"))
        .expect("create invalid queue directory");
    let output = ash_for(dir.path())
        .env("RAVEN_IDENTITY_BACKEND", "locked-file")
        .env("RAVEN_PREKEY_BACKEND", "locked-file")
        .arg("status")
        .output()
        .expect("run ash status");
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("invalid queue path"));
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
fn terminal_two_device_walkthrough_is_explicitly_debug_gated() {
    let demo = include_str!("../../../TERMINAL_DEMO.md");
    assert!(demo.contains("Manual two-device Debug-lab path"));
    assert!(demo.contains("export RAVEN_LAB_TEST_A=1"));
    assert!(demo.contains("target/release/ash send` is expected to fail"));
    assert!(demo.contains("closed today"));
    assert!(demo.contains("Status is read-only"));
    assert!(demo.contains("reciprocal pin"));
    assert!(demo.contains("--address <A_RVN_ADDRESS>"));
    assert!(demo.contains("--address <B_RVN_ADDRESS>"));
    assert!(!demo.contains("## Manual two-device terminal path (`ash` + secure service)"));
    assert!(!demo.contains("Status** → creates identity"));
}

#[test]
fn windows_status_timeout_wraps_the_whole_pipe_request() {
    let source = include_str!("../src/pair_init_lab.rs");
    assert!(source.contains("tokio::time::timeout(response_timeout, async move"));
    assert!(source.contains("ipc whole-request timeout"));
    assert!(source.contains("Duration::from_millis(300)"));
}

#[test]
fn windows_instance_lock_allows_read_only_owner_attribution() {
    let node = include_str!("../../raven-node/src/main.rs");
    assert!(node.contains(".share_mode(FILE_SHARE_READ)"));
    assert!(!node.contains(".share_mode(0)"));
    assert!(node.contains("publish_service_instance_owner(&mut file, &path)"));
}

#[test]
fn mailbox_route_key_never_has_an_argv_option() {
    let help = ash_for(tempfile::tempdir().expect("tempdir").path())
        .args(["mailbox", "put", "--help"])
        .output()
        .expect("mailbox put help");
    assert!(help.status.success());
    let stdout = String::from_utf8_lossy(&help.stdout);
    assert!(stdout.contains("--k-route-file"), "stdout={stdout:?}");
    assert!(stdout.contains("--k-route-stdin"), "stdout={stdout:?}");
    assert!(!stdout.contains("k-route-hex"), "stdout={stdout:?}");

    let secret = "7f".repeat(32);
    let rejected = ash_for(tempfile::tempdir().expect("tempdir").path())
        .args(["mailbox", "get", "--k-route-hex", &secret])
        .output()
        .expect("reject legacy argv secret");
    assert!(!rejected.status.success());
    assert!(!String::from_utf8_lossy(&rejected.stdout).contains(&secret));
    assert!(!String::from_utf8_lossy(&rejected.stderr).contains(&secret));
}

#[cfg(unix)]
#[test]
fn mailbox_route_key_stdin_is_absent_from_live_process_arguments() {
    let dir = tempfile::tempdir().expect("tempdir");
    let secret = "7f".repeat(32);
    let mut child = ash_for(dir.path())
        .args([
            "mailbox",
            "get",
            "--k-route-stdin",
            "--epoch",
            "1",
            "--slot",
            "0",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn mailbox get");
    let mut stdin = child.stdin.take().expect("mailbox stdin");
    stdin
        .write_all(secret.as_bytes())
        .expect("write route key to pipe");

    // `read_to_end` intentionally keeps the child blocked until EOF, giving us
    // a deterministic view of the real process command while the key is in its
    // stdin stream. The key must never be present in that command line.
    let process = Command::new("ps")
        .args(["-o", "command=", "-p", &child.id().to_string()])
        .output()
        .expect("inspect process arguments");
    assert!(process.status.success());
    let command_line = String::from_utf8_lossy(&process.stdout);
    assert!(command_line.contains("--k-route-stdin"), "{command_line:?}");
    assert!(!command_line.contains(&secret), "{command_line:?}");

    drop(stdin);
    let output = child.wait_with_output().expect("wait for mailbox get");
    assert!(output.status.success(), "status={:?}", output.status);
    assert!(!String::from_utf8_lossy(&output.stdout).contains(&secret));
    assert!(!String::from_utf8_lossy(&output.stderr).contains(&secret));
}

#[test]
fn installer_uses_release_defaults_and_never_hard_resets() {
    let installer = include_str!("../../../scripts/install.sh");
    assert!(installer.contains("do not pipe a"));
    assert!(installer.contains("Rust/Cargo is required"));
    assert!(!installer.contains("curl "));
    assert!(!installer.contains("| sh"));
    assert!(installer.contains("cargo build -q --locked --release -p ash -p raven-node"));
    assert!(installer.contains("target/release"));
    assert!(installer.contains("validate_link \"$BIN/raven\" \"$RAVEN_LINK\""));
    assert!(!installer.contains("unsafe-demo-crypto"));
    assert!(!installer.contains("reset --hard"));
    assert!(!installer.contains("git checkout -f"));
    assert!(installer.contains("remote get-url origin"));
    assert!(installer.contains("not a recognized RAVEN checkout"));
    assert!(installer.contains("REF=\"${RAVEN_INSTALL_REF:-main}\""));
    assert!(installer.contains("git check-ref-format --branch \"$REF\""));
    assert!(installer.contains("HEAD|refs/*"));
    assert!(installer.contains("-*|*@{*"));
    assert!(installer.contains("git -C \"$DIR\" status --porcelain"));
    assert!(installer.contains("git -C \"$DIR\" fetch --depth 1 origin \"$REF\""));
    assert!(installer.contains("rev-parse --verify 'FETCH_HEAD^{commit}'"));
    assert!(installer.contains("checkout --detach \"$RESOLVED_COMMIT\""));
    assert!(!installer.contains("merge --ff-only"));
    assert!(installer.contains("Linux release install is blocked in R1"));
    assert!(installer.contains("refusing to overwrite it"));
    assert!(!installer.contains("ln -sf"));
    assert!(!installer.contains("RAVEN_IDENTITY_BACKEND=locked-file"));
}

#[test]
fn unsigned_release_builder_uses_locked_default_features() {
    let builder = include_str!("../../../scripts/release/build_unsigned.sh");
    assert!(builder.contains("umask 022"));
    assert!(builder.contains("--locked"));
    assert!(builder.contains("--release"));
    assert!(builder.contains("CARGO_TARGET_DIR=\"$BUILD_TARGET\""));
    assert!(builder.contains("--target \"$HOST_TRIPLE\""));
    assert!(builder.contains("BUILT_BIN=\"$BUILD_TARGET/$HOST_TRIPLE/release\""));
    assert!(builder.contains("export SOURCE_DATE_EPOCH"));
    assert!(builder.contains("OUTPUT_WORK=\"$(mktemp -d \"$OUT_ROOT/"));
    assert!(builder.contains("LOCK_DIR=\"$OUT_ROOT/.$PACKAGE.lock\""));
    assert!(builder.contains("mv \"$ARCHIVE_TMP\" \"$FINAL_ARCHIVE\""));
    assert!(builder.contains("source_tree_clean=true"));
    assert!(builder.contains("info.mode = 0o755"));
    assert!(!builder.contains("$NODE_ROOT/target/release/raven"));
    assert!(!builder.contains("\"$NODE_ROOT\"/*.md"));
    assert!(!builder.contains("--features"));
    assert!(!builder.contains("unsafe-demo-crypto"));
    assert!(!builder.contains("experimental-offline-mailbox"));
    assert!(!builder.contains("experimental-nat-connectivity"));
}

#[test]
fn windows_artifact_service_and_legacy_ci_match_terminal_release_boundary() {
    let workflow = include_str!("../../../../.github/workflows/build-raven-windows.yml");
    assert!(workflow.contains("-p ash -p raven-node"));
    assert!(workflow.contains("raven.exe"));
    assert!(workflow.contains("ash.exe"));
    assert!(workflow.contains("raven-node.exe"));
    assert!(workflow.contains("aarch64-pc-windows-msvc"));
    assert!(workflow.contains("x86_64-pc-windows-msvc"));
    assert!(!workflow.contains("dotnet publish"));
    assert!(!workflow.contains("RAVEN-Windows/src/bin"));

    let service = include_str!("../../../scripts/install/windows_service.ps1");
    assert!(service.contains("-ExecutionTimeLimit ([TimeSpan]::Zero)"));
    assert!(service.contains("target\\release\\raven.exe\" $destinations[1]"));
    let service_docs = include_str!("../../../scripts/install/WINDOWS_SERVICE.md");
    assert!(service_docs.contains("-Profile Private -RemoteAddress LocalSubnet"));
    assert!(service_docs.contains("Do not create an `Any`/`Public` rule"));

    let legacy = include_str!("../../../../.github/workflows/integration_tests.yml");
    assert!(legacy.contains("Legacy Flutter Integration Tests (disabled)"));
    assert!(legacy.contains("workflow_dispatch:"));
    assert!(!legacy.contains("\n  push:"));
    assert!(!legacy.contains("\n  pull_request:"));
    assert!(!legacy.contains("subosito/flutter-action"));
    assert!(!legacy.contains("|| true"));
}

#[test]
fn macos_service_installer_serializes_and_arms_rollback_before_bootout() {
    let installer = include_str!("../../../scripts/install/macos_launchd.sh");
    assert!(installer.contains("install -m 755 \"$ROOT/target/release/raven\" \"$BIN_DIR/raven\""));
    assert!(installer.contains("INSTALL_LOCK_DIR=\"$INSTALL_STATE_DIR/.service-install.lock\""));
    assert!(!installer.contains("INSTALL_LOCK_DIR=\"$DATA_DIR/.service-install.lock\""));
    assert!(installer.contains("install directory is group/world-writable"));
    assert!(installer.contains("trap 'exit 130' HUP INT TERM"));
    let rollback_armed = installer
        .find("SERVICE_REPLACEMENT_STARTED=1")
        .expect("rollback marker");
    let bootout = installer
        .rfind("launchctl bootout \"gui/$(id -u)/${LABEL}\"")
        .expect("launchctl bootout");
    assert!(rollback_armed < bootout);
}
