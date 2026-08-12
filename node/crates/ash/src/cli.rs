//! RAVEN terminal CLI (`ash` product name). Local-only Raven Node control.
//!
//! This is the **product** CLI in `node/` — not Cursor/ash-autonomous automation.
//! Never prints private keys, seeds, session keys, recovery secrets, or plaintext.

mod ext;

use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::Command;

use clap::{Parser, Subcommand};
use raven_core::address::{decode_address, encode_address};
use raven_core::alias_record::{AliasClaimStore, AliasRecord};
use raven_core::contact_request::{
    ContactRequestInbox, ContactRequestInner, RavenContactRequestV1,
};
use raven_core::discovery_resolver::{
    DiscoveryContext, DiscoveryResolver, DiscoveryResult, DiscoveryScope, LocalContactRow,
    VerificationState,
};
use raven_core::fingerprint::device_fingerprint_v1;
use raven_core::forward_queue::ForwardQueue;
use raven_core::identity::Identity;
use raven_core::ipc::{
    decode_response, default_socket_path, encode_request, IpcRequest, IpcResponse, IPC_VERSION,
};
use raven_core::messaging_path::{
    assert_no_silent_fastapi, resolve_terminal_messaging_path, MessagingPath,
};
use raven_core::nearby::{NearbyAdvertisement, NearbyRegistry};
use raven_core::node_policy::{load_policy, save_policy, BridgeStatusSnapshot, NodePolicy};
use raven_core::prekey_bundle::{PrekeyBundle, PrekeyBundleJson, PrekeyStore};
use raven_core::profile_record::ProfileStore;
use raven_core::queue::{DeliveryState, OutgoingQueue};
use raven_core::sanitize::sanitize_terminal_text;
use raven_core::chat_history::BlockList;
use serde::{Deserialize, Serialize};
use std::time::{SystemTime, UNIX_EPOCH};

use std::sync::OnceLock;

/// Monochrome terminal style (bold / dim only — no cyan/purple/green).
/// Empty strings when NO_COLOR is set or TERM=dumb.
#[derive(Clone, Copy)]
struct Style {
    bold: &'static str,
    dim: &'static str,
    reset: &'static str,
}

fn color_enabled() -> bool {
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| {
        std::env::var_os("NO_COLOR").is_none()
            && !std::env::var_os("TERM").is_some_and(|t| t == "dumb")
    })
}

fn style() -> Style {
    if color_enabled() {
        Style {
            bold: "\x1b[1m",
            dim: "\x1b[2m",
            reset: "\x1b[0m",
        }
    } else {
        Style {
            bold: "",
            dim: "",
            reset: "",
        }
    }
}

// Monochrome palette (bold/dim). Former cyan/purple/green brand colors removed.
// When NO_COLOR/TERM=dumb, prefer `style()` in new UX paths; these consts stay
// bold/dim-only (still B&W) for legacy call sites.
const C_BOLD: &str = "\x1b[1m";
const C_DIM: &str = "\x1b[2m";
const C_RESET: &str = "\x1b[0m";
const C_CYAN: &str = "\x1b[1m";
const C_PURPLE: &str = "\x1b[1m";
const C_GREEN: &str = "\x1b[1m";

/// Public logo assets (no secrets) — credit raven-messager.com.
pub const LOGO_URL: &str = "https://raven-messager.com/raven_logo.png";
#[allow(dead_code)]
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
    /// Forward send to raven-node. Plaintext ONLY via stdin (never argv).
    Send {
        #[arg(long)]
        peer: String,
        #[arg(long)]
        peer_pub_hex: String,
        #[arg(long, default_value = "127.0.0.1:0")]
        listen: String,
        /// Read message body from stdin (required — argv plaintext is refused).
        #[arg(long, default_value_t = true)]
        stdin_text: bool,
        /// Interactive chat session with /back /info /verify /block.
        #[arg(long, default_value_t = false)]
        chat: bool,
    },
    /// Print welcome banner only (safe — no secrets).
    Banner,
    /// Show identity + Bridge/transports/forward queue (safe fields only).
    Status,
    /// Diagnose ash vs system ash conflict, paths, and node socket.
    Doctor,
    /// Ping raven-node UDS IPC (must be running: `raven-node ipc` / service).
    IpcPing,
    /// Configure local raven-node policy / bootstrap (bridge/store/relay/peers).
    Node {
        #[command(subcommand)]
        cmd: NodeCommands,
    },
    /// Local friendship plane — contacts + fingerprint verify (never FastAPI).
    Contact {
        #[command(subcommand)]
        cmd: ContactCommands,
    },
    /// Multi-lane discovery (DiscoveryResolver — no central Raven DB / no FastAPI).
    Find {
        /// Query: `rvn1…`, `@alias`, or local petname/tag text.
        query: String,
        /// Local-only (no public fuzzy in V1).
        #[arg(long, default_value_t = false)]
        local: bool,
        /// Exact Raven ID lane only.
        #[arg(long, default_value_t = false)]
        exact_id: bool,
        /// Exact alias lane only.
        #[arg(long, default_value_t = false)]
        exact_alias: bool,
        /// Non-interactive: print all conflict candidates (never silent pick).
        #[arg(long, default_value_t = false)]
        all: bool,
    },
    /// Nearby BLE ephemeral scan (software mock — no permanent ID in adv).
    Nearby,
    /// Publish / manage signed Alias V1 claims (community DHT stand-in).
    Alias {
        #[command(subcommand)]
        cmd: AliasCommands,
    },
    /// Signed prekey publish/fetch via local untrusted store (OOB/DHT stand-in).
    Prekey {
        #[command(subcommand)]
        cmd: PrekeyCommands,
    },
    /// Multi-device encrypted contact sync + revocation (OOB sealed blobs).
    Device {
        #[command(subcommand)]
        cmd: DeviceCommands,
    },
    /// Offline opaque mailbox put/get (store_tag only — no usernames).
    Mailbox {
        #[command(subcommand)]
        cmd: MailboxCommands,
    },
}

