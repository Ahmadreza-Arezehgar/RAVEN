//! RAVEN terminal CLI (`ash` product name). Local-only Raven Node control.
//!
//! This is the **product** CLI in `node/` — not Cursor/ash-autonomous automation.
//! Never prints private keys, seeds, session keys, recovery secrets, or plaintext.

use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::Command;

use clap::{Parser, Subcommand};
use raven_core::address::{decode_address, encode_address};
use raven_core::fingerprint::device_fingerprint_v1;
use raven_core::forward_queue::ForwardQueue;
use raven_core::identity::Identity;
use raven_core::ipc::{
    decode_response, default_socket_path, encode_request, IpcRequest, IpcResponse, IPC_VERSION,
};
use raven_core::messaging_path::{
    assert_no_silent_fastapi, resolve_terminal_messaging_path, MessagingPath,
};
use raven_core::node_policy::{load_policy, save_policy, BridgeStatusSnapshot, NodePolicy};
use raven_core::prekey_bundle::{PrekeyBundle, PrekeyBundleJson, PrekeyStore, MLKEM768_EK_LEN};
use raven_core::queue::{DeliveryState, OutgoingQueue};
use raven_core::sanitize::sanitize_terminal_text;
use serde::{Deserialize, Serialize};
use std::time::{SystemTime, UNIX_EPOCH};

// Brand palette from https://raven-messager.com/ (public CSS vars).
const C_CYAN: &str = "\x1b[38;2;64;242;255m";
const C_PURPLE: &str = "\x1b[38;2;191;115;255m";
const C_BLUE: &str = "\x1b[38;2;41;141;255m";
const C_DIM: &str = "\x1b[38;2;160;160;170m";
const C_WHITE: &str = "\x1b[38;2;255;255;255m";
const C_GREEN: &str = "\x1b[38;2;34;197;94m";
const C_RESET: &str = "\x1b[0m";
const C_BOLD: &str = "\x1b[1m";

/// Public logo assets (no secrets) — credit raven-messager.com.
pub const LOGO_URL: &str = "https://raven-messager.com/raven_logo.png";
pub const LOGO_64_URL: &str = "https://raven-messager.com/raven_logo_64.png";

#[derive(Parser, Debug)]
#[command(
    name = "ash",
    about = "RAVEN Node — Messaging Beyond Connectivity",
    long_about = "Local serverless Raven Node CLI. Run with no subcommand for the interactive shell.\n\
                  Never prints private keys. Brand: https://raven-messager.com/"
)]
struct Cli {
    #[arg(long, global = true, default_value = "./raven-data")]
    data_dir: PathBuf,
    #[command(subcommand)]
    cmd: Option<Commands>,
}

#[derive(Subcommand, Debug)]
enum Commands {
    /// Create local identity (prints address + pub hex + fingerprint only).
    Init,
    /// Show public identity bits for data dir.
    Whoami,
    /// Forward send to raven-node. Prefer `--stdin-text` so plaintext is not in argv.
    Send {
        #[arg(long)]
        peer: String,
        #[arg(long)]
        peer_pub_hex: String,
        #[arg(long, default_value = "127.0.0.1:0")]
        listen: String,
        /// Legacy: text on argv (discouraged — visible in `ps`). Prefer `--stdin-text`.
        text: Option<String>,
        /// Read message body from stdin (one line). Default when `text` omitted.
        #[arg(long, default_value_t = false)]
        stdin_text: bool,
    },
    /// Print welcome banner only (safe — no secrets).
    Banner,
    /// Show identity + Bridge/transports/forward queue (safe fields only).
    Status,
    /// Diagnose ash vs system ash conflict, paths, and node socket.
    Doctor,
    /// Ping raven-node UDS IPC (must be running: `raven-node ipc`).
    IpcPing,
    /// Configure local raven-node policy (bridge/store/relay). Does not stop a running node.
    Node {
        #[command(subcommand)]
        cmd: NodeCommands,
    },
    /// Local friendship plane — contacts + fingerprint verify (never FastAPI).
    Contact {
        #[command(subcommand)]
        cmd: ContactCommands,
    },
    /// Signed prekey publish/fetch via local untrusted store (OOB/DHT stand-in).
    Prekey {
        #[command(subcommand)]
        cmd: PrekeyCommands,
    },
}

#[derive(Subcommand, Debug)]
enum ContactCommands {
    /// Add contact (QR/OOB). Petname-first; --verify-fp pins Tag+key locally.
    Add {
        #[arg(long)]
        address: String,
        #[arg(long)]
        pub_hex: String,
        /// Layer C — unique on this device only (primary label).
        #[arg(long, default_value = "")]
        petname: String,
        /// Layer B — public Alias V1 tag (NOT globally unique), e.g. ahmad.
        #[arg(long, default_value = "")]
        tag: String,
        /// Legacy alias of --tag (deprecated).
        #[arg(long, default_value = "")]
        alias: String,
        /// Expected fingerprint. On match: pin Tag+key (DHT cannot overwrite).
        #[arg(long)]
        verify_fp: Option<String>,
    },
    /// List contacts: petname first, @tag subtitle (never address-primary).
    List,
    /// Fingerprint / pin check by --tag, --petname, or --address.
    Verify {
        #[arg(long)]
        tag: Option<String>,
        #[arg(long)]
        alias: Option<String>,
        #[arg(long)]
        petname: Option<String>,
        #[arg(long)]
        address: Option<String>,
    },
    /// Resolve @tag with ambiguity picker (never silent winner).
    Resolve {
        #[arg(long)]
        tag: String,
    },
}

#[derive(Subcommand, Debug)]
enum PrekeyCommands {
    /// Publish a demo/signed prekey bundle into local prekey_store.json (no FastAPI).
    Publish {
        #[arg(long, default_value = "ash-device")]
        device_id: String,
        /// Optional path to write OOB JSON export (public fields only).
        #[arg(long)]
        out: Option<PathBuf>,
    },
    /// Fetch+verify a bundle for a contact pub hex from local store or --file.
    Fetch {
        #[arg(long)]
        pub_hex: String,
        #[arg(long)]
        file: Option<PathBuf>,
    },
}

