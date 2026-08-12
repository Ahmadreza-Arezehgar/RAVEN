# RAVEN Error Codes V1

**Version:** 1 (`rvn1`)  
**Status:** Binding for IPC, CLI, and transport-mapped failures  
**Companions:** [`RAVEN_TRANSPORT_INTERFACE_V1.md`](RAVEN_TRANSPORT_INTERFACE_V1.md), `raven_core::ipc`

## 1. Rules

- Codes are **stable ASCII identifiers** (`SCREAMING_SNAKE`), not free-form English alone.  
- Messages MUST NOT include seeds, private keys, plaintext bodies, or recovery material.  
- Unknown codes → treat as `INTERNAL` at UI layer; do not crash.

## 2. Code registry

| Code | Class | Meaning |
|------|-------|---------|
| `OK` | success | operation completed |
| `IPC_VERSION` | ipc | peer IPC version mismatch |
| `IPC_AUTH` | ipc | peer-cred / socket auth failed |
| `IPC_FRAME` | ipc | malformed / oversized IPC frame |
| `IPC_FORBIDDEN_FIELD` | ipc | request contained prohibited secret field name |
| `POLICY_DENIED` | policy | local policy forbids bridge/store/relay action |
| `ENVELOPE_MALFORMED` | parse | not a valid RavenEnvelopeV1 |
| `ENVELOPE_BAD_SIG` | crypto | sender_authentication failed |
| `ENVELOPE_EXPIRED` | ttl | expires_at reached |
| `ENVELOPE_REPLAY` | replay | message_id already seen |
| `ENVELOPE_HOP` | routing | hop_limit exhausted |
| `ACK_BAD_SIG` | crypto | ACK signature failed |
| `PEER_UNREACHABLE` | net | dial / send failed |
| `PEER_HELLO` | net | internet hello auth failed |
| `STORE_FULL` | store | capacity / rate limit |
| `STORE_NOT_FOUND` | store | no objects for tag |
| `STORE_FORBIDDEN` | store | retrieval auth failed |
| `PREKEY_EXPIRED` | crypto | prekey bundle expired |
| `PREKEY_BAD_SIG` | crypto | prekey signature failed |
| `BLE_REASSEMBLY` | ble | chunk timeout / missing |
| `RATE_LIMITED` | abuse | per-peer rate exceeded |
| `INTERNAL` | other | unexpected local error (no secrets in message) |

## 3. IPC mapping

`IpcResponse::Error { code, message }` uses codes from this registry. Example: oversized frame → `IPC_FRAME`.

## 4. Vectors

Negative envelope fixtures under `shared-vectors/rvn1/negative/` map to `ENVELOPE_*`. Rust IPC tests cover `IPC_FORBIDDEN_FIELD` behavior (decode error).