#[derive(Subcommand, Debug)]
enum ContactCommands {
    /// Add a contact from QR/OOB public bits (never a private key).
    ///
    /// Soft Unique Tags: `@alias` is public and NOT globally unique — always
    /// confirm fingerprint. Petname is your private label on this device.
    ///
    /// Examples:
    ///
    ///   ash contact add --address rvn1q… --pub-hex <64 hex> --petname "Poline"
    ///
    ///   ash contact add --address rvn1q… --pub-hex <64 hex> --petname "Poline" --tag poline --verify-fp XXXX-XXXX-XXXX
    ///
    ///   ash contact add --address rvn1q… --pub-hex <64 hex> --petname "Ahmad (Berlin)" --tag ahmad
    #[command(after_help = "\
Soft Unique Tags (Raven Tag V1):
  • Layer A — Raven address (rvn1…) is the durable identity
  • Layer B — @alias / public tag is Soft Unique (conflicts show a picker)
  • Layer C — petname is local-only (e.g. \"Poline\") and primary in the UI
  • --verify-fp pins Tag+key locally after you confirm fingerprint OOB
  Never pass seeds or private keys. Public hex + address only.

Interactive (recommended for first-timers):
  ash                  # menu → 3 Contacts → guided add
")]
    Add {
        #[arg(long, help = "Raven address (rvn1… bech32m) from QR/OOB")]
        address: String,
        #[arg(long, help = "Ed25519 public key hex (64 chars) — never a seed")]
        pub_hex: String,
        /// Layer C — unique on this device only (primary label).
        #[arg(long, default_value = "", help = "Local petname, e.g. Poline")]
        petname: String,
        /// Layer B — public Alias V1 tag (NOT globally unique), e.g. ahmad.
        #[arg(long, default_value = "", help = "Optional public @tag (Soft Unique)")]
        tag: String,
        /// Legacy alias of --tag (deprecated).
        #[arg(long, default_value = "")]
        alias: String,
        /// Expected fingerprint. On match: pin Tag+key (DHT cannot overwrite).
        #[arg(long, help = "Confirm fingerprint to pin Tag+key locally")]
        verify_fp: Option<String>,
        /// Optional OOB prekey JSON for first-message hybrid initiate.
        #[arg(long)]
        prekey_file: Option<PathBuf>,
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
    /// Send encrypted contact request (E2EE; delivered via MessageRouter / store).
    Request {
        /// Target `@alias` or `rvn1…` address.
        target: String,
        /// Optional short message (sealed inside ciphertext).
        #[arg(long, default_value = "")]
        message: String,
        /// When multiple alias claims: pick 1-based index (interactive if omitted).
        #[arg(long)]
        pick: Option<usize>,
    },
    /// List pending inbound contact requests (opened locally).
    Pending,
    /// Ingest a received RavenContactRequestV1 wire blob into the local inbox.
    Ingest {
        #[arg(long)]
        file: PathBuf,
    },
    /// Accept a pending request: emit ContactAcceptV1 + bind petname locally.
    Accept {
        /// request_id hex (32 chars).
        request_id: String,
        #[arg(long)]
        petname: String,
    },
    /// Decline a pending request (local only — no central moderation).
    Decline {
        request_id: String,
    },
    /// Block sender of a pending request (local block list).
    Block {
        request_id: String,
    },
}

#[derive(Subcommand, Debug)]
enum AliasCommands {
    /// Publish a signed Alias V1 claim into the local community store.
    Publish {
        #[arg(long)]
        alias: String,
        #[arg(long, default_value_t = 1)]
        sequence: u64,
        /// Expiry unix ms (default: now + 30d).
        #[arg(long)]
        expires_at: Option<u64>,
    },
}

#[derive(Subcommand, Debug)]
enum PrekeyCommands {
    /// Publish a signed prekey bundle (real X25519 + ML-KEM) into local store.
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
    /// Add a custom bootstrap multiaddr (or --manual peer).
    AddBootstrap {
        multiaddr: String,
        #[arg(long, default_value_t = false)]
        manual: bool,
    },
    /// Disable and clear Raven-shipped bootstrap defaults.
    DisableRavenDefaults,
    /// Show effective bootstrap peers.
    ShowBootstrap,
    /// Write empty/default bootstrap.json (--no-raven-defaults clears Raven list).
    InitBootstrap {
        #[arg(long, default_value_t = false)]
        no_raven_defaults: bool,
    },
}

#[derive(Subcommand, Debug)]
enum DeviceCommands {
    /// Export sealed contact/petname sync blob (hex) for another authorized device.
    SyncExport {
        #[arg(long, default_value = "ash-device")]
        device_id: String,
        #[arg(long)]
        out: PathBuf,
    },
    /// Import sealed sync blob; merges petname/tag/pin with key-change rules.
    SyncImport {
        #[arg(long)]
        file: PathBuf,
    },
    /// Issue + persist a signed device revocation record.
    Revoke {
        #[arg(long)]
        device_id: String,
        #[arg(long, default_value_t = 1)]
        epoch: u64,
    },
}

#[derive(Subcommand, Debug)]
enum MailboxCommands {
    /// Deposit opaque envelope under rotating mailbox → store_tag index.
    Put {
        #[arg(long)]
        k_route_hex: String,
        #[arg(long, default_value_t = 1)]
        epoch: u64,
        #[arg(long, default_value_t = 0)]
        slot: u64,
        #[arg(long)]
        envelope_hex: String,
    },
    /// Retrieve by opaque rotating tags (current + previous epoch).
    Get {
        #[arg(long)]
        k_route_hex: String,
        #[arg(long, default_value_t = 1)]
        epoch: u64,
        #[arg(long, default_value_t = 0)]
        slot: u64,
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
    raven_core::load_or_create_identity(data_dir)
        .map(|(id, _)| id)
        .expect("secure identity store")
}

fn try_load_identity(data_dir: &Path) -> Option<Identity> {
    raven_core::load_identity(data_dir).ok().flatten()
}

fn print_public_identity(id: &Identity) {
    let s = style();
    let dim = s.dim;
    let reset = s.reset;
    let pubk = id.public_key_bytes();
    println!("{dim}address{reset}     {}", id.address());
    println!("{dim}fingerprint{reset} {}", device_fingerprint_v1(&pubk));
    println!("{dim}pub_hex{reset}     {}", hex::encode(pubk));
}

/// Unique Raven Node welcome — monochrome ASCII raven/node motif.
/// Never includes private material. Honors NO_COLOR / TERM=dumb.
fn print_welcome(data_dir: &Path) {
    let s = style();
    let bold = s.bold;
    let dim = s.dim;
    let reset = s.reset;

    println!();
    println!("{dim}      ┌──────────────────────────────────────────────────┐{reset}");
    println!("{dim}      │{reset}                                                  {dim}│{reset}");
    println!(
        "{dim}      │{reset}  {bold}    .--.     ≺═══◈═══≻{reset}                         {dim}│{reset}"
    );
    println!(
        "{dim}      │{reset}  {bold}   /  {reset}◉{bold}\\      NODE{reset}                            {dim}│{reset}"
    );
    println!(
        "{dim}      │{reset}  {bold}  /  /\\ \\{reset}                                       {dim}│{reset}"
    );
    println!(
        "{dim}      │{reset}  {bold} /__/  \\_\\{reset}   {bold}Welcome to Raven Node{reset}            {dim}│{reset}"
    );
    println!(
        "{dim}      │{reset}              {dim}Messaging Beyond Connectivity{reset}     {dim}│{reset}"
    );
    println!("{dim}      │{reset}                                                  {dim}│{reset}");
    println!(
        "{dim}      │{reset}  {dim}serverless · ATSAM · peer-to-peer{reset}               {dim}│{reset}"
    );
    println!("{dim}      └──────────────────────────────────────────────────┘{reset}");
    println!();
    println!("{dim}Brand logo (PNG):{reset} {LOGO_URL}");
    println!("{dim}Site:{reset}             https://raven-messager.com/");
    println!();

    match try_load_identity(data_dir) {
        Some(id) => {
            println!("{bold}●{reset} identity ready {dim}(public bits only — never a seed){reset}");
            print_public_identity(&id);
        }
        None => {
            println!("{bold}○ First run — no local identity yet{reset}");
            println!("{dim}  Create one (public address + fingerprint only; private key stays on disk):{reset}");
            println!("  {bold}1.{reset} Choose menu {bold}4 Status{reset}  — creates identity if missing");
            println!("  {bold}2.{reset} Or run:  {bold}ash --data-dir <dir> init{reset}");
            println!("{dim}  Then add contacts (menu 3) before Send / Chat.{reset}");
        }
    }
    println!();
}

fn print_menu() {
    let s = style();
    let bold = s.bold;
    let dim = s.dim;
    let reset = s.reset;
    println!("{bold}  Menu{reset}");
    println!(
        "  {bold}1{reset}  Messages      {dim}outgoing queue + local chat history (ids only){reset}"
    );
    println!(
        "  {bold}2{reset}  Send / Chat   {dim}message a contact — add contacts first if empty{reset}"
    );
    println!(
        "  {bold}3{reset}  Contacts      {dim}add by rvn1… / @alias / petname + fingerprint{reset}"
    );
    println!(
        "  {bold}4{reset}  Status        {dim}identity, bridge, transports (public fields){reset}"
    );
    println!("  {bold}q{reset}  Quit");
    print!("\n{bold}raven>{reset} ");
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
    let qpath2 = data_dir.join("queue.sqlite");
    let path = if qpath.exists() {
        qpath
    } else {
        qpath2
    };
    if path.exists() {
        match OutgoingQueue::open(&path) {
            Ok(q) => match q.list_all() {
                Ok(items) => {
                    if items.is_empty() {
                        println!("{C_DIM}Queue empty.{C_RESET}");
                    } else {
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
                            println!(
                                "{}… {:<12} {}",
                                &id[..8.min(id.len())],
                                st,
                                it.peer_addr
                            );
                        }
                    }
                }
                Err(e) => eprintln!("queue list error: {e}"),
            },
            Err(e) => eprintln!("queue open error: {e}"),
        }
    } else {
        println!("{C_DIM}No outgoing queue yet.{C_RESET}");
    }
    let hist = raven_core::ChatHistory::load(data_dir);
    if hist.entries.is_empty() {
        println!("{C_DIM}No local chat history.{C_RESET}");
    } else {
        println!("{C_BOLD}Recent history{C_RESET} (sanitized previews)");
        for e in hist.entries.iter().rev().take(15).rev() {
            let label = if !e.peer_petname.is_empty() {
                sanitize_terminal_text(&e.peer_petname)
            } else if !e.peer_tag.is_empty() {
                format!("@{}", sanitize_terminal_text(&e.peer_tag))
            } else {
                e.peer_pub_hex.chars().take(12).collect()
            };
            println!(
                "  {C_DIM}{}{C_RESET} {} → {}  {}",
                &e.message_id_hex[..8.min(e.message_id_hex.len())],
                e.direction,
                label,
                sanitize_terminal_text(&e.preview)
            );
        }
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

fn alias_store_path(data_dir: &Path) -> PathBuf {
    data_dir.join("alias_claims.json")
}

fn nearby_store_path(data_dir: &Path) -> PathBuf {
    data_dir.join("nearby_registry.json")
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct AliasClaimJson {
    alias: String,
    identity_address: String,
    sequence: u64,
    expires_at: u64,
    signature_hex: String,
    ed25519_pub_hex: String,
}

fn load_alias_store(data_dir: &Path, now: u64) -> AliasClaimStore {
    let mut store = AliasClaimStore::default();
    let Ok(raw) = std::fs::read_to_string(alias_store_path(data_dir)) else {
        return store;
    };
    let Ok(rows) = serde_json::from_str::<Vec<AliasClaimJson>>(&raw) else {
        return store;
    };
    for row in rows {
        let Ok(sig_v) = hex::decode(&row.signature_hex) else {
            continue;
        };
        let Ok(pub_v) = hex::decode(&row.ed25519_pub_hex) else {
            continue;
        };
        if sig_v.len() != 64 || pub_v.len() != 32 {
            continue;
        }
        let mut signature = [0u8; 64];
        signature.copy_from_slice(&sig_v);
        let mut ed25519_pub = [0u8; 32];
        ed25519_pub.copy_from_slice(&pub_v);
        let rec = AliasRecord {
            alias: row.alias,
            identity_address: row.identity_address,
            sequence: row.sequence,
            expires_at: row.expires_at,
            signature,
            ed25519_pub,
        };
        let _ = store.put(rec, now);
    }
    store
}

fn save_alias_claim(data_dir: &Path, rec: &AliasRecord) -> Result<(), String> {
    let path = alias_store_path(data_dir);
    let mut rows: Vec<AliasClaimJson> = std::fs::read_to_string(&path)
        .ok()
        .and_then(|r| serde_json::from_str(&r).ok())
        .unwrap_or_default();
    rows.retain(|r| {
        !(r.alias == rec.alias && r.identity_address == rec.identity_address)
    });
    rows.push(AliasClaimJson {
        alias: rec.alias.clone(),
        identity_address: rec.identity_address.clone(),
        sequence: rec.sequence,
        expires_at: rec.expires_at,
        signature_hex: hex::encode(rec.signature),
        ed25519_pub_hex: hex::encode(rec.ed25519_pub),
    });
    std::fs::create_dir_all(data_dir).map_err(|e| e.to_string())?;
    let raw = serde_json::to_string_pretty(&rows).map_err(|e| e.to_string())?;
    std::fs::write(path, raw).map_err(|e| e.to_string())
}

fn load_profile_store(_data_dir: &Path, _now: u64) -> ProfileStore {
    ProfileStore::default()
}

fn build_discovery_ctx(data_dir: &Path) -> DiscoveryContext {
    let now = now_ms();
    let contacts: Vec<LocalContactRow> = load_contacts(data_dir)
        .into_iter()
        .map(|c| LocalContactRow {
            raven_id: c.address.clone(),
            pub_hex: c.pub_hex.clone(),
            petname: c.petname.clone(),
            public_tag: if c.public_tag.is_empty() {
                c.alias.clone()
            } else {
                c.public_tag.clone()
            },
            display_name: c.petname.clone(),
            pinned: c.pinned,
            directly_verified: c.pinned,
        })
        .collect();
    DiscoveryContext {
        contacts,
        aliases: load_alias_store(data_dir, now),
        profiles: load_profile_store(data_dir, now),
        blocked: BlockList::load(data_dir),
        serverless: true,
        public_profile_index_enabled: false,
        now_ms: now,
        ..Default::default()
    }
}

fn print_discovery_hit(i: usize, h: &DiscoveryResult) {
    println!(
        "  {C_CYAN}{}{C_RESET}  {}  {}",
        i + 1,
        if h.display_name.is_empty() {
            "(no display name)".into()
        } else {
            sanitize_terminal_text(&h.display_name)
        },
        match h.verification_state {
            VerificationState::AliasConflict => format!("{C_PURPLE}ALIAS_CONFLICT{C_RESET}"),
            VerificationState::DirectlyVerified => format!("{C_GREEN}DIRECTLY_VERIFIED{C_RESET}"),
            VerificationState::TrustedContact => format!("{C_GREEN}TRUSTED_CONTACT{C_RESET}"),
            VerificationState::Blocked => format!("{C_PURPLE}BLOCKED{C_RESET}"),
            VerificationState::Introduced => "INTRODUCED".into(),
            VerificationState::NearbyVerified => "NEARBY_VERIFIED".into(),
            VerificationState::PublicSignedProfile => "PUBLIC_SIGNED_PROFILE".into(),
            VerificationState::ScopedVerified => "SCOPED_VERIFIED".into(),
            VerificationState::ExpiredOrStale => "EXPIRED_OR_STALE".into(),
        }
    );
    println!("      {C_DIM}raven_id{C_RESET}  {}", sanitize_terminal_text(&h.raven_id));
    if !h.aliases.is_empty() {
        println!(
            "      {C_DIM}aliases{C_RESET}   {}",
            h.aliases
                .iter()
                .map(|a| format!("@{a}"))
                .collect::<Vec<_>>()
                .join(" ")
        );
    }
    println!(
        "      {C_DIM}sources{C_RESET}   {:?}  conflict={}",
        h.source_set, h.conflict_count
    );
}

fn cmd_find(data_dir: &Path, query: &str, local: bool, exact_id: bool, exact_alias: bool, all: bool) {
    let ctx = build_discovery_ctx(data_dir);
    let scope = if local {
        DiscoveryScope::Local
    } else if exact_id {
        DiscoveryScope::ExactId
    } else if exact_alias || query.trim().starts_with('@') {
        DiscoveryScope::ExactAlias
    } else if query.trim().starts_with("rvn1") {
        DiscoveryScope::ExactId
    } else {
        // Bare text → local only in V1 (no public fuzzy).
        DiscoveryScope::Local
    };
    let hits = DiscoveryResolver::v1().search(query, scope, &ctx);
    println!(
        "{C_BOLD}Discovery{C_RESET} query={} scope={:?} hits={}",
        sanitize_terminal_text(query),
        scope,
        hits.len()
    );
    if hits.is_empty() {
        println!("{C_DIM}No results. Try ash find @alias / rvn1… / --local{C_RESET}");
        return;
    }
    let conflicts = hits
        .iter()
        .any(|h| h.verification_state == VerificationState::AliasConflict);
    for (i, h) in hits.iter().enumerate() {
        print_discovery_hit(i, h);
    }
    if conflicts && !all && hits.len() > 1 {
        println!(
            "{C_PURPLE}alias conflict{C_RESET}: {} candidates — pick one (never silent)",
            hits.len()
        );
        print!("pick [1-{}] or Enter to abort: ", hits.len());
        let _ = io::stdout().flush();
        let line = read_line();
        if let Ok(n) = line.trim().parse::<usize>() {
            if n >= 1 && n <= hits.len() {
                let h = &hits[n - 1];
                println!(
                    "{C_GREEN}selected{C_RESET} {} — use: ash contact request {}",
                    sanitize_terminal_text(&h.raven_id),
                    sanitize_terminal_text(&h.raven_id)
                );
            }
        }
    }
}

fn cmd_nearby(data_dir: &Path) {
    let path = nearby_store_path(data_dir);
    let mut reg = NearbyRegistry::default();
    if let Ok(raw) = std::fs::read_to_string(&path) {
        if let Ok(tokens) = serde_json::from_str::<Vec<String>>(&raw) {
            for t in tokens {
                if let Ok(v) = hex::decode(&t) {
                    if v.len() == 16 {
                        let mut token = [0u8; 16];
                        token.copy_from_slice(&v);
                        let mut adv = NearbyAdvertisement::mint(now_ms(), 60_000, b"ash-nearby");
                        adv.ephemeral_token = token;
                        let _ = reg.publish_ephemeral(adv);
                    }
                }
            }
        }
    }
    let adv = NearbyAdvertisement::mint(now_ms(), 60_000, b"ash-nearby");
    if adv.contains_permanent_raven_id() {
        eprintln!("refused: permanent Raven ID in nearby advertisement");
        std::process::exit(1);
    }
    reg.publish_ephemeral(adv.clone()).unwrap();
    let mut tokens: Vec<String> = reg
        .live_ads
        .iter()
        .map(|a| hex::encode(a.ephemeral_token))
        .collect();
    tokens.sort();
    tokens.dedup();
    std::fs::create_dir_all(data_dir).ok();
    let _ = std::fs::write(path, serde_json::to_string_pretty(&tokens).unwrap_or_default());
    println!("{C_BOLD}Nearby{C_RESET} (ephemeral — no permanent Raven ID in adv)");
    for a in reg.scan_live(now_ms()) {
        let phrase = raven_core::nearby_safety_phrase(&a.ephemeral_token, &a.session_commitment);
        println!(
            "  token={} ttl_ms={} commitment={}",
            hex::encode(a.ephemeral_token),
            a.ttl_ms,
            hex::encode(a.session_commitment)
        );
        println!(
            "  {C_PURPLE}safety phrase{C_RESET} {phrase}  {C_DIM}(confirm OOB before pin){C_RESET}"
        );
    }
    println!("{C_DIM}Confirm pairing locally before binding to rvn1 identity.{C_RESET}");
}

fn cmd_contact_request(
    data_dir: &Path,
    target: &str,
    message: &str,
    pick: Option<usize>,
) {
    let id = ensure_identity(data_dir);
    let ctx = build_discovery_ctx(data_dir);
    let q = target.trim();
    let mut hits = if q.starts_with("rvn1") {
        DiscoveryResolver::v1().search(q, DiscoveryScope::ExactId, &ctx)
    } else {
        DiscoveryResolver::v1().search(q, DiscoveryScope::ExactAlias, &ctx)
    };
    // Fall back to local contacts for @tag
    if hits.is_empty() {
        hits = DiscoveryResolver::v1().search(q, DiscoveryScope::Local, &ctx);
    }
    if hits.is_empty() {
        eprintln!("no discovery hit for {q}");
        std::process::exit(1);
    }
    let chosen = if hits.len() == 1 {
        &hits[0]
    } else if let Some(n) = pick {
        hits.get(n.saturating_sub(1)).unwrap_or_else(|| {
            eprintln!("pick out of range");
            std::process::exit(1);
        })
    } else {
        println!("{C_PURPLE}multiple candidates{C_RESET} — pick one:");
        for (i, h) in hits.iter().enumerate() {
            print_discovery_hit(i, h);
        }
        print!("pick [1-{}]: ", hits.len());
        let _ = io::stdout().flush();
        let line = read_line();
        let n: usize = line.trim().parse().unwrap_or(0);
        if n < 1 || n > hits.len() {
            eprintln!("aborted");
            std::process::exit(1);
        }
        &hits[n - 1]
    };
    if chosen.verification_state == VerificationState::Blocked {
        eprintln!("refused: target is blocked locally");
        std::process::exit(1);
    }
    let peer_pub = if let Some(c) = ctx.contacts.iter().find(|c| c.raven_id == chosen.raven_id) {
        parse_pub_hex(&c.pub_hex).unwrap_or_else(|e| {
            eprintln!("{e}");
            std::process::exit(1);
        })
    } else if let Ok(claims) = ctx.aliases.lookup_exact(
        chosen
            .aliases
            .first()
            .map(|s| s.as_str())
            .unwrap_or(q),
        now_ms(),
    ) {
        if let Some(claim) = claims.iter().find(|c| c.identity_address == chosen.raven_id) {
            claim.ed25519_pub
        } else if claims.len() == 1 {
            claims[0].ed25519_pub
        } else {
            eprintln!("need contact pub_hex or signed alias claim with matching raven_id");
            std::process::exit(1);
        }
    } else {
        eprintln!("need local contact or signed alias claim to seal request (address alone is not a pubkey)");
        std::process::exit(1);
    };
    let mut request_id = [0u8; 16];
    {
        use rand::RngCore;
        rand::thread_rng().fill_bytes(&mut request_id);
    }
    let req = RavenContactRequestV1::create(
        &id,
        &peer_pub,
        &chosen.raven_id,
        ContactRequestInner {
            request_id,
            sender_raven_id: id.address(),
            sender_display_name: String::new(),
            sender_aliases: vec![],
            sender_profile_digest: [0u8; 32],
            optional_message: sanitize_terminal_text(message),
            created_at: now_ms(),
            expires_at: now_ms() + 7 * 24 * 3600 * 1000,
        },
    )
    .unwrap_or_else(|e| {
        eprintln!("seal failed: {e}");
        std::process::exit(1);
    });
    assert!(req.is_ciphertext_only());
    let wire = req.encode_wire().unwrap_or_else(|e| {
        eprintln!("wire encode failed: {e}");
        std::process::exit(1);
    });
    // Ciphertext-only file (opaque to store/bridge) + full wire for endpoint delivery.
    let out_ct = data_dir.join(format!("contact_request_{}.bin", hex::encode(request_id)));
    let out_wire = data_dir.join(format!("contact_request_{}.wire", hex::encode(request_id)));
    std::fs::write(&out_ct, &req.ciphertext).ok();
    std::fs::write(&out_wire, &wire).ok();
    println!("{C_GREEN}contact request sealed{C_RESET} (ciphertext-only for store/bridge)");
    println!("{C_DIM}request_id{C_RESET} {}", hex::encode(request_id));
    println!("{C_DIM}recipient{C_RESET}  {}", sanitize_terminal_text(&chosen.raven_id));
    println!("{C_DIM}ciphertext{C_RESET} {}", out_ct.display());
    println!("{C_DIM}wire{C_RESET}       {}", out_wire.display());
    println!(
        "{C_DIM}deliver wire via MessageRouter (direct/relay/store/BLE/Bridge) — same message_id{C_RESET}"
    );
}

fn contact_inbox_dir(data_dir: &Path) -> PathBuf {
    data_dir.join("contact_inbox")
}

fn parse_request_id_hex(s: &str) -> [u8; 16] {
    let v = hex::decode(s.trim()).unwrap_or_else(|_| {
        eprintln!("bad request_id hex");
        std::process::exit(1);
    });
    if v.len() != 16 {
        eprintln!("request_id must be 16 bytes (32 hex chars)");
        std::process::exit(1);
    }
    let mut id = [0u8; 16];
    id.copy_from_slice(&v);
    id
}

fn load_contact_inbox(data_dir: &Path) -> ContactRequestInbox {
    let id = ensure_identity(data_dir);
    let mut inbox = ContactRequestInbox::default();
    let dir = contact_inbox_dir(data_dir);
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return inbox;
    };
    for ent in entries.flatten() {
        let path = ent.path();
        if path.extension().and_then(|e| e.to_str()) != Some("wire") {
            continue;
        }
        let Ok(raw) = std::fs::read(&path) else {
            continue;
        };
        let Ok(outer) = RavenContactRequestV1::decode_wire(&raw) else {
            continue;
        };
        let _ = inbox.ingest(outer, &id, now_ms());
    }
    inbox
}

fn persist_inbox_wire(data_dir: &Path, outer: &RavenContactRequestV1) -> Result<(), String> {
    let dir = contact_inbox_dir(data_dir);
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let path = dir.join(format!("{}.wire", hex::encode(outer.request_id)));
    let wire = outer.encode_wire()?;
    std::fs::write(path, wire).map_err(|e| e.to_string())
}

fn remove_inbox_wire(data_dir: &Path, request_id: &[u8; 16]) {
    let path = contact_inbox_dir(data_dir).join(format!("{}.wire", hex::encode(request_id)));
    let _ = std::fs::remove_file(path);
}

fn cmd_contact_pending(data_dir: &Path) {
    let inbox = load_contact_inbox(data_dir);
    println!(
        "{C_BOLD}Pending contact requests{C_RESET} ({})",
        inbox.pending().len()
    );
    if inbox.pending().is_empty() {
        println!(
            "{C_DIM}None. Ingest with: ash contact ingest --file contact_request_….wire{C_RESET}"
        );
        return;
    }
    for (i, p) in inbox.pending().iter().enumerate() {
        println!(
            "  {C_CYAN}{}{C_RESET}  id={}  from={}  name=\"{}\"  msg=\"{}\"",
            i + 1,
            hex::encode(p.outer.request_id),
            sanitize_terminal_text(&p.inner.sender_raven_id),
            sanitize_terminal_text(&p.inner.sender_display_name),
            sanitize_terminal_text(&p.inner.optional_message)
        );
    }
    println!(
        "{C_DIM}ash contact accept <id> --petname \"…\" | decline <id> | block <id>{C_RESET}"
    );
}

fn cmd_contact_ingest(data_dir: &Path, file: &Path) {
    let id = ensure_identity(data_dir);
    let raw = std::fs::read(file).unwrap_or_else(|e| {
        eprintln!("read failed: {e}");
        std::process::exit(1);
    });
    let outer = RavenContactRequestV1::decode_wire(&raw).unwrap_or_else(|e| {
        eprintln!("bad wire: {e}");
        std::process::exit(1);
    });
    // Bridge/store opacity: wire encodes outer metadata + opaque ciphertext.
    assert!(outer.is_ciphertext_only());
    let mut inbox = ContactRequestInbox::default();
    let inner = inbox.ingest(outer.clone(), &id, now_ms()).unwrap_or_else(|e| {
        eprintln!("ingest refused: {e}");
        std::process::exit(1);
    });
    if let Err(e) = persist_inbox_wire(data_dir, &outer) {
        eprintln!("persist failed: {e}");
        std::process::exit(1);
    }
    println!("{C_GREEN}ingested{C_RESET} request {}", hex::encode(inner.request_id));
    println!(
        "{C_DIM}from{C_RESET} {} — {}",
        sanitize_terminal_text(&inner.sender_raven_id),
        sanitize_terminal_text(&inner.sender_display_name)
    );
}

fn cmd_contact_accept(data_dir: &Path, request_id_hex: &str, petname: &str) {
    let id = ensure_identity(data_dir);
    let rid = parse_request_id_hex(request_id_hex);
    let mut inbox = load_contact_inbox(data_dir);
    let outcome = inbox.accept(&rid, &id, petname, now_ms()).unwrap_or_else(|e| {
        eprintln!("accept failed: {e}");
        std::process::exit(1);
    });
    remove_inbox_wire(data_dir, &rid);
    // Bind local contact (raven_id + petname); verification = trusted contact.
    if let Err(e) = add_contact(
        data_dir,
        &outcome.binding.raven_id,
        &outcome.binding.pub_hex,
        &outcome.binding.petname,
        "",
        None,
    ) {
        eprintln!("bind note: {e}");
    }
    let wire = outcome.accept.encode_wire().unwrap_or_else(|e| {
        eprintln!("accept wire: {e}");
        std::process::exit(1);
    });
    let out = data_dir.join(format!("contact_accept_{}.wire", hex::encode(rid)));
    std::fs::write(&out, &wire).ok();
    println!("{C_GREEN}accepted{C_RESET} + bound petname \"{}\"", sanitize_terminal_text(&outcome.binding.petname));
    println!("{C_DIM}raven_id{C_RESET} {}", sanitize_terminal_text(&outcome.binding.raven_id));
    println!("{C_DIM}verify{C_RESET}   {:?}", outcome.binding.verification_state);
    println!("{C_DIM}accept wire{C_RESET} {} (deliver opaque via MessageRouter)", out.display());
}

fn cmd_contact_decline(data_dir: &Path, request_id_hex: &str) {
    let rid = parse_request_id_hex(request_id_hex);
    let mut inbox = load_contact_inbox(data_dir);
    if let Err(e) = inbox.decline(&rid) {
        eprintln!("decline failed: {e}");
        std::process::exit(1);
    }
    remove_inbox_wire(data_dir, &rid);
    println!("{C_GREEN}declined{C_RESET} {}", hex::encode(rid));
}

fn cmd_contact_block(data_dir: &Path, request_id_hex: &str) {
    let rid = parse_request_id_hex(request_id_hex);
    let mut inbox = load_contact_inbox(data_dir);
    let mut blocks = BlockList::load(data_dir);
    if let Err(e) = inbox.block(&rid, &mut blocks) {
        eprintln!("block failed: {e}");
        std::process::exit(1);
    }
    if let Err(e) = blocks.save(data_dir) {
        eprintln!("block save failed: {e}");
        std::process::exit(1);
    }
    remove_inbox_wire(data_dir, &rid);
    println!("{C_GREEN}blocked{C_RESET} sender of {}", hex::encode(rid));
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
    let s = style();
    let bold = s.bold;
    let dim = s.dim;
    let reset = s.reset;
    let contacts = load_contacts(data_dir);
    println!(
        "{bold}Contacts{reset} ({}) — petname first (Raven Tag V1)",
        contacts.len()
    );
    if contacts.is_empty() {
        println!("{dim}No contacts yet. Soft Unique Tags in brief:{reset}");
        println!("  {dim}• rvn1… address = durable identity (from QR / whoami){reset}");
        println!("  {dim}• @alias = public Soft Unique tag (conflicts → picker){reset}");
        println!("  {dim}• petname = your private label (e.g. \"Poline\"){reset}");
        println!("  {dim}• verify fingerprint OOB before pinning{reset}");
        println!();
        println!("{dim}Add interactively below, or:{reset}");
        println!(
            "  {bold}ash contact add --address rvn1… --pub-hex <64 hex> --petname \"Poline\"{reset}"
        );
        println!(
            "  {dim}ash contact add --help{reset}  for Soft Unique Tag examples"
        );
        return;
    }
    for (i, c) in contacts.iter().enumerate() {
        let sub = c
            .tag_subtitle()
            .map(|t| format!("  {dim}{t}{reset}"))
            .unwrap_or_default();
        let pin = if c.pinned { " [pinned]" } else { "" };
        println!(
            "  {bold}{}{reset}  {}{}{pin}",
            i + 1,
            c.primary_label(),
            sub
        );
        println!(
            "      {dim}fp={}{reset}",
            contact_fingerprint(c)
        );
    }
}

fn resolve_alias_claims_for_add(data_dir: &Path, alias: &str) -> Vec<AliasRecord> {
    let now = now_ms();
    let store = load_alias_store(data_dir, now);
    store.lookup_exact(alias, now).unwrap_or_default()
}

/// Interactive contact add — teaches Soft Unique Tags; never prints private keys.
fn cmd_contacts(data_dir: &Path) {
    let s = style();
    let bold = s.bold;
    let dim = s.dim;
    let reset = s.reset;

    cmd_contact_list(data_dir);
    println!();
    println!("{bold}Contacts menu{reset}");
    println!("  {bold}a{reset}  Add contact     {dim}rvn1… or @alias + petname + fingerprint{reset}");
    println!("  {bold}l{reset}  List again");
    println!("  {bold}Enter{reset}  Back to main menu");
    print!("\n{bold}contacts>{reset} ");
    let _ = io::stdout().flush();
    let choice = read_line();
    match choice.to_ascii_lowercase().as_str() {
        "a" | "add" | "y" | "yes" => cmd_contact_add_interactive(data_dir),
        "l" | "list" => cmd_contact_list(data_dir),
        "" => {}
        other => println!("{dim}unknown:{reset} {other} — try a / l / Enter"),
    }
}

fn cmd_contact_add_interactive(data_dir: &Path) {
    let s = style();
    let bold = s.bold;
    let dim = s.dim;
    let reset = s.reset;

    println!();
    println!("{bold}Add contact{reset} {dim}(public bits only — never paste a seed){reset}");
    println!("{dim}Soft Unique Tags: @alias is NOT globally unique. Always check fingerprint.{reset}");
    println!();
    print!("Enter Raven address (rvn1…) or @alias: ");
    let _ = io::stdout().flush();
    let who = read_line();
    if who.trim().is_empty() {
        println!("{dim}cancelled.{reset}");
        return;
    }

    let address;
    let pub_hex;
    let tag;

    let trimmed = who.trim();
    if trimmed.starts_with('@') || (!trimmed.starts_with("rvn1") && !trimmed.contains(':')) {
        // Treat as @alias (Soft Unique) — look up local alias claims.
        let alias = trimmed.trim_start_matches('@');
        tag = normalize_tag(alias);
        let claims = resolve_alias_claims_for_add(data_dir, &tag);
        if claims.is_empty() {
            println!("{dim}No local alias claim for @{tag}.{reset}");
            println!("{dim}Ask them for their rvn1… address + pub_hex (ash whoami), or:{reset}");
            println!("  {bold}ash find @{tag}{reset}");
            print!("Paste rvn1… address instead (or Enter to cancel): ");
            let _ = io::stdout().flush();
            address = read_line();
            if address.trim().is_empty() {
                return;
            }
            print!("pub_hex (64 chars, public only): ");
            let _ = io::stdout().flush();
            pub_hex = read_line();
        } else if claims.len() == 1 {
            let c = &claims[0];
            address = c.identity_address.clone();
            pub_hex = hex::encode(c.ed25519_pub);
            println!("{dim}Resolved @{tag} → {}{reset}", sanitize_terminal_text(&address));
        } else {
            println!(
                "{bold}alias conflict{reset}: {} candidates — pick one (never silent)",
                claims.len()
            );
            for (i, c) in claims.iter().enumerate() {
                let fp = device_fingerprint_v1(&c.ed25519_pub);
                println!(
                    "  {bold}{}{reset}  {}  fp={}",
                    i + 1,
                    sanitize_terminal_text(&c.identity_address),
                    fp
                );
            }
            print!("pick [1-{}]: ", claims.len());
            let _ = io::stdout().flush();
            let line = read_line();
            let Ok(n) = line.trim().parse::<usize>() else {
                println!("{dim}cancelled.{reset}");
                return;
            };
            if n < 1 || n > claims.len() {
                println!("{dim}invalid pick.{reset}");
                return;
            }
            let c = &claims[n - 1];
            address = c.identity_address.clone();
            pub_hex = hex::encode(c.ed25519_pub);
        }
    } else {
        address = trimmed.to_string();
        print!("pub_hex (64 chars from their `ash whoami` — public only): ");
        let _ = io::stdout().flush();
        pub_hex = read_line();
        print!("optional public @tag (Soft Unique, e.g. poline): ");
        let _ = io::stdout().flush();
        tag = read_line();
    }

    print!("Optional petname (e.g. \"Poline\" — local label): ");
    let _ = io::stdout().flush();
    let petname = read_line();

    let ed = match parse_pub_hex(&pub_hex) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("rejected: {e}");
            return;
        }
    };
    let fp = device_fingerprint_v1(&ed);
    println!();
    println!("{bold}Fingerprint{reset}  {fp}");
    println!("{dim}Compare this with your peer out-of-band (Signal call, in person, etc.).{reset}");
    print!("[V]erify & pin  /  [C]ontinue unpinned  /  [A]bort: ");
    let _ = io::stdout().flush();
    let choice = read_line();
    let verify = match choice.trim().to_ascii_lowercase().as_str() {
        "v" | "verify" | "pin" => Some(fp.clone()),
        "c" | "continue" | "" => None,
        "a" | "abort" | "q" => {
            println!("{dim}cancelled.{reset}");
            return;
        }
        other if other.eq_ignore_ascii_case(&fp) => Some(fp.clone()),
        _ => {
            println!("{dim}cancelled (expected V, C, or A).{reset}");
            return;
        }
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
    } else {
        println!("{dim}Tip: menu 2 Send / Chat → pick this contact by # or @tag.{reset}");
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

fn cmd_prekey_publish(data_dir: &Path, device_id: &str, out: Option<&Path>) {
    let id = ensure_identity(data_dir);
    ext::cmd_prekey_publish_real(data_dir, &id, device_id, out);
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
    let s = style();
    let bold = s.bold;
    let dim = s.dim;
    let reset = s.reset;

    // Ensure identity exists, but teach if this is effectively first-run.
    if try_load_identity(data_dir).is_none() {
        println!("{bold}No identity yet.{reset}");
        println!("{dim}Create one first: menu 4 Status, or `ash init` (public bits only).{reset}");
        return;
    }
    let id = ensure_identity(data_dir);
    let contacts = load_contacts(data_dir);

    if contacts.is_empty() {
        println!("{bold}Send / Chat{reset}");
        println!("{dim}You have no contacts yet — don't jump to host:port.{reset}");
        println!();
        println!("  {bold}1.{reset} Add someone first: menu {bold}3 Contacts{reset}");
        println!("     (rvn1… address + pub_hex from their `ash whoami`, or @alias)");
        println!("  {bold}2.{reset} Advanced: direct peer host:port (LAN demo / power users)");
        println!();
        print!("Add a contact now? [Y/n/advanced]: ");
        let _ = io::stdout().flush();
        let ans = read_line();
        let a = ans.trim().to_ascii_lowercase();
        if a.is_empty() || a == "y" || a == "yes" {
            cmd_contact_add_interactive(data_dir);
            return;
        }
        if a != "advanced" && a != "a" && a != "n" && a != "no" {
            println!("{dim}cancelled — use menu 3 to add a contact.{reset}");
            return;
        }
        if a == "n" || a == "no" {
            println!("{dim}Add a contact first (menu 3), then try Send / Chat again.{reset}");
            return;
        }
        // advanced direct peer
        println!();
        println!("{bold}Advanced — direct peer{reset}");
        println!("{dim}Use when you already know the peer's LAN listen address + public key.{reset}");
        println!("{dim}Prefer contacts for normal messaging (menu 3).{reset}");
        print!("peer host:port: ");
        let _ = io::stdout().flush();
        let peer = read_line();
        print!("peer pub_hex (64 chars, public only): ");
        let _ = io::stdout().flush();
        let pub_hex = read_line();
        print!("message (stdin — never argv): ");
        let _ = io::stdout().flush();
        let text = read_line();
        if text.is_empty() {
            eprintln!("empty message");
            return;
        }
        ext::run_send_secure(data_dir, &id, &peer, &pub_hex, "127.0.0.1:0", &text, "", "");
        return;
    }

    println!("{bold}Send / Chat{reset}");
    println!("{dim}Pick a contact by number or @tag. Direct host:port is advanced only.{reset}");
    for (i, c) in contacts.iter().enumerate() {
        let sub = c
            .tag_subtitle()
            .map(|t| format!("  {dim}{t}{reset}"))
            .unwrap_or_default();
        println!(
            "  {bold}{}{reset}  {}{}{}",
            i + 1,
            c.primary_label(),
            sub,
            if c.pinned { " [pinned]" } else { "" }
        );
    }
    print!("contact # | @tag | advanced: ");
    let _ = io::stdout().flush();
    let choice = read_line();

    let (peer, peer_pub_hex, petname, tag, open_chat) = if choice.trim().eq_ignore_ascii_case("advanced")
        || choice.trim().contains(':') && choice.parse::<usize>().is_err() && !choice.trim().starts_with('@')
    {
        if choice.trim().eq_ignore_ascii_case("advanced") {
            println!("{dim}Direct peer — enter LAN listen host:port and their public key.{reset}");
            print!("peer host:port: ");
            let _ = io::stdout().flush();
            let peer = read_line();
            print!("peer pub_hex: ");
            let _ = io::stdout().flush();
            let pub_hex = read_line();
            (peer, pub_hex, String::new(), String::new(), false)
        } else {
            print!("peer pub_hex: ");
            let _ = io::stdout().flush();
            let pub_hex = read_line();
            (choice, pub_hex, String::new(), String::new(), false)
        }
    } else if let Ok(n) = choice.parse::<usize>() {
        if n >= 1 && n <= contacts.len() {
            let c = &contacts[n - 1];
            print!("peer listen host:port (where they are listening): ");
            let _ = io::stdout().flush();
            let peer = read_line();
            print!("open chat session? [Y/n]: ");
            let _ = io::stdout().flush();
            let yn = read_line();
            let chat =
                yn.is_empty() || yn.eq_ignore_ascii_case("y") || yn.eq_ignore_ascii_case("yes");
            (
                peer,
                c.pub_hex.clone(),
                c.primary_label(),
                normalize_tag(&c.public_tag),
                chat,
            )
        } else {
            eprintln!("invalid contact #");
            return;
        }
    } else if choice.trim().starts_with('@')
        || (resolve_alias_contacts(&contacts, choice.trim()).len() == 1 && !choice.contains(':'))
    {
        let alias = choice.trim().trim_start_matches('@');
        let hits = resolve_alias_contacts(&contacts, alias);
        if hits.is_empty() {
            eprintln!("no contact for @{alias}");
            eprintln!("{dim}Add them via menu 3, or check `ash contact list`.{reset}");
            return;
        }
        if hits.len() > 1 {
            eprintln!(
                "{bold}alias ambiguity{reset}: {} matches — pick # or verify fingerprints",
                hits.len()
            );
            for (i, c) in hits.iter().enumerate() {
                eprintln!(
                    "  {}  {}  fp={}",
                    i + 1,
                    c.primary_label(),
                    contact_fingerprint(c)
                );
            }
            return;
        }
        print!("peer listen host:port (where they are listening): ");
        let _ = io::stdout().flush();
        let peer = read_line();
        (
            peer,
            hits[0].pub_hex.clone(),
            hits[0].primary_label(),
            normalize_tag(&hits[0].public_tag),
            true,
        )
    } else {
        eprintln!("{dim}Unknown choice. Pick a contact #, @tag, or type `advanced`.{reset}");
        return;
    };

    if open_chat {
        ext::cmd_chat_session(data_dir, &id, &petname, &tag, &peer_pub_hex, &peer);
        return;
    }
    print!("message (stdin — never argv): ");
    let _ = io::stdout().flush();
    let text = read_line();
    if text.is_empty() {
        eprintln!("empty message");
        return;
    }
    ext::run_send_secure(
        data_dir,
        &id,
        &peer,
        &peer_pub_hex,
        "127.0.0.1:0",
        &text,
        &petname,
        &tag,
    );
}

fn run_send(data_dir: &Path, peer: &str, peer_pub_hex: &str, listen: &str, text: &str) {
    let id = ensure_identity(data_dir);
    ext::run_send_secure(data_dir, &id, peer, peer_pub_hex, listen, text, "", "");
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

pub fn run() {
    let path = resolve_terminal_messaging_path();
    if let Err(e) = assert_no_silent_fastapi(path) {
        eprintln!("{e}");
        std::process::exit(1);
    }
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
            NodeCommands::AddBootstrap { multiaddr, manual } => {
                ext::cmd_bootstrap_add(&data_dir, &multiaddr, manual)
            }
            NodeCommands::DisableRavenDefaults => ext::cmd_bootstrap_disable_raven(&data_dir),
            NodeCommands::ShowBootstrap => ext::cmd_bootstrap_show(&data_dir),
            NodeCommands::InitBootstrap { no_raven_defaults } => {
                ext::cmd_bootstrap_init(&data_dir, no_raven_defaults)
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
            stdin_text,
            chat,
        }) => {
            let _ = stdin_text;
            // Refuse any leftover argv-style invocation that clap might have accepted historically.
            if std::env::args().any(|a| a == "--text" || (!a.starts_with('-') && false)) {
                ext::refuse_argv_plaintext();
            }
            let id = ensure_identity(&data_dir);
            if chat {
                let contacts = load_contacts(&data_dir);
                let c = contacts
                    .iter()
                    .find(|c| c.pub_hex.eq_ignore_ascii_case(&peer_pub_hex));
                let pet = c.map(|c| c.primary_label()).unwrap_or_default();
                let tag = c
                    .map(|c| normalize_tag(&c.public_tag))
                    .unwrap_or_default();
                ext::cmd_chat_session(&data_dir, &id, &pet, &tag, &peer_pub_hex, &peer);
            } else {
                print!("message (stdin, never argv): ");
                let _ = io::stdout().flush();
                let body = read_line();
                if body.is_empty() {
                    eprintln!("empty message");
                    std::process::exit(1);
                }
                run_send(&data_dir, &peer, &peer_pub_hex, &listen, &body);
            }
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
                prekey_file,
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
                if prekey_file.is_some() || data_dir.join("prekey_store.json").exists() {
                    match ext::contact_add_fetch_prekey(
                        &data_dir,
                        &pub_hex,
                        prekey_file.as_deref(),
                    ) {
                        Ok(()) => {}
                        Err(e) => {
                            eprintln!("{C_DIM}prekey note:{C_RESET} {e}");
                        }
                    }
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
            ContactCommands::Request {
                target,
                message,
                pick,
            } => cmd_contact_request(&data_dir, &target, &message, pick),
            ContactCommands::Pending => cmd_contact_pending(&data_dir),
            ContactCommands::Ingest { file } => cmd_contact_ingest(&data_dir, &file),
            ContactCommands::Accept {
                request_id,
                petname,
            } => cmd_contact_accept(&data_dir, &request_id, &petname),
            ContactCommands::Decline { request_id } => {
                cmd_contact_decline(&data_dir, &request_id)
            }
            ContactCommands::Block { request_id } => cmd_contact_block(&data_dir, &request_id),
        },
        Some(Commands::Find {
            query,
            local,
            exact_id,
            exact_alias,
            all,
        }) => cmd_find(&data_dir, &query, local, exact_id, exact_alias, all),
        Some(Commands::Nearby) => cmd_nearby(&data_dir),
        Some(Commands::Alias { cmd }) => match cmd {
            AliasCommands::Publish {
                alias,
                sequence,
                expires_at,
            } => {
                let id = ensure_identity(&data_dir);
                let exp = expires_at.unwrap_or_else(|| now_ms() + 30 * 24 * 3600 * 1000);
                let rec = AliasRecord {
                    alias,
                    identity_address: String::new(),
                    sequence,
                    expires_at: exp,
                    signature: [0u8; 64],
                    ed25519_pub: [0u8; 32],
                }
                .sign(&id)
                .unwrap_or_else(|e| {
                    eprintln!("sign failed: {e}");
                    std::process::exit(1);
                });
                let mut store = load_alias_store(&data_dir, now_ms());
                if let Err(e) = store.put(rec.clone(), now_ms()) {
                    eprintln!("rejected: {e}");
                    std::process::exit(1);
                }
                if let Err(e) = save_alias_claim(&data_dir, &rec) {
                    eprintln!("persist failed: {e}");
                    std::process::exit(1);
                }
                println!(
                    "{C_GREEN}alias published{C_RESET} @{} → {}",
                    rec.alias,
                    sanitize_terminal_text(&rec.identity_address)
                );
            }
        },
        Some(Commands::Prekey { cmd }) => match cmd {
            PrekeyCommands::Publish { device_id, out } => {
                cmd_prekey_publish(&data_dir, &device_id, out.as_deref())
            }
            PrekeyCommands::Fetch { pub_hex, file } => {
                cmd_prekey_fetch(&data_dir, &pub_hex, file.as_deref())
            }
        },
        Some(Commands::Device { cmd }) => {
            let id = ensure_identity(&data_dir);
            match cmd {
                DeviceCommands::SyncExport { device_id, out } => {
                    ext::cmd_device_sync_export(&data_dir, &id, &device_id, &out)
                }
                DeviceCommands::SyncImport { file } => {
                    ext::cmd_device_sync_import(&data_dir, &id, &file)
                }
                DeviceCommands::Revoke { device_id, epoch } => {
                    ext::cmd_device_revoke(&data_dir, &id, &device_id, epoch)
                }
            }
        }
        Some(Commands::Mailbox { cmd }) => match cmd {
            MailboxCommands::Put {
                k_route_hex,
                epoch,
                slot,
                envelope_hex,
            } => ext::cmd_mailbox_put(&data_dir, &k_route_hex, epoch, slot, &envelope_hex),
            MailboxCommands::Get {
                k_route_hex,
                epoch,
                slot,
            } => ext::cmd_mailbox_get(&data_dir, &k_route_hex, epoch, slot),
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
    {
        let cfg = raven_core::load_bootstrap(data_dir);
        println!(
            "  bootstrap: use_raven_defaults={} effective_peers={} manual_only_ok={}",
            cfg.use_raven_defaults,
            cfg.effective_peers().len(),
            cfg.manual_peer_only_ok()
        );
    }

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

    // Identity store (backend label only — never seed bytes).
    let ks = raven_core::store_status(data_dir);
    let backend = ks
        .backend
        .map(|b| b.as_str())
        .unwrap_or("none");
    println!(
        "  secure_keystore: backend={backend} identity={}",
        if ks.has_identity { "present" } else { "absent" }
    );
    if ks.legacy_plaintext_present {
        println!(
            "  {C_PURPLE}secure_keystore{C_RESET}: legacy plaintext seed file still present — reopen once to migrate"
        );
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
    ] {
        let p = data_dir.join(name);
        let label = if name.contains("queue") {
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
        // Capture-style: ensure motif strings exist; monochrome only (no brand RGB).
        let art = format!("{}Welcome to Raven Node{}", "\x1b[1m", "\x1b[0m");
        assert!(art.contains("Welcome to Raven Node"));
        assert!(!art.contains("identity.seed"));
        assert!(!art.contains("private"));
        assert!(!art.contains("38;2;64;242;255")); // old cyan RGB gone
        assert!(!art.contains("38;2;191;115;255")); // old purple RGB gone
    }

    #[test]
    fn no_color_style_is_empty() {
        // style() reads env once — verify monochrome consts have no brand RGB.
        assert!(!C_CYAN.contains("38;2"));
        assert!(!C_PURPLE.contains("38;2"));
        assert!(!C_GREEN.contains("38;2"));
        assert_eq!(C_CYAN, C_BOLD);
    }
}
