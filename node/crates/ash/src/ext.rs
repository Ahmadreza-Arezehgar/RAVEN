//! Extended ash commands: bootstrap, device sync, chat, secure send, mailbox.
//! Kept separate from main.rs to keep the interactive shell readable.

use std::io::{self, Write};
use std::path::{Path, PathBuf};

use rand::RngCore;
use raven_core::address::encode_address;
use raven_core::atsam_mlkem::{HybridKeypair, DK_SEED_LEN};
use raven_core::bootstrap::{load_bootstrap, save_bootstrap, BootstrapConfig};
use raven_core::chat_history::{BlockList, ChatHistory};
use raven_core::device_cert::{load_device_registry, save_device_registry};
use raven_core::device_sync::{
    import_contact_sync, seal_contact_sync, unseal_contact_sync, ContactSyncPlaintext,
    RevocationRecord, RevocationStore, SyncContact,
};
use raven_core::envelope::Envelope;
use raven_core::fingerprint::device_fingerprint_v1;
use raven_core::identity::Identity;
#[cfg(unix)]
use raven_core::ipc::{decode_response, encode_request};
use raven_core::ipc::{default_socket_path, IpcRequest, IpcResponse, IPC_VERSION};
use raven_core::messaging_path::{assert_no_silent_fastapi, resolve_terminal_messaging_path};
use raven_core::prekey_bundle::{PrekeyBundle, PrekeyBundleJson, PrekeyStore};
use raven_core::sanitize::sanitize_terminal_text;
use raven_core::store_object::{
    mailbox_tag, mailbox_tags_with_overlap, store_tag_from_mailbox, StoreMailbox, StoreObject,
};
use std::process::Command;
use std::time::Duration;
use zeroize::{Zeroize, Zeroizing};

const DEFAULT_LAN_PORT: u16 = 7420;
const HYBRID_PREKEY_PRIVATE_LEN: usize = 32 + DK_SEED_LEN;

const C_CYAN: &str = "\x1b[38;2;64;242;255m";
const C_PURPLE: &str = "\x1b[38;2;191;115;255m";
const C_DIM: &str = "\x1b[38;2;160;160;170m";
const C_GREEN: &str = "\x1b[38;2;34;197;94m";
const C_RESET: &str = "\x1b[0m";
const C_BOLD: &str = "\x1b[1m";

pub fn read_line() -> String {
    let mut s = String::new();
    if io::stdin().read_line(&mut s).is_err() {
        return String::new();
    }
    s.trim().to_string()
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn parse_pub_hex(s: &str) -> Result<[u8; 32], String> {
    let h = s.trim().to_lowercase();
    if h.len() != 64 {
        return Err("pub_hex must be 64 hex chars (32 bytes)".into());
    }
    let v = hex::decode(&h).map_err(|_| "pub_hex invalid hex".to_string())?;
    if v.len() != 32 {
        return Err("pub_hex must decode to 32 bytes".into());
    }
    let mut a = [0u8; 32];
    a.copy_from_slice(&v);
    Ok(a)
}

fn raven_node_bin() -> PathBuf {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.join("raven-node")))
        .unwrap_or_else(|| PathBuf::from("raven-node"))
}

#[allow(dead_code)]
fn peer_is_local_listen_queue(peer: &str) -> bool {
    let t = peer.trim();
    t.eq_ignore_ascii_case("local-listen") || t.eq_ignore_ascii_case("local")
}

#[allow(dead_code)]
fn local_lan_ipv4_hint() -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        for iface in ["en0", "en1"] {
            if let Ok(out) = Command::new("ipconfig").args(["getifaddr", iface]).output() {
                if out.status.success() {
                    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
                    if !s.is_empty() && s.parse::<std::net::Ipv4Addr>().is_ok() {
                        return Some(s);
                    }
                }
            }
        }
    }
    None
}

/// Start / revive Mac LAN + IPC daemon so local-listen enqueue works.
pub fn ensure_mac_lan_daemon(data_dir: &Path) -> bool {
    let sock = default_socket_path(data_dir);
    if sock.exists() {
        if matches!(
            ipc_request_blocking(&sock, &IpcRequest::Ping { v: IPC_VERSION }),
            Ok(IpcResponse::Pong { .. })
        ) {
            return true;
        }
        // Stale UDS after crash → remove so a fresh service can bind.
        let _ = std::fs::remove_file(&sock);
    }
    let node = raven_node_bin();
    let listen = format!("0.0.0.0:{DEFAULT_LAN_PORT}");
    let data = data_dir.to_str().unwrap_or(".");
    if let Err(e) = Command::new(&node)
        .args([
            "service",
            "--data-dir",
            data,
            "--lan-listen",
            &listen,
            "--ble-listen",
            "127.0.0.1:0",
        ])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
    {
        eprintln!("{C_DIM}could not auto-start raven-node service ({e}){C_RESET}");
        return false;
    }
    for _ in 0..50 {
        if sock.exists()
            && matches!(
                ipc_request_blocking(&sock, &IpcRequest::Ping { v: IPC_VERSION }),
                Ok(IpcResponse::Pong { .. })
            )
        {
            return true;
        }
        std::thread::sleep(Duration::from_millis(40));
    }
    false
}

