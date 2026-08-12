//! Extended ash commands: bootstrap, device sync, chat, secure send, mailbox.
//! Kept separate from main.rs to keep the interactive shell readable.

use std::io::{self, Write};
use std::path::{Path, PathBuf};

use raven_core::address::encode_address;
use raven_core::atsam_mlkem::HybridKeypair;
use raven_core::bootstrap::{load_bootstrap, save_bootstrap, BootstrapConfig};
use raven_core::chat_history::{BlockList, ChatHistory, ChatHistoryEntry};
use raven_core::device_cert::{load_device_registry, save_device_registry};
use raven_core::device_sync::{
    import_contact_sync, seal_contact_sync, unseal_contact_sync, ContactSyncPlaintext,
    RevocationRecord, RevocationStore, SyncContact,
};
use raven_core::envelope::{Envelope, EnvType};
use raven_core::fingerprint::device_fingerprint_v1;
use raven_core::identity::Identity;
use raven_core::ipc::{
    decode_response, default_socket_path, encode_request, IpcRequest, IpcResponse, IPC_VERSION,
};
use raven_core::messaging_path::{assert_no_silent_fastapi, resolve_terminal_messaging_path};
use raven_core::prekey_bundle::{PrekeyBundle, PrekeyBundleJson, PrekeyStore};
use raven_core::routing_tag;
use raven_core::sanitize::sanitize_terminal_text;
use raven_core::seal::{derive_pairwise_key, seal_message};
use raven_core::store_object::{
    mailbox_tag, mailbox_tags_with_overlap, store_tag_from_mailbox, StoreMailbox, StoreObject,
};
use rand::RngCore;

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
    println!("{C_DIM}manual_peers{C_RESET}      {}", cfg.manual_peers.len());
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

