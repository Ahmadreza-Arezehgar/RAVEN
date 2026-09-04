# Ticket draft: Minimal cross-OS bridge proof matrix (`bridge_v1` + `bridge_abc`/smoke)

**Status:** **DESIGN ONLY** — no implementation until Manager batches  
**Risk class if later implemented:** R1–R2 (CI / test wiring; not this PR)  
**Governance parent:** [`../terminal-path-reliability.md`](../terminal-path-reliability.md)  
**Evidence tiers:** [`../reliability-evidence-bar.md`](../reliability-evidence-bar.md)

> This file is a **ticket draft**. It must not be read as a workflow change, a green CI claim, or an assigned sprint commitment. **This PR does not implement any of the work below.**

---

## Goal

Produce **linux + macos + windows** CI evidence for the **Bridge** path under the honest bar in the parent one-pager:

- Delivered + ACK + dedup + opaque on a **named** Bridge step
- **≥2 OS** minimum toward a full 3-OS matrix (Linux already has a named `bridge_v1` on current `main`)
- Fail-loud; **no silent skip**

Do not label macOS or Windows Bridge **Proven (software)** until the named step is **green on `main`**. [PR #26](https://github.com/Raven-ASHCO/RAVEN/pull/26) already **proposes** named `bridge_v1` on `rust-macos` / `rust-windows` — treat that as in-flight, not done.

---

## In scope

- Wire or extend **`cargo test -p raven-core --test bridge_v1`** as a **named** step on each of `rust-linux` (already named on `main`), `rust-macos`, and `rust-windows` (Windows: cargo / default shell, not bash).
- And/or a **minimal `bridge_abc`-equivalent smoke** per OS that can fail-loud (A–B–C software / mock_ble-over-TCP; same opacity rules as [`node/scripts/bridge_abc_demo.sh`](../../../../node/scripts/bridge_abc_demo.sh)).
- Exit non-zero if the binary or runner prerequisite is missing. No `|| true`. Do not honor skip flags that turn absence into green.
- Keep Proven labeling with **#19 SRE Perf** (consult) so software Bridge is not confused with physical BLE.

## Out of scope (explicit)

| Not in this ticket | Why |
|--------------------|-----|
| Circuit Relay two-client integration | Separate network/relay track; not Bridge software proof |
| Mesh-physical BLE pretenses | [`MESH_TEST_SCENARIOS.md`](../../../../MESH_TEST_SCENARIOS.md) and [`docs/PHYSICAL_BLE_THREE_DEVICE.md`](../../../PHYSICAL_BLE_THREE_DEVICE.md) stay `BLOCKED_HARDWARE` / manual |
| WAN / DCUtR claims | Direct Internet remains localhost fail-closed (`internet_dial_smoke`); public CGNAT/DCUtR stay Blocked |
| Soft soak fail-rate / SLO numbers | Forbidden until a real snapshot (founder harvest rule / [`../perf-baseline-2026-09-04.md`](../perf-baseline-2026-09-04.md)) |
| Relabeling B11 `install.sh` or B12 Win loopback as Proven | Locked exclusions in the evidence bar |
| Implementing the matrix in the same PR as this draft | Manager batches implementation separately |

---

## Proposed owners (Sprint 0 assignment titles)

[`org-structure.md`](../org-structure.md) still uses freeze titles. Batch against the Sprint 0 names below.

| Role | Sprint 0 title | Why this ticket |
|------|----------------|-----------------|
| **#6** | P2P Network | libp2p / swarm adjacency **if any** (localhost swarm must not be sold as Bridge Proven) |
| **#7** | DTN Forward | `forward_queue` / store-carry semantics on the A–B–C path |
| **#12** | CLI DX | `ash` / operator smoke surfaces and exit codes (fail-loud; doctor axes stay distinct) |
| **#20** | DevSecOps | CI workflow / required checks on `raven-serverless.yml` jobs |
| **#19** | SRE Perf | Evidence bar / **Proven** labeling — **consult** (does not implement CI in this draft) |

Manager decides the implementation batch and primary assignee. Do not start workflow edits from this ticket text alone.

---

## Suggested evidence (when implementation is batched)

Copy from the evidence bar; do not invent extra gates:

1. Named `bridge_v1` green on **at least two** of `{rust-linux, rust-macos, rust-windows}`.
2. Optional: a minimal `bridge_abc` smoke **only** where the OS can run it without silent skip (Linux/macOS bash; Windows needs a pwsh/cargo equivalent — do not add bash smokes to `rust-windows`).
3. Cite the Actions run ID (or the merge to `main`) before anyone writes **Proven (software)** on that OS.
4. Still **not** physical BLE, **not** WAN.

---

## Acceptance (later implementation PR — not this file)

- [ ] Named Bridge step exists on ≥2 OS jobs and is required or otherwise fail-loud
- [ ] No silent skip / no green-on-missing-binary
- [ ] Evidence bar Path × OS table updated **after** green on `main` (not before)
- [ ] Out-of-scope rows still Blocked
