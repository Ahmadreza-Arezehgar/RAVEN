# ATSAM KAT consumer matrix V1

**Scope:** every file under `shared-vectors/rvn1/atsam/**` on `main` (38 files: 37 JSON + `negative/`).  
**Sprint 0:** Crypto ATSAM Role #3 companion to [`ATSAM_THREAT_ASSUMPTIONS_V1.md`](ATSAM_THREAT_ASSUMPTIONS_V1.md).  
**Rust first.** Swift is **OFF-MAIN** on every row (`ios-native/` absent; cited SoT not in this tree). Feature-branch Swift claims are **unverified-from-main**.  
**Date:** 2026-09-04

### Status legend

| Mark | Meaning |
|------|---------|
| **run** | Loads the vector and executes the matching KDF / codec / AEAD / state check |
| **partial** | Generator twin, hardcoded lock, injected-share oracle, or order/schema subset only |
| **schema** | JSON shape / lengths / layout; no cryptographic oracle |
| **missing** | No `main` consumer found for that language |
| **OFF-MAIN** | Swift tree not on `main`; do not treat mapping-doc paths as evidence |

Python **never Encaps/Decaps** ML-KEM. Where Python “runs” PairInit / HR v2, shares are **injected**. That is not a seal oracle and MUST NOT be used to originate confidential traffic.

---

## 1. Portable KDF / RVNA1 / indexed-session v1 / PairInit V1

| Vector file | Profile / area | Rust consumer | Python consumer | Swift consumer | Notes |
|-------------|----------------|---------------|-----------------|----------------|-------|
| `chain_kdf_001.json` | Indexed / RVNA1 v2 chain HKDF | **run** — `vectors.rs` + `atsam_kdf` | **partial** — written by `generate_rvn1.py`; no dedicated pytest load | **OFF-MAIN** | Known `K_root`; no ML-KEM |
| `root_hkdf_001.json` | PairInit V1 combiner HKDF | **partial** — `atsam_root` hardcoded lock matches generator; JSON not loaded | **partial** — `generate_rvn1.py` cryptographic write; no dedicated pytest | **OFF-MAIN** (`ATSAMRootDerivation` cited) | `ikm = Z_X‖Z_PQ`; no Encaps |
| `rvna1_header_layouts_001.json` | RVNA1 classify / proto | **run** — `vectors.rs` + `seal::parse_rvna1_header` | **partial** — generator only | **OFF-MAIN** | Includes interim-stub class |
| `rvna1_v2_aead_known_root_001.json` | RVNA1 proto `0x02` AEAD | **run** — `vectors.rs` + `atsam_aead` | **partial** — generator AEAD; no dedicated pytest | **OFF-MAIN** (`ATSAMMessageSealer`) | Known root; proto `0x02` ≠ indexed `0x03` |
| `indexed_session_v1_subkeys_001.json` | `ATSAM/indexed-session/v1` lanes | **run** — `vectors.rs` + `atsam_indexed_session` | **partial** — `indexed_session.py` helpers + generator; pytest does not load JSON | **OFF-MAIN** | Production disabled; ACK/route **subset** of key tree only |
| `indexed_session_v1_sealed_ack_001.json` | Indexed proto `0x03` sealed ACK | **run** — `vectors.rs` + `atsam_indexed_session` | **partial** — `test_indexed_session.py` helper crypto; JSON not loaded | **OFF-MAIN** | 101-byte plaintext / 143-byte wire |
| `pair_init_v1_001.json` | PairInit V1 codec + provisional root | **run** — `pair_init.rs` | **run** — `test_pair_init.py` (injected `z_x`/`z_pq`) | **OFF-MAIN** (`ATSAMPairInitV1.swift` cited) | No Python Encaps; production disabled |

`tests/adversarial_atsam.rs` exercises `atsam_aead` / `atsam_indexed_session` / `atsam_root` / HR v2 EC-DR **attacks**, not these JSON files.

---

## 2. Hybrid pairing and lab incremental ML-KEM

