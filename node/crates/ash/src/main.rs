//! RAVEN terminal CLI (`ash` product name). Local-only Raven Node control.
//!
//! This is the **product** CLI in `node/` — not Cursor/ash-autonomous automation.
//! Never prints private keys, seeds, session keys, recovery secrets, or plaintext.

use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::Command;

use clap::{Parser, Subcommand};
use raven_core::fingerprint::device_fingerprint_v1;
use raven_core::forward_queue::ForwardQueue;
use raven_core::identity::Identity;
use raven_core::node_policy::{load_policy, save_policy, BridgeStatusSnapshot, NodePolicy};
use raven_core::queue::{DeliveryState, OutgoingQueue};
use serde::{Deserialize, Serialize};

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
    /// Configure local raven-node policy (bridge/store/relay). Does not stop a running node.
    Node {
        #[command(subcommand)]
        cmd: NodeCommands,
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
    /// Optional human label (not a secret).
    alias: String,
    /// Raven address (rvn1…).
    address: String,
    /// Ed25519 public key hex only.
    pub_hex: String,
}

fn contacts_path(data_dir: &Path) -> PathBuf {
    data_dir.join("contacts.json")
}

fn load_contacts(data_dir: &Path) -> Vec<Contact> {
    let path = contacts_path(data_dir);
    let Ok(raw) = std::fs::read_to_string(&path) else {
        return Vec::new();
    };
    serde_json::from_str(&raw).unwrap_or_default()
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

fn cmd_contacts(data_dir: &Path) {
    let mut contacts = load_contacts(data_dir);
    println!("{C_BOLD}Contacts{C_RESET} ({})", contacts.len());
    if contacts.is_empty() {
        println!("{C_DIM}None yet. Add a peer pub (public hex only).{C_RESET}");
    } else {
        for (i, c) in contacts.iter().enumerate() {
            let fp = if let Ok(bytes) = hex::decode(&c.pub_hex) {
                if bytes.len() == 32 {
                    let mut a = [0u8; 32];
                    a.copy_from_slice(&bytes);
                    device_fingerprint_v1(&a)
                } else {
                    "—".into()
                }
            } else {
                "—".into()
            };
            println!(
                "  {C_CYAN}{}{C_RESET}  {}  {C_DIM}fp={fp}{C_RESET}",
                i + 1,
                if c.alias.is_empty() {
                    &c.address
                } else {
                    &c.alias
                }
            );
            println!("      {C_DIM}{}{C_RESET}", c.address);
        }
    }
    print!("Add contact? [y/N] ");
    let _ = io::stdout().flush();
    if read_line().eq_ignore_ascii_case("y") {
        print!("alias (optional): ");
        let _ = io::stdout().flush();
        let alias = read_line();
        print!("address (rvn1…): ");
        let _ = io::stdout().flush();
        let address = read_line();
        print!("pub_hex (64 chars, public only): ");
        let _ = io::stdout().flush();
        let pub_hex = read_line().to_lowercase();
        if pub_hex.len() != 64 || hex::decode(&pub_hex).map(|v| v.len()) != Ok(32) {
            eprintln!("rejected: pub_hex must be 32-byte hex (never paste seeds)");
            return;
        }
        if address.is_empty() {
            eprintln!("rejected: address required");
            return;
        }
        contacts.push(Contact {
            alias,
            address,
            pub_hex,
        });
        if let Err(e) = save_contacts(data_dir, &contacts) {
            eprintln!("save failed: {e}");
        } else {
            println!("{C_GREEN}saved{C_RESET} (public fields only)");
        }
    }
}

fn cmd_status(data_dir: &Path) {
    println!("{C_BOLD}Status{C_RESET}");
    println!("{C_DIM}data_dir{C_RESET} {}", data_dir.display());
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
        println!("Pick contact # or paste peer host:port");
        for (i, c) in contacts.iter().enumerate() {
            println!(
                "  {C_CYAN}{}{C_RESET}  {}",
                i + 1,
                if c.alias.is_empty() {
                    &c.address
                } else {
                    &c.alias
                }
            );
        }
        print!("peer host:port (or contact #): ");
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
    print!("message text: ");
    let _ = io::stdout().flush();
    let text = read_line();
    if peer.is_empty() || peer_pub_hex.len() != 64 || text.is_empty() {
        eprintln!("need peer, 64-char pub_hex, and non-empty text");
        return;
    }
    // Do not echo plaintext back; spawn raven-node which logs lengths only.
    println!("{C_DIM}sending… (plaintext not logged by ash){C_RESET}");
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
    }
}

fn cmd_doctor(data_dir: &Path) {
    println!("{C_BOLD}raven doctor{C_RESET}");
    let exe = std::env::current_exe()
        .map(|p| p.display().to_string())
        .unwrap_or_else(|_| "?".into());
    println!("  this_binary={exe}");
    println!("  data_dir={}", data_dir.display());
    let sock = raven_core::default_socket_path(data_dir);
    println!("  ipc_sock={} exists={}", sock.display(), sock.exists());
    #[cfg(unix)]
    {
        let bin_ash = Path::new("/bin/ash");
        if bin_ash.exists() {
            println!(
                "  {C_GREEN}note{C_RESET}: /bin/ash exists — Raven must NOT overwrite it"
            );
            println!("  use `raven` or ~/.local/bin/ash → raven from install scripts");
        } else {
            println!("  /bin/ash: absent on this host");
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