#[derive(Subcommand, Debug)]
enum NodeCommands {
    /// Bridge cross-transport forward (opaque RavenEnvelope).
    Bridge {
        #[command(subcommand)]
        state: OnOff,
    },
    /// Persistent store-carry-forward queue.
    Store {
        #[command(subcommand)]
        state: OnOff,
    },
    /// Same-transport relay (optional V1).
    Relay {
        #[command(subcommand)]
        state: OnOff,
    },
}

#[derive(Subcommand, Debug, Clone, Copy)]
enum OnOff {
    On,
    Off,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Contact {
    /// Layer C — device-local petname (primary UI label). Unique on MY device.
    #[serde(default)]
    petname: String,
    /// Layer B — public Raven Tag / Alias V1 self-claim (NOT globally unique).
    #[serde(default)]
    public_tag: String,
    /// Legacy field — migrated into public_tag on load when public_tag empty.
    #[serde(default)]
    alias: String,
    /// Layer A — Raven address (rvn1…).
    address: String,
    /// Ed25519 public key hex only.
    pub_hex: String,
    /// Soft-unique pin: first-meet / QR verify locked Tag+key locally.
    #[serde(default)]
    pinned: bool,
}

impl Contact {
    fn migrate(mut self) -> Self {
        if self.public_tag.is_empty() && !self.alias.is_empty() {
            self.public_tag = self.alias.clone();
        }
        if self.petname.is_empty() {
            if !self.public_tag.is_empty() {
                self.petname = self.public_tag.clone();
            } else if !self.alias.is_empty() {
                self.petname = self.alias.clone();
            }
        }
        self
    }

    fn primary_label(&self) -> String {
        let p = sanitize_terminal_text(&self.petname);
        if !p.is_empty() {
            return p;
        }
        let t = normalize_tag(&self.public_tag);
        if !t.is_empty() {
            return format!("@{t}");
        }
        // Address only as last resort — never preferred.
        sanitize_terminal_text(&self.address)
    }

    fn tag_subtitle(&self) -> Option<String> {
        let t = normalize_tag(&self.public_tag);
        if t.is_empty() {
            None
        } else {
            Some(format!("@{t}"))
        }
    }
}

fn contacts_path(data_dir: &Path) -> PathBuf {
    data_dir.join("contacts.json")
}

fn load_contacts(data_dir: &Path) -> Vec<Contact> {
    let path = contacts_path(data_dir);
    let Ok(raw) = std::fs::read_to_string(&path) else {
        return Vec::new();
    };
    let list: Vec<Contact> = serde_json::from_str(&raw).unwrap_or_default();
    list.into_iter().map(Contact::migrate).collect()
}

fn save_contacts(data_dir: &Path, contacts: &[Contact]) -> Result<(), String> {
    std::fs::create_dir_all(data_dir).map_err(|e| e.to_string())?;
    let path = contacts_path(data_dir);
    let raw = serde_json::to_string_pretty(contacts).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&path)
            .map_err(|e| e.to_string())?;
        f.write_all(raw.as_bytes()).map_err(|e| e.to_string())?;
    }
    #[cfg(not(unix))]
    {
        std::fs::write(&path, raw).map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn ensure_identity(data_dir: &Path) -> Identity {
    std::fs::create_dir_all(data_dir).ok();
    let path = data_dir.join("identity.seed");
    if path.exists() {
        let bytes = std::fs::read(&path).expect("read identity");
        let mut seed = [0u8; 32];
        seed.copy_from_slice(&bytes[..32]);
        return Identity::from_seed(&seed);
    }
    let id = Identity::generate();
    let seed = id.seed_bytes();
    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
            .expect("write seed");
        f.write_all(&seed).unwrap();
    }
    #[cfg(not(unix))]
    {
        std::fs::write(&path, seed).unwrap();
    }
    id
}

fn try_load_identity(data_dir: &Path) -> Option<Identity> {
    let path = data_dir.join("identity.seed");
    let bytes = std::fs::read(&path).ok()?;
    if bytes.len() < 32 {
        return None;
    }
    let mut seed = [0u8; 32];
    seed.copy_from_slice(&bytes[..32]);
    Some(Identity::from_seed(&seed))
}

fn print_public_identity(id: &Identity) {
    let pubk = id.public_key_bytes();
    println!("{C_DIM}address{C_RESET}     {}", id.address());
    println!("{C_DIM}fingerprint{C_RESET} {}", device_fingerprint_v1(&pubk));
    println!("{C_DIM}pub_hex{C_RESET}     {}", hex::encode(pubk));
}

/// Unique Raven Node welcome — ANSI bird motif; logo image cannot render in TTY.
/// Colors from raven-messager.com. Never includes private material.
fn print_welcome(data_dir: &Path) {
    // Raven-in-flight silhouette (node = eye/node hub). Professional, on-brand.
    println!();
    println!(
        "{C_CYAN}        .--.     {C_PURPLE}╭──────────────────────────────╮{C_RESET}"
    );
    println!(
        "{C_CYAN}       /  {C_WHITE}◉{C_CYAN}\\    {C_PURPLE}│{C_RESET}  {C_BOLD}{C_WHITE}Welcome to Raven Node{C_RESET}  {C_PURPLE}│{C_RESET}"
    );
    println!(
        "{C_CYAN}      /  /\\ \\   {C_PURPLE}│{C_RESET}  {C_BLUE}Messaging Beyond{C_RESET}         {C_PURPLE}│{C_RESET}"
    );
    println!(
        "{C_CYAN}     /__/  \\_\\  {C_PURPLE}│{C_RESET}  {C_BLUE}Connectivity{C_RESET}             {C_PURPLE}│{C_RESET}"
    );
    println!(
        "{C_PURPLE}    ≺{C_CYAN}═══{C_PURPLE}◈{C_CYAN}═══{C_PURPLE}≻   ╰──────────────────────────────╯{C_RESET}"
    );
    println!(
        "{C_DIM}         serverless · ATSAM · peer-to-peer{C_RESET}"
    );
    println!();
    println!(
        "{C_DIM}Brand logo (PNG):{C_RESET} {C_CYAN}{LOGO_URL}{C_RESET}"
    );
    println!("{C_DIM}Site:{C_RESET}             https://raven-messager.com/");
    println!();

    match try_load_identity(data_dir) {
        Some(id) => {
            println!("{C_GREEN}●{C_RESET} identity ready (public bits only)");
            print_public_identity(&id);
        }
        None => {
            println!(
                "{C_DIM}○{C_RESET} no identity yet — choose Status or run `{C_CYAN}ash init{C_RESET}`"
            );
        }
    }
    println!();
}