// ── Bootstrap UX ──────────────────────────────────────────────────────────

pub fn cmd_bootstrap_show(data_dir: &Path) {
    let cfg = load_bootstrap(data_dir);
    println!("{C_BOLD}bootstrap{C_RESET}");
    println!(
        "{C_DIM}use_raven_defaults{C_RESET} {}",
        cfg.use_raven_defaults
    );
    println!(
        "{C_DIM}raven_defaults{C_RESET}     {}",
        cfg.raven_defaults.len()
    );
    for p in &cfg.raven_defaults {
        println!("  {C_DIM}raven{C_RESET} {}", sanitize_terminal_text(p));
    }
    println!("{C_DIM}custom{C_RESET}            {}", cfg.custom.len());
    for p in &cfg.custom {
        println!("  {C_CYAN}+{C_RESET} {}", sanitize_terminal_text(p));
    }
    println!(
        "{C_DIM}manual_peers{C_RESET}      {}",
        cfg.manual_peers.len()
    );
    for p in &cfg.manual_peers {
        println!("  {C_GREEN}*{C_RESET} {}", sanitize_terminal_text(p));
    }
    println!(
        "{C_DIM}effective{C_RESET}         {} peers",
        cfg.effective_peers().len()
    );
    println!(
        "{C_DIM}manual_only_ok{C_RESET}    {}",
        cfg.manual_peer_only_ok()
    );
}

pub fn cmd_bootstrap_add(data_dir: &Path, multiaddr: &str, manual: bool) {
    let mut cfg = load_bootstrap(data_dir);
    let s = sanitize_terminal_text(multiaddr.trim());
    if s.is_empty() {
        eprintln!("empty multiaddr");
        std::process::exit(1);
    }
    if manual {
        if !cfg.manual_peers.iter().any(|x| x == &s) {
            cfg.manual_peers.push(s.clone());
        }
    } else {
        cfg.add_custom(s.clone());
    }
    if let Err(e) = save_bootstrap(data_dir, &cfg) {
        eprintln!("save failed: {e}");
        std::process::exit(1);
    }
    println!("{C_GREEN}ok{C_RESET} added {}", s);
    cmd_bootstrap_show(data_dir);
}

pub fn cmd_bootstrap_disable_raven(data_dir: &Path) {
    let mut cfg = load_bootstrap(data_dir);
    cfg.remove_raven_defaults();
    if let Err(e) = save_bootstrap(data_dir, &cfg) {
        eprintln!("save failed: {e}");
        std::process::exit(1);
    }
    println!("{C_GREEN}ok{C_RESET} raven defaults disabled/cleared");
    cmd_bootstrap_show(data_dir);
}

pub fn cmd_bootstrap_init(data_dir: &Path, no_raven_defaults: bool) {
    let mut cfg = BootstrapConfig::default();
    if no_raven_defaults {
        cfg.remove_raven_defaults();
    }
    if let Err(e) = save_bootstrap(data_dir, &cfg) {
        eprintln!("save failed: {e}");
        std::process::exit(1);
    }
    println!("{C_GREEN}ok{C_RESET} wrote bootstrap.json");
    cmd_bootstrap_show(data_dir);
}

// ── Device sync ───────────────────────────────────────────────────────────

#[derive(serde::Serialize, serde::Deserialize)]
struct LocalContactRow {
    #[serde(default)]
    petname: String,
    #[serde(default)]
    public_tag: String,
    #[serde(default)]
    alias: String,
    address: String,
    pub_hex: String,
    #[serde(default)]
    pinned: bool,
    #[serde(default)]
    lan_dial: String,
}

fn load_local_contacts(data_dir: &Path) -> Vec<LocalContactRow> {
    let path = data_dir.join("contacts.json");
    let Ok(raw) = std::fs::read_to_string(&path) else {
        return vec![];
    };
    serde_json::from_str(&raw).unwrap_or_default()
}

fn save_local_contacts(data_dir: &Path, rows: &[LocalContactRow]) -> Result<(), String> {
    let raw = serde_json::to_string_pretty(rows).map_err(|e| e.to_string())?;
    std::fs::write(data_dir.join("contacts.json"), raw).map_err(|e| e.to_string())
}