| Vector file | Profile / area | Rust consumer | Python consumer | Swift consumer | Notes |
|-------------|----------------|---------------|-----------------|----------------|-------|
| `mlkem768_hybrid_kat_001.json` | ML-KEM-768 + X25519 hybrid KAT | **run** — `atsam_mlkem` (`ml-kem` 0.3 hazmat) | **schema / missing Encaps oracle** — integrity-pinned copy in `generate_rvn1.py`; HR v2 injects frozen `z_pq` | **OFF-MAIN** (comments cite CryptoKit 26+ `ATSAMMlKemHybridKatTests`) | Python cannot Encaps/Decaps. Unverified-from-main Swift CT interop. |
| `mlkem768_incremental_encaps_001.json` | Incremental Encaps1/2 | **run** (lab) — `mlkem768_incremental.rs` + `libcrux-ml-kem` behind `mlkem768-incremental-lab` | **schema** — `mlkem768_incremental_check.py` / `test_mlkem768_incremental_check.py` (no live ML-KEM) | **OFF-MAIN** | **`lab_only`.** `dk_hex` must not ship to production clients. |

---

## 3. Hybrid Ratchet V2 (sealed proto `0x04`)

| Vector file | Profile / area | Rust consumer | Python consumer | Swift consumer | Notes |
|-------------|----------------|---------------|-----------------|----------------|-------|
| `pair_init_v2_001.json` | PairInit V2 wire + expand | **run** — `hybrid_ratchet_v2.rs` | **run** — `test_hybrid_ratchet_v2.py` (injected shares) | **OFF-MAIN** | Profile `ATSAM/hybrid-ratchet/v2`; not V1 |
| `negative/pair_init_v1_as_v2_001.json` | V1 ≠ V2 | **run** — `hybrid_ratchet_v2::reject_if_pair_init_v1` | **run** — `test_pair_init_v1_rejected_as_v2` | **OFF-MAIN** | Sole combiner/profile negative in-tree |
| `tr_domain_labels_001.json` | Domain / `SEALED_PROTO=0x04` | **run** — `hybrid_ratchet_v2.rs` | **run** | **OFF-MAIN** | |
| `tr_ec_kdf_001.json` | `KDF_RK` / `KDF_CK` | **run** — `hybrid_ratchet_v2.rs` | **run** | **OFF-MAIN** | |
| `tr_scka_init_001.json` | Role-separated SCKA init | **run** — `hybrid_ratchet_v2.rs` | **run** | **OFF-MAIN** | |
| `tr_hybrid_aead_001.json` | `KDF_HYBRID` + AEAD | **run** — `hybrid_ratchet_v2.rs` | **run** | **OFF-MAIN** | Injected EC/PQ message keys |
| `tr_ackv2_001.json` | AckV2 + object digest | **missing** | **run** — `test_ackv2` | **OFF-MAIN** | Frozen in spec §13; no Rust filename load |
| `tr_candidate_fail_001.json` | Candidate AEAD fail-closed | **missing** | **run** — `test_candidate_fail_and_crash_order` | **OFF-MAIN** | Rust gap vs spec “frozen” |
| `tr_crash_ack_cas_001.json` | PENDING_ACK_SEND before CAS | **missing** | **partial** — step-order asserts only | **OFF-MAIN** | KAT only; not durable crash proof |
| `tr_crash_receive_commit_001.json` | Receive-commit machine | **run** — `hybrid_ratchet_v2_state.rs` `crash_machines` | **run** — `test_hybrid_ratchet_v2_state.py` | **OFF-MAIN** | Ordering; not store restart |
| `tr_crash_skipped_persist_001.json` | Skipped-key persist order | **run** — same | **run** | **OFF-MAIN** | Same limit |
| `tr_crash_epoch_promote_001.json` | Epoch promote order | **run** — same | **run** | **OFF-MAIN** | Same limit |
| `tr_braid_epoch_001.json` | SCKA promote (injected ss) | **run** — `hybrid_ratchet_v2_state.rs` | **run** | **OFF-MAIN** | Partial vs full KEM path |
| `tr_ec_ooo_001.json` | Same-chain OOO | **run** — `hybrid_ratchet_v2_state.rs` | **run** | **OFF-MAIN** | |
| `tr_ec_dh_ratchet_001.json` | EC DH + skip + all-zero reject | **run** — `hybrid_ratchet_v2_tr.rs` | **run** | **OFF-MAIN** | |
| `tr_braid_kem_chunk_001.json` | Braid chunk + KAT `z_pq` | **run** — `hybrid_ratchet_v2_tr.rs` | **run** | **OFF-MAIN** | Not full Signal Encaps1/2 + erasure |
| `tr_braid_codec_negatives_001.json` | Strict braid wire | **run** — `hybrid_ratchet_v2_tr.rs` | **run** | **OFF-MAIN** | |
| `tr_combo_multi_001.json` | ≥2 DH + ≥2 SCKA | **run** — `hybrid_ratchet_v2_tr.rs` | **run** | **OFF-MAIN** | Partial vs full Signal Braid |
| `tr_skip_boundary_001.json` | Skip window | **run** — `hybrid_ratchet_v2_state.rs` | **run** | **OFF-MAIN** | |
| `tr_replay_duplicate_001.json` | Replay / duplicate | **run** — `hybrid_ratchet_v2_state.rs` | **run** | **OFF-MAIN** | |
| `tr_tamper_candidate_001.json` | Tamper candidate decrypt | **run** — `hybrid_ratchet_v2_state.rs` | **run** | **OFF-MAIN** | |
| `tr_route_mailbox_001.json` | Route / mailbox catch-up | **run** — `hybrid_ratchet_v2_state.rs` | **run** | **OFF-MAIN** | Tags ≠ confidentiality |