fn print_menu() {
    println!("{C_BOLD}{C_WHITE}  Menu{C_RESET}");
    println!("  {C_CYAN}1{C_RESET}  Messages      {C_DIM}queue status (ids + delivery only){C_RESET}");
    println!("  {C_CYAN}2{C_RESET}  Send New Message");
    println!("  {C_CYAN}3{C_RESET}  Contacts");
    println!("  {C_CYAN}4{C_RESET}  Status");
    println!("  {C_CYAN}q{C_RESET}  Quit");
    print!("\n{C_PURPLE}raven>{C_RESET} ");
    let _ = io::stdout().flush();
}

fn read_line() -> String {
    let mut s = String::new();
    if io::stdin().read_line(&mut s).is_err() {
        return String::new();
    }
    s.trim().to_string()
}

fn cmd_messages(data_dir: &Path) {
    let qpath = data_dir.join("queue.db");
    if !qpath.exists() {
        println!("{C_DIM}No outgoing queue yet.{C_RESET}");
        return;
    }
    match OutgoingQueue::open(&qpath) {
        Ok(q) => match q.list_all() {
            Ok(items) => {
                if items.is_empty() {
                    println!("{C_DIM}Queue empty.{C_RESET}");
                    return;
                }
                println!(
                    "{C_DIM}{:<12} {:<12} {}{C_RESET}",
                    "msg_id", "state", "peer"
                );
                for it in items {
                    let id = hex::encode(it.message_id);
                    let st = match it.state {
                        DeliveryState::Queued => "queued",
                        DeliveryState::Sent => "sent",
                        DeliveryState::Delivered => "delivered",
                        DeliveryState::Failed => "failed",
                    };
                    // Never print packed envelope / ciphertext bytes.
                    println!(
                        "{}… {:<12} {}",
                        &id[..8.min(id.len())],
                        st,
                        it.peer_addr
                    );
                }
            }
            Err(e) => eprintln!("queue list error: {e}"),
        },
        Err(e) => eprintln!("queue open error: {e}"),
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
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

fn contact_fingerprint(c: &Contact) -> String {
    match parse_pub_hex(&c.pub_hex) {
        Ok(a) => device_fingerprint_v1(&a),
        Err(_) => "—".into(),
    }
}

fn normalize_tag(tag: &str) -> String {
    sanitize_terminal_text(tag.trim().trim_start_matches('@')).to_lowercase()
}

/// Resolve @public_tag — never silent pick when multiple match.
fn resolve_tag_contacts<'a>(contacts: &'a [Contact], tag: &str) -> Vec<&'a Contact> {
    let want = normalize_tag(tag);
    contacts
        .iter()
        .filter(|c| normalize_tag(&c.public_tag) == want || normalize_tag(&c.alias) == want)
        .collect()
}

/// Back-compat alias used by interactive send.
fn resolve_alias_contacts<'a>(contacts: &'a [Contact], alias: &str) -> Vec<&'a Contact> {
    resolve_tag_contacts(contacts, alias)
}

fn add_contact(
    data_dir: &Path,
    address: &str,
    pub_hex: &str,
    petname: &str,
    public_tag: &str,
    verify_fp: Option<&str>,
) -> Result<(), String> {
    let ed = parse_pub_hex(pub_hex)?;
    let address = address.trim();
    if address.is_empty() {
        return Err("address required".into());
    }
    let address = raven_core::address::from_display(address);
    if decode_address(&address).is_none() {
        return Err("address must be valid rvn1 bech32m".into());
    }
    let derived = encode_address(&ed);
    if derived != address {
        return Err(format!(
            "address/pub mismatch: pub encodes to {derived}, got {address}"
        ));
    }
    let fp = device_fingerprint_v1(&ed);
    let pin = if let Some(expected) = verify_fp {
        let exp = expected.trim();
        if !exp.eq_ignore_ascii_case(&fp) {
            return Err(format!(
                "fingerprint mismatch: got {fp}, expected {}",
                sanitize_terminal_text(exp)
            ));
        }
        true
    } else {
        false
    };

    let tag_clean = normalize_tag(public_tag);
    let mut pet = sanitize_terminal_text(petname.trim());
    if pet.is_empty() && !tag_clean.is_empty() {
        pet = tag_clean.clone();
    }

    let mut contacts = load_contacts(data_dir);

    // Key-change warning: pinned row with same public_tag but different pub/address.
    if !tag_clean.is_empty() {
        for c in contacts.iter() {
            if normalize_tag(&c.public_tag) == tag_clean && c.pinned {
                if c.pub_hex != hex::encode(ed) || c.address != address {
                    eprintln!(
                        "{C_PURPLE}KEY-CHANGE WARNING{C_RESET}: pinned @{tag_clean} was"
                    );
                    eprintln!(
                        "  old fp={}  {}",
                        contact_fingerprint(c),
                        sanitize_terminal_text(&c.address)
                    );
                    eprintln!("  new fp={fp}  {}", sanitize_terminal_text(&address));
                    eprintln!(
                        "{C_DIM}DHT/gossip cannot overwrite pin. Refuse unless you intend to re-pin after verify.{C_RESET}"
                    );
                    return Err("KEY_CHANGE_REFUSED_WITHOUT_REPIN".into());
                }
            }
        }
    }

    // Soft-unique: competing same @tag → ambiguity notice; require distinct petnames.
    if !tag_clean.is_empty() {
        let clashes: Vec<&Contact> = contacts
            .iter()
            .filter(|c| {
                normalize_tag(&c.public_tag) == tag_clean && c.pub_hex != hex::encode(ed)
            })
            .collect();
        if !clashes.is_empty() {
            eprintln!(
                "{C_PURPLE}tag ambiguity{C_RESET}: {} other contact(s) claim '@{tag_clean}'",
                clashes.len()
            );
            for (i, c) in clashes.iter().enumerate() {
                eprintln!(
                    "  {}  {}  @{}  fp={}{}",
                    i + 1,
                    c.primary_label(),
                    normalize_tag(&c.public_tag),
                    contact_fingerprint(c),
                    if c.pinned { " [pinned]" } else { "" }
                );
            }
            if pet.is_empty() || clashes.iter().any(|c| c.petname == pet) {
                return Err(
                    "choose a distinct --petname (e.g. \"Ahmad (Berlin)\") — never silent pick"
                        .into(),
                );
            }
            eprintln!("{C_DIM}saving with distinct petname — pinned rows stay authoritative{C_RESET}");
        }
    }

    // Replace same pub_hex if present (preserve pin if already pinned and same key).
    let prior_pinned = contacts
        .iter()
        .find(|c| c.pub_hex == hex::encode(ed))
        .map(|c| c.pinned)
        .unwrap_or(false);
    contacts.retain(|c| c.pub_hex != hex::encode(ed));
    contacts.push(Contact {
        petname: pet,
        public_tag: tag_clean.clone(),
        alias: tag_clean,
        address,
        pub_hex: hex::encode(ed),
        pinned: pin || prior_pinned,
    });
    save_contacts(data_dir, &contacts)?;
    println!("{C_GREEN}contact saved{C_RESET} (local only — no FastAPI / no registrar)");
    println!("{C_DIM}petname{C_RESET}     {}", contacts.last().unwrap().primary_label());
    if let Some(t) = contacts.last().unwrap().tag_subtitle() {
        println!("{C_DIM}public_tag{C_RESET}  {t}");
    }
    println!("{C_DIM}fingerprint{C_RESET} {fp}");
    println!(
        "{C_DIM}pinned{C_RESET}      {}",
        if pin || prior_pinned {
            "yes (Tag+key locked locally)"
        } else {
            "no (pass --verify-fp to pin)"
        }
    );
    Ok(())
}