pub fn cmd_device_sync_export(
    data_dir: &Path,
    id: &Identity,
    device_id: &str,
    out: &Path,
) {
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
        if local.iter().any(|c| c.pub_hex.eq_ignore_ascii_case(&sc.pub_hex)) {
            continue;
        }
        // Pin conflict: refuse overwrite of pinned different key for same tag.
        let tag = if sc.public_tag.is_empty() {
            sc.alias.clone()
        } else {
            sc.public_tag.clone()
        };
        if !tag.is_empty() {
            if local.iter().any(|c| {
                c.pinned
                    && c.public_tag.eq_ignore_ascii_case(&tag)
                    && !c.pub_hex.eq_ignore_ascii_case(&sc.pub_hex)
            }) {
                eprintln!(
                    "{C_PURPLE}skip{C_RESET} @{tag} — pinned local key differs"
                );
                continue;
            }
        }
        local.push(LocalContactRow {
            petname: sc.petname,
            public_tag: tag,
            alias: sc.alias,
            address: sc.address,
            pub_hex: sc.pub_hex,
            pinned: sc.pinned,
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
            println!("{C_GREEN}ok{C_RESET} revoked {}", sanitize_terminal_text(device_id));
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
    eprintln!(
        "{C_PURPLE}REFUSE{C_RESET}: plaintext on argv is forbidden (visible via ps)."
    );
    eprintln!("{C_DIM}use:{C_RESET} ash send --peer … --peer-pub-hex …   # then type message on stdin");
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

/// Seal plaintext locally and enqueue via always-on raven-node IPC when possible.
/// Falls back to raven-node `--send-stdin` (plaintext on pipe, never argv).
pub fn run_send_secure(
    data_dir: &Path,
    id: &Identity,
    peer: &str,
    peer_pub_hex: &str,
    listen: &str,
    text: &str,
    petname: &str,
    tag: &str,
) {
    let path = resolve_terminal_messaging_path();
    if let Err(e) = assert_no_silent_fastapi(path) {
        eprintln!("{e}");
        std::process::exit(1);
    }
    let blocks = BlockList::load(data_dir);
    if blocks.is_blocked(peer_pub_hex) {
        eprintln!("{C_PURPLE}blocked{C_RESET}: peer is on local block list");
        std::process::exit(1);
    }
    let peer_pub = match parse_pub_hex(peer_pub_hex) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    };

    let mut message_id = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut message_id);
    let created = now_ms();
    let my_pub = id.public_key_bytes();
    let my_addr = id.address();
    let peer_addr = encode_address(&peer_pub);
    let key = derive_pairwise_key(&my_pub, &peer_pub);
    let sealed = match seal_message(&key, text.as_bytes(), &my_addr, &peer_addr, &message_id) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("seal failed: {e}");
            std::process::exit(1);
        }
    };
    let k_route = derive_pairwise_key(&my_pub, &peer_pub);
    let dest = routing_tag::derive(&k_route, created / 1000, 0);
    let mut nonce = [0u8; 12];
    rand::thread_rng().fill_bytes(&mut nonce);
    let mut env = Envelope {
        env_type: EnvType::Message as u8,
        flags: 0,
        message_id,
        routing_tag: dest,
        dest_device_hint: 0,
        created_at: created,
        expires_at: created.saturating_add(7 * 24 * 3600 * 1000),
        hop_limit: 8,
        replication_budget: 2,
        anti_replay_nonce: nonce,
        ratchet_header_ciphertext: vec![],
        message_ciphertext: sealed,
        sender_authentication: vec![],
    };
    env.sign_with(id);
    let packed = env.pack();

    // Record sanitized history (local only).
    let mut hist = ChatHistory::load(data_dir);
    hist.append(ChatHistoryEntry {
        message_id_hex: hex::encode(message_id),
        direction: "out".into(),
        peer_petname: petname.to_string(),
        peer_tag: tag.to_string(),
        peer_pub_hex: peer_pub_hex.to_lowercase(),
        created_at_ms: created,
        delivery: "queued".into(),
        preview: text.chars().take(80).collect(),
    });
    let _ = hist.save(data_dir);

    let sock = default_socket_path(data_dir);
    if sock.exists() {
        use base64::Engine;
        let b64 = base64::engine::general_purpose::STANDARD.encode(&packed);
        let req = IpcRequest::EnqueueSealed {
            v: IPC_VERSION,
            envelope_b64: b64,
            peer_hint: Some(peer.to_string()),
        };
        match ipc_request_blocking(&sock, &req) {
            Ok(IpcResponse::Accepted { .. }) => {
                println!(
                    "{C_GREEN}enqueued{C_RESET} via IPC msg={}… peer={}",
                    &hex::encode(message_id)[..8],
                    sanitize_terminal_text(peer)
                );
                return;
            }
            Ok(IpcResponse::Error { code, message, .. }) => {
                eprintln!("ipc enqueue {code}: {message} — falling back to stdin spawn");
            }
            Ok(other) => {
                eprintln!("unexpected ipc: {other:?} — falling back");
            }
            Err(e) => {
                eprintln!("ipc: {e} — falling back to stdin spawn");
            }
        }
    }

    // Fallback: spawn raven-node with --send-stdin (no argv plaintext).
    let exe = std::env::current_exe().ok();
    let node = exe
        .as_ref()
        .and_then(|p| p.parent().map(|d| d.join("raven-node")))
        .unwrap_or_else(|| PathBuf::from("raven-node"));
    use std::process::{Command, Stdio};
    let mut child = Command::new(&node)
        .args([
            "run",
            "--data-dir",
            data_dir.to_str().unwrap_or("."),
            "--listen",
            listen,
            "--peer",
            peer,
            "--peer-pub-hex",
            peer_pub_hex,
            "--send-stdin",
            "--exit-after-ack",
            "--timeout-secs",
            "20",
        ])
        .stdin(Stdio::piped())
        .spawn()
        .unwrap_or_else(|e| {
            eprintln!("failed to spawn {}: {e}", node.display());
            std::process::exit(1);
        });
    if let Some(mut stdin) = child.stdin.take() {
        use std::io::Write;
        let _ = writeln!(stdin, "{text}");
    }
    let status = child.wait().unwrap_or_else(|e| {
        eprintln!("wait: {e}");
        std::process::exit(1);
    });
    if !status.success() {
        std::process::exit(status.code().unwrap_or(1));
    }
}

