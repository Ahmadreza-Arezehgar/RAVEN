# RAVEN terminal demo (safe — no secrets)

Local-only walkthrough for the serverless **`ash`** product CLI and `raven-node`.
Uses **ephemeral identities** (`mktemp -d` / Windows TEMP). Never paste real production keys,
tokens, APNs/JWT material, or recovery secrets into this file or shell history demos.

**Brand:** [raven-messager.com](https://raven-messager.com/) · public logo  
`https://raven-messager.com/raven_logo.png` (also `/raven_logo_64.png`, `/raven_logo_192.png`)  
Terminal welcome uses **black & white** (monochrome bold/dim ANSI — or plain text with `NO_COLOR=1` / `TERM=dumb`). Site CSS palette is separate from the CLI.

## Persian quick start / شروع سریع (FA + EN)

| Step | EN | FA |
|---|---|---|
| 1 | Clone/copy the **whole** repo on **this** Mac (your home path) | کل ریپو را روی **همین** مک کپی/کلون کنید (مسیر خانهٔ خودتان) |
| 2 | `bash scripts/ash_first_run.sh` | اسکریپت پرتابل — مسیر `/Users/ahmd` لازم نیست |
| 3 | Run `ash init`; **Status is read-only** | `ash init` را اجرا کنید؛ Status فقط خواندنی است |
| 4 | Share `ash whoami` (address + pub_hex only) | فقط address و pub_hex را بفرستید — **هرگز seed** |
| 5 | Menu **5 Contacts** → Menu **1 Send** | مخاطب → ارسال (شماره مخاطب، نه host:port) |

```bash
# From repo root — works on any Mac username:
bash scripts/ash_first_run.sh
# build only:
bash scripts/ash_first_run.sh --no-run
# init + print whoami then exit:
bash scripts/ash_first_run.sh --init-only
```

اگر `rustc`/`cargo` نباشد، اسکریپت پیام دو زبانه می‌دهد → [rustup.rs](https://rustup.rs).

## Two Macs on the same LAN

**Why Mac2 often fails:** docs/commands with `/Users/ahmd/...` are **someone else’s home**. On Mac2 use *their* clone path (or the portable script above).

> **Debug-lab only:** terminal message origination currently requires the
> compile-time Debug build **and** `RAVEN_LAB_TEST_A=1`. Export the gate in both
> device shells before these commands. A Release binary intentionally ignores
> this lab gate and must refuse `ash send` until the production ATSAM bootstrap
> is complete; this walkthrough is not Release-mode send evidence.

```bash
# Mac2 — after copying/cloning the repo to YOUR home:
cd ~/hybrid_messenger          # or wherever YOU put it
export PATH="$HOME/.cargo/bin:$PATH"
export RAVEN_LAB_TEST_A=1       # Debug lab only; set on Mac1 too
bash scripts/ash_first_run.sh --init-only
# Run the same init on Mac1, exchange BOTH `ash whoami` outputs, and verify
# fingerprints out of band. Each Mac must add/pin the other (menu 5 Contacts)
# before either listener/send test. Follow “Manual two-device Debug-lab path”
# below for the exact reciprocal commands, then use menu 4 Listen + menu 1 Send.
```

Do not use `raven-node run` as the receiver for `ash send`: that is the legacy
raw-envelope command and is not the Noise/RLB1 + PairInit service protocol.
`ash listen` reports success immediately when an installed service is already
IPC-ready; when it starts the service itself, it stays in the foreground and
propagates daemon failures.

Automated loopback proof (same machine):

```bash
cd node
./scripts/ash_listen_secure_service_smoke.sh
./scripts/lan_direct_two_node.sh
./scripts/ash_menu_smoke.sh
```

`ash_listen_secure_service_smoke.sh` is the real process-lifecycle regression:
it starts/reuses the secure service and verifies startup failures are nonzero.
`lan_direct_two_node.sh` (also available through the compatibility name
`ash_contacts_lan_demo.sh`) exercises authenticated contact → send → inbox and
stranger refusal, but explicitly enables the debug-only `RAVEN_LAB_TEST_A`
origination gate. It is transport/integration evidence, not a claim that the
production ATSAM bootstrap or automatic A→B→C routing is complete.

## Prerequisites

```bash
# Prefer portable script, or:
cd /path/to/hybrid_messenger/node   # ← your path, not /Users/ahmd
cargo build -p raven-core -p raven-node -p ash
cargo test -p raven-core -p ash
cargo test -p raven-core --test reliability
```

Python oracle (repo venv has `cryptography`):

```bash
cd /path/to/hybrid_messenger/protocol/reference
../.venv/bin/python -m pytest -q
```

**Windows:** see [`WINDOWS.md`](./WINDOWS.md) (native MSVC build → `ash.exe` / `raven-node.exe`, or cross-compile notes). No installer yet.

## First time

```bash
cd /path/to/hybrid_messenger/node
DATA=$(mktemp -d)
./target/debug/ash --data-dir "$DATA" init     # explicitly create identity (public bits only)
./target/debug/ash --data-dir "$DATA" status   # read-only; never creates identity/state
./target/debug/ash --data-dir "$DATA"          # interactive menu after init
./target/debug/ash --data-dir "$DATA" banner   # welcome only
```

1. Run `ash` with a fresh `--data-dir` — the banner explains first-run steps.
2. Create identity explicitly with `ash init`. **Status is read-only** and reports a missing identity without creating one.
3. **Add a contact** (menu **5 Contacts**) before Send / Chat — paste their `ash whoami` or rvn1… + pub_hex.
4. Then menu **1 Send** → pick contact **#** or `@tag`. Enter LAN `host:port` **once**; it is saved on the contact (`lan_dial`). Beginners should not re-type host:port every send.

## Add a contact

### Interactive (recommended)

```text
raven> 5
Contacts menu
  a  Add contact
contacts> a
Enter Raven address (rvn1…) / @alias / paste whoami:   # paste full whoami OK
…
Optional LAN dial host:port (Enter to skip — set later on Send): 192.168.1.20:7420
[V]erify & pin  /  [C]ontinue unpinned  /  [A]bort: V
```

Soft Unique Tags (brief):

| Layer | What | Notes |
|---|---|---|
| A | `rvn1…` address | Durable identity |
| B | `@alias` / public tag | Soft Unique — conflicts show a picker |
| C | petname (e.g. Poline) | Local-only primary label |
| — | fingerprint verify | Pins Tag+key locally (`V` or `--verify-fp`) |
| — | `lan_dial` | Optional saved `host:port` for Send |

### CLI

```bash
# Peer runs: ash --data-dir "$PEER" whoami   → copy address + pub_hex (+ fingerprint)
./target/debug/ash --data-dir "$DATA" contact add \
  --address rvn1q… \
  --pub-hex <64 hex> \
  --petname "Poline" \
  --tag poline \
  --lan-dial 192.168.1.20:7420 \
  --verify-fp XXXX-XXXX-XXXX

./target/debug/ash contact add --help   # Soft Unique Tag examples
```

## Primary entry: `ash` interactive welcome

`ash` with **no subcommand** opens the Raven Node shell (not Cursor/ash-autonomous).

```bash
cd /path/to/hybrid_messenger/node
DATA=$(mktemp -d)
./target/debug/ash --data-dir "$DATA" init     # public bits only
./target/debug/ash --data-dir "$DATA" banner   # non-interactive welcome
./target/debug/ash --data-dir "$DATA"          # interactive menu
NO_COLOR=1 ./target/debug/ash --data-dir "$DATA" banner   # plain text
```

**Welcome (B&W stand-in; bold/dim ANSI in a real TTY):**

```
      ┌──────────────────────────────────────────────────┐
      │                                                  │
      │      .--.     ≺═══◈═══≻                         │
      │     /  ◉\      NODE                            │
      │    /  /\ \                                       │
      │   /__/  \_\   Welcome to Raven Node            │
      │              Messaging Beyond Connectivity     │
      │                                                  │
      │  serverless · ATSAM · peer-to-peer               │
      └──────────────────────────────────────────────────┘

Brand logo (PNG): https://raven-messager.com/raven_logo.png
Site:             https://raven-messager.com/

● identity ready (public bits only — never a seed)
address     rvn1q…          # placeholder — yours will differ
fingerprint XXXX-XXXX-XXXX
pub_hex     <64 hex chars>  # public Ed25519 only — never a seed

  Menu
  1  Chat / Send   message a contact — guided
  2  Inbox         committed endpoint inbox
  3  Status        identity, bridge, transports (read-only)
  4  Listen        receive — one command, no flags
  5  Contacts      add by rvn1… / @alias / petname + fingerprint
  6  Mailbox       opaque offline put/get
  7  Nearby scan   ephemeral BLE discovery
  8  Tutorial      guided walkthrough
  q  Quit

raven>
```

### Banner / CLI security checklist

| Check | Status |
|---|---|
| No private keys / seeds / session keys / tokens in banner or menu | **Yes** |
| After identity: only `address` / `fingerprint` / `pub_hex` | **Yes** |
| Messages view: msg id prefix + delivery state + peer address — no plaintext, no packed envelopes logged | **Yes** |
| Contacts store public `address` + `pub_hex` (+ optional alias) only | **Yes** |
| No unauthenticated localhost admin HTTP | **Yes** — ash/raven-node local files only; no daemon HTTP |
| Demo data dirs ephemeral (`mktemp -d`) | **Yes** |
| E2EE / ATSAM path unchanged; node logs lengths / opaque status only | **Yes** |

## One-shot reliability demo

```bash
cd /path/to/hybrid_messenger/node
./scripts/two_node_demo.sh
./scripts/lan_path_smoke.sh
./scripts/bridge_abc_demo.sh
./scripts/ash_menu_smoke.sh
./scripts/ash_listen_secure_service_smoke.sh
./scripts/lan_direct_two_node.sh
cargo test -p raven-core --test bridge_v1
```

**Expected:** four `round N OK` + `ALL DEMO CHECKS PASSED`; `mode=interim OK`, `mode=opaque-atsam OK`;  
`bridge_abc_demo` → three A–B–C rounds + store-carry + `ALL BRIDGE A-B-C CHECKS PASSED`;  
`ash_menu_smoke` → menu green; `ash_listen_secure_service_smoke` → real service
start/reuse/failure propagation green; `lan_direct_two_node` → lab-gated secure
contact LAN delivery and untrusted PairInit refusal green.

## Bridge A–B–C (local, mock BLE)

See **[`BRIDGE_V1.md`](./BRIDGE_V1.md)** for the full Bridge V1 spec walkthrough.

Topology: **A** LAN-only → **B** bridge (LAN + mock BLE) → **C** BLE-only. Same opaque `RavenEnvelopeV1`; B never decrypts; Delivered ACK only from C.

```bash
cd /path/to/hybrid_messenger/node
cargo build -p raven-node -p ash
./scripts/bridge_abc_demo.sh
```

### ash Bridge controls (config only — does not stop `raven-node`)

```bash
DATA_B=$(mktemp -d)
./target/debug/ash --data-dir "$DATA_B" init
./target/debug/ash --data-dir "$DATA_B" node bridge on
./target/debug/ash --data-dir "$DATA_B" node store on
./target/debug/ash --data-dir "$DATA_B" node relay off
./target/debug/ash --data-dir "$DATA_B" status
```

Sample status (safe fields only):

```
Bridge
  bridge     on
  store      on
  relay      off
  transports lan, mock_ble
  caps       ble, internet, store, bridge
  forward_q  0 pending / N total
note      ash configures only — raven-node bridge keeps running after ash exits
```

Start B daemon separately (survives ash quit):

```bash
./target/debug/raven-node bridge \
  --data-dir "$DATA_B" \
  --lan-listen 127.0.0.1:0 \
  --ble-listen 127.0.0.1:0 \
  --write-lan-addr /tmp/raven-b.lan \
  --write-ble-addr /tmp/raven-b.ble \
  --timeout-secs 0
```

## Manual two-device Debug-lab path (`ash` + secure service)

Do not use the legacy raw `raven-node run --send …` examples found in old
snapshots. Plaintext argv sending is deliberately refused, and that raw command
does not speak the authenticated service protocol used by `ash send`.

This section deliberately uses `target/debug`. In **both** device terminals,
export `RAVEN_LAB_TEST_A=1` before starting the receiver or sender. The gate is
compiled out of Release behavior: `target/release/ash send` is expected to fail
closed today, even if that environment variable is present.

First initialize **both** stable profiles and exchange only the public `whoami`
fields over an out-of-band channel. Verify both fingerprints before pinning:

```bash
# Device A
cd /path/to/hybrid_messenger/node
DATA_A="$HOME/.raven-device-a"
export RAVEN_LAB_TEST_A=1       # Debug-only test gate
./target/debug/ash --data-dir "$DATA_A" init
./target/debug/ash --data-dir "$DATA_A" whoami

# Device B
cd /path/to/hybrid_messenger/node
DATA_B="$HOME/.raven-device-b"
export RAVEN_LAB_TEST_A=1       # Debug-only test gate
./target/debug/ash --data-dir "$DATA_B" init
./target/debug/ash --data-dir "$DATA_B" whoami
```

Mutual PairInit requires a **reciprocal pin**. Add B on A and A on B; a one-way
contact book is intentionally rejected as a stranger:

```bash
# On A
./target/debug/ash --data-dir "$DATA_A" contact add \
  --address <B_RVN_ADDRESS> \
  --pub-hex <B_PUBLIC_HEX> \
  --petname "Device B" \
  --tag device-b \
  --lan-dial <B_LAN_IP>:7420 \
  --verify-fp <B_FINGERPRINT>

# On B
./target/debug/ash --data-dir "$DATA_B" contact add \
  --address <A_RVN_ADDRESS> \
  --pub-hex <A_PUBLIC_HEX> \
  --petname "Device A" \
  --tag device-a \
  --lan-dial <A_LAN_IP>:7420 \
  --verify-fp <A_FINGERPRINT>
```

In a dedicated terminal on **each** device, export the same Debug gate and keep
the secure service listening:

```bash
# A receiver terminal
export RAVEN_LAB_TEST_A=1
./target/debug/ash --data-dir "$DATA_A" listen

# B receiver terminal
export RAVEN_LAB_TEST_A=1
./target/debug/ash --data-dir "$DATA_B" listen
```

Use second terminals for the two directions (message text stays on stdin):

```bash
# A → B
printf '%s\n' 'hello from device A' \
  | ./target/debug/ash --data-dir "$DATA_A" send --contact @device-b

# B → A
printf '%s\n' 'hello from device B' \
  | ./target/debug/ash --data-dir "$DATA_B" send --contact @device-a

# Confirm committed endpoint delivery on both sides.
./target/debug/ash --data-dir "$DATA_A" inbox
./target/debug/ash --data-dir "$DATA_B" inbox
```

Each send must complete through the authenticated session/ACK path and the
opposite inbox must contain exactly one committed message. The automated
`scripts/lan_direct_two_node.sh` regression is the deterministic send→decrypt→ACK
proof (including stranger refusal). A Release build without an approved
production ATSAM bootstrap must fail closed instead of silently using demo
crypto; this Debug gate is not physical-device or production-bootstrap evidence.

## Mobile fixtures are not the current terminal acceptance path

Older versions of this document mixed iOS feature-flag fixtures and the legacy
raw `raven-node run` receiver into the terminal walkthrough. The supported
open-source product tested here is now the cross-platform terminal/node path.
Historical iOS/BLE source and unit fixtures may remain in the repository, but
they are not prerequisites for—and must not be cited as proof of—the two-device
terminal workflow above.

## Portable ATSAM KATs (Rust)

| Vector | Meaning |
|---|---|
| `shared-vectors/rvn1/atsam/chain_kdf_001.json` | Chain HKDF labels |
| `shared-vectors/rvn1/atsam/rvna1_header_layouts_001.json` | Header classify |
| `shared-vectors/rvn1/atsam/rvna1_v2_aead_known_root_001.json` | RVNA1 v2 AEAD + AAD with **known** `K_root` (no ML-KEM) |

Network path for shipping ATSAM without a known root remains **opaque ACK**.

## What is NOT ready yet

- Full ATSAM ML-KEM pairing in Rust (needs known root or ML-KEM port)
- libp2p DHT / NAT in Rust (InternetTransport stubbed behind path selection)
- Windows MSI/MSIX installer / WinUI LAN UI
- raven-node CoreBluetooth/BlueZ GATT (mock_ble stays for CI; iOS GATT via BLEMeshEngine)
- ash-autonomous (out of scope)

## Safety rules for public/GitHub demos

- Show only `address=` / `pub_hex=` / fingerprints / delivery status
- Credit logo URL from raven-messager.com (public asset)
- Use `mktemp -d`; do not commit `identity.seed`, queue DBs, or `.env`
- Do not dump message plaintext
- Prefer local demos; do not push secrets or demo data dirs