pub fn cmd_device_sync_export(data_dir: &Path, id: &Identity, device_id: &str, out: &Path) {
    let contacts = load_local_contacts(data_dir);
    let sync: Vec<SyncContact> = contacts
        .into_iter()
        .map(|c| {
            SyncContact {
                petname: c.petname,
                public_tag: if c.public_tag.is_empty() {
                    c.alias.clone()
                } else {
                    c.public_tag
                },
                alias: c.alias,
                address: c.address,
                pub_hex: c.pub_hex,
                pinned: c.pinned,
            }
            .migrate()
        })
        .collect();
    let plain = ContactSyncPlaintext {
        schema: 1,
        from_device_id: sanitize_terminal_text(device_id),
        contacts: sync,
        issued_at_ms: now_ms(),
    };
    match seal_contact_sync(id, &plain) {
        Ok(wire) => {
            if let Err(e) = std::fs::write(out, hex::encode(&wire)) {
                eprintln!("write failed: {e}");
                std::process::exit(1);
            }
            println!(
                "{C_GREEN}ok{C_RESET} sealed {} contacts → {}",
                plain.contacts.len(),
                out.display()
            );
            println!("{C_DIM}note{C_RESET} hex blob — exchange OOB / opaque store only");
        }
        Err(e) => {
            eprintln!("seal failed: {e}");
            std::process::exit(1);
        }
    }
}

pub fn cmd_device_sync_import(data_dir: &Path, id: &Identity, file: &Path) {
    let raw = match std::fs::read_to_string(file) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("read: {e}");
            std::process::exit(1);
        }
    };
    let wire = match hex::decode(raw.trim()) {
        Ok(w) => w,
        Err(e) => {
            eprintln!("hex: {e}");
            std::process::exit(1);
        }
    };
    let reg = load_device_registry(data_dir);
    let imported = match import_contact_sync(id, &reg, &wire, now_ms()) {
        Ok(c) => c,
        Err(e) => {
            // Soft-allow when registry empty (first import before device certs):
            // still require unseal with user key.
            if e == "SYNC_FROM_UNAUTHORIZED_OR_REVOKED" && reg.certs.is_empty() {
                match unseal_contact_sync(id, &wire) {
                    Ok(p) => {
                        eprintln!(
                            "{C_PURPLE}warn{C_RESET}: empty device registry — imported without device-auth check"
                        );
                        p.contacts.into_iter().map(SyncContact::migrate).collect()
                    }
                    Err(e2) => {
                        eprintln!("import failed: {e2}");
                        std::process::exit(1);
                    }
                }
            } else {
                eprintln!("import failed: {e}");
                std::process::exit(1);
            }
        }
    };
    let mut local = load_local_contacts(data_dir);
    let mut added = 0usize;
    for sc in imported {
        if local
            .iter()
            .any(|c| c.pub_hex.eq_ignore_ascii_case(&sc.pub_hex))
        {
            continue;
        }
        // Pin conflict: refuse overwrite of pinned different key for same tag.
        let tag = if sc.public_tag.is_empty() {
            sc.alias.clone()
        } else {
            sc.public_tag.clone()
        };
        if !tag.is_empty()
            && local.iter().any(|c| {
                c.pinned
                    && c.public_tag.eq_ignore_ascii_case(&tag)
                    && !c.pub_hex.eq_ignore_ascii_case(&sc.pub_hex)
            })
        {
            eprintln!("{C_PURPLE}skip{C_RESET} @{tag} — pinned local key differs");
            continue;
        }
        local.push(LocalContactRow {
            petname: sc.petname,
            public_tag: tag,
            alias: sc.alias,
            address: sc.address,
            pub_hex: sc.pub_hex,
            pinned: sc.pinned,
            lan_dial: String::new(),
        });
        added += 1;
    }
    if let Err(e) = save_local_contacts(data_dir, &local) {
        eprintln!("save contacts: {e}");
        std::process::exit(1);
    }
    println!("{C_GREEN}ok{C_RESET} imported {added} new contact(s)");
}

pub fn cmd_device_revoke(data_dir: &Path, id: &Identity, device_id: &str, epoch: u64) {
    let rec = match RevocationRecord::issue(id, device_id, epoch, now_ms(), "operator-revoke") {
        Ok(r) => r,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    };
    let mut store = RevocationStore::load(data_dir);
    match store.apply(rec) {
        Ok(true) => {
            let _ = store.save(data_dir);
            let mut reg = load_device_registry(data_dir);
            store.push_into_registry(&mut reg);
            let _ = save_device_registry(data_dir, &reg);
            println!(
                "{C_GREEN}ok{C_RESET} revoked {}",
                sanitize_terminal_text(device_id)
            );
        }
        Ok(false) => println!("{C_DIM}already applied / older epoch{C_RESET}"),
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    }
}

