# iOS ↔ Terminal LAN lab checklist (Phase A2 manual order)

**Lab-gated only.** Never enable Release / production flags. Use Debug unlock via `RAVEN_LAB_TEST_A=1`, launch argument `-ravenLabTestA`, or Settings → Lab Test A toggle. `ATSAMLabGate.productionEnabled` stays **false** in Release builds.

Secure LAN must **never** fall back to `RavenServerlessLanPath`. The iPhone secure listener is **foreground-only** (app active / lab screen visible); background LAN is out of scope.

**A2 is NOT complete** until bidirectional live Terminal↔iPhone rows below are PASS. Automated memory-duplex tests do not substitute for live proof.

---

## Task 17 A2 gate (automated + live)

### Automated (Mac / simulator — no physical phone)

Run: `./node/scripts/ios_lan_a2_live_gate.sh`

| Gate | What it proves |
|------|----------------|
| `cargo test -p raven-core --lib lan_` | Rust Noise/RLB1 vectors |
| `lan_direct_two_node.sh` | Terminal two-node secure dial (Mac-only) |
| `ios_lan_kat.sh` | iOS Noise + RLB1 KAT + Release lab gate |
| `RavenSecureLanLoopbackIntegrationTests` | Memory duplex Noise+RLB1+contact gate |
| `RavenSecureLanA2GateTests` | Bidirectional duplex, duplicate, delete, block, PairInit/PairResponse retry bytes, legacy-path grep |

### Live operator gate (physical iPhone + Mac Terminal)

Mark each PASS/FAIL after `./node/scripts/ios_lan_a2_live_gate.sh` automated prerequisites are green.

| # | Requirement | Checklist ref | Live |
|---|-------------|---------------|------|
| 1 | Terminal → iPhone: PairInit, indexed message, sealed ACK | §2, §3 | [ ] |
| 2 | iPhone → Terminal: reverse | §2, §3 | [ ] |
| 3 | Kill/relaunch iPhone; session continues | §4 | [ ] |
| 4 | ACK loss + PairResponse loss; retry **exact same bytes** | §4 | [ ] |
| 5 | Duplicate frame → identical ACK; no second decrypt | §4 | [ ] |
| 6 | Contact delete → refuse message/ACK/PairInit | §5 | [ ] |
| 7 | Block peer → refuse | §6 | [ ] |
| 8 | Revoke/expiry → fail-closed abandon | §6 | [ ] |
| 9 | No raw/RVNP1/interim fallback on secure entrypoints | §2 | [ ] |

**A2 COMPLETE:** YES only when live rows 1–9 are PASS. Otherwise **A2 NOT COMPLETE**.

Required live env:

- `RAVEN_LAB_TEST_A=1` (or `-ravenLabTestA` / Settings toggle)
- Mac `contacts.json` `pub_hex` = iPhone **device_ed_pub** (not user key)
- iPhone foreground on Serverless LAN; listen port saved (default 7421)
- Device-pub bootstrap (§0) done before PairInit

---

## Deterministic CI (no live network)

These run in `.github/workflows/raven-serverless.yml` and do **not** substitute for the manual steps below.

| Gate | Command / test |
|------|----------------|
| Rust LAN vectors | `cd node && cargo test -p raven-core --lib lan_` |
| iOS Noise + RLB1 KAT | `RavenSecureLanNoiseTests`, `RavenSecureLanRlb1Tests` |
| Release lab gate | `ATSAMLabGateReleaseVerificationTests` (Release config only) |
| Local iOS bundle | `./node/scripts/ios_lan_kat.sh` |
| Shared fixtures | `shared-vectors/rvn1/lan/{noise_static,noise_bind,noise_xx_handshake,rlb1_offer}_001.json` |

---

## Design §11 manual order (items 1–10)

| §11 | Checklist section |
|-----|-------------------|
| 1 | §0 device-pub bootstrap + §1 listener + §2 PairInit both directions |
| 2 | §3 indexed message + ACK both directions |
| 3 | §4 kill iPhone mid-Sent; relaunch; retry/ACK |
| 4 | §4 kill Terminal mid-receive; recover ACK |
| 5 | §4 duplicate frame → identical ACK; no second decrypt |
| 6 | §4 drop PairResponse; same PairInit → cached response |
| 7 | §5 delete contact → refuse message/ACK/PairInit |
| 8 | §6 block peer → refuse |
| 9 | §6 expired session → abandon |
| 10 | §7 background iPhone → do not rely on listener |

