#![cfg(unix)]

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::os::unix::net::UnixStream;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use raven_core::ipc::{
    decode_response, default_socket_path, encode_request, IpcRequest, IpcResponse, IPC_VERSION,
};

struct ChildGuard(Option<Child>);

impl Drop for ChildGuard {
    fn drop(&mut self) {
        if let Some(child) = self.0.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

fn free_loopback_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .expect("reserve test port")
        .local_addr()
        .expect("test address")
        .port()
}

fn ipc_roundtrip(data_dir: &std::path::Path, request: &IpcRequest) -> Result<IpcResponse, String> {
    let mut stream =
        UnixStream::connect(default_socket_path(data_dir)).map_err(|e| e.to_string())?;
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .map_err(|e| e.to_string())?;
    stream
        .set_write_timeout(Some(Duration::from_secs(10)))
        .map_err(|e| e.to_string())?;
    stream
        .write_all(&encode_request(request)?)
        .map_err(|e| e.to_string())?;
    let mut length = [0u8; 4];
    stream.read_exact(&mut length).map_err(|e| e.to_string())?;
    let n = u32::from_be_bytes(length) as usize;
    if n == 0 || n > raven_core::MAX_IPC_FRAME {
        return Err("invalid IPC response length".into());
    }
    let mut response = vec![0u8; 4 + n];
    response[..4].copy_from_slice(&length);
    stream
        .read_exact(&mut response[4..])
        .map_err(|e| e.to_string())?;
    decode_response(&response)
}

#[test]
fn legacy_run_rejects_malformed_optional_verification_key() {
    let fixture = tempfile::tempdir().expect("fixture");
    let profile = fixture.path().join("profile");
    let output = Command::new(env!("CARGO_BIN_EXE_raven-node"))
        .args(["run", "--data-dir"])
        .arg(&profile)
        .args([
            "--listen",
            "127.0.0.1:0",
            "--peer-pub-hex",
            "not-a-public-key",
            "--timeout-secs",
            "1",
        ])
        .env("RAVEN_ALLOW_EPHEMERAL_DATA_DIR", "1")
        .env("RAVEN_IDENTITY_BACKEND", "locked-file")
        .env("RAVEN_PREKEY_BACKEND", "locked-file")
        .output()
        .expect("run malformed optional key");
    assert!(!output.status.success());
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("--peer-pub-hex"),
        "stderr={}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn service_process_exposes_secure_lan_ipc_and_published_bridge() {
    let version = Command::new(env!("CARGO_BIN_EXE_raven-node"))
        .arg("--version")
        .output()
        .expect("raven-node --version");
    assert!(version.status.success());
    assert_eq!(
        String::from_utf8_lossy(&version.stdout).trim(),
        format!("raven-node {}", env!("CARGO_PKG_VERSION"))
    );

    let fixture = tempfile::tempdir().expect("fixture");
    let profile = fixture.path().join("profile");
    std::fs::create_dir(&profile).expect("profile directory");
    let lan_port = free_loopback_port();
    let bridge_file = fixture.path().join("bridge.addr");
    let log_path = fixture.path().join("service.log");
    let log = std::fs::File::create(&log_path).expect("service log");
    let log_err = log.try_clone().expect("clone service log");

    let child = Command::new(env!("CARGO_BIN_EXE_raven-node"))
        .args(["service", "--data-dir"])
        .arg(&profile)
        .args(["--lan-listen", &format!("127.0.0.1:{lan_port}")])
        .args(["--bridge-listen", "0.0.0.0:0", "--write-bridge-addr"])
        .arg(&bridge_file)
        .args(["--ble-listen", "127.0.0.1:0"])
        .env("RAVEN_ALLOW_EPHEMERAL_DATA_DIR", "1")
        .env("RAVEN_IDENTITY_BACKEND", "locked-file")
        .env("RAVEN_PREKEY_BACKEND", "locked-file")
        .stdin(Stdio::null())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(log_err))
        .spawn()
        .expect("spawn service");
    let mut service = ChildGuard(Some(child));

    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if matches!(
            ipc_roundtrip(&profile, &IpcRequest::Ping { v: IPC_VERSION }),
            Ok(IpcResponse::Pong { .. })
        ) && bridge_file.is_file()
        {
            break;
        }
        if let Some(status) = service
            .0
            .as_mut()
            .expect("service child")
            .try_wait()
            .expect("poll service")
        {
            let logs = std::fs::read_to_string(&log_path).unwrap_or_default();
            panic!("service exited before readiness ({status}):\n{logs}");
        }
        if Instant::now() >= deadline {
            let logs = std::fs::read_to_string(&log_path).unwrap_or_default();
            panic!("service readiness timeout:\n{logs}");
        }
        std::thread::sleep(Duration::from_millis(50));
    }

    let canonical_before = std::fs::read_to_string(profile.join("service-bridge.addr"))
        .expect("canonical bridge publication before duplicate");
    let custom_before =
        std::fs::read_to_string(&bridge_file).expect("custom bridge publication before duplicate");
    let duplicate = Command::new(env!("CARGO_BIN_EXE_raven-node"))
        .args(["service", "--data-dir"])
        .arg(&profile)
        .args(["--lan-listen", &format!("127.0.0.1:{lan_port}")])
        .args(["--bridge-listen", "127.0.0.1:0"])
        .args(["--ble-listen", "127.0.0.1:0"])
        .env("RAVEN_ALLOW_EPHEMERAL_DATA_DIR", "1")
        .env("RAVEN_IDENTITY_BACKEND", "locked-file")
        .env("RAVEN_PREKEY_BACKEND", "locked-file")
        .stdin(Stdio::null())
        .output()
        .expect("run duplicate service");
    assert!(!duplicate.status.success(), "duplicate service must fail");
    assert!(
        String::from_utf8_lossy(&duplicate.stderr).contains("already running"),
        "duplicate error must identify the held profile instance lock: {}",
        String::from_utf8_lossy(&duplicate.stderr)
    );
    let duplicate_bridge = Command::new(env!("CARGO_BIN_EXE_raven-node"))
        .args(["bridge", "--data-dir"])
        .arg(&profile)
        .args([
            "--lan-listen",
            "127.0.0.1:0",
            "--ble-listen",
            "127.0.0.1:0",
            "--timeout-secs",
            "1",
        ])
        .env("RAVEN_ALLOW_EPHEMERAL_DATA_DIR", "1")
        .env("RAVEN_IDENTITY_BACKEND", "locked-file")
        .env("RAVEN_PREKEY_BACKEND", "locked-file")
        .output()
        .expect("run standalone bridge against live service");
    assert!(
        !duplicate_bridge.status.success(),
        "standalone bridge must not share custody state with a live service"
    );
    assert!(
        String::from_utf8_lossy(&duplicate_bridge.stderr).contains("already running"),
        "bridge lock refusal must be explicit: {}",
        String::from_utf8_lossy(&duplicate_bridge.stderr)
    );
    assert!(matches!(
        ipc_roundtrip(&profile, &IpcRequest::Ping { v: IPC_VERSION }),
        Ok(IpcResponse::Pong { .. })
    ));
    assert_eq!(
        std::fs::read_to_string(profile.join("service-bridge.addr"))
            .expect("canonical publication survives duplicate"),
        canonical_before
    );
    assert_eq!(
        std::fs::read_to_string(&bridge_file).expect("custom publication survives duplicate"),
        custom_before
    );

    let address = Command::new(env!("CARGO_BIN_EXE_raven-node"))
        .args(["address", "--data-dir"])
        .arg(&profile)
        .env("RAVEN_ALLOW_EPHEMERAL_DATA_DIR", "1")
        .env("RAVEN_IDENTITY_BACKEND", "locked-file")
        .output()
        .expect("read service public identity");
    assert!(address.status.success());
    let address_stdout = String::from_utf8_lossy(&address.stdout);
    let public_hex = address_stdout
        .lines()
        .find_map(|line| line.strip_prefix("pub_hex="))
        .expect("public key output");
    let response = ipc_roundtrip(
        &profile,
        &IpcRequest::LanDial {
            v: IPC_VERSION,
            lan_dial: format!("127.0.0.1:{lan_port}"),
            expected_pub_hex: public_hex.to_string(),
            frames_b64: Vec::new(),
        },
    )
    .expect("secure self LanDial");
    match response {
        IpcResponse::LanDialResult { frames_b64, .. } => {
            assert!(!frames_b64.is_empty(), "RLB1 offer must be returned");
        }
        other => panic!("unexpected LanDial response: {other:?}"),
    }

    let published: SocketAddr = std::fs::read_to_string(&bridge_file)
        .expect("published bridge address")
        .parse()
        .expect("bridge socket address");
    let canonical: SocketAddr = std::fs::read_to_string(profile.join("service-bridge.addr"))
        .expect("canonical bridge address")
        .parse()
        .expect("canonical bridge socket address");
    assert_eq!(canonical, published);
    assert!(published.ip().is_unspecified());
    assert_ne!(published.port(), 0);
    TcpStream::connect(("127.0.0.1", published.port())).expect("LAN-reachable bridge listener");
}