// ── Secure send (seal in ash → IPC enqueue; never argv plaintext) ─────────

pub fn refuse_argv_plaintext() {
    eprintln!("{C_PURPLE}REFUSE{C_RESET}: plaintext on argv is forbidden (visible via ps).");
    eprintln!(
        "{C_DIM}use:{C_RESET} ash send --peer … --peer-pub-hex …   # then type message on stdin"
    );
    eprintln!("{C_DIM} or:{C_RESET} ash send --peer … --peer-pub-hex … --stdin-text < msg.txt");
    std::process::exit(2);
}

fn ipc_request_blocking(sock: &Path, req: &IpcRequest) -> Result<IpcResponse, String> {
    #[cfg(unix)]
    {
        use std::io::{Read, Write};
        use std::os::unix::net::UnixStream;
        let mut stream = UnixStream::connect(sock).map_err(|e| e.to_string())?;
        let frame = encode_request(req)?;
        stream.write_all(&frame).map_err(|e| e.to_string())?;
        let mut len_buf = [0u8; 4];
        stream.read_exact(&mut len_buf).map_err(|e| e.to_string())?;
        let n = u32::from_be_bytes(len_buf) as usize;
        if n == 0 || n > raven_core::MAX_IPC_FRAME {
            return Err("IPC_FRAME".into());
        }
        let mut body = vec![0u8; n];
        stream.read_exact(&mut body).map_err(|e| e.to_string())?;
        let mut frame = Vec::with_capacity(4 + n);
        frame.extend_from_slice(&len_buf);
        frame.extend_from_slice(&body);
        decode_response(&frame)
    }
    #[cfg(not(unix))]
    {
        let _ = (sock, req);
        Err("IPC UDS not available on this OS — use Windows named-pipe daemon".into())
    }
}

/// Lab Test A send: PairInit LAN OOB → PairResponse → IndexedSessionStore envelope.
/// Never uses public-key-derived seal_message / unsafe-demo-crypto.
#[allow(clippy::too_many_arguments)]
pub fn run_send_secure(
    data_dir: &Path,
    id: &Identity,
    peer: &str,
    peer_pub_hex: &str,
    listen: &str,
    text: &str,
    petname: &str,
    tag: &str,
) -> Result<(), String> {
    let path = resolve_terminal_messaging_path();
    assert_no_silent_fastapi(path)?;
    let blocks = BlockList::load(data_dir);
    if blocks.is_blocked(peer_pub_hex) {
        return Err("peer is on the local block list".into());
    }
    let _peer_pub = parse_pub_hex(peer_pub_hex)?;
    let _ = (listen, petname, tag);

    let mut message_id = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut message_id);
    let mid_prefix = hex::encode(&message_id[..4]);

    if !super::trace_delivery::live_pair_init_outbound_ready() {
        let status = super::trace_delivery::production_gate_status();
        super::trace_delivery::trace_event(
            "ash/ext.rs:run_send_secure",
            "TRACE_SEND_BLOCKED",
            status,
            Some(&mid_prefix),
            Some("no_live_pair_init_or_indexed_session_callsite"),
        );
        println!("{C_PURPLE}status{C_RESET} {status}");
        println!(
            "{C_DIM}EN:{C_RESET} Message not sent — set RAVEN_LAB_TEST_A=1 (debug) after wiring, or wait for production gates."
        );
        println!(
            "{C_DIM}FA:{C_RESET} پیام ارسال نشد؛ تا PairInit و session واقعی فعال نشوند صف ساختگی باز نمی‌شود."
        );
        return Err(status.into());
    }

    let _ = ensure_mac_lan_daemon(data_dir);
    super::trace_delivery::trace_event(
        "ash/ext.rs:run_send_secure",
        "TRACE_SEND_LAB_PAIR_INIT",
        super::trace_delivery::production_gate_status(),
        Some(&mid_prefix),
        Some("pair_init_lab"),
    );
    super::pair_init_lab::run_pair_init_and_send(data_dir, id, peer, peer_pub_hex, text)
}


// ── Chat session with slash commands ──────────────────────────────────────

