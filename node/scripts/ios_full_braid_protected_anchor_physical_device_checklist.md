# Task 0B.2 — Physical iPhone protected-anchor Keychain checklist

Lab-only. Not a production gate. Signed-simulator XCTest covers API/ordering/idempotency/conflict;
this checklist was the physical-device stop-line for Independent Task 0B.2 evidence.

**Ledger status (Rev27):** Task **0B.2 INDEPENDENT PASS** recorded (§37 of the Task 0 execution ledger). Task 0B.3+ remains **NOT AUTHORIZED** without a separate explicit owner order. Production / commit / push / stage remain forbidden.

## Operator harness (required path)

Use the multi-phase physical gate (digests only on host; no inter-phase cleanup; ordered cleanup only after Phase D):

```bash
DEVICE_UDID=<physical-iphone-udid> \
  ./node/scripts/ios_full_braid_protected_anchor_physical_gate.sh
```

Mandatory order (exact predecessor; completed phases not re-runnable): `A → B → C → D → cleanup`.  
`A_RESUME` = same-run exact replay while `last_phase` is A/A_RESUME.  
`recovery_cleanup` only with `RECOVERY_CLEANUP_CONFIRM=YES-DELETE-SCOPED-FULLBRAID-KEYCHAIN`.

Host negatives (no device): `./node/scripts/ios_full_braid_protected_anchor_physical_gate_negatives.sh`  
(`ORDER_CHECK_ONLY=1` path; `last_phase=C`+`PHASE=B` fails before preflight; `ok!=true` refuses write.)

| Phase | Operator action | Harness check |
|---|---|---|
| A | none | clean preflight + **Created** seed + RVFA1 seq1; `run_id`/`device_udid` bound |
| A_RESUME | optional | exact seed/seq1 replay for same run/device |
| B | kill / relaunch | seed+seq1 digests match; append seq2 |
| C | lock / unlock | digests match; no rewrite (Phase-C evidence bundle) |
| D | real BFU **or** frozen hold code only | requires complete Phase-C bundle + same run/device; free-form hold rejected |
| cleanup | after D only | `SynchronizableAny` proves zero seed+anchor items for scope |

Frozen Phase D hold code:
`FULL_BRAID_PHYSICAL_GATE_HOLD_MAIN_APP_CANNOT_RUN_BEFORE_FIRST_UNLOCK_V1`

Swift entry: `ATSAMFullBraidProtectedStorePhysicalGateTests`  
Evidence dir default: `artifacts/full-braid-0b2-physical-gate/` (digests / summary only — never seed bytes)

## Required before claiming device protected-store evidence

- [x] Main app provisioning includes `group.app.raven.fullbraid` (App Group + Keychain access group).
- [x] Extensions / Watch / Catalyst still lack that Keychain access group (expect `errSecMissingEntitlement`).
- [x] Phase A–cleanup completed on a **physical** iPhone via the operator harness above (Independent 0B.2 PASS).
- [x] Phase B kill/relaunch digest match + seq2 append recorded in evidence.
- [x] Phase C lock/unlock digest match / no-rewrite recorded.
- [x] Phase D real BFU (`LOCKED_OR_PROMPT_REQUIRED`) **or** exact frozen platform hold code.
- [x] Release/App Store path still cannot enable Full Braid protected-anchor production (`FULL_BRAID_PROTECTED_ANCHOR_NOT_APPROVED`).

## CI contract

GitHub Actions may assert this file exists and retains the section headers above. It does not execute the device steps.
The operator harness refuses simulator UDIDs.
