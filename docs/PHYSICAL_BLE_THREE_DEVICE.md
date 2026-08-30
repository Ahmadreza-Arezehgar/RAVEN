# Physical BLE three-device proof (operator)

**Status:** `BLOCKED_IMPLEMENTATION_AND_HARDWARE`. The current desktop
`--ble-listen` carrier is `mock_ble` over loopback TCP, not CoreBluetooth or
BlueZ GATT, so desktop B cannot exchange frames with physical iOS/Android C.
Fresh Linux Release identity creation is also held, and the macOS service has
the separate-executable Keychain handoff hold. Three devices alone cannot make
this proof pass today.

## Future acceptance topology (not currently executable)

```
Phone A (Internet/LAN capable) ──LAN/TCP──► Bridge B (Mac/Linux raven-node) ──BLE──► Phone C (BLE-only / airplane+BT)
```

- **A** = terminal `ash` + `raven-node` *or* iOS with `FeatureFlag.ravenEnvelopeV1` ON  
- **B** = future always-on bridge with an approved physical GATT carrier and
  protected service identity — **must never decrypt**
- **C** = iOS/Android mesh client receiving opaque `RVN1` over GATT

Port 7422 is the authenticated bridge pull carrier; it is not BLE and opening
it in a firewall does not bypass pinned-contact mutual authentication. A future
physical proof additionally needs a production GATT implementation and route
construction/discovery from A through B to C. The removed loopback command was
only a mock rehearsal and could never satisfy this physical topology.

## Future iOS A / C procedure (after implementation gates clear)

1. Build `ios-native/RAVEN` with `FeatureFlag.ravenEnvelopeV1 = true`.
2. Pair A↔C via QR / Soft Unique Tag verify (friendship plane — not FastAPI).
3. On C: enable Airplane Mode, leave Bluetooth ON.
4. On A: send text 1:1; confirm Outbox → then Delivered after B carries.
5. Reverse: C sends over BLE → B → A Internet path.
6. Confirm: identical `message_id` in diagnostics; no duplicate UI rows; B logs show forward only (no plaintext).

## Future pass criteria (human checklist)

- [ ] No FastAPI / central inbox involved (`ash doctor` → `serverless_rvn1`)
- [ ] B cannot show plaintext of either direction
- [ ] ACK → Delivered on sender after C decrypts
- [ ] Duplicate suppression if A retries same mid
- [ ] Record screen + `ash status` / bridge status JSON (redact pubs if sharing publicly)

## Current software rehearsal

```bash
bash node/scripts/bridge_abc_demo.sh
# → ALL BRIDGE A-B-C CHECKS PASSED
```

This proves only opaque custody/forwarding over the mock carrier. It is not
physical BLE evidence and does not clear the GATT, protected-service-identity,
route-construction, or three-device gates.