pub fn cmd_chat_session(
    data_dir: &Path,
    id: &Identity,
    contact_petname: &str,
    contact_tag: &str,
    contact_pub: &str,
    peer_listen: &str,
) {
    println!(
        "{C_BOLD}chat{C_RESET} {} {}{C_DIM}  /back /info /verify /block /clear-local-history{C_RESET}",
        sanitize_terminal_text(contact_petname),
        if contact_tag.is_empty() {
            String::new()
        } else {
            format!("@{contact_tag}")
        }
    );
    match ChatHistory::load(data_dir) {
        Ok(history) => {
            let rows = history.for_peer(contact_pub);
            if rows.is_empty() {
                println!("{C_DIM}(no local history){C_RESET}");
            } else {
                for e in rows.iter().rev().take(20).rev() {
                    let dir = if e.direction == "out" { "→" } else { "←" };
                    println!(
                        "  {C_DIM}{}{C_RESET} {} {}",
                        &e.message_id_hex[..8.min(e.message_id_hex.len())],
                        dir,
                        sanitize_terminal_text(&e.preview)
                    );
                }
            }
        }
        Err(error) => {
            eprintln!("local protected history unavailable: {error}");
        }
    }
    loop {
        print!(
            "{C_PURPLE}{}>{C_RESET} ",
            sanitize_terminal_text(contact_petname)
        );
        let _ = io::stdout().flush();
        let line = read_line();
        if line.is_empty() {
            continue;
        }
        if line.starts_with('/') {
            match line.split_whitespace().next().unwrap_or("") {
                "/back" | "/quit" | "/q" => {
                    println!("{C_DIM}left chat{C_RESET}");
                    return;
                }
                "/info" => {
                    println!(
                        "{C_DIM}petname{C_RESET} {}",
                        sanitize_terminal_text(contact_petname)
                    );
                    if !contact_tag.is_empty() {
                        println!("{C_DIM}tag{C_RESET}     @{contact_tag}");
                    }
                    println!("{C_DIM}pub{C_RESET}     {contact_pub}");
                    if let Ok(p) = parse_pub_hex(contact_pub) {
                        println!("{C_DIM}fp{C_RESET}      {}", device_fingerprint_v1(&p));
                        println!("{C_DIM}address{C_RESET} {}", encode_address(&p));
                    }
                }
                "/verify" => {
                    if let Ok(p) = parse_pub_hex(contact_pub) {
                        println!("{C_BOLD}fingerprint{C_RESET} {}", device_fingerprint_v1(&p));
                        println!(
                            "{C_DIM}compare out-of-band / pin via: ash contact verify{C_RESET}"
                        );
                    }
                }
                "/block" => {
                    let mut b = BlockList::load(data_dir);
                    b.block(contact_pub);
                    let _ = b.save(data_dir);
                    println!("{C_GREEN}blocked{C_RESET} {contact_pub}");
                    return;
                }
                "/clear-local-history" => {
                    match ChatHistory::clear_peer_persisted(data_dir, contact_pub) {
                        Ok(()) => {
                            println!("{C_GREEN}cleared{C_RESET} local history for peer");
                        }
                        Err(error) => {
                            eprintln!("local history clear failed: {error}");
                        }
                    }
                }
                other => println!("{C_DIM}unknown command:{C_RESET} {other}"),
            }
            continue;
        }
        if let Err(error) = run_send_secure(
            data_dir,
            id,
            peer_listen,
            contact_pub,
            "127.0.0.1:0",
            &line,
            contact_petname,
            contact_tag,
        ) {
            eprintln!("send refused: {error}");
        }
    }
}

// ── Real prekey publish ───────────────────────────────────────────────────

/// Atomically replace the responder's hybrid prekey private state.
///
/// The temporary file is created in the same directory with owner-only access,
/// synced before rename, and the containing directory is synced after rename.
/// Until the rename succeeds, an existing private state remains untouched.
#[cfg(unix)]
fn persist_hybrid_prekey_private_state(
    data_dir: &Path,
    private_state: &[u8],
) -> Result<(), String> {
    use std::fs::{File, OpenOptions, Permissions};
    use std::io::ErrorKind;
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

    if private_state.len() != HYBRID_PREKEY_PRIVATE_LEN {
        return Err("PREKEY_PRIVATE_STATE_LENGTH".into());
    }

    std::fs::create_dir_all(data_dir).map_err(|e| format!("PREKEY_PRIVATE_STORE_CREATE: {e}"))?;
    let destination = data_dir.join("prekey_hybrid.secret");
    let mut rng = rand::thread_rng();
    let (temporary, mut file) = loop {
        let candidate = data_dir.join(format!(".prekey_hybrid.secret.tmp.{:016x}", rng.next_u64()));
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&candidate)
        {
            Ok(file) => break (candidate, file),
            Err(e) if e.kind() == ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(format!("PREKEY_PRIVATE_STORE_CREATE: {e}")),
        }
    };

    let prepared = (|| -> Result<(), String> {
        file.set_permissions(Permissions::from_mode(0o600))
            .map_err(|e| format!("PREKEY_PRIVATE_STORE_PERMISSIONS: {e}"))?;
        file.write_all(private_state)
            .map_err(|e| format!("PREKEY_PRIVATE_STORE_WRITE: {e}"))?;
        file.sync_all()
            .map_err(|e| format!("PREKEY_PRIVATE_STORE_SYNC: {e}"))?;
        Ok(())
    })();
    drop(file);
    if let Err(e) = prepared {
        let _ = std::fs::remove_file(&temporary);
        return Err(e);
    }

    if let Err(e) = std::fs::rename(&temporary, &destination) {
        let _ = std::fs::remove_file(&temporary);
        return Err(format!("PREKEY_PRIVATE_STORE_RENAME: {e}"));
    }
    File::open(data_dir)
        .and_then(|directory| directory.sync_all())
        .map_err(|e| format!("PREKEY_PRIVATE_STORE_DIRECTORY_SYNC: {e}"))?;
    Ok(())
}

