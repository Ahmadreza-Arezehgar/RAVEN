# Terminal reliability evidence bar (Sprint 0)

**Date:** 2026-09-04  
**Owner (semantics / CI bar):** Role #19 SRE Perf  
**Co-owner (operator surface, appendix later):** CLI DX  
**Repo:** [Raven-ASHCO/RAVEN](https://github.com/Raven-ASHCO/RAVEN)  
**Workflow cited:** [`.github/workflows/raven-serverless.yml`](../../../.github/workflows/raven-serverless.yml) (`name: Raven Serverless Node`)

This file defines **Proven** vs **PASS_SOFTWARE_SUBSTITUTE** vs **Blocked** for terminal Win / macOS / Linux reliability. It does **not** invent run counts, soak rates, or `reliability_matrix_20` pass totals. Soft latency budgets stay **draft** — see [`perf-baseline-2026-09-04.md`](perf-baseline-2026-09-04.md) (present on this branch). Swarm / NAT / relay honesty: [`docs/network/raven-swarm-connectivity-matrix.md`](../../network/raven-swarm-connectivity-matrix.md) (on `main` as of PR #2; not required to exist on every topic branch).

Org chart [`org-structure.md`](org-structure.md) still titles #19 as Release Engineering Lead. This bar follows the Sprint 0 assignment (**Role #19 SRE Perf**), same as the perf harvest.

---

## Purpose and owners

| Surface | Owner | Owns |
|---------|-------|------|
| Evidence tiers, named CI jobs, what may be labeled Proven | **#19 SRE Perf** | This document; workflow steps that are reliability *evidence* (queue 10k, `bridge_v1`, path-row labels) |
| Operator how-to, `ash doctor` / install exit codes, how to run `reliability_matrix_20.sh` | **CLI DX** | Stubs at the bottom of this file; `ash` menu UX; install-script operator docs |

**Menu-smoke CI (linux + macOS):** owned by **CLI DX PR #16** (`cursor/ash-menu-smoke-linux-ci-a976`, agent `bc-097f7c8d`). That PR wires `node/scripts/ash_menu_smoke.sh` into `rust-linux` **and** `rust-macos`. This PR does **not** add those steps. Until #16 is merged to `main`, menu-smoke is **pending / in-flight** — do not claim green.

Related:

- Perf numbers and draft soft budgets: [`perf-baseline-2026-09-04.md`](perf-baseline-2026-09-04.md)
- Localhost swarm vs public NAT: [`docs/network/raven-swarm-connectivity-matrix.md`](../../network/raven-swarm-connectivity-matrix.md)
- NAT substitutes (not WAN): [`docs/NAT_SOFTWARE_SIM.md`](../../NAT_SOFTWARE_SIM.md)

---

## Tier definitions (strict)

Labels apply **per OS** and **per path**. A green Linux job does not make Windows Proven.

### Proven

Automated **green on that OS** for **Delivered + ACK** (or **queue Delivered** for `reliability_10k`) **and** dedup **and** no panic on malformed input, via a **named** CI job / test on that OS.

Examples that can become Proven when the named step is green on that OS’s job:

- `cargo test -p raven-core --test reliability` (`reliability.rs`: restart→Delivered, inbound dedup, malformed/truncated do not panic)
- `cargo test -p raven-core --test reliability_10k -- --ignored` (queue enqueue / dedup / Delivered × 10_000)
- `cargo test -p raven-core --test bridge_v1` (software bridge Delivered + ACK + dedup)

**CLI / terminal-path Proven** is a *distinct* claim (see below). It is **not** implied by queue or `bridge_v1` Proven.

### PASS_SOFTWARE_SUBSTITUTE

Substitute results that **may** count toward a `reliability_matrix_20` budget and **MUST NOT** be labeled cross-OS terminal Proven:

- `reliability_matrix_20.sh` `sc_windows_wine`: wine64 `ash --help` or PE32+ self-check when wine is absent (`PASS_SOFTWARE_SUBSTITUTE`)
- lima `ash --help` / lima uname-only (`sc_linux_container`)
- Docker NAT topology **without** `raven-swarm` (`scripts/nat_docker_sim.sh`; `not_claimed=public_CGNAT,DCUtR,AutoNAT`)
- Cross-built `ash.exe` PE header check on a non-Windows host

**`reliability_matrix_20` wine / lima `ash --help` ≠ Windows Proven.** Never promote those rows to `terminal-path Proven (Windows)`.

### Blocked

No evidence on that OS’s CI job, or the path is hardware / portal / public-Internet by existing docs:

- Physical BLE (mock_ble / software bridge is not a radio claim)
- Public CGNAT / DCUtR / live multi-NAT
- Apple notarization / Windows Authenticode
- **`node/scripts/install.sh` (B11)** — see exclusion below
- Any path with **no** named job/test on that OS

**Doctor IPC-up alone ≠ Proven for send / CLI ready.** `ash doctor` printing `daemon_state: up` (or a socket/pipe existing) does **not** make the terminal path Proven. CLI / terminal ready requires **install → doctor → send** (or green `ash_menu_smoke` on that OS, or green `ash_doctor_send_smoke.ps1` on Windows). Doctor must also show **identity** and **`messaging_path` / `serverless_rvn1`**, not merely IPC up.

---

## CLI / terminal-ready gate (SRE Perf)

| Claim | Required evidence on that OS | Not enough |
|-------|------------------------------|------------|
| Queue / protocol reliability | Named `reliability.rs` / `reliability_10k` / `bridge_v1` green | Doctor, `ash --help`, wine PE check |
| **CLI / terminal-path Proven** | Named CI step: `ash_menu_smoke.sh` (Unix; CLI DX #16) **or** `ash_doctor_send_smoke.ps1` (Windows; this PR) exercising **init → doctor (identity + messaging_path) → send teach or fail-closed send** | Doctor IPC-up; `ash --help`; matrix_20 wine/lima |
| `terminal-path Proven (Windows)` | Green `rust-windows` step running `node/scripts/ash_doctor_send_smoke.ps1` on MSVC `ash.exe` | matrix_20 `14_windows_ash` wine / PE substitute |

Until the named step is green **on `main`**, label the row **proposed / in-flight**, not Proven.

---

## B11 — `node/scripts/install.sh` is non-evidence (Blocked)

**Do not cite [`node/scripts/install.sh`](../../../node/scripts/install.sh) as Proven or as an install path for reliability claims.**

Facts in tree:

- Header curl URL and `REPO=` clone **Ahmadreza-Arezehgar/RAVEN** (wrong remote for Raven-ASHCO)
- `cargo build … --features raven-node/unsafe-demo-crypto` (debug lab crypto; Linux CI’s `release crypto feature gate` forbids that feature in **release**)

SRE Perf: **CI / evidence exclusion**. CLI DX owns operator-doc relabel.

Prefer install helpers under [`node/scripts/install/`](../../../node/scripts/install/) when those are what docs actually endorse:

| Script | What CI does today (current `main` / this branch before merge) |
|--------|----------------------------------------------------------------|
| `linux_systemd_user.sh` | **Not** a `rust-linux` step |
| `macos_launchd.sh` | **Not** a `rust-macos` step |
| `windows_service.ps1` | `rust-windows` **parse-only** (`Parser::ParseFile`) — syntax, not install→doctor→send |

Parse-only or an unchecked helper is **not** terminal-path Proven.

---

## Per-OS CI evidence

Two columns: **current `main`** (workflow as investigated; `origin/main` at write time still matches the job bodies below) vs **this PR’s intended bar**. “Proposed” becomes Proven only after the named step is green on `main`.

`cargo test -p raven-core` (no `--ignored`) **does** run `reliability.rs`, `bridge_v1`, and `network_sim_1000` because those tests are not `#[ignore]`. `reliability_10k` is `#[ignore]` and runs **only** when a step passes `--ignored`.

### Linux — job `rust-linux` / **Rust + vectors (Linux)**

| Gate | Current `main` | This PR |
|------|----------------|---------|
| `reliability.rs` (via `cargo test -p raven-core`) | Yes | Unchanged |
| Named `reliability_10k --ignored` | Yes — step `10,000-message queue reliability gate` | Unchanged |
| Named `bridge_v1` (+ `fuzz_smoke`) | Yes — step `bridge + fuzz smoke` | Unchanged |
| Named `network_sim_1000` debug + release | Yes | Unchanged |
| `lan_` KATs | Yes | Unchanged |
| `lan_direct_two_node.sh` | Yes | Unchanged |
| `libp2p_swarm_smoke.sh` / `bootstrap_manual_peer_smoke.sh` | Yes | Unchanged |
| Mailbox smokes (`mailbox_opaque_smoke.sh`, `swarm_mailbox_smoke.sh`) | Yes | Unchanged |
| `internet_dial_smoke.sh` (legacy path **fail-closed**) | Yes | Unchanged |
| Experimental mailbox/NAT binaries + security-hold | Yes | Unchanged |
| `ash_menu_smoke.sh` | **No** | **No** — CLI DX PR #16 / follow-up |
| `reliability_matrix_20.sh` | **Not in CI** | **Not in CI** |

### macOS — job `rust-macos` / **Rust (macOS)**

| Gate | Current `main` | This PR |
|------|----------------|---------|
| `cargo test -p raven-core -p ash -p raven-node` (includes `reliability.rs`, `bridge_v1`, `network_sim_1000`) | Yes | Unchanged |
| `lan_` KATs | Yes | Unchanged |
| Named `reliability_10k --ignored` | **No** | **Proposed** — new step |
| Named `bridge_v1` | **No** dedicated step (covered only inside the umbrella `cargo test`) | **Proposed** — new named step |
| Named `network_sim_1000` debug+release | **No** dedicated step (debug sim already inside umbrella `cargo test`) | Not added (already in `cargo test`; Linux keeps the extra release pass) |
| `lan_direct_two_node.sh` | **No** | **No** |
| Mailbox / `internet_dial_smoke.sh` | **No** | **No** |
| Swarm + bootstrap bash smokes | Yes | Unchanged |
| `ash_menu_smoke.sh` | **No** | **No** — CLI DX PR #16 / follow-up |

`network_sim_1000` is a deterministic virtual-time model (harvest wall ~0.5 s debug on Linux). It is **not** skipped here for heaviness; a second named macOS/Windows invocation is omitted because the umbrella `cargo test -p raven-core` already executes it. That umbrella is **not** a substitute for naming `reliability_10k` (ignored) or a dedicated `bridge_v1` step.

### Windows — job `rust-windows` / **Rust (Windows)**

| Gate | Current `main` | This PR |
|------|----------------|---------|
| `cargo test -p raven-core -p ash -p raven-node` (includes `reliability.rs`, `bridge_v1`, `network_sim_1000`) | Yes | Unchanged |
| Named `reliability_10k --ignored` | **No** | **Proposed** — new step (cargo, not bash) |
| Named `bridge_v1` | **No** dedicated step | **Proposed** — new named cargo step |
| Bash smokes (swarm / bootstrap / mailbox / internet / lan_direct / `ash_menu_smoke`) | **No** | **No** — do not add |
| `windows_service.ps1` | Parse-only | Unchanged (not terminal-path Proven) |
| `ash_doctor_send_smoke.ps1` | **No** | **Proposed** — new pwsh step; fail loud if `ash.exe` missing |
| matrix_20 wine `ash --help` | Not CI | Never Windows Proven |

Windows cargo steps use the job default shell (not bash). No `|| true` on the new smoke.

---

## Artifact map

| Artifact | Role | CI |
|----------|------|----|
| [`node/crates/raven-core/tests/reliability.rs`](../../../node/crates/raven-core/tests/reliability.rs) | Restart mid-queue → Delivered; inbound dedup; malformed/truncated `Envelope::unpack` must not panic; OOO message_ids dedup independently | Via `cargo test -p raven-core` on `rust-linux`, `rust-macos`, `rust-windows` |
| [`node/crates/raven-core/tests/reliability_10k.rs`](../../../node/crates/raven-core/tests/reliability_10k.rs) | Ignored 10k enqueue / dedup / Delivered | Named on `rust-linux` today; **this PR** adds the same named command on `rust-macos` and `rust-windows` |
| [`node/scripts/reliability_10k.sh`](../../../node/scripts/reliability_10k.sh) | Operator wrapper; without `RAVEN_RELIABILITY_10K=1` runs a 1k `fuzz_smoke` subset instead of 10k | **Not** a workflow step (CI calls `cargo test … --ignored` directly) |
| [`scripts/reliability_matrix_20.sh`](../../../scripts/reliability_matrix_20.sh) | Looped operator matrix; allows `PASS` / `PASS_SOFTWARE_SUBSTITUTE` / `SKIP` | **NOT in CI.** No pass counts recorded here. |
| [`node/scripts/ash_menu_smoke.sh`](../../../node/scripts/ash_menu_smoke.sh) | Unix install→doctor→menu/send (ephemeral dir, `RAVEN_IDENTITY_BACKEND=locked-file`) | **pending / in-flight** — CLI DX PR #16 / follow-up. Not on current `main`. Not added in this PR. |
| [`node/scripts/ash_doctor_send_smoke.ps1`](../../../node/scripts/ash_doctor_send_smoke.ps1) | Windows init→doctor→send teach / fail-closed (MSVC `ash.exe`) | **This PR** wires `rust-windows`. Intended `terminal-path Proven (Windows)` **after** green on `main`. |
| [`node/scripts/install.sh`](../../../node/scripts/install.sh) | Wrong remote + `unsafe-demo-crypto` debug | **Blocked / non-evidence (B11)** |

No `RELIABILITY_20_GREEN` rate or soak percentage is claimed. `proof_artifacts/` is gitignored; absence is not a pass rate.

---

## Path × OS (honest map)

Software bridge is the strongest automated story. Mesh is sim + (optional) manual. Direct Internet in CI is localhost **fail-closed**, not WAN Proven.

| Path | Linux | macOS | Windows |
|------|-------|-------|---------|
| **Mesh relay** | **Partial** — `network_sim_1000` (named) + `reliability.rs`; `reliability_matrix_20` `02_mesh_relay` is `bridge_v1` cargo (operator, not CI). Not a live multi-hop radio mesh. | **Partial** — sim inside umbrella `cargo test`; no named extra sim step. | **Partial** — same umbrella `cargo test`. No bash mesh smoke. |
| **Bridge** | **Proven (software)** on current `main` via named `bridge_v1` + `lan_direct_two_node.sh`. Not physical BLE. | **Partial** on current `main` (umbrella `cargo test` includes `bridge_v1`). **This PR:** named `bridge_v1` → **proposed Proven (software)** once green on `main`. No `lan_direct` / `bridge_abc` on this job. | **Partial** on current `main`. **This PR:** named `bridge_v1` → **proposed Proven (software)** once green on `main`. No bash bridge demo. |
| **Direct Internet** | **Not WAN Proven.** `internet_dial_smoke.sh` proves legacy `InternetTransport` origination stays **fail-closed** on localhost. Public IP / CGNAT / DCUtR **Blocked**. | **Blocked** for WAN. No `internet_dial_smoke` on `rust-macos`. Swarm smoke is localhost Kad/Noise, not public Internet. | **Blocked** for WAN. No internet smoke. Wine `ash --help` is **Substitute**, not this row. |

**Always Blocked (all OS):** physical BLE, public CGNAT/DCUtR, notarization / Authenticode, any path with no named evidence on that OS.

---

## Windows real path vs wine substitute

| Tier | What it is | What it is not |
|------|------------|----------------|
| **`terminal-path Proven (Windows)`** | Future/this-PR pwsh: `ash.exe init` → `doctor` (identity + `serverless_rvn1`) → send teach or fail-closed send, on an MSVC runner via [`node/scripts/ash_doctor_send_smoke.ps1`](../../../node/scripts/ash_doctor_send_smoke.ps1) | matrix_20 wine, PE self-check, lima, Docker NAT |
| **PASS_SOFTWARE_SUBSTITUTE (Windows)** | `sc_windows_wine` in `reliability_matrix_20.sh` | Never upgrade to terminal-path Proven |

If `target/debug/ash.exe` is missing after `cargo build -p ash`, the smoke **exits 1** with `MSVC ash binary missing — blocked on Windows Platform PR1`. There is **no** silent skip and **no** green path when the binary is absent. `RAVEN_ALLOW_ASH_SMOKE_SKIP` is **not** honored by this script (fail-on-silent-skip).

Do **not** conflate `windows_service.ps1` parse-only with this tier.

---

## Soft budgets

Soft latency / SLO drafts are **not** enforced. Harvest maxima and Queue10kWall times in [`perf-baseline-2026-09-04.md`](perf-baseline-2026-09-04.md) are **not** caps. This evidence bar does not add numeric budgets.

---

## Operator how-to (CLI DX)

<!-- CLI DX: how operators run reliability_matrix_20.sh, first_run, ash_menu_smoke -->

## Doctor / install exit codes (CLI DX)

<!-- CLI DX: ash doctor checks, install script exit codes, fail-closed messaging -->