---

## 4. Full Braid (lab)

| Vector file | Profile / area | Rust consumer | Python consumer | Swift consumer | Notes |
|-------------|----------------|---------------|-----------------|----------------|-------|
| `full_braid_digests_001.json` | Binding digests | **run** — `hybrid_ratchet_v2_full_braid/full_braid_vectors.rs` | **run** — `test_full_braid.py` | **OFF-MAIN** | `full-braid-lab` |
| `full_braid_send_receive_round_001.json` | Send/receive round | **run** — same | **run** | **OFF-MAIN** | |
| `full_braid_wire_negatives_001.json` | Wire reject | **run** — same | **run** | **OFF-MAIN** | |
| `full_braid_rvbe1_negatives_001.json` | RVBE1 reject | **run** — same | **run** | **OFF-MAIN** | |
| `full_braid_sm_round_001.json` | State-machine round | **run** — `full_braid_vectors.rs` + `exit_matrix.rs` | **run** (Python computes; oracle fixture) | **OFF-MAIN** | |
| `full_braid_full_exchange_2pq_2dh_001.json` | 2 PQ + 2 DH exchange | **run** — `full_braid_vectors.rs` + `transition.rs` | **run** | **OFF-MAIN** | Incremental KEM via lab backend / oracles |
| `full_braid_protected_anchor_001.json` | Protected anchor | **run** — `full_braid_durable_lab/protected_anchor.rs` | **run** — `test_full_braid_protected_anchor.py` | **OFF-MAIN** | Durable-lab feature |

---

## 5. Cross-cutting gaps (no file, or not covered by the files above)

| Gap | Reality on `main` |
|-----|-------------------|
| **Combiner negatives** | No vector for truncated IKM, swapped halves, omitted `Z_PQ`/`Z_X`, or info-domain mix-up. Only `negative/pair_init_v1_as_v2_001.json` exists under `atsam/negative/`. |
| **CT / side-channel** | No constant-time or cache/timing KATs in `atsam/**`. |
| **Noise RVNH1** | Mapping honesty table: **none** in `shared-vectors/rvn1/`. Handshake remains unvectored. |
| **Indexed crash beyond `tr_crash_*`** | `tr_crash_*` are HR v2 **ordering** machines, not indexed-session durable restart. Errata still requires crash-safe indexed persistence; those vectors are absent. |
| **Key tree beyond indexed subset** | BBE / Ghost Handshake / PV-Stealth / PV seed still lack committed KATs (`ATSAM_PRIMITIVE_MAPPING_V1.md` §2, §5). |
| **NIST FIPS 203 CAVP pack** | Absent. Software KATs are Raven-authored (`ml-kem` / lab libcrux), not the NIST ACVP/FIPS pack. |
| **Rust missing HR v2 rows** | `tr_ackv2_001`, `tr_candidate_fail_001`, `tr_crash_ack_cas_001` have no Rust filename consumer. |
| **Swift** | Entire column OFF-MAIN. Do not cite `ios-native/...` as a passing consumer. |

File count check: 7 (portable/V1) + 2 (hybrid/lab) + 22 (HR v2 including `negative/`) + 7 (full braid) = **38**.