#[cfg(unix)]
#[allow(dead_code)] // consumed by the production PairInit activation path once frozen
fn load_hybrid_prekey_private_state(data_dir: &Path) -> Result<Zeroizing<Vec<u8>>, String> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    let path = data_dir.join("prekey_hybrid.secret");
    let metadata =
        std::fs::symlink_metadata(&path).map_err(|e| format!("PREKEY_PRIVATE_STORE_READ: {e}"))?;
    if !metadata.file_type().is_file()
        || metadata.file_type().is_symlink()
        || metadata.nlink() != 1
        || metadata.permissions().mode() & 0o077 != 0
    {
        return Err("PREKEY_PRIVATE_STORE_UNSAFE_METADATA".into());
    }
    let bytes = Zeroizing::new(
        std::fs::read(&path).map_err(|e| format!("PREKEY_PRIVATE_STORE_READ: {e}"))?,
    );
    if bytes.len() != HYBRID_PREKEY_PRIVATE_LEN {
        return Err("PREKEY_PRIVATE_STATE_LENGTH".into());
    }
    Ok(bytes)
}

#[cfg(not(unix))]
#[allow(dead_code)] // consumed by the production PairInit activation path once frozen
fn load_hybrid_prekey_private_state(_data_dir: &Path) -> Result<Zeroizing<Vec<u8>>, String> {
    Err("PREKEY_PROTECTED_STORE_UNAVAILABLE".into())
}

/// A protected private-material backend has not been implemented on this
/// platform. Refuse publication instead of falling back to a plaintext file.
#[cfg(not(unix))]
fn persist_hybrid_prekey_private_state(
    _data_dir: &Path,
    _private_state: &[u8],
) -> Result<(), String> {
    Err("PREKEY_PROTECTED_STORE_UNAVAILABLE".into())
}

pub fn cmd_prekey_publish_real(
    data_dir: &Path,
    id: &Identity,
    device_id: &str,
    out: Option<&Path>,
) {
    let mut rng = rand::thread_rng();
    let mut kp = HybridKeypair::generate(&mut rng);
    let mut private_state = Zeroizing::new([0u8; HYBRID_PREKEY_PRIVATE_LEN]);
    private_state[..32].copy_from_slice(&kp.x25519_secret);
    private_state[32..].copy_from_slice(&kp.mlkem_seed);
    kp.x25519_secret.zeroize();
    kp.mlkem_seed.zeroize();

    let now = now_ms();
    let bundle = match PrekeyBundle::from_hybrid_public(
        sanitize_terminal_text(device_id),
        kp.x25519_public,
        kp.mlkem_ek_bytes.clone(),
        1,
        now,
        now.saturating_add(30 * 24 * 3600 * 1000),
    ) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("{e}");
            return;
        }
    };
    let bundle = match bundle.sign(id) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("sign: {e}");
            return;
        }
    };

    // Private state must be durable before any public bundle is inserted,
    // exported, or reported. `Zeroizing` wipes the staging copy on every exit.
    let private_store_result = persist_hybrid_prekey_private_state(data_dir, &private_state[..]);
    if let Err(e) = private_store_result {
        eprintln!("prekey publish refused: {e}");
        return;
    }

    let mut store = PrekeyStore::load(data_dir);
    if let Err(e) = store.publish(&bundle, now) {
        eprintln!("publish: {e}");
        return;
    }
    if let Err(e) = store.save(data_dir) {
        eprintln!("save: {e}");
        return;
    }
    println!("{C_GREEN}prekey published{C_RESET} (real X25519 + ML-KEM-768 EK)");
    println!(
        "{C_DIM}store_key{C_RESET} {}",
        hex::encode(PrekeyBundle::store_key(&id.public_key_bytes()))
    );
    println!("{C_DIM}note{C_RESET}      never FastAPI — OOB/file/DHT only");
    if let Some(path) = out {
        let j = bundle.to_json();
        if let Ok(raw) = serde_json::to_string_pretty(&j) {
            let _ = std::fs::write(path, raw);
            println!("{C_DIM}oob_file{C_RESET} {}", path.display());
        }
    }
}