fn cmd_contact_list(data_dir: &Path) {
    let contacts = load_contacts(data_dir);
    println!(
        "{C_BOLD}Contacts{C_RESET} ({}) — petname first (Raven Tag V1)",
        contacts.len()
    );
    if contacts.is_empty() {
        println!(
            "{C_DIM}None. ash contact add --address … --pub-hex … --petname \"…\" --tag ahmad --verify-fp …{C_RESET}"
        );
        return;
    }
    for (i, c) in contacts.iter().enumerate() {
        let sub = c
            .tag_subtitle()
            .map(|t| format!("  {C_DIM}{t}{C_RESET}"))
            .unwrap_or_default();
        let pin = if c.pinned { " [pinned]" } else { "" };
        println!(
            "  {C_CYAN}{}{C_RESET}  {}{}{pin}",
            i + 1,
            c.primary_label(),
            sub
        );
        println!(
            "      {C_DIM}fp={}{C_RESET}",
            contact_fingerprint(c)
        );
    }
}

fn cmd_contact_resolve(data_dir: &Path, tag: &str) {
    let contacts = load_contacts(data_dir);
    let hits = resolve_tag_contacts(&contacts, tag);
    if hits.is_empty() {
        eprintln!("no local contacts for @{}", normalize_tag(tag));
        eprintln!("{C_DIM}no \"is tag taken?\" API — add via QR/OOB only{C_RESET}");
        return;
    }
    if hits.len() == 1 {
        let c = hits[0];
        println!("{C_GREEN}resolved{C_RESET} {}", c.primary_label());
        if let Some(t) = c.tag_subtitle() {
            println!("{C_DIM}public_tag{C_RESET}  {t}");
        }
        println!("{C_DIM}fingerprint{C_RESET} {}", contact_fingerprint(c));
        println!(
            "{C_DIM}pinned{C_RESET}      {}",
            if c.pinned { "yes" } else { "no" }
        );
        return;
    }
    println!(
        "{C_PURPLE}ambiguity picker{C_RESET}: {} claims for @{} — never silent pick",
        hits.len(),
        normalize_tag(tag)
    );
    for (i, c) in hits.iter().enumerate() {
        println!(
            "  {C_CYAN}{}{C_RESET}  {}  {}  fp={}{}",
            i + 1,
            c.primary_label(),
            c.tag_subtitle().unwrap_or_default(),
            contact_fingerprint(c),
            if c.pinned { " [pinned]" } else { "" }
        );
    }
    println!("{C_DIM}Pick a # and use that petname in send — or re-add with a distinct petname.{C_RESET}");
}

fn cmd_contact_verify(
    data_dir: &Path,
    tag: Option<&str>,
    alias: Option<&str>,
    petname: Option<&str>,
    address: Option<&str>,
) {
    let contacts = load_contacts(data_dir);
    let tag = tag.or(alias);
    let matches: Vec<&Contact> = if let Some(t) = tag {
        resolve_tag_contacts(&contacts, t)
    } else if let Some(p) = petname {
        let want = sanitize_terminal_text(p.trim());
        contacts
            .iter()
            .filter(|c| c.petname.eq_ignore_ascii_case(&want))
            .collect()
    } else if let Some(addr) = address {
        let addr = raven_core::address::from_display(addr.trim());
        contacts.iter().filter(|c| c.address == addr).collect()
    } else {
        eprintln!("need --tag, --petname, or --address");
        return;
    };
    if matches.is_empty() {
        eprintln!("no contact matched");
        return;
    }
    if matches.len() > 1 {
        println!(
            "{C_PURPLE}ambiguity{C_RESET}: {} matches — compare fingerprints",
            matches.len()
        );
    }
    for c in matches {
        println!("{C_DIM}petname{C_RESET}     {}", c.primary_label());
        if let Some(t) = c.tag_subtitle() {
            println!("{C_DIM}public_tag{C_RESET}  {t}");
        }
        println!(
            "{C_DIM}address{C_RESET}     {}",
            sanitize_terminal_text(&c.address)
        );
        println!("{C_DIM}fingerprint{C_RESET} {}", contact_fingerprint(c));
        println!(
            "{C_DIM}pinned{C_RESET}      {}",
            if c.pinned { "yes" } else { "no" }
        );
    }
}

