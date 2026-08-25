# A2 live gate results (operator)

Fill after `./node/scripts/ios_lan_a2_live_gate.sh` shows **AUTOMATED: PASS**.
Do **not** mark A2 complete until all nine rows are PASS on a real iPhone + Mac Terminal on one LAN.

**Automated gate log:** `/tmp/a2_live_gate_full.txt` (latest local run)
**Automated status:** PASS (2026-08-15T18:08Z UTC, EXIT 0, without `SKIP_RUST`)
**iOS production flags:** must remain off (`productionEnabled` compile-false / Release LabGate fail-closed)
**TCP note:** simulator TCP XCTest skip is acceptable **only if** row 1–2 prove real TCP Noise on device.

| # | Scenario | Result | When (local) | Non-sensitive notes / TRACE tags |
|---|----------|--------|--------------|----------------------------------|
| 1 | Terminal → iPhone: PairInit, indexed message, sealed ACK | [ ] PASS [ ] FAIL | | |
| 2 | iPhone → Terminal: reverse PairInit, message, ACK | [ ] PASS [ ] FAIL | | |
| 3 | Kill/relaunch iPhone; session continues; retry/ACK | [ ] PASS [ ] FAIL | | |
| 4 | ACK loss + PairResponse loss; retry exact same bytes | [ ] PASS [ ] FAIL | | |
| 5 | Duplicate frame → identical ACK; no second decrypt | [ ] PASS [ ] FAIL | | |
| 6 | Contact delete → refuse message/ACK/PairInit | [ ] PASS [ ] FAIL | | |
| 7 | Block peer → refuse | [ ] PASS [ ] FAIL | | |
| 8 | Revoke/expiry → fail-closed abandon | [ ] PASS [ ] FAIL | | |
| 9 | No raw/RVNP1/interim fallback on secure path | [ ] PASS [ ] FAIL | | |

**A2 COMPLETE:** NO until rows 1–9 are all PASS.

Operator initials / device: _______________
Mac LAN IP / iPhone listen port: _______________
Lab unlock used (`RAVEN_LAB_TEST_A` / `-ravenLabTestA` / Settings): _______________