#[cfg(all(test, unix))]
mod prekey_private_store_tests {
    use super::*;
    use std::io::{Read, Seek, SeekFrom};
    use std::os::unix::fs::PermissionsExt;
    use tempfile::tempdir;

    #[test]
    fn private_state_is_owner_only_and_atomically_replaced() {
        let dir = tempdir().expect("tempdir");
        let first = [0x11; HYBRID_PREKEY_PRIVATE_LEN];
        let second = [0x22; HYBRID_PREKEY_PRIVATE_LEN];
        let path = dir.path().join("prekey_hybrid.secret");

        persist_hybrid_prekey_private_state(dir.path(), &first).expect("first write");
        let mode = std::fs::metadata(&path)
            .expect("metadata")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600);

        let mut old_handle = std::fs::File::open(&path).expect("old handle");
        persist_hybrid_prekey_private_state(dir.path(), &second).expect("replacement");
        assert_eq!(std::fs::read(&path).expect("new path"), second);

        old_handle.seek(SeekFrom::Start(0)).expect("seek");
        let mut old_contents = Vec::new();
        old_handle
            .read_to_end(&mut old_contents)
            .expect("read old handle");
        assert_eq!(old_contents, first);
        assert!(std::fs::read_dir(dir.path())
            .expect("read dir")
            .all(|entry| !entry
                .expect("entry")
                .file_name()
                .to_string_lossy()
                .starts_with(".prekey_hybrid.secret.tmp.")));
    }

    #[test]
    fn malformed_private_state_cannot_replace_existing_state() {
        let dir = tempdir().expect("tempdir");
        let first = [0x33; HYBRID_PREKEY_PRIVATE_LEN];
        let path = dir.path().join("prekey_hybrid.secret");
        persist_hybrid_prekey_private_state(dir.path(), &first).expect("first write");

        let err = persist_hybrid_prekey_private_state(dir.path(), &[0x44; 8])
            .expect_err("short state must fail");
        assert_eq!(err, "PREKEY_PRIVATE_STATE_LENGTH");
        assert_eq!(std::fs::read(path).expect("preserved state"), first);
    }

    #[test]
    fn persistence_failure_prevents_publication_and_export() {
        let dir = tempdir().expect("tempdir");
        let unusable_data_dir = dir.path().join("not-a-directory");
        std::fs::write(&unusable_data_dir, b"blocker").expect("blocker");
        let export = dir.path().join("public-prekey.json");
        let identity = Identity::from_seed(&[0x55; 32]);

        cmd_prekey_publish_real(&unusable_data_dir, &identity, "test-device", Some(&export));

        assert!(!export.exists());
        assert!(!unusable_data_dir.join("prekey_store.json").exists());
        assert!(!unusable_data_dir.join("prekey_hybrid.secret").exists());
    }

    #[test]
    fn private_state_loader_rejects_weak_permissions_and_wrong_length() {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("prekey_hybrid.secret");
        persist_hybrid_prekey_private_state(dir.path(), &[0x66; HYBRID_PREKEY_PRIVATE_LEN])
            .expect("persist");
        assert_eq!(
            load_hybrid_prekey_private_state(dir.path())
                .expect("safe load")
                .len(),
            HYBRID_PREKEY_PRIVATE_LEN
        );

        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).expect("chmod");
        assert_eq!(
            load_hybrid_prekey_private_state(dir.path()).unwrap_err(),
            "PREKEY_PRIVATE_STORE_UNSAFE_METADATA"
        );

        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
            .expect("chmod back");
        std::fs::write(&path, [0u8; 8]).expect("truncate");
        assert_eq!(
            load_hybrid_prekey_private_state(dir.path()).unwrap_err(),
            "PREKEY_PRIVATE_STATE_LENGTH"
        );
    }
}