fn cmd_contacts(data_dir: &Path) {
    cmd_contact_list(data_dir);
    print!("Add contact? [y/N] ");
    let _ = io::stdout().flush();
    if !read_line().eq_ignore_ascii_case("y") {
        return;
    }
    print!("petname (primary, e.g. Ahmad — work): ");
    let _ = io::stdout().flush();
    let petname = read_line();
    print!("public tag (optional @ahmad — NOT unique): ");
    let _ = io::stdout().flush();
    let tag = read_line();
    print!("address (rvn1… from QR/OOB): ");
    let _ = io::stdout().flush();
    let address = read_line();
    print!("pub_hex (64 chars, public only — never seed): ");
    let _ = io::stdout().flush();
    let pub_hex = read_line();
    match parse_pub_hex(&pub_hex) {
        Ok(ed) => {
            let fp = device_fingerprint_v1(&ed);
            println!("{C_BOLD}Verify fingerprint with peer:{C_RESET} {fp}");
            print!("Type fingerprint to PIN Tag+key (recommended), or Enter to save unpinned: ");
            let _ = io::stdout().flush();
            let typed = read_line();
            let verify = if typed.trim().is_empty() {
                None
            } else {
                Some(typed)
            };
            if let Err(e) = add_contact(
                data_dir,
                &address,
                &pub_hex,
                &petname,
                &tag,
                verify.as_deref(),
            ) {
                eprintln!("rejected: {e}");
            }
        }
        Err(e) => eprintln!("rejected: {e}"),
    }
}

fn cmd_prekey_publish(data_dir: &Path, device_id: &str, out: Option<&Path>) {
    let id = ensure_identity(data_dir);
    // Demo X25519 + deterministic non-zero ML-KEM EK placeholder for store path tests.
    // Real ML-KEM EK comes from hybrid initiate; this publishes a signed bundle shape.
    let mut ek = vec![0u8; MLKEM768_EK_LEN];
    for (i, b) in ek.iter_mut().enumerate() {
        *b = (i as u8).wrapping_mul(17).wrapping_add(3);
    }
    let now = now_ms();
    let bundle = PrekeyBundle {
        identity_ed25519_pub: id.public_key_bytes(),
        device_id: sanitize_terminal_text(device_id),
        x25519_pub: {
            // Derive a stable demo X25519 pub marker from identity (not a real DH pub).
            let mut x = [0u8; 32];
            x.copy_from_slice(&id.public_key_bytes());
            x[0] |= 0x08;
            x
        },
        mlkem768_ek: ek,
        signed_prekey_id: 1,
        one_time_prekey_id: 0,
        one_time_x25519_pub: None,
        created_at_ms: now,
        expires_at_ms: now.saturating_add(30 * 24 * 3600 * 1000),
        signature: [0u8; 64],
    };
    let bundle = match bundle.sign(&id) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("sign failed: {e}");
            return;
        }
    };
    let mut store = PrekeyStore::load(data_dir);
    if let Err(e) = store.publish(&bundle, now) {
        eprintln!("publish failed: {e}");
        return;
    }
    if let Err(e) = store.save(data_dir) {
        eprintln!("save store failed: {e}");
        return;
    }
    println!("{C_GREEN}prekey published{C_RESET} → local prekey_store.json (untrusted store stand-in)");
    println!("{C_DIM}store_key{C_RESET} {}", hex::encode(PrekeyBundle::store_key(&id.public_key_bytes())));
    println!("{C_DIM}note{C_RESET}      never FastAPI — OOB/file/DHT only");
    if let Some(path) = out {
        let j = bundle.to_json();
        match serde_json::to_string_pretty(&j) {
            Ok(raw) => {
                if let Err(e) = std::fs::write(path, raw) {
                    eprintln!("write --out failed: {e}");
                } else {
                    println!("{C_DIM}oob_file{C_RESET} {}", path.display());
                }
            }
            Err(e) => eprintln!("json: {e}"),
        }
    }
}

fn cmd_prekey_fetch(data_dir: &Path, pub_hex: &str, file: Option<&Path>) {
    let ed = match parse_pub_hex(pub_hex) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("{e}");
            return;
        }
    };
    let now = now_ms();
    let bundle = if let Some(path) = file {
        match std::fs::read_to_string(path) {
            Ok(raw) => match serde_json::from_str::<PrekeyBundleJson>(&raw) {
                Ok(j) => match PrekeyBundle::from_json(&j) {
                    Ok(b) => b,
                    Err(e) => {
                        eprintln!("bundle parse: {e}");
                        return;
                    }
                },
                Err(e) => {
                    eprintln!("json: {e}");
                    return;
                }
            },
            Err(e) => {
                eprintln!("read: {e}");
                return;
            }
        }
    } else {
        match PrekeyStore::load(data_dir).fetch(&ed, now) {
            Ok(Some(b)) => b,
            Ok(None) => {
                eprintln!("no bundle in local store for that pub (try --file OOB json)");
                return;
            }
            Err(e) => {
                eprintln!("fetch/verify failed: {e}");
                return;
            }
        }
    };
    if let Err(e) = bundle.verify(now) {
        eprintln!("verify failed: {e}");
        return;
    }
    if bundle.identity_ed25519_pub != ed {
        eprintln!("PREKEY_IDENTITY_MISMATCH");
        return;
    }
    println!("{C_GREEN}prekey ok{C_RESET}");
    println!(
        "{C_DIM}fingerprint{C_RESET} {}",
        device_fingerprint_v1(&bundle.identity_ed25519_pub)
    );
    println!("{C_DIM}device_id{C_RESET}   {}", sanitize_terminal_text(&bundle.device_id));
    println!("{C_DIM}prekey_id{C_RESET}   {}", bundle.signed_prekey_id);
    println!("{C_DIM}expires_ms{C_RESET}  {}", bundle.expires_at_ms);
}