fn rand_fill(buf: &mut [u8]) {
    rand::thread_rng().fill_bytes(buf);
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
    let hist = ChatHistory::load(data_dir);
    let rows = hist.for_peer(contact_pub);
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
    loop {
        print!("{C_PURPLE}{}>{C_RESET} ", sanitize_terminal_text(contact_petname));
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
                    println!("{C_DIM}petname{C_RESET} {}", sanitize_terminal_text(contact_petname));
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
                        println!(
                            "{C_BOLD}fingerprint{C_RESET} {}",
                            device_fingerprint_v1(&p)
                        );
                        println!("{C_DIM}compare out-of-band / pin via: ash contact verify{C_RESET}");
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
                    let mut h = ChatHistory::load(data_dir);
                    h.clear_peer(contact_pub);
                    let _ = h.save(data_dir);
                    println!("{C_GREEN}cleared{C_RESET} local history for peer");
                }
                other => println!("{C_DIM}unknown command:{C_RESET} {other}"),
            }
            continue;
        }
        run_send_secure(
            data_dir,
            id,
            peer_listen,
            contact_pub,
            "127.0.0.1:0",
            &line,
            contact_petname,
            contact_tag,
        );
    }
}

// ── Real prekey publish ───────────────────────────────────────────────────

pub fn cmd_prekey_publish_real(data_dir: &Path, id: &Identity, device_id: &str, out: Option<&Path>) {
    let mut rng = rand::thread_rng();
    let kp = HybridKeypair::generate(&mut rng);
    // Persist private hybrid material next to identity (0600) for later respond path.
    let secrets_path = data_dir.join("prekey_hybrid.secret");
    {
        let mut blob = Vec::new();
        blob.extend_from_slice(&kp.x25519_secret);
        blob.extend_from_slice(&kp.mlkem_seed);
        #[cfg(unix)]
        {
            use std::io::Write;
            use std::os::unix::fs::OpenOptionsExt;
            if let Ok(mut f) = std::fs::OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .mode(0o600)
                .open(&secrets_path)
            {
                let _ = f.write_all(&blob);
            }
        }
        #[cfg(not(unix))]
        {
            let _ = std::fs::write(&secrets_path, &blob);
        }
    }
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
    let cache = data_dir.join(format!("prekey_cache_{}.json", &pub_hex[..16.min(pub_hex.len())]));
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
    let mtag = mailbox_tag(&k, epoch, slot);
    let store_tag = store_tag_from_mailbox(&mtag);
    let mut mid = [0u8; 16];
    rand_fill(&mut mid);
    let now = now_ms();
    let obj = StoreObject {
        store_tag,
        message_id: mid,
        created_at_ms: now,
        expires_at_ms: now.saturating_add(7 * 24 * 3600 * 1000),
        flags: 0,
        packed_envelope: packed,
        custody_sig: None,
    };
    let mut mb = StoreMailbox::load_disk(&mailbox_db_path(data_dir), 64).unwrap_or_else(|_| {
        StoreMailbox::new(64)
    });
    if let Err(e) = mb.put(obj) {
        eprintln!("put: {e}");
        std::process::exit(1);
    }
    let _ = mb.save_disk(&mailbox_db_path(data_dir));
    println!("{C_GREEN}stored{C_RESET}");
    println!("{C_DIM}mailbox_tag{C_RESET} {}", hex::encode(mtag));
    println!("{C_DIM}store_tag{C_RESET}   {} (opaque index — no username)", hex::encode(store_tag));
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
    let mb = StoreMailbox::load_disk(&mailbox_db_path(data_dir), 64).unwrap_or_else(|_| {
        StoreMailbox::new(64)
    });
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
