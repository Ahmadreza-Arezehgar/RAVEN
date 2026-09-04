# Windows tree gap on `main`

**Status:** Documented gap · no Windows tree bring-up this sprint · WinUI retired prototype · this-phase reliability blocker is the terminal path (named-pipe IPC)  
**As of:** 2026-09-04  
**Sprint 0 source of truth:** `main` (Rust / serverless)

## Governance

Sprint 0 governance source of truth is **`main`**. The live baseline is the Rust node (`node/`), protocol specs (`protocol/`), shared vectors, and serverless CI. A feature branch does not silently hold authority for trees that are not on `main`.

## Founder priority this phase

The real Windows reliability blocker this phase is the **terminal path** (`ash` / `raven-node`), especially **named-pipe IPC absence** — not WinUI.

Windows terminal reliability is elevated **above WinUI for the entire phase**. WinUI / `RAVEN-Windows` remains a retired prototype; do not revive WinUI CI this sprint.

Facts on `main` today:

- `raven-node` IPC server is `#[cfg(unix)]` only (`ipc` / `service` commands and UDS bind; no Windows named-pipe server).
- `ash` has no named-pipe client (non-unix IPC path errors out; framing in `raven-core::ipc` is shared, OS bind is not).
- `ash doctor` / daemon probes are UDS-shaped (`default_socket_path` + UDS ping) → **false-red / no local IPC** while the Task Scheduler bridge (`RavenNodeBridge` / `windows_service.ps1`) may be up.
- MSVC `ash` compile was also blocked (P0 in flight separately; not this note).

This note does not implement those fixes. SoT remains **`main`**. Eng Program **B9** still owns Windows tree landing. The RAVEN-Windows absence / unrelated-history / no-force-merge record below is unchanged.

## Absent trees

As of this note, `RAVEN-Windows/` is **absent on `main`**. Related CODEOWNERS claims that name that tree are also a documented gap — not silent authority of `feature/raven-serverless-v1`.

`main` and `feature/raven-serverless-v1` have **no common ancestor** (unrelated histories). Do **not** force-merge them this sprint.

Windows working trees on `feature/raven-serverless-v1` (`RAVEN-Windows/` WinUI / .NET 8, plus Windows-only workflows) exist for **reference only**, until Eng Program’s B9 landing plan executes.

WinUI / `RAVEN-Windows` is a **retired prototype** for Sprint 0. Do not revive CI for it this sprint.

`node/WINDOWS.md` currently implies the WinUI app “lives under `RAVEN-Windows/`”. That claim is **false on `main`**. This gap note is the corrective governance record.

The Rust terminal path on `main` remains valid source of truth:

- [`docs/INSTALL_Windows.md`](../../INSTALL_Windows.md)
- [`node/INSTALL_Windows.md`](../../../node/INSTALL_Windows.md)
- [`node/WINDOWS.md`](../../../node/WINDOWS.md)
- [`node/scripts/install/WINDOWS_SERVICE.md`](../../../node/scripts/install/WINDOWS_SERVICE.md)
- [`node/scripts/install/windows_service.ps1`](../../../node/scripts/install/windows_service.ps1)
- raven-core DPAPI identity (`node/crates/raven-core/` identity store)

## Inert CODEOWNERS and CI

`.github/CODEOWNERS` already claims:

- `/RAVEN-Windows/` → `@Raven-ASHCO/windows`
- `/**/windows/**` → `@Raven-ASHCO/windows`

Those claims are **inert** until the trees land on `main` — ownership reserved, not silent authority of the feature branch.

The following Windows-only workflows are **absent on `main`** (feature-branch only today) and remain **reference only** until B9 executes:

- `.github/workflows/build-raven-windows.yml`
- `.github/workflows/raven-lab-gates.yml` Full Braid Task 0A Windows

Do **not** revive WinUI CI this sprint.

## Landing plan (Eng Program B9)

Do **not** force-merge unrelated histories this sprint. Eng Program owns landing plan **B9** (Windows tree landing), parallel to Apple B8. Import strategy / subtree / fresh bring-up is TBD by Eng Program before any Windows tree lands on `main`.

## Related debt (out of scope here)

This-phase founder priority (terminal path; **not** this PR — see above):

- named-pipe IPC — **ABSENT** (`raven-node` server `#[cfg(unix)]` only; `ash` has no named-pipe client)
- MSVC `ash` compile — blocked; P0 in flight separately

Priority backlog **after** the B9 landing plan — mention only:

- MSVC CI on `main`
- `protected_anchor` Windows backend — **ABSENT**
- installer / Authenticode

This note does not implement those items. WinUI bring-up is not the this-phase reliability work.