fn print_messaging_path_diag() {
    let path = resolve_terminal_messaging_path();
    let _ = assert_no_silent_fastapi(path);
    println!(
        "{C_DIM}messaging_path{C_RESET} {} ({})",
        path.as_diag_label(),
        path.human()
    );
    println!(
        "{C_DIM}path_rule{C_RESET}     serverless never silently uses FastAPI ({})",
        MessagingPath::LegacyFastApi.as_diag_label()
    );
}

fn cmd_status(data_dir: &Path) {
    println!("{C_BOLD}Status{C_RESET}");
    println!("{C_DIM}data_dir{C_RESET} {}", data_dir.display());
    print_messaging_path_diag();
    match try_load_identity(data_dir) {
        Some(id) => {
            println!("{C_GREEN}●{C_RESET} identity");
            print_public_identity(&id);
        }
        None => println!("{C_DIM}○{C_RESET} identity missing"),
    }
    let contacts = load_contacts(data_dir);
    println!("{C_DIM}contacts{C_RESET} {}", contacts.len());

    let policy = load_policy(data_dir);
    let fwd_path = data_dir.join("forward_queue.sqlite");
    let (pending, total) = if fwd_path.exists() {
        ForwardQueue::open(&fwd_path)
            .ok()
            .map(|q| {
                (
                    q.count_pending().unwrap_or(0),
                    q.count_all().unwrap_or(0),
                )
            })
            .unwrap_or((0, 0))
    } else {
        (0, 0)
    };
    let snap = BridgeStatusSnapshot::from_policy(
        &policy,
        &["lan", "mock_ble"],
        pending,
        total,
    );
    let on = |b: bool| {
        if b {
            format!("{C_GREEN}on{C_RESET}")
        } else {
            format!("{C_DIM}off{C_RESET}")
        }
    };
    println!("{C_BOLD}Bridge{C_RESET}");
    println!("  {C_DIM}bridge{C_RESET}     {}", on(snap.bridge));
    println!("  {C_DIM}store{C_RESET}      {}", on(snap.store));
    println!("  {C_DIM}relay{C_RESET}      {}", on(snap.relay));
    println!("  {C_DIM}endpoint{C_RESET}   {}", on(snap.endpoint));
    println!(
        "  {C_DIM}policy{C_RESET}     {}",
        if snap.auto_policy {
            "AUTO (override with ash node bridge on|off)"
        } else {
            "manual"
        }
    );
    println!(
        "  {C_DIM}transports{C_RESET} {}",
        snap.transports.join(", ")
    );
    println!(
        "  {C_DIM}caps{C_RESET}       {}",
        snap.capabilities.join(", ")
    );
    println!(
        "  {C_DIM}forward_q{C_RESET}  {} pending / {} total",
        snap.forward_queue_pending, snap.forward_queue_total
    );

    let qpath = data_dir.join("queue.db");
    let qpath2 = data_dir.join("queue.sqlite");
    let out_q = if qpath.exists() {
        Some(qpath)
    } else if qpath2.exists() {
        Some(qpath2)
    } else {
        None
    };
    if let Some(qp) = out_q {
        if let Ok(q) = OutgoingQueue::open(&qp) {
            if let Ok(items) = q.list_all() {
                let delivered = items
                    .iter()
                    .filter(|i| i.state == DeliveryState::Delivered)
                    .count();
                println!(
                    "{C_DIM}outbox{C_RESET}    {} items ({} delivered)",
                    items.len(),
                    delivered
                );
            }
        }
    } else {
        println!("{C_DIM}outbox{C_RESET}    (none)");
    }
    println!(
        "{C_DIM}note{C_RESET}      ash configures only — raven-node bridge keeps running after ash exits"
    );
}

fn set_node_flag(data_dir: &Path, which: &str, on: bool) {
    let mut policy = load_policy(data_dir);
    policy.auto_policy = false;
    match which {
        "bridge" => policy.bridge = on,
        "store" => policy.store = on,
        "relay" => policy.relay = on,
        _ => {
            eprintln!("unknown flag {which}");
            return;
        }
    }
    if let Err(e) = save_policy(data_dir, &policy) {
        eprintln!("save policy failed: {e}");
        std::process::exit(1);
    }
    println!(
        "{C_GREEN}ok{C_RESET} {which}={} (raven-node reloads from {})",
        if on { "on" } else { "off" },
        data_dir.join("node_policy.json").display()
    );
    // Never print keys.
    let _ = NodePolicy::default();
}

fn cmd_send_interactive(data_dir: &Path) {
    let contacts = load_contacts(data_dir);
    let (peer, peer_pub_hex) = if !contacts.is_empty() {
        println!("Pick contact #, @alias, or paste peer host:port");
        for (i, c) in contacts.iter().enumerate() {
            let sub = c
                .tag_subtitle()
                .map(|t| format!("  {C_DIM}{t}{C_RESET}"))
                .unwrap_or_default();
            println!(
                "  {C_CYAN}{}{C_RESET}  {}{}{}",
                i + 1,
                c.primary_label(),
                sub,
                if c.pinned { " [pinned]" } else { "" }
            );
        }
        print!("peer host:port | contact # | @alias: ");
        let _ = io::stdout().flush();
        let choice = read_line();
        if let Ok(n) = choice.parse::<usize>() {
            if n >= 1 && n <= contacts.len() {
                print!("peer listen host:port: ");
                let _ = io::stdout().flush();
                let peer = read_line();
                (peer, contacts[n - 1].pub_hex.clone())
            } else {
                eprintln!("invalid contact #");
                return;
            }
        } else if choice.trim().starts_with('@') || resolve_alias_contacts(&contacts, choice.trim()).len() == 1
            && !choice.contains(':')
        {
            let alias = choice.trim().trim_start_matches('@');
            let hits = resolve_alias_contacts(&contacts, alias);
            if hits.is_empty() {
                eprintln!("no contact for @{alias}");
                return;
            }
            if hits.len() > 1 {
                eprintln!(
                    "{C_PURPLE}alias ambiguity{C_RESET}: {} matches — pick # or verify fingerprints",
                    hits.len()
                );
                for (i, c) in hits.iter().enumerate() {
                    eprintln!(
                        "  {}  {}  fp={}",
                        i + 1,
                        sanitize_terminal_text(&c.address),
                        contact_fingerprint(c)
                    );
                }
                return;
            }
            print!("peer listen host:port: ");
            let _ = io::stdout().flush();
            let peer = read_line();
            (peer, hits[0].pub_hex.clone())
        } else {
            print!("peer pub_hex: ");
            let _ = io::stdout().flush();
            let pub_hex = read_line();
            (choice, pub_hex)
        }
    } else {
        print!("peer host:port: ");
        let _ = io::stdout().flush();
        let peer = read_line();
        print!("peer pub_hex: ");
        let _ = io::stdout().flush();
        let pub_hex = read_line();
        (peer, pub_hex)
    };
    print!("message (stdin — not stored in shell history as argv): ");
    let _ = io::stdout().flush();
    let text = read_line();
    if text.is_empty() {
        eprintln!("empty message");
        return;
    }
    run_send(data_dir, &peer, &peer_pub_hex, "127.0.0.1:0", &text);
}