---

## 0. Device-pub bootstrap (§6.3.1) — do this first

Noise bind runs **before** RLB1. The initiator cannot learn `cert.device_ed_pub` from the offer on the same connection.

1. On iPhone (Settings → Serverless LAN, Lab Test A ON): tap **Ensure lab cert + prekey**, then **Copy my lab cert JSON**.
2. On Mac Terminal: `ash lab import-peer-cert` (paste iPhone cert JSON).
3. On Mac: copy iPhone **device_ed_pub** into `contacts.json` as `pub_hex` (32-byte hex). **Not** the user Ed25519 when user ≠ device.
4. On Mac: copy Mac lab cert JSON; on iPhone tap **Paste Mac cert JSON from clipboard**.
5. Confirm iPhone shows **Device Ed25519 pub** — that hex is what Mac must store for the iPhone contact.

**Critical:** Terminal `contacts.json` `pub_hex` = iPhone `device_ed_pub`. Storing only the iPhone user key fails Noise bind when keys differ.

---

## 1. macOS raven-node + iPhone lab listener

- [ ] Mac `raven-node` running with LAN direct enabled (lab).
- [ ] iPhone Raven open on Serverless LAN screen (foreground).
- [ ] Save LAN config: Mac host/port + peer pub + listen port (default 7421).
- [ ] Confirm secure listener started (Debug log: `secure listen :7421`).
- [ ] Device pubs provisioned in contacts both sides (step 0).

---

## 2. PairInit both directions

- [ ] Mac → iPhone PairInit completes (contact gate passes).
- [ ] iPhone → Mac PairInit completes.
- [ ] Sessions confirmed; no legacy raw/RVNP1 path used on secure entrypoints.

---

## 3. Indexed message + ACK both directions

- [ ] Mac sends indexed message → iPhone receives and displays.
- [ ] iPhone sends sealed ACK → Mac marks delivered/read.
- [ ] iPhone sends indexed message → Mac receives.
- [ ] Mac sends sealed ACK → iPhone delivery state updates.

---

## 4. Crash / recovery

- [ ] Kill iPhone mid-Sent; relaunch; retry succeeds; ACK eventually delivered.
- [ ] Kill Terminal mid-receive; recover; ACK not lost.
- [ ] Duplicate frame → identical ACK resend; no second decrypt.
- [ ] Drop PairResponse; initiator resends same PairInit; responder returns cached response.

---

## 5. Delete contact → refuse

- [ ] Remove peer from Mac `contacts.json` (or iPhone: clear imported peer cert).
- [ ] Confirm refuse on message, ACK, and PairInit (contact gate fail-closed).

---

## 6. Block / expiry (if configured in lab)

- [ ] Block peer → refuse on secure path.
- [ ] Expired session → abandon; no silent continue.

---

## 7. Foreground-only listener

- [ ] Background iPhone (home button / app switcher) → secure listener stops accepting.
- [ ] Return to foreground → listener resumes on saved listen port (lab gate still open).
- [ ] Do **not** rely on background LAN for Phase A.

---

## 8. Lab unlock reminder

- Debug only: `RAVEN_LAB_TEST_A=1` **or** `-ravenLabTestA` **or** Settings toggle.
- **Never** ship Release with lab gate enabled.
- CI: `ATSAMLabGateReleaseVerificationTests` asserts Release cannot enable secure/ATSAM paths (`productionEnabled` compile-time false).

---

## References

- Design: `docs/superpowers/specs/2026-08-15-phase-a-swift-endpoint-lan-parity-design.md` §6.3.1, §11
- Rust KAT: `node/crates/raven-core/src/lan_vectors.rs` ↔ `shared-vectors/rvn1/lan/`
- iOS KAT script: `node/scripts/ios_lan_kat.sh`
- iOS trust OOB: Settings → Serverless LAN → Test A trust (cert/prekey paste)
- Terminal contacts: `contacts.json` `pub_hex` = peer **device** Ed25519