pub fn contact_add_fetch_prekey(
    data_dir: &Path,
    pub_hex: &str,
    prekey_file: Option<&Path>,
) -> Result<(), String> {
    let ed = parse_pub_hex(pub_hex)?;
    let now = now_ms();
    let bundle = if let Some(path) = prekey_file {
        let raw = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
        let j: PrekeyBundleJson = serde_json::from_str(&raw).map_err(|e| e.to_string())?;
        PrekeyBundle::from_json(&j)?
    } else {
        PrekeyStore::load(data_dir)
            .fetch(&ed, now)?
            .ok_or_else(|| "no prekey in local store (pass --prekey-file)".to_string())?
    };
    bundle.verify(now)?;
    if bundle.identity_ed25519_pub != ed {
        return Err("PREKEY_IDENTITY_MISMATCH".into());
    }
    // Cache under contact pub for first-message initiate.
    let cache = data_dir.join(format!(
        "prekey_cache_{}.json",
        &pub_hex[..16.min(pub_hex.len())]
    ));
    let raw = serde_json::to_string_pretty(&bundle.to_json()).map_err(|e| e.to_string())?;
    std::fs::write(&cache, raw).map_err(|e| e.to_string())?;
    println!(
        "{C_GREEN}prekey ready{C_RESET} for first message (fp={})",
        device_fingerprint_v1(&ed)
    );
    Ok(())
}

// ── Mailbox put/get (opaque tags) ─────────────────────────────────────────

pub fn mailbox_db_path(data_dir: &Path) -> PathBuf {
    data_dir.join("mailbox_store.json")
}

pub fn cmd_mailbox_put(
    data_dir: &Path,
    k_route_hex: &str,
    epoch: u64,
    slot: u64,
    envelope_hex: &str,
) {
    let k = match hex::decode(k_route_hex.trim()) {
        Ok(v) if !v.is_empty() => v,
        _ => {
            eprintln!("k_route_hex required");
            std::process::exit(1);
        }
    };
    let packed = match hex::decode(envelope_hex.trim()) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("envelope hex: {e}");
            std::process::exit(1);
        }
    };
    let envelope = match Envelope::unpack(&packed) {
        Some(value) => value,
        None => {
            eprintln!("envelope must be a strict RavenEnvelopeV1 object");
            std::process::exit(1);
        }
    };
    let mtag = mailbox_tag(&k, epoch, slot);
    let store_tag = store_tag_from_mailbox(&mtag);
    let now = now_ms();
    if now < envelope.created_at || now >= envelope.expires_at {
        eprintln!("envelope is not within its validity window");
        std::process::exit(1);
    }
    let obj = StoreObject {
        store_tag,
        message_id: envelope.message_id,
        created_at_ms: now,
        expires_at_ms: envelope.expires_at,
        flags: 0,
        packed_envelope: packed,
        custody_sig: None,
    };
    let mut mb = match StoreMailbox::load_disk(&mailbox_db_path(data_dir), 64) {
        Ok(value) => value,
        Err(error) => {
            eprintln!("mailbox database: {error}");
            std::process::exit(1);
        }
    };
    if let Err(e) = mb.put(obj) {
        eprintln!("put: {e}");
        std::process::exit(1);
    }
    if let Err(error) = mb.save_disk(&mailbox_db_path(data_dir)) {
        eprintln!("mailbox persistence: {error}");
        std::process::exit(1);
    }
    println!("{C_GREEN}stored{C_RESET}");
    println!("{C_DIM}mailbox_tag{C_RESET} {}", hex::encode(mtag));
    println!(
        "{C_DIM}store_tag{C_RESET}   {} (opaque index — no username)",
        hex::encode(store_tag)
    );
}

pub fn cmd_mailbox_get(data_dir: &Path, k_route_hex: &str, epoch: u64, slot: u64) {
    let k = match hex::decode(k_route_hex.trim()) {
        Ok(v) if !v.is_empty() => v,
        _ => {
            eprintln!("k_route_hex required");
            std::process::exit(1);
        }
    };
    let tags = mailbox_tags_with_overlap(&k, epoch, slot);
    let mb = match StoreMailbox::load_disk(&mailbox_db_path(data_dir), 64) {
        Ok(value) => value,
        Err(error) => {
            eprintln!("mailbox database: {error}");
            std::process::exit(1);
        }
    };
    let now = now_ms();
    let mut found = 0usize;
    for mtag in &tags {
        let st = store_tag_from_mailbox(mtag);
        for obj in mb.get(&st, now) {
            found += 1;
            println!(
                "{C_GREEN}hit{C_RESET} store_tag={} msg={}… env_len={}",
                hex::encode(st),
                &hex::encode(obj.message_id)[..8],
                obj.packed_envelope.len()
            );
        }
    }
    if found == 0 {
        println!("{C_DIM}no objects for rotating mailbox tags{C_RESET}");
    } else {
        println!("{C_DIM}retrieved {found} (opaque tags only){C_RESET}");
    }
}