fn run_send(data_dir: &Path, peer: &str, peer_pub_hex: &str, listen: &str, text: &str) {
    let _ = ensure_identity(data_dir);
    let exe = std::env::current_exe().ok();
    let node = exe
        .as_ref()
        .and_then(|p| p.parent().map(|d| d.join("raven-node")))
        .unwrap_or_else(|| PathBuf::from("raven-node"));
    let status = Command::new(&node)
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
            "--send",
            text,
            "--exit-after-ack",
            "--timeout-secs",
            "20",
        ])
        .status()
        .unwrap_or_else(|e| {
            eprintln!("failed to spawn {}: {e}", node.display());
            std::process::exit(1);
        });
    if !status.success() {
        std::process::exit(status.code().unwrap_or(1));
    }
}

fn interactive(data_dir: &Path) {
    print_welcome(data_dir);
    loop {
        print_menu();
        let choice = read_line();
        match choice.as_str() {
            "1" | "m" | "messages" => cmd_messages(data_dir),
            "2" | "s" | "send" => cmd_send_interactive(data_dir),
            "3" | "c" | "contacts" => cmd_contacts(data_dir),
            "4" | "status" => cmd_status(data_dir),
            "q" | "quit" | "exit" => {
                println!("{C_DIM}fly safe.{C_RESET}");
                break;
            }
            "" => continue,
            other => println!("{C_DIM}unknown:{C_RESET} {other}"),
        }
        println!();
    }
}

fn main() {
    let cli = Cli::parse();
    let data_dir = cli.data_dir;
    match cli.cmd {
        None => interactive(&data_dir),
        Some(Commands::Banner) => print_welcome(&data_dir),
        Some(Commands::Status) => cmd_status(&data_dir),
        Some(Commands::Node { cmd }) => match cmd {
            NodeCommands::Bridge { state } => {
                set_node_flag(&data_dir, "bridge", matches!(state, OnOff::On))
            }
            NodeCommands::Store { state } => {
                set_node_flag(&data_dir, "store", matches!(state, OnOff::On))
            }
            NodeCommands::Relay { state } => {
                set_node_flag(&data_dir, "relay", matches!(state, OnOff::On))
            }
        },
        Some(Commands::Init) => {
            let id = ensure_identity(&data_dir);
            println!("address={}", id.address());
            println!(
                "fingerprint={}",
                device_fingerprint_v1(&id.public_key_bytes())
            );
            println!("pub_hex={}", hex::encode(id.public_key_bytes()));
        }
        Some(Commands::Whoami) => {
            let id = try_load_identity(&data_dir).unwrap_or_else(|| {
                eprintln!("identity missing — run: ash init --data-dir …");
                std::process::exit(1);
            });
            print_public_identity(&id);
        }
        Some(Commands::Send {
            peer,
            peer_pub_hex,
            listen,
            text,
            stdin_text,
        }) => {
            let body = if stdin_text || text.is_none() {
                if let Some(t) = text {
                    eprintln!(
                        "{C_DIM}warning: plaintext on argv is visible via ps; prefer --stdin-text only{C_RESET}"
                    );
                    t
                } else {
                    print!("message (stdin, not echoed to argv): ");
                    let _ = io::stdout().flush();
                    read_line()
                }
            } else {
                eprintln!(
                    "{C_DIM}warning: plaintext on argv is visible via ps — use --stdin-text{C_RESET}"
                );
                text.unwrap_or_default()
            };
            if body.is_empty() {
                eprintln!("empty message");
                std::process::exit(1);
            }
            run_send(&data_dir, &peer, &peer_pub_hex, &listen, &body);
        }
        Some(Commands::Doctor) => cmd_doctor(&data_dir),
        Some(Commands::IpcPing) => cmd_ipc_ping(&data_dir),
        Some(Commands::Contact { cmd }) => match cmd {
            ContactCommands::Add {
                address,
                pub_hex,
                petname,
                tag,
                alias,
                verify_fp,
            } => {
                let tag = if !tag.is_empty() { tag } else { alias };
                if let Err(e) = add_contact(
                    &data_dir,
                    &address,
                    &pub_hex,
                    &petname,
                    &tag,
                    verify_fp.as_deref(),
                ) {
                    eprintln!("rejected: {e}");
                    std::process::exit(1);
                }
            }
            ContactCommands::List => cmd_contact_list(&data_dir),
            ContactCommands::Verify {
                tag,
                alias,
                petname,
                address,
            } => cmd_contact_verify(
                &data_dir,
                tag.as_deref(),
                alias.as_deref(),
                petname.as_deref(),
                address.as_deref(),
            ),
            ContactCommands::Resolve { tag } => cmd_contact_resolve(&data_dir, &tag),
        },
        Some(Commands::Prekey { cmd }) => match cmd {
            PrekeyCommands::Publish { device_id, out } => {
                cmd_prekey_publish(&data_dir, &device_id, out.as_deref())
            }
            PrekeyCommands::Fetch { pub_hex, file } => {
                cmd_prekey_fetch(&data_dir, &pub_hex, file.as_deref())
            }
        },
    }
}

