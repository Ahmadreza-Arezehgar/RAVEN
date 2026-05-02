# RAVEN for Windows — Context (give this to Claude on first turn)

## What we're building

A native **Windows port of RAVEN**, an end-to-end encrypted mesh messenger
that already ships on iOS (App Store) and macOS (signed DMG). The Windows
build is intentionally a **lightweight client + full mesh node**:

| Surface | Status |
|---|---|
| Feed (Echo Wall posts) | UI built, needs server hookup |
| DMs | UI built, needs recipient picker + login |
| Group chats | Backend complete, UI not built |
| Audio rooms / RavenShot / Vault | OUT OF SCOPE for Windows |

The non-negotiable requirement is **mesh interop** with iPhone and Mac:
the same room with all three platforms must form one mesh, with full
support for **direct mesh** (peer-to-peer BLE), **multi-hop relay**
(forwarding encrypted envelopes you can't read), and **online bridge**
(uplifting offline-mesh envelopes to the server when online).

## The core promise

**Security stays the same regardless of transport.** Whether a message
goes via the server, direct BLE, or a 5-hop bridge, it's E2E encrypted
with X25519 + AES-256-GCM and signed with Ed25519. The relay never sees
plaintext.

## What's already done (don't redo)

- **All Windows code** — 5500+ lines, .NET 8 + WinUI 3, lives in
  `RAVEN-Windows/`. Pushed to private GitHub at commit `69a475f`.
- **Wire protocol spec** — `docs/MESH_PROTOCOL.md` is the single source
  of truth. **DO NOT** deviate from it without bumping
  `MeshConstants.ProtocolVersion` to 2 and updating iOS in lockstep.
- **15/15 unit tests pass** under `cd RAVEN-Windows/tests && dotnet test`
  on macOS — verifying byte-equality of crypto and signing data.
- **Server bridge endpoint** — `server/routers/mesh.py` (NOT deployed yet).
- **iOS test vector twin** — `ios-native/RAVEN/RAVENTests/MeshInteropVectorsTests.swift`
  documents the byte-equal expected outputs for every operation.

## What we're working on RIGHT NOW

You (this Claude session, on Windows) need to do **M1 first, then M2,
then M3** from `RAVEN-Windows/HANDOFF.md`:

### M1 — First successful compile on Windows

```powershell
cd RAVEN-Windows
dotnet restore
dotnet build RAVEN.Windows.sln -c Debug
```

Likely issues to expect (all listed in HANDOFF.md §"Likely first-build
issues"):
1. UserControl namespace not found in MainWindow.xaml
2. DI bootstrap deadlock from `.GetAwaiter().GetResult()` on UI thread
3. `x:Bind` glitches on ItemsRepeater
4. NotifyIcon needs `Application.EnableVisualStyles()`

Fix them. Re-run `dotnet test` after every fix and verify **15/15 still
pass**.

### M2 — App launches

```powershell
cd src
dotnet run -c Debug
```

Expected: window opens, sidebar (Feed / Messages / Account) works, mesh
status pill says "Mesh idle".

### M3 — Discovery with iPhone

iPhone with RAVEN v1.5 nearby; Windows app open. Account view "Peers
nearby" should go 0 → 1 within 30s.

**Likely blocker — iOS-side fix needed:** iOS only reads BLE LocalName,
but Windows publishes its fingerprint in ServiceData. There's a documented
~10-line fix for `ios-native/RAVEN/RAVEN/Core/Mesh/BLEMeshEngine.swift`
around line 2447 — the exact patch is in HANDOFF.md §M3.

## Hard rules

1. **Wire protocol is LOCKED.** Any change = coordinated v2 across iOS,
   Mac, Windows, AND `docs/MESH_PROTOCOL.md`. If you can't do all four,
   don't change anything.
2. **No secrets in the repo.** Repo is private but assume any commit could
   leak. Run a secret-scan before pushing (look for AWS keys, GCP keys,
   `.p8`, JWT secrets, hardcoded passwords).
3. **All Windows-specific UI/glue goes in `RAVEN-Windows/` only.** Don't
   touch iOS or Mac files unless fixing a documented interop bug.
4. **Tests stay green.** `dotnet test` must report 15/15 after every
   change to crypto/envelope/router code.
5. **Commit messages explain the why.** Future-you (next session, possibly
   on a different machine) needs to understand the reasoning.

## Where to look for context

- `RAVEN-Windows/HANDOFF.md` — full handoff doc with all 7 milestones
- `docs/MESH_PROTOCOL.md` — wire protocol spec
- `RAVEN-Windows/README.md` — project overview + scope
- `ios-native/RAVEN/RAVEN/Core/Mesh/BLEMeshEngine.swift` — iOS reference
  implementation (do not modify casually)

## When in doubt

Ask the user. Specifically don't:
- Change the wire protocol unilaterally
- Add features outside the Windows scope (no audio rooms, no RavenShot, no Vault)
- Push secrets
- Refactor things that already pass tests

Do:
- Fix Windows-specific bugs
- Add UI screens (login, recipient picker, group create/manage) when
  user asks
- Surface real problems honestly (don't paper over BLE failures)
- Update HANDOFF.md as milestones complete so the next session knows where things stand