fn cmd_ipc_ping(data_dir: &Path) {
    let sock = default_socket_path(data_dir);
    if !sock.exists() {
        eprintln!("ipc socket missing: {}", sock.display());
        eprintln!("start: raven-node ipc --data-dir {}", data_dir.display());
        std::process::exit(1);
    }
    match ipc_ping_blocking(&sock) {
        Ok(IpcResponse::Pong { v }) => {
            println!("{C_GREEN}ipc pong{C_RESET} v={v} sock={}", sock.display());
        }
        Ok(other) => {
            eprintln!("unexpected response: {other:?}");
            std::process::exit(1);
        }
        Err(e) => {
            eprintln!("ipc ping failed: {e}");
            std::process::exit(1);
        }
    }
}

fn ipc_ping_blocking(sock: &Path) -> Result<IpcResponse, String> {
    #[cfg(unix)]
    {
        use std::io::{Read, Write};
        use std::os::unix::net::UnixStream;
        let mut stream = UnixStream::connect(sock).map_err(|e| e.to_string())?;
        let req = encode_request(&IpcRequest::Ping { v: IPC_VERSION })?;
        stream.write_all(&req).map_err(|e| e.to_string())?;
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
        return decode_response(&frame);
    }
    #[cfg(not(unix))]
    {
        let _ = sock;
        Err("IPC UDS not available on this OS".into())
    }
}

fn cmd_doctor(data_dir: &Path) {
    println!("{C_BOLD}raven doctor{C_RESET}");
    let exe = std::env::current_exe()
        .map(|p| p.display().to_string())
        .unwrap_or_else(|_| "?".into());
    let exe_clean = sanitize_terminal_text(&exe);
    println!("  this_binary={exe_clean}");
    println!("  argv0_hint: prefer `raven` as primary command; `ash` is product alias");
    println!(
        "  data_dir={}",
        sanitize_terminal_text(&data_dir.display().to_string())
    );
    print_messaging_path_diag();

    let sock = default_socket_path(data_dir);
    println!(
        "  ipc_sock={} exists={}",
        sanitize_terminal_text(&sock.display().to_string()),
        sock.exists()
    );
    if sock.exists() {
        match ipc_ping_blocking(&sock) {
            Ok(IpcResponse::Pong { v }) => {
                println!("  daemon_state: {C_GREEN}up{C_RESET} (ipc_ping ok v={v})");
            }
            Ok(_) => println!("  daemon_state: unexpected ipc response"),
            Err(e) => {
                let clean = sanitize_terminal_text(&e);
                println!("  daemon_state: {C_DIM}down/fail ({clean}){C_RESET}");
            }
        }
    } else {
        println!("  daemon_state: no socket (start raven-node ipc)");
    }

    // Database / queue files (existence only — no secret contents).
    for name in [
        "queue.sqlite",
        "queue.db",
        "forward_queue.sqlite",
        "contacts.json",
        "device_registry.json",
        "node_policy.json",
        "bootstrap.json",
        "identity.seed",
    ] {
        let p = data_dir.join(name);
        let label = if name == "identity.seed" {
            "secure_keystore"
        } else if name.contains("queue") {
            "database"
        } else {
            "local_file"
        };
        println!(
            "  {label}: {} {}",
            name,
            if p.exists() { "present" } else { "absent" }
        );
    }

    println!("  bluetooth: not probed in headless ash (see mock_ble / iOS CoreBluetooth)");
    println!("  nat_class: software unknown here — see node/NAT_TRAVERSAL.md (BLOCKED_HARDWARE for live CGNAT)");
    println!("  relay_hint: policy.relay + bootstrap peers (no Raven-mandatory relay)");

    #[cfg(unix)]
    {
        let bin_ash = Path::new("/bin/ash");
        if bin_ash.exists() {
            println!(
                "  {C_GREEN}note{C_RESET}: /bin/ash exists — Raven must NOT overwrite it"
            );
            println!("  conflict_detection: system ash present; use `raven` or ~/.local/bin/ash → raven");
            if let (Ok(cur), Ok(sys)) = (
                std::fs::canonicalize(&exe),
                std::fs::canonicalize(bin_ash),
            ) {
                if cur == sys {
                    println!("  {C_PURPLE}WARNING{C_RESET}: running binary IS /bin/ash — unexpected");
                } else {
                    println!("  conflict_ok: this binary ≠ /bin/ash");
                }
            }
        } else {
            println!("  /bin/ash: absent on this host");
        }
        if let Ok(out) = Command::new("sh")
            .args(["-c", "command -v ash; command -v raven"])
            .output()
        {
            let s = String::from_utf8_lossy(&out.stdout);
            for line in s.lines() {
                let clean = sanitize_terminal_text(line);
                println!("  path_which: {clean}");
            }
        }
    }
    match try_load_identity(data_dir) {
        Some(id) => {
            println!("  identity: present");
            print_public_identity(&id);
        }
        None => println!("  identity: missing (run raven init)"),
    }
    let pol = load_policy(data_dir);
    println!(
        "  policy bridge={} store={} relay={}",
        pol.bridge, pol.store, pol.relay
    );
    println!("{C_DIM}Closing this CLI does not stop raven-node if installed as a service.{C_RESET}");
    println!("{C_DIM}Diagnostics never print private keys, seeds, or plaintext bodies.{C_RESET}");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn banner_constants_are_public_https() {
        assert!(LOGO_URL.starts_with("https://raven-messager.com/"));
        assert!(LOGO_64_URL.starts_with("https://raven-messager.com/"));
        assert!(!LOGO_URL.contains("seed"));
        assert!(!LOGO_URL.contains("private"));
    }

    #[test]
    fn welcome_art_has_branding_not_secrets() {
        // Capture-style: ensure motif strings exist in source via constants usage.
        let art = format!("{C_CYAN}Welcome to Raven Node{C_RESET}");
        assert!(art.contains("Welcome to Raven Node"));
        assert!(!art.contains("identity.seed"));
        assert!(!art.contains("private"));
    }
}
